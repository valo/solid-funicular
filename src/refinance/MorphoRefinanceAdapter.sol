// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRefinanceAdapter} from "../interfaces/IRefinanceAdapter.sol";
import {IMorpho, MarketParams} from "morpho-blue/src/interfaces/IMorpho.sol";

contract MorphoRefinanceAdapter is IRefinanceAdapter {
    using SafeERC20 for IERC20;

    error InvalidMorpho();
    error TokenMismatch();

    IMorpho public immutable morpho;

    constructor(address morpho_) {
        if (morpho_ == address(0)) {
            revert InvalidMorpho();
        }
        morpho = IMorpho(morpho_);
    }

    /// @notice Attempts to refinance using Morpho Blue.
    /// @dev Expects data = abi.encode(MarketParams, bytes callbackData).
    function attemptRefinance(
        address borrower,
        address lender,
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint256 repaymentAmount,
        bytes calldata data
    ) external override returns (bool success) {
        (MarketParams memory params, bytes memory callbackData) = abi.decode(data, (MarketParams, bytes));

        if (params.collateralToken != collateralToken || params.loanToken != debtToken) {
            revert TokenMismatch();
        }

        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), collateralAmount);
        IERC20(collateralToken).forceApprove(address(morpho), collateralAmount);

        morpho.supplyCollateral(params, collateralAmount, borrower, callbackData);
        morpho.borrow(params, repaymentAmount, 0, borrower, lender);

        return true;
    }
}
