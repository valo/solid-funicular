// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

import {RFQRouter} from "../src/RFQRouter.sol";
import {LoanVault} from "../src/LoanVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracleAdapter} from "./mocks/MockOracleAdapter.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";
import {MockRefinanceAdapter} from "./mocks/MockRefinanceAdapter.sol";

contract LoanProtocolTest is Test {
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

    function test_OpenLoanAndSettle_DefaultCase() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 100_000_000;
        uint256 repayment = 200_000_000;
        uint256 expiry = block.timestamp + 7 days;
        uint256 callStrike = 2_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            1,
            refiData
        );
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 1, true);

        vm.warp(expiry);
        LoanVault(vault).settleNormally();

        assertEq(LoanVault(vault).collateralForLender(), collateralAmount);
        assertEq(LoanVault(vault).collateralForBorrower(), 0);

        vm.prank(lender);
        LoanVault(vault).claimLender();
        assertEq(collateralToken.balanceOf(lender), collateralAmount);
    }

    function test_OpenLoanAndSettle_MiddleCase() public {
        uint256 collateralAmount = 500_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 5_000_000;
        uint256 expiry = block.timestamp + 10 days;
        uint256 callStrike = 200;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            2,
            refiData
        );
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 100, true);

        vm.warp(expiry);
        LoanVault(vault).settleNormally();

        uint256 lenderAmount = LoanVault(vault).collateralForLender();
        uint256 borrowerAmount = LoanVault(vault).collateralForBorrower();
        assertEq(lenderAmount + borrowerAmount, collateralAmount);
    }

    function test_OpenLoanAndSettle_MoonCase() public {
        uint256 collateralAmount = 500_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 5_000_000;
        uint256 expiry = block.timestamp + 12 days;
        uint256 callStrike = 200;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            3,
            refiData
        );
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 300, true);

        vm.warp(expiry);
        LoanVault(vault).settleNormally();

        uint256 lenderAmount = LoanVault(vault).collateralForLender();
        uint256 borrowerAmount = LoanVault(vault).collateralForBorrower();
        assertEq(lenderAmount + borrowerAmount, collateralAmount);
        assertGt(lenderAmount, 0);
    }

    function test_OpenLoan_ChargesUnderwritingFee() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 2_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 180 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            14,
            refiData
        );

        uint256 feeAtOrigination = _feeForQuoteAt(quote, block.timestamp);
        uint256 feeCollectorBefore = debtToken.balanceOf(feeCollector);

        _openLoan(quote, collateralAmount, refiData);

        assertEq(debtToken.balanceOf(feeCollector), feeCollectorBefore + feeAtOrigination);
    }

    function test_AttemptRefinance_Succeeds() public {
        uint256 collateralAmount = 500_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 5_000_000;
        uint256 expiry = block.timestamp + 5 days;
        uint256 callStrike = 200;

        bytes memory refiData = _buildRefiData(true);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            4,
            refiData
        );
        uint256 feeAtOrigination = _feeForQuoteAt(quote, block.timestamp);
        refiAdapter.setShouldSucceed(true);
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 100, true);
        vm.warp(expiry);

        bool success = LoanVault(vault).attemptRefinance();
        assertTrue(success);
        assertEq(debtToken.balanceOf(lender), 1_000_000_000_000 - principal - feeAtOrigination + repayment);
        assertEq(collateralToken.balanceOf(borrower), 1_000_000_000);
    }

    function test_AttemptRefinance_FailsThenSettleAfterGrace() public {
        uint256 collateralAmount = 500_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 5_000_000;
        uint256 expiry = block.timestamp + 5 days;
        uint256 callStrike = 200;

        bytes memory refiData = _buildRefiData(true);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            5,
            refiData
        );
        refiAdapter.setShouldSucceed(false);
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 100, true);
        vm.warp(expiry);

        bool success = LoanVault(vault).attemptRefinance();
        assertFalse(success);

        vm.warp(expiry + 3 days);
        LoanVault(vault).settleNormally();
        assertEq(LoanVault(vault).collateralForLender() + LoanVault(vault).collateralForBorrower(), collateralAmount);
    }

    function test_Settle_RevertsBeforeExpiry() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 5 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            6,
            refiData
        );
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 100, true);

        vm.expectRevert(LoanVault.NotExpired.selector);
        LoanVault(vault).settleNormally();
    }

    function test_Settle_RevertsOnInvalidOracle() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 5 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            7,
            refiData
        );
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 0, true);
        vm.warp(expiry);
        vm.expectRevert(LoanVault.InvalidOracle.selector);
        LoanVault(vault).settleNormally();
    }

    function test_SetFeeConfig_OnlyOwner() public {
        address newCollector = address(0x1234);
        uint256 newFeeBps = 200;
        router.setFeeConfig(newCollector, newFeeBps);
        assertEq(router.feeCollector(), newCollector);
        assertEq(router.feeBps(), newFeeBps);
    }

    function test_SetFeeConfig_RevertsForNonOwner() public {
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, borrower));
        router.setFeeConfig(address(0x1234), 1);
    }

    function test_SetRefiAdapters_RevertsForNonOwner() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(refiAdapter);
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, borrower));
        router.setRefiAdapters(adapters, true);
    }

    function test_ViewHelpers_OracleAndRefiHash() public view {
        bytes memory data = abi.encodePacked("BTCUSD-HASH");
        bytes memory refiData = _buildRefiData(true);
        assertEq(router.computeOracleDataHash(data), keccak256(data));
        assertEq(router.computeRefiConfigHash(refiData), keccak256(refiData));
    }

    function test_PreviewFee_MatchesFeeCalc() public view {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 2_000_000;
        uint256 repayment = 2_500_000;
        uint256 expiry = block.timestamp + 30 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            16,
            refiData
        );

        uint256 expectedFee = _feeForQuoteAt(quote, block.timestamp);
        uint256 preview = router.previewFee(quote.principal, quote.expiry, block.timestamp);
        assertEq(preview, expectedFee);
    }

    function test_PreviewFee_RevertsIfExpiredAtTimestamp() public {
        vm.expectRevert(RFQRouter.LoanExpired.selector);
        router.previewFee(1, block.timestamp - 1, block.timestamp);
    }

    function test_OpenLoan_RefiAdapterMustBeWhitelisted() public {
        address[] memory adapters = new address[](1);
        adapters[0] = address(refiAdapter);
        router.setRefiAdapters(adapters, false);

        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 7 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(true);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            15,
            refiData
        );

        bytes32 digest = router.getQuoteDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(borrower);
        vm.expectRevert(RFQRouter.RefiAdapterNotWhitelisted.selector);
        router.openLoan(quote, collateralAmount, oracleData, refiData, signature);
    }

    function test_OpenLoan_ReplayNonce() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 7 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            8,
            refiData
        );
        _openLoan(quote, collateralAmount, refiData);
        assertTrue(router.usedNonces(lender, quote.nonce));

        bytes32 digest = router.getQuoteDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(RFQRouter.NonceUsed.selector);
        vm.prank(borrower);
        router.openLoan(quote, collateralAmount, oracleData, refiData, signature);
    }

    function test_OpenLoan_InvalidSignature() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 7 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            9,
            refiData
        );

        bytes32 digest = router.getQuoteDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(borrowerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(borrower);
        vm.expectRevert(RFQRouter.InvalidSignature.selector);
        router.openLoan(quote, collateralAmount, oracleData, refiData, signature);
    }

    function test_OpenLoan_ExpiredQuote() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 7 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = RFQRouter.LoanQuote({
            lender: lender,
            debtToken: address(debtToken),
            collateralToken: address(collateralToken),
            principal: principal,
            repaymentAmount: repayment,
            minCollateralAmount: collateralAmount,
            expiry: expiry,
            callStrike: callStrike,
            oracleAdapter: address(oracle),
            oracleDataHash: keccak256(oracleData),
            refiConfigHash: keccak256(refiData),
            deadline: block.timestamp - 1,
            nonce: 10
        });

        bytes32 digest = router.getQuoteDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(borrower);
        vm.expectRevert(RFQRouter.QuoteExpired.selector);
        router.openLoan(quote, collateralAmount, oracleData, refiData, signature);
    }

    function test_Claim_ReentrancyGuard() public {
        ReentrantERC20 reentrantToken = new ReentrantERC20("Reentrant", "REENT", 8);
        reentrantToken.mint(borrower, 1_000_000_000);

        RFQRouter localRouter = new RFQRouter(feeCollector, feeBps);
        MockOracleAdapter localOracle = new MockOracleAdapter();

        vm.prank(borrower);
        reentrantToken.approve(address(localRouter), type(uint256).max);
        vm.prank(lender);
        debtToken.approve(address(localRouter), type(uint256).max);

        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 1_000_000;
        uint256 expiry = block.timestamp + 5 days;
        uint256 callStrike = 1_000_000;
        bytes memory localData = abi.encodePacked("BTCUSD-REENT");
        bytes memory refiData = _buildRefiData(false);

        RFQRouter.LoanQuote memory quote = RFQRouter.LoanQuote({
            lender: lender,
            debtToken: address(debtToken),
            collateralToken: address(reentrantToken),
            principal: principal,
            repaymentAmount: repayment,
            minCollateralAmount: collateralAmount,
            expiry: expiry,
            callStrike: callStrike,
            oracleAdapter: address(localOracle),
            oracleDataHash: keccak256(localData),
            refiConfigHash: keccak256(refiData),
            deadline: block.timestamp + 1 days,
            nonce: 11
        });

        bytes32 digest = localRouter.getQuoteDigest(quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(lenderKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(borrower);
        address vault = localRouter.openLoan(quote, collateralAmount, localData, refiData, signature);

        localOracle.setPrice(localData, 100, true);
        vm.warp(expiry);
        LoanVault(vault).settleNormally();

        reentrantToken.setReenter(vault, abi.encodeWithSelector(LoanVault.claimBorrower.selector));

        vm.prank(borrower);
        vm.expectRevert();
        LoanVault(vault).claimBorrower();
    }

    function test_DoubleSettleReverts() public {
        uint256 collateralAmount = 100_000_000;
        uint256 principal = 1_000_000;
        uint256 repayment = 2_000_000;
        uint256 expiry = block.timestamp + 7 days;
        uint256 callStrike = 1_000_000;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repayment,
            collateralAmount,
            expiry,
            callStrike,
            12,
            refiData
        );
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, 100, true);
        vm.warp(expiry);
        LoanVault(vault).settleNormally();

        vm.expectRevert(LoanVault.AlreadyFinalized.selector);
        LoanVault(vault).settleNormally();
    }

    function testFuzz_SettlementSplits(uint256 price, uint256 callStrike, uint256 repaymentAmount) public {
        price = bound(price, 1, 1_000_000_000);
        callStrike = bound(callStrike, 1, 1_000_000_000);
        repaymentAmount = bound(repaymentAmount, 1, 100_000_000);

        uint256 collateralAmount = 1_000_000_000;
        uint256 principal = repaymentAmount;
        uint256 expiry = block.timestamp + 3 days;

        bytes memory refiData = _buildRefiData(false);
        RFQRouter.LoanQuote memory quote = _buildQuote(
            principal,
            repaymentAmount,
            collateralAmount,
            expiry,
            callStrike,
            13,
            refiData
        );
        address vault = _openLoan(quote, collateralAmount, refiData);

        oracle.setPrice(oracleData, price, true);
        vm.warp(expiry);
        LoanVault(vault).settleNormally();

        uint256 lenderAmount = LoanVault(vault).collateralForLender();
        uint256 borrowerAmount = LoanVault(vault).collateralForBorrower();
        assertEq(lenderAmount + borrowerAmount, collateralAmount);
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

    function _feeForQuoteAt(RFQRouter.LoanQuote memory quote, uint256 timestamp) internal view returns (uint256) {
        if (feeBps == 0) {
            return 0;
        }
        uint256 duration = quote.expiry - timestamp;
        uint256 annualFee = (quote.principal * feeBps) / 10_000;
        return (annualFee * duration) / 365 days;
    }
}
