// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

contract MockOracleAdapter is IOracleAdapter {
    struct PriceData {
        uint256 price;
        bool valid;
    }

    mapping(bytes32 => PriceData) public prices;

    function setPrice(bytes calldata data, uint256 price, bool valid) external {
        prices[keccak256(data)] = PriceData(price, valid);
    }

    function getPrice(bytes calldata data, uint256) external view override returns (uint256 price, bool valid) {
        PriceData memory dataPoint = prices[keccak256(data)];
        return (dataPoint.price, dataPoint.valid);
    }
}
