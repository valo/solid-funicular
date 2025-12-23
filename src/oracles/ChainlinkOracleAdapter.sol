// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "foundry-chainlink-toolkit/interfaces/feeds/AggregatorV3Interface.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @notice Oracle adapter that reads from a Chainlink AggregatorV3 price feed.
/// @dev Expects the `data` payload to be `abi.encode(ChainlinkConfig)`.
contract ChainlinkOracleAdapter is IOracleAdapter {
    struct ChainlinkConfig {
        address feed;
        uint256 maxStaleness;
    }

    error InvalidFeed();

    /// @inheritdoc IOracleAdapter
    function getPrice(bytes calldata data, uint256 atTimestamp) external view returns (uint256 price, bool valid) {
        ChainlinkConfig memory config = _decodeConfig(data);
        if (config.feed == address(0)) {
            revert InvalidFeed();
        }

        (
            uint80 roundId,
            int256 answer,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = AggregatorV3Interface(config.feed).latestRoundData();

        if (answer <= 0) {
            return (0, false);
        }
        if (answeredInRound < roundId || updatedAt == 0) {
            return (0, false);
        }
        // Disallow using prices that pre-date the requested timestamp (e.g. loan expiry).
        if (updatedAt < atTimestamp) {
            return (0, false);
        }
        if (config.maxStaleness > 0 && block.timestamp - updatedAt > config.maxStaleness) {
            return (0, false);
        }

        return (uint256(answer), true);
    }

    function _decodeConfig(bytes calldata data) internal pure returns (ChainlinkConfig memory config) {
        if (data.length == 0) {
            revert InvalidFeed();
        }
        config = abi.decode(data, (ChainlinkConfig));
    }
}
