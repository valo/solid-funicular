// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRefinanceAdapter} from "../interfaces/IRefinanceAdapter.sol";

/// @notice Minimal interface for the Ethereum Vault Connector batch helper.
interface IEVCMinimal {
    struct BatchItem {
        address targetContract;
        address onBehalfOfAccount;
        uint256 value;
        bytes data;
    }

    function batch(BatchItem[] calldata items) external payable;
}

interface IEVaultLike {
    function asset() external view returns (address);

    function deposit(uint256 amount, address receiver) external returns (uint256);

    function borrow(uint256 amount, address receiver) external returns (uint256);
}

/// @notice Refinance adapter that routes collateral and borrowing through Euler V2 (EVC + EVault).
/// @dev `data` must be `abi.encode(EulerConfig)`.
contract EulerRefinanceAdapter is IRefinanceAdapter {
    using SafeERC20 for IERC20;

    error InvalidConfig();
    error TokenMismatch();

    struct EulerConfig {
        address evc;
        address collateralVault;
        address debtVault;
        /// @dev Euler account to act on behalf of (must have controller + approvals configured). Defaults to this adapter when zero.
        address controllerAccount;
    }

    /// @inheritdoc IRefinanceAdapter
    function attemptRefinance(
        address borrower,
        address lender,
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint256 repaymentAmount,
        bytes calldata data
    ) external override returns (bool success) {
        EulerConfig memory cfg = _decodeConfig(data);
        if (cfg.evc == address(0) || cfg.collateralVault == address(0) || cfg.debtVault == address(0)) {
            revert InvalidConfig();
        }

        address controller = cfg.controllerAccount == address(0) ? address(this) : cfg.controllerAccount;

        // Validate vault assets to avoid accidental cross-token usage.
        if (IEVaultLike(cfg.collateralVault).asset() != collateralToken || IEVaultLike(cfg.debtVault).asset() != debtToken) {
            revert TokenMismatch();
        }

        // Stage collateral and approvals from msg.sender into the controller account.
        IERC20(collateralToken).safeTransferFrom(msg.sender, controller, collateralAmount);
        // Ensure the vault can pull from the controller.
        _forceApprove(collateralToken, controller, cfg.collateralVault, collateralAmount);

        IEVCMinimal.BatchItem[] memory items = new IEVCMinimal.BatchItem[](2);
        items[0] = IEVCMinimal.BatchItem({
            targetContract: cfg.collateralVault,
            onBehalfOfAccount: controller,
            value: 0,
            data: abi.encodeWithSelector(IEVaultLike.deposit.selector, collateralAmount, borrower)
        });
        items[1] = IEVCMinimal.BatchItem({
            targetContract: cfg.debtVault,
            onBehalfOfAccount: controller,
            value: 0,
            data: abi.encodeWithSelector(IEVaultLike.borrow.selector, repaymentAmount, address(this))
        });

        IEVCMinimal(cfg.evc).batch(items);

        IERC20(debtToken).safeTransfer(lender, repaymentAmount);
        return true;
    }

    function _decodeConfig(bytes calldata data) internal pure returns (EulerConfig memory cfg) {
        if (data.length == 0) {
            revert InvalidConfig();
        }
        cfg = abi.decode(data, (EulerConfig));
    }

    function _forceApprove(address token, address owner, address spender, uint256 amount) private {
        if (owner != address(this)) {
            // The adapter cannot set approvals for external controller accounts.
            if (amount > 0) {
                revert InvalidConfig();
            }
            return;
        }
        IERC20(token).forceApprove(spender, amount);
    }
}
