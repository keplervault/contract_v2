//SPDX-License-Identifier: Unlicense
pragma solidity 0.8.1;
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import '@openzeppelin/contracts/access/Ownable.sol';

import '../interface/IPancakePair.sol';
import '../interface/IPancakeRouter.sol';
import '../interface/IPancakeFarm.sol';
import '../interface/IStrategy.sol';
/**
 * pancakeswapLP farm strategy 
 */
contract LPFarmStrategy is  ReentrancyGuard, Context, Ownable, IStrategy{
    using SafeERC20 for IERC20;
 
    event Harvest(address indexed token, uint256 indexed balanceToken);

    address immutable public  lptoken;
    address immutable public  router;
    address immutable public  farm ;
    address immutable public  farmRewardToken ;
    uint256 immutable public swapLimit;
    uint256 immutable public poolId;
    uint256 immutable public waitTime;
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
        address _dispatcher,
        uint256 _swapLimit,
        uint256 _poolId,
        uint256 _waitTime
    ) {
        require(_lptoken != address(0), "_lptoken is zero address");
        require(_router != address(0), "_router is zero address");
        require(_farm != address(0), "_farm is zero address");
        require(_farmRewardToken != address(0), "_farmRewardToken is zero address");
        require(_dispatcher != address(0), "_dispatcher is zero address");
        require(_swapLimit > 0, "_swapLimit is zero");
        require(_poolId > 0, "_poolId is zero");
        require(_waitTime > 0, "_waitTime is zero");
        lptoken = _lptoken;
        router = _router;
        farm = _farm;
        farmRewardToken = _farmRewardToken;
        dispatcher = _dispatcher;
        swapLimit = _swapLimit;
        poolId = _poolId;
        waitTime = _waitTime;

        IERC20(IPancakePair(_lptoken).token0()).approve(_router, ~uint256(0));
        IERC20(IPancakePair(_lptoken).token1()).approve(_router, ~uint256(0));
        IERC20(_farmRewardToken).approve(_router, ~uint256(0));
        IERC20(_lptoken).approve(_router, ~uint256(0));
        IERC20(_lptoken).approve(_farm, ~uint256(0));
    }
    
     // Call initApprove before calling
    function withdrawToDispatcher(uint256 leaveAmount, address token) external override onlyDispatcher  {
        require(leaveAmount > 0, "LPFarmStrategy: leaveAmount is zero");
        IPancakeFarm pancakeFarm = IPancakeFarm(farm);
        pancakeFarm.withdraw(poolId, leaveAmount);
        IPancakePair pair = IPancakePair(lptoken);
        IPancakeRouter(router).removeLiquidity(pair.token0(), pair.token1(), leaveAmount, 0, 0, dispatcher, block.timestamp + waitTime); 
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
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(balanceReward, 1,path, address(this), block.timestamp + waitTime);
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
            require(balanceB > amountBOptimal, "amountBOptimal value too large");
            uint256 swapAmount = (balanceB - amountBOptimal) / 2;
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, 1,path, address(this), block.timestamp + waitTime);
        } else if(token == pair.token1()) {
            address[] memory path = new address[](2);
            path[0] = pair.token0();
            path[1] = pair.token1();
            uint256 amountAOptimal =0;
            if ( balanceB > 0 ) {
                amountAOptimal = quote(balanceB, reserveB, reserveA);
            }
            require(balanceA > amountAOptimal, "amountAOptimal value too large");
            uint256 swapAmount = (balanceA - amountAOptimal) / 2;
            IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(swapAmount, 1,path, address(this), block.timestamp + waitTime);
        }
        uint256 balanceToken = IERC20(token).balanceOf(address(this));
        if (balanceToken > 0) {
            IERC20(token).safeTransfer(dispatcher, balanceToken);
        }
        emit Harvest(token, balanceToken);
    }

    // Call initApprove before calling
    function executeStrategy() external override onlyDispatcher nonReentrant{
        IPancakePair pair = IPancakePair(lptoken);
        uint256 balanceA = IERC20(pair.token0()).balanceOf(address(this));
        uint256 balanceB = IERC20(pair.token1()).balanceOf(address(this));
        require(balanceA > 0 || balanceB > 0, "LPFarmStrategy: balanceA and/or balanceB are zero");
        IPancakeRouter(router).addLiquidity(pair.token0(), pair.token1(), balanceA, balanceB, 1, 1, address(this), block.timestamp + waitTime);
        IPancakeFarm(farm).deposit(poolId, pair.balanceOf(address(this)));
    }

    function totalAmount() external override view returns(uint256) {
        IPancakeFarm pancakeFarm = IPancakeFarm(farm);
        (uint256 amount,) = pancakeFarm.userInfo(poolId, address(this));
        return amount;
    }

    // fetches and sorts the reserves for a pair
    function getReserves(
        address _lptoken
    ) internal view returns (uint256, uint256) {
        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(_lptoken).getReserves();
        return (reserve0, reserve1);
    }

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) internal pure returns (uint256 amountB) {
        require(amountA > 0, "LPFarmStrategy: INSUFFICIENT_AMOUNT");
        require(reserveA > 0 && reserveB > 0, "LPFarmStrategy: INSUFFICIENT_LIQUIDITY");
        amountB = amountA * reserveB / reserveA;
    }
}