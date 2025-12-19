// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRefinanceAdapter} from "../../src/interfaces/IRefinanceAdapter.sol";

contract MockRefinanceAdapter is IRefinanceAdapter {
    using SafeERC20 for IERC20;

    bool public shouldSucceed;

    function setShouldSucceed(bool value) external {
        shouldSucceed = value;
    }

    function attemptRefinance(
        address borrower,
        address lender,
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint256 repaymentAmount,
        bytes calldata
    ) external override returns (bool success) {
        if (!shouldSucceed) {
            return false;
        }

        IERC20(collateralToken).safeTransferFrom(msg.sender, borrower, collateralAmount);
        IERC20(debtToken).safeTransfer(lender, repaymentAmount);
        return true;
    }
}
