// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RFQRouter} from "../src/RFQRouter.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracleAdapter} from "./mocks/MockOracleAdapter.sol";
import {MockRefinanceAdapter} from "./mocks/MockRefinanceAdapter.sol";

contract GasProfileTest is Test {
    RFQRouter private router;
    MockERC20 private collateralToken;
    MockERC20 private debtToken;
    MockOracleAdapter private oracle;
    MockRefinanceAdapter private refiAdapter;

    address private borrower;
    uint256 private borrowerKey;
    address private lender;
    uint256 private lenderKey;
    address private feeCollector;
    uint256 private feeBps;

    bytes private oracleData;
    bytes private refiAdapterData;

    function setUp() public {
        feeCollector = address(0xFEE);
        feeBps = 100;
        router = new RFQRouter(feeCollector, feeBps);
        collateralToken = new MockERC20("Wrapped BTC", "WBTC", 8);
        debtToken = new MockERC20("USD Coin", "USDC", 6);
        oracle = new MockOracleAdapter();
        refiAdapter = new MockRefinanceAdapter();

        borrowerKey = 0xB0B;
        lenderKey = 0xA11CE;
        borrower = vm.addr(borrowerKey);
        lender = vm.addr(lenderKey);

        oracleData = abi.encodePacked("BTCUSD");
        refiAdapterData = "";

        collateralToken.mint(borrower, 1_000_000_000);
        debtToken.mint(lender, 1_000_000_000_000);
        debtToken.mint(address(refiAdapter), 1_000_000_000_000);

        vm.prank(borrower);
        collateralToken.approve(address(router), type(uint256).max);
        vm.prank(lender);
        debtToken.approve(address(router), type(uint256).max);
        address[] memory adapters = new address[](1);
        adapters[0] = address(refiAdapter);
        router.setRefiAdapters(adapters, true);
    }

    function testGas_OpenLoan() public {
        uint256 collateralAmount = 250_000_000;
        uint256 principal = 5_000_000;
        uint256 repayment = 5_500_000;
        uint256 expiry = block.timestamp + 14 days;
        uint256 callStrike = 40_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            21,
            refiData
        );

        _openLoan(quote, collateralAmount, refiData);
        vm.snapshotGasLastCall("RFQRouter", "openLoan");
    }

    function testGas_SettleDownside() public {
        uint256 collateralAmount = 1_000_000;
        uint256 principal = 2_000_000;
        uint256 repayment = 8_000_000;
        uint256 expiry = block.timestamp + 7 days;
        uint256 callStrike = 30_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            22,
            refiData
        );

        address vault = _openLoan(quote, collateralAmount, refiData);
        oracle.setPrice(oracleData, 1, true); // Value below repayment triggers downside branch.

        vm.warp(expiry);
        LoanVault(vault).settleNormally();
        vm.snapshotGasLastCall("LoanVault", "settle_downside");
    }

    function testGas_SettleMiddleWithRefiEnabled() public {
        uint256 collateralAmount = 500_000_000;
        uint256 principal = 1_500_000;
        uint256 repayment = 3_000_000;
        uint256 expiry = block.timestamp + 10 days;
        uint256 callStrike = 40_000;

        bytes memory refiData = _buildRefiData(true);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            23,
            refiData
        );

        address vault = _openLoan(quote, collateralAmount, refiData);
        oracle.setPrice(oracleData, 10_000, true); // Middle region: repayment covered, below cap.

        vm.warp(expiry);
        vm.prank(borrower);
        LoanVault(vault).settleNormally();
        vm.snapshotGasLastCall("LoanVault", "settle_middle_refi_enabled");
    }

    function testGas_SettleUpside() public {
        uint256 collateralAmount = 350_000_000;
        uint256 principal = 3_000_000;
        uint256 repayment = 4_000_000;
        uint256 expiry = block.timestamp + 9 days;
        uint256 callStrike = 25_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            24,
            refiData
        );

        address vault = _openLoan(quote, collateralAmount, refiData);
        oracle.setPrice(oracleData, 50_000, true); // Upside region: price above cap.

        vm.warp(expiry);
        LoanVault(vault).settleNormally();
        vm.snapshotGasLastCall("LoanVault", "settle_upside");
    }

    function _buildRefiData(bool enableRefi) internal view returns (bytes memory) {
        if (!enableRefi) {
            return "";
        }
        LoanVault.RefiData memory data = LoanVault.RefiData({
            enabled: true,
            adapter: address(refiAdapter),
            gracePeriod: 2 days,
            maxLtvBps: 9_000,
            adapterData: refiAdapterData
        });
        return abi.encode(data);
    }

    function _buildQuote(
        uint256 principal,
        uint256 repayment,
        uint256 minCollateral,
        uint256 expiry,
        uint256 callStrike,
        uint256 nonce,
        bytes memory refiData
    ) internal view returns (RFQRouter.LoanQuote memory) {
        return
            RFQRouter.LoanQuote({
                lender: lender,
                debtToken: address(debtToken),
                collateralToken: address(collateralToken),
                principal: principal,
                repaymentAmount: repayment,
                minCollateralAmount: minCollateral,
                expiry: expiry,
                callStrike: callStrike,
                oracleAdapter: address(oracle),
                oracleDataHash: keccak256(oracleData),
                refiConfigHash: keccak256(refiData),
                deadline: block.timestamp + 1 days,
                nonce: nonce
            });
    }

    function _openLoan(RFQRouter.LoanQuote memory quote, uint256 collateralAmount, bytes memory refiData)
        internal
        returns (address vault)
    {
        bytes32 digest = router.getQuoteDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(borrower);
        vault = router.openLoan(quote, collateralAmount, oracleData, refiData, signature);
    }
}
