//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.1;
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import '@openzeppelin/contracts/access/Ownable.sol';

import '../interface/IPancakePair.sol';
import '../interface/IPancakeRouter.sol';
import '../interface/IPancakeFarm.sol';
/**
 * pancakeswapLP farm strategy 
 */
contract LPFarmStrategy is  ReentrancyGuard, Context, Ownable{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
 
    event Harvest(address indexed token, uint256 indexed balanceToken);
    event Sweep(address indexed token, address indexed recipient, uint256 amount);
    event SetDispatcher(address indexed dispatcher);
    event SetSwapLimit(uint256 swapLimit);
    event SetPoolId(uint256 poolId);
    event SetWaitTime(uint256 time);

    address immutable public  lptoken;
    address immutable public  router;
    address immutable public  farm ;
    address immutable public  farmRewardToken ;
    uint256 public swapLimit = 1e3;
    uint256 public poolId = 0;
    uint256 public waitTime = 300;
    address public dispatcher;

    modifier onlyDispatcher() {
        require(_msgSender() == dispatcher, "LPFarmStrategy:sender is not dispatcher");
        _;
    }

    constructor(
        address _lptoken,
        address _farmRewardToken,
        address _router,
        address _farm,
        address _dispatcher
    ) {
        require(_lptoken != address(0), "_lptoken is zero address");
        require(_router != address(0), "_router is zero address");
        require(_farm != address(0), "_farm is zero address");
        require(_farmRewardToken != address(0), "_farmRewardToken is zero address");
        require(_dispatcher != address(0), "_dispatcher is zero address");
        lptoken = _lptoken;
        router = _router;
        farm = _farm;
        farmRewardToken = _farmRewardToken;
        dispatcher = _dispatcher;
    }
    
     // Call initApprove before calling
    function withdrawToDispatcher(uint256 leaveAmount, address token) external onlyDispatcher  {
        require(leaveAmount > 0, "LPFarmStrategy: leaveAmount is zero");
        IPancakeFarm pancakeFarm = IPancakeFarm(farm);
        pancakeFarm.withdraw(poolId, leaveAmount);
        IPancakePair pair = IPancakePair(lptoken);
        IPancakeRouter(router).removeLiquidity(pair.token0(), pair.token1(), leaveAmount, 0, 0, dispatcher, block.timestamp.add(waitTime)); 
        harvest(token);
    }

    function harvest(address token) public onlyDispatcher{
        IPancakeFarm pancakeFarm = IPancakeFarm(farm);
        (uint256 amount,) = pancakeFarm.userInfo(poolId, address(this));
        if (amount > 0) {
            IPancakeFarm(farm).withdraw(poolId, 0);
        }
        IPancakePair pair = IPancakePair(lptoken);
        uint256 balanceReward = IERC20(farmRewardToken).balanceOf(address(this));
        uint256 balanceA =  IERC20(pair.token0()).balanceOf(address(this));
        uint256 balanceB =  IERC20(pair.token1()).balanceOf(address(this));

        if(balanceReward > 0 && farmRewardToken != pair.token0() &&  pair.token1() != farmRewardToken) {
            address[] memory path = new address[](2);
            path[0] = farmRewardToken;
            path[1] = pair.token0();
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(balanceReward, 0 ,path, address(this), block.timestamp.add(waitTime));
        }
        (uint256 reserveA, uint256 reserveB) = getReserves(lptoken);
        if (token == pair.token0()) {
            address[] memory path = new address[](2);
            path[0] = pair.token1();
            path[1] = pair.token0();
            uint256 amountBOptimal = 0;
            if ( balanceA > 0 ) {
                amountBOptimal = quote(balanceA, reserveA, reserveB);
            }
            uint256 swapAmount = balanceB.sub(amountBOptimal).div(2);
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, 0 ,path, address(this), block.timestamp.add(waitTime));
        } else {
            address[] memory path = new address[](2);
            path[0] = pair.token0();
            path[1] = pair.token1();
            uint256 amountAOptimal =0;
            if ( balanceB > 0 ) {
                amountAOptimal = quote(balanceB, reserveB, reserveA);
            }
            uint256 swapAmount = balanceA.sub(amountAOptimal).div(2);
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, 0 ,path, address(this), block.timestamp.add(waitTime));
        }
        uint256 balanceToken = IERC20(token).balanceOf(address(this));
        if (balanceToken > 0) {
            IERC20(token).safeTransfer(dispatcher, balanceToken);
        }
        emit Harvest(token, balanceToken);
    }

    // Call initApprove before calling
    function executeStrategy() external onlyDispatcher nonReentrant{
        IPancakePair pair = IPancakePair(lptoken);
        uint256 balanceA =  IERC20(pair.token0()).balanceOf(address(this));
        uint256 balanceB =  IERC20(pair.token1()).balanceOf(address(this));
        require(balanceA > 0 || balanceB > 0, "LPFarmStrategy: balanceA and balanceB are zero");
        (uint256 reserveA, uint256 reserveB) = getReserves(lptoken);
        uint256 timesOfA = reserveB.mul(balanceB).div(reserveA); //
        if(balanceA > timesOfA.add(swapLimit)) {
            address[] memory path = new address[](2);
            path[0] = pair.token0();
            path[1] = pair.token1();
            uint256 amountAOptimal =0;
            if ( balanceB > 0 ) {
                amountAOptimal = quote(balanceB, reserveB, reserveA);
            }
            uint256 swapAmount = balanceA.sub(amountAOptimal).div(2);
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, 0 ,path, address(this), block.timestamp.add(waitTime));
        } else if(timesOfA > balanceA.add(swapLimit)) {
            address[] memory path = new address[](2);
            path[0] = pair.token1();
            path[1] = pair.token0();
            uint256 amountBOptimal = 0;
            if ( balanceA > 0 ) {
                amountBOptimal = quote(balanceA, reserveA, reserveB);
            }
            uint256 swapAmount = balanceB.sub(amountBOptimal).div(2);
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, 0 ,path, address(this), block.timestamp.add(waitTime));
        }
        balanceA = IERC20(pair.token0()).balanceOf(address(this));
        balanceB = IERC20(pair.token1()).balanceOf(address(this));
        IPancakeRouter(router).addLiquidity(pair.token0(), pair.token1(), balanceA, balanceB, 0, 0, address(this), block.timestamp.add(waitTime));
        IPancakeFarm(farm).deposit(poolId, pair.balanceOf(address(this)));
    }

    function totalAmount() external view returns(uint256) {
        IPancakeFarm pancakeFarm = IPancakeFarm(farm);
        (uint256 amount,) = pancakeFarm.userInfo(poolId, address(this));
        return amount;
    }

    // fetches and sorts the reserves for a pair
    function getReserves(
        address _lptoken
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
         address tokenA =  IPancakePair(_lptoken).token0();
         address tokenB =  IPancakePair(_lptoken).token1();
        (address token0, ) = sortTokens(tokenA, tokenB);
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(_lptoken).getReserves();
        (reserveA, reserveB) = tokenA == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        require(amountA > 0, "LPFarmStrategy: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "LPFarmStrategy: INSUFFICIENT_LIQUIDITY");
        amountB = amountA.mul(reserveB) / reserveA;
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "LPFarmStrategy: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "LPFarmStrategy: ZERO_ADDRESS");
    }

    function setDispatcher(address _dispatcher) external onlyDispatcher{
        require(_dispatcher != address(0), "LPFarmStrategy: ZERO_ADDRESS");
        dispatcher = _dispatcher;
        emit SetDispatcher(dispatcher);
    }

    function sweep(address stoken, address recipient) external onlyOwner {
      require(recipient != address(0), "LPFarmStrategy: ZERO_ADDRESS");
       uint256 balance = IERC20(stoken).balanceOf(address(this));
       if(balance > 0) {
           IERC20(stoken).safeTransfer(recipient, balance);
           emit Sweep(stoken, recipient, balance);
       }
    }

    function setSwapLimit(uint256 _swapLimit) external onlyOwner {
       swapLimit = _swapLimit;
       emit SetSwapLimit(swapLimit);
    }

    function setPoolId(uint256 _poolId) external onlyOwner {
        poolId = _poolId;
        emit SetPoolId(poolId);
    }

    function setWaitTime(uint256 time) external onlyOwner {
        waitTime = time;
        emit SetWaitTime(time);
    }

    function approveTokenToRouter(address token,  uint256 amount) public onlyOwner{
        require(amount > 0, "LPFarmStrategy: INSUFFICIENT_AMOUNT");
        IERC20(token).approve(router, amount);
    }

    function approveLptokenToFarm( uint256 amount) public onlyOwner{
        require(amount > 0, "LPFarmStrategy: INSUFFICIENT_AMOUNT");
        IERC20(lptoken).approve(farm, amount);
    }

    function initApprove() external onlyOwner{
        approveTokenToRouter(IPancakePair(lptoken).token0(), ~uint256(0));
        approveTokenToRouter(IPancakePair(lptoken).token1(), ~uint256(0));
        approveTokenToRouter(farmRewardToken, ~uint256(0));
        approveTokenToRouter(lptoken, ~uint256(0));
        approveLptokenToFarm( ~uint256(0));
    }
}