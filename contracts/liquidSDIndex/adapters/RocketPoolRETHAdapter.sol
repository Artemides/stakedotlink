// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.15;

import "../base/LiquidSDAdapter.sol";
import "../interfaces/IRocketPoolRETH.sol";

/**
 * @title RocketPool rETH Adapter
 * @notice Adapter for RocketPool's rETH
 */
contract RocketPoolRETHAdapter is LiquidSDAdapter {
    function initialize(address _token, address _indexPool) public initializer {
        __LiquidSDAdapter_init(_token, _indexPool);
    }

    /**
     * @notice returns the exchange rate between this adapter's token and the underlying asset
     * @return exchange rate
     */
    function getExchangeRate() public view override returns (uint256) {
        return IRocketPoolRETH(address(token)).getExchangeRate();
    }
}
