// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IEVaultLike} from "../../src/refinance/EulerRefinanceAdapter.sol";

interface IEVCContext {
    function currentAccount() external view returns (address);
}

/// @dev Lightweight stand-in for an Euler EVault to exercise the refinance adapter.
contract MockEulerVault is IEVaultLike {
    using SafeERC20 for IERC20;

    IERC20 public immutable underlying;

    mapping(address => uint256) public deposits;

    constructor(IERC20 asset_) {
        underlying = asset_;
    }

    function deposit(uint256 amount, address receiver) external override returns (uint256) {
        address payer = msg.sender;
        if (msg.sender.code.length > 0) {
            // Allow a mock EVC to forward an on-behalf-of account.
            try IEVCContext(msg.sender).currentAccount() returns (address account) {
                if (account != address(0)) {
                    payer = account;
                }
            } catch {}
        }

        underlying.safeTransferFrom(payer, address(this), amount);
        deposits[receiver] += amount;
        return amount;
    }

    function borrow(uint256 amount, address receiver) external override returns (uint256) {
        if (amount > underlying.balanceOf(address(this))) {
            revert("insufficient");
        }
        underlying.safeTransfer(receiver, amount);
        return amount;
    }

    // Minimal interface surface needed by the adapter.
    function asset() external view override returns (address) {
        return address(underlying);
    }
}
