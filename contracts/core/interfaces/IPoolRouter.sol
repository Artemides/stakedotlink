// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

interface IPoolRouter {
    function isReservedMode() external view returns (bool);

    function getReservedMultiplier() external view returns (uint256);

    function poolUtilisation(address _token, uint16 _index) external view returns (uint256);
}
