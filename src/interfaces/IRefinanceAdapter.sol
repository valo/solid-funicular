// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRefinanceAdapter {
    /// @notice Attempts to refinance by opening an external lending position.
    /// @return success Whether refinancing succeeded and lender was repaid in full.
    function attemptRefinance(
        address borrower,
        address lender,
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint256 repaymentAmount,
        bytes calldata data
    ) external returns (bool success);
}
