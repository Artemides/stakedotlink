// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

import "./IERC677.sol";

interface ILendingPool is IERC677 {
    function currentRate(address _token, uint16 _index) external view returns (uint256);

    function stakeAllowance(address _account, uint _amount) external;
}
