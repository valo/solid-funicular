// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracleAdapter {
    /// @notice Returns the BTC price in the same units expected by the loan terms.
    /// @param data Oracle-specific payload.
    /// @param atTimestamp Timestamp to read a price at/near.
    /// @return price BTC/USD price in adapter-defined units.
    /// @return valid Whether the returned price is valid.
    function getPrice(bytes calldata data, uint256 atTimestamp) external view returns (uint256 price, bool valid);
}
