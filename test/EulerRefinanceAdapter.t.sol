// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EulerRefinanceAdapter, IEVCMinimal} from "../src/refinance/EulerRefinanceAdapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockEulerVault} from "./mocks/MockEulerVault.sol";
import {MockEVC} from "./mocks/MockEVC.sol";

contract EulerRefinanceAdapterTest is Test {
    EulerRefinanceAdapter private adapter;
    MockERC20 private collateral;
    MockERC20 private debt;
    MockEulerVault private collateralVault;
    MockEulerVault private debtVault;
    MockEVC private evc;

    address private borrower = address(0xB0B);
    address private lender = address(0xA11CE);
    address private vault = address(0x1234);

    function setUp() public {
        adapter = new EulerRefinanceAdapter();
        collateral = new MockERC20("Collateral", "COL", 18);
        debt = new MockERC20("Debt", "DEBT", 6);
        collateralVault = new MockEulerVault(collateral);
        debtVault = new MockEulerVault(debt);
        evc = new MockEVC();

        // Fund lender vault with debt liquidity.
        debt.mint(address(debtVault), 1_000_000e6);
    }

    function test_AttemptRefinance_Succeeds() public {
        uint256 collateralAmount = 100 ether;
        uint256 repayment = 50_000e6;

        // Collateral sits in the loan vault (msg.sender).
        collateral.mint(vault, collateralAmount);
        vm.prank(vault);
        collateral.approve(address(adapter), collateralAmount);

        EulerRefinanceAdapter.EulerConfig memory cfg = EulerRefinanceAdapter.EulerConfig({
            evc: address(evc),
            collateralVault: address(collateralVault),
            debtVault: address(debtVault),
            controllerAccount: address(0)
        });

        vm.prank(vault);
        bool success = adapter.attemptRefinance(
            borrower,
            lender,
            address(collateral),
            address(debt),
            collateralAmount,
            repayment,
            abi.encode(cfg)
        );

        assertTrue(success);
        assertEq(collateralVault.deposits(borrower), collateralAmount);
        assertEq(debt.balanceOf(lender), repayment);
    }

    function test_AttemptRefinance_RevertsOnTokenMismatch() public {
        EulerRefinanceAdapter.EulerConfig memory cfg = EulerRefinanceAdapter.EulerConfig({
            evc: address(evc),
            collateralVault: address(debtVault), // mismatched asset on purpose
            debtVault: address(debtVault),
            controllerAccount: address(0)
        });

        vm.expectRevert(EulerRefinanceAdapter.TokenMismatch.selector);
        adapter.attemptRefinance(
            borrower,
            lender,
            address(collateral),
            address(debt),
            1,
            1,
            abi.encode(cfg)
        );
    }
}
