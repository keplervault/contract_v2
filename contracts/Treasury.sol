// SPDX-License-Identifier: MIT
pragma solidity 0.8.1;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interface/IStrategy.sol";

contract Treasury is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable tetherToken;
    address public lpStrategy;
    uint256 public totalAmount = 0;
    uint256 private constant minLock = 100 ether;
    uint256 private oid = 1;
    bool public isInit = true;

    struct Account {
        uint256 amount;
    }

    struct Order {
        address who;
        uint256 amount;
        uint256 timeOfStart;
        uint256 timeOfEnd;
        uint256 day;
        bool isFinish;
    }

    mapping(uint256 => Order) private _orders;
    mapping(address => Account) private _accounts;
    mapping(address => uint256[]) private _ordersRecord;

    event Deposit(address indexed who, uint256 amount);
    event Withdraw(address indexed who, uint256 amount, uint256 left);
    event LockByCurrent(address indexed who, uint256 indexed id, uint256 amount, uint256 timeOfStart, uint256 timeOfEnd, uint256 day);
    event LockByWallet(address indexed who, uint256 indexed id, uint256 amount, uint256 timeOfStart, uint256 timeOfEnd, uint256 day);
    event UnLock(address indexed who, uint256 indexed id, uint256 amount);
    event ExtLock(address indexed who, uint256 indexed id, uint256 timeOfStart, uint256 timeOfEnd, uint256 day);
    event SetLpStrategy(address lpStrategy);

    fallback() external payable {}

    receive() external payable {}

    constructor(address _tetherToken) {
        require(_tetherToken != address(0), "_token is zero address");
        tetherToken = _tetherToken;
    }

    function balanceOf(address _who) public view returns (uint256) {
        return _accounts[_who].amount;
    }

    function getOrder(uint256 _id) external view returns (Order memory) {
        return _orders[_id];
    }

    function getOrderRecord(address _addr) external view returns (uint256[] memory) {
        return _ordersRecord[_addr];
    }

    function deposit(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Treasury: _amount is zero");
        address sender = msg.sender;
        if (_accounts[sender].amount == 0) {
            _accounts[sender].amount = _amount;
        } else {
            _accounts[sender].amount += _amount;
        }
        totalAmount += _amount;
        IERC20(tetherToken).safeTransferFrom(sender, address(this), _amount);
        IERC20(tetherToken).safeTransfer(lpStrategy, _amount);
        IStrategy(lpStrategy).executeStrategy();
        emit Deposit(sender, _amount);
    }

    function withdraw(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Treasury: _amount is zero");
        require(balanceOf(msg.sender) >= _amount, "Insufficient balance");

        uint256 quantity = (_amount * 99) / 100;
        uint256 lpAmount = IStrategy(lpStrategy).totalAmount();
        uint256 leavePercent = (_amount * lpAmount) / totalAmount;
        _accounts[msg.sender].amount -= _amount;
        totalAmount -= _amount;

        IStrategy(lpStrategy).withdrawToDispatcher(leavePercent, tetherToken);
        IERC20(tetherToken).safeTransfer(msg.sender, quantity);
        emit Withdraw(msg.sender, _amount, quantity);
    }

    function lockByCurrent(uint256 _amount, uint256 _day) external nonReentrant {
        require(_amount >= minLock, "Amount must be larger than 100");
        require(balanceOf(msg.sender) >= _amount, "Insufficient balance");
        require(_day > 0, "Invalid _day");

        _accounts[msg.sender].amount -= _amount;
        uint256 timeOfStart = block.timestamp;
        uint256 timeOfEnd = timeOfStart + (_day * 1 days);

        _orders[oid] = Order({
            who: msg.sender,
            amount: _amount,
            timeOfStart: timeOfStart,
            timeOfEnd: timeOfEnd,
            day: _day,
            isFinish: false
        });
        _ordersRecord[msg.sender].push(oid);
        emit LockByCurrent(msg.sender, oid, _amount, timeOfStart, timeOfEnd, _day);
        oid += 1;
    }

    function lockByWallet(uint256 _amount, uint256 _day) external nonReentrant {
        require(_amount >= minLock, "Amount must be larger than 100");
        require(_day > 0, "Invalid _day");


        uint256 timeOfStart = block.timestamp;
        uint256 timeOfEnd = timeOfStart + (_day * 1 days);

        _orders[oid] = Order({
            who: msg.sender,
            amount: _amount,
            timeOfStart: timeOfStart,
            timeOfEnd: timeOfEnd,
            day: _day,
            isFinish: false
        });
        _ordersRecord[msg.sender].push(oid);
        oid += 1;
        IERC20(tetherToken).safeTransferFrom(msg.sender, address(this), _amount);
        emit LockByWallet(msg.sender, oid, _amount, timeOfStart, timeOfEnd, _day);
    }

    function unlock(uint256 _orderId) external nonReentrant {
        require(_orders[_orderId].who == msg.sender, "Invalid who");
        require(_orders[_orderId].amount > 0, "Invalid amount");
        require(_orders[_orderId].isFinish == false, "order already finished");
        require(block.timestamp > _orders[_orderId].timeOfEnd, "time not expired");
        _orders[_orderId].isFinish = true;
        _accounts[msg.sender].amount += _orders[_orderId].amount;
        emit UnLock(msg.sender, _orderId, _orders[_orderId].amount);
    }

    function extendlock(uint256 _orderId, uint256 _day) external nonReentrant {
        require(_orders[_orderId].who == msg.sender, "Invalid who");
        require(_orders[_orderId].isFinish == false, "order already finished");
        require(_orders[_orderId].timeOfEnd > block.timestamp, "Order already expired");
        require(_orders[_orderId].amount > 0, "Invalid amount");
        require(_orders[_orderId].day <= _day, "extend day must large create day");
        _orders[_orderId].timeOfStart = block.timestamp;
        _orders[_orderId].timeOfEnd = block.timestamp + _day * 1 days;
        _orders[_orderId].day = _day;
        emit ExtLock(msg.sender, _orderId, _orders[_orderId].timeOfStart, _orders[_orderId].timeOfEnd, _day);
    }

    function setLpStrategy(address _lpStrategy) external onlyOwner {
        require(isInit, "already init");
        require(_lpStrategy != address(0), "_lpStrategy is zero address");
        lpStrategy = _lpStrategy;
        isInit = false;
        emit SetLpStrategy(_lpStrategy);
    }
}
