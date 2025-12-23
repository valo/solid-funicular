// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "foundry-chainlink-toolkit/interfaces/feeds/AggregatorV3Interface.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";

contract ChainlinkOracleAdapterTest is Test {
    ChainlinkOracleAdapter private adapter;
    MockAggregator private feed;

    function setUp() public {
        adapter = new ChainlinkOracleAdapter();
        feed = new MockAggregator(8, 30_000e8);
    }

    function test_ReadsFreshPrice() public view {
        ChainlinkOracleAdapter.ChainlinkConfig memory cfg =
            ChainlinkOracleAdapter.ChainlinkConfig({feed: address(feed), maxStaleness: 1 hours});
        (uint256 price, bool valid) = adapter.getPrice(abi.encode(cfg), block.timestamp);
        assertTrue(valid);
        assertEq(price, uint256(30_000e8));
    }

    function test_ReturnsFalseWhenStale() public {
        ChainlinkOracleAdapter.ChainlinkConfig memory cfg =
            ChainlinkOracleAdapter.ChainlinkConfig({feed: address(feed), maxStaleness: 1 hours});
        vm.warp(block.timestamp + 3 hours);
        feed.setManualRound(2, 25_000e8, block.timestamp - 2 hours, block.timestamp - 2 hours, 2);

        (uint256 price, bool valid) = adapter.getPrice(abi.encode(cfg), block.timestamp);
        assertFalse(valid);
        assertEq(price, 0);
    }

    function test_ReturnsFalseWhenAnsweredInRoundMismatch() public {
        ChainlinkOracleAdapter.ChainlinkConfig memory cfg =
            ChainlinkOracleAdapter.ChainlinkConfig({feed: address(feed), maxStaleness: 0});
        feed.setManualRound(5, 28_000e8, block.timestamp, block.timestamp, 4);

        (uint256 price, bool valid) = adapter.getPrice(abi.encode(cfg), block.timestamp);
        assertFalse(valid);
        assertEq(price, 0);
    }

    function test_ReturnsFalseWhenPriceBeforeRequestedTimestamp() public {
        ChainlinkOracleAdapter.ChainlinkConfig memory cfg =
            ChainlinkOracleAdapter.ChainlinkConfig({feed: address(feed), maxStaleness: 0});
        // Feed updated now, but request a price for a later timestamp.
        uint256 atTimestamp = block.timestamp + 1 hours;

        (uint256 price, bool valid) = adapter.getPrice(abi.encode(cfg), atTimestamp);
        assertFalse(valid);
        assertEq(price, 0);
    }

    function test_RevertsOnEmptyData() public {
        vm.expectRevert(ChainlinkOracleAdapter.InvalidFeed.selector);
        adapter.getPrice("", block.timestamp);
    }
}

contract MockAggregator is AggregatorV3Interface {
    uint8 private immutable _decimals;
    string private constant _DESCRIPTION = "Mock BTC/USD";
    uint256 public constant VERSION = 1;

    uint80 private _roundId;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;
    uint80 private _answeredInRound;

    constructor(uint8 decimals_, int256 initialAnswer) {
        _decimals = decimals_;
        _roundId = 1;
        _answer = initialAnswer;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
        _answeredInRound = 1;
    }

    function setManualRound(
        uint80 roundId_,
        int256 answer_,
        uint256 startedAt_,
        uint256 updatedAt_,
        uint80 answeredInRound_
    ) external {
        _roundId = roundId_;
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
        _answeredInRound = answeredInRound_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return _DESCRIPTION;
    }

    function version() external pure override returns (uint256) {
        return VERSION;
    }

    function getRoundData(uint80)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
