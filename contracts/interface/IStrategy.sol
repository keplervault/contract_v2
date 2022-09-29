// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.0;

interface IStrategy {
     function executeStrategy() external;
     function totalAmount() external view returns(uint256);
     function withdrawToDispatcher(uint256 leaveAmount, address token) external;
} 