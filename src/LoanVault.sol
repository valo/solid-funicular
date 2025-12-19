// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IRefinanceAdapter} from "./interfaces/IRefinanceAdapter.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

contract LoanVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum LoanStatus {
        Active,
        Expired,
        Refinanced,
        SettledNormally
    }

    struct RefiData {
        bool enabled;
        address adapter;
        uint256 gracePeriod;
        uint256 maxLtvBps;
        bytes adapterData;
    }

    error AlreadyInitialized();
    error NotRouter();
    error InvalidParams();
    error NotExpired();
    error InvalidOracle();
    error AlreadyFinalized();
    error NotExpiredState();
    error NotSettled();
    error NotBorrower();
    error NotLender();
    error AlreadyClaimed();
    error RefiNotEligible();
    error RefiWindowClosed();
    error RefiWindowActive();
    error RefiDisabled();

    uint256 private constant BPS_DENOMINATOR = 10_000;

    event LoanInitialized(
        address indexed borrower,
        address indexed lender,
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint256 principal,
        uint256 repaymentAmount,
        uint256 expiry,
        uint256 callStrike,
        address oracleAdapter,
        bytes oracleData,
        bool refiEnabled,
        address refiAdapter,
        bytes refiData,
        uint256 refiGracePeriod,
        uint256 refiMaxLtvBps
    );
    event LoanExpired(uint256 price, bool refiEligible, uint256 refiDeadline);
    event LoanRefinanceAttempt(bool success);
    event LoanRefinanced(address indexed borrower, address indexed lender);
    event LoanSettled(uint256 price, uint256 collateralForBorrower, uint256 collateralForLender);
    event BorrowerClaimed(address indexed borrower, uint256 amount);
    event LenderClaimed(address indexed lender, uint256 amount);

    address public immutable router;

    address public borrower;
    address public lender;
    address public collateralToken;
    address public debtToken;
    uint256 public collateralAmount;
    uint256 public principal;
    uint256 public repaymentAmount;
    uint256 public expiry;
    uint256 public callStrike;
    address public oracleAdapter;
    bytes public oracleData;

    bool public refiEnabled;
    address public refiAdapter;
    bytes public refiData;
    uint256 public refiGracePeriod;
    uint256 public refiMaxLtvBps;

    LoanStatus public status;
    uint256 public settlementPrice;
    bool public refiEligible;
    uint256 public collateralForBorrower;
    uint256 public collateralForLender;
    bool public borrowerClaimed;
    bool public lenderClaimed;
    bool public initialized;

    constructor(address router_) {
        if (router_ == address(0)) {
            revert InvalidParams();
        }
        router = router_;
    }

    /// @notice Initializes the loan vault with immutable terms.
    function initialize(
        address borrower_,
        address lender_,
        address collateralToken_,
        address debtToken_,
        uint256 collateralAmount_,
        uint256 principal_,
        uint256 repaymentAmount_,
        uint256 expiry_,
        uint256 callStrike_,
        address oracleAdapter_,
        bytes calldata oracleData_,
        bytes calldata refiData_
    ) external {
        if (msg.sender != router) {
            revert NotRouter();
        }
        if (initialized) {
            revert AlreadyInitialized();
        }
        if (
            borrower_ == address(0) ||
            lender_ == address(0) ||
            collateralToken_ == address(0) ||
            debtToken_ == address(0) ||
            oracleAdapter_ == address(0) ||
            collateralAmount_ == 0 ||
            repaymentAmount_ == 0 ||
            principal_ == 0 ||
            expiry_ == 0 ||
            callStrike_ == 0
        ) {
            revert InvalidParams();
        }
        if (expiry_ <= block.timestamp) {
            revert InvalidParams();
        }
        RefiData memory refi = _decodeRefiData(refiData_);
        if (refi.enabled && refi.adapter == address(0)) {
            revert InvalidParams();
        }
        if (refi.maxLtvBps > BPS_DENOMINATOR) {
            revert InvalidParams();
        }

        borrower = borrower_;
        lender = lender_;
        collateralToken = collateralToken_;
        debtToken = debtToken_;
        collateralAmount = collateralAmount_;
        principal = principal_;
        repaymentAmount = repaymentAmount_;
        expiry = expiry_;
        callStrike = callStrike_;
        oracleAdapter = oracleAdapter_;
        oracleData = oracleData_;
        refiEnabled = refi.enabled;
        refiAdapter = refi.adapter;
        refiData = refi.adapterData;
        refiGracePeriod = refi.gracePeriod;
        refiMaxLtvBps = refi.maxLtvBps;
        status = LoanStatus.Active;
        initialized = true;

        emit LoanInitialized(
            borrower_,
            lender_,
            collateralToken_,
            debtToken_,
            collateralAmount_,
            principal_,
            repaymentAmount_,
            expiry_,
            callStrike_,
            oracleAdapter_,
            oracleData_,
            refi.enabled,
            refi.adapter,
            refi.adapterData,
            refi.gracePeriod,
            refi.maxLtvBps
        );
    }

    /// @notice Fixes the oracle price at or after expiry, entering Expired state.
    function expire() external nonReentrant {
        _ensureExpired();
    }

    /// @notice Attempts to refinance during the grace window in the middle region.
    function attemptRefinance() external nonReentrant returns (bool success) {
        _ensureExpired();
        if (status != LoanStatus.Expired) {
            revert NotExpiredState();
        }
        if (!refiEligible) {
            revert RefiNotEligible();
        }
        if (!refiEnabled) {
            revert RefiDisabled();
        }
        if (block.timestamp > expiry + refiGracePeriod) {
            revert RefiWindowClosed();
        }

        if (!_withinRefiSafetyLimit()) {
            emit LoanRefinanceAttempt(false);
            return false;
        }

        IERC20(collateralToken).forceApprove(refiAdapter, collateralAmount);
        try
            IRefinanceAdapter(refiAdapter).attemptRefinance(
                borrower,
                lender,
                collateralToken,
                debtToken,
                collateralAmount,
                repaymentAmount,
                refiData
            )
        returns (bool adapterSuccess) {
            success = adapterSuccess;
        } catch {
            success = false;
        }

        emit LoanRefinanceAttempt(success);

        if (!success) {
            return false;
        }

        status = LoanStatus.Refinanced;
        emit LoanRefinanced(borrower, lender);
        return true;
    }

    /// @notice Settles the loan normally after expiry or when borrower opts out of refi.
    function settleNormally() external nonReentrant {
        _ensureExpired();
        if (status != LoanStatus.Expired) {
            revert NotExpiredState();
        }
        if (refiEligible && block.timestamp <= expiry + refiGracePeriod && msg.sender != borrower) {
            revert RefiWindowActive();
        }

        (uint256 lenderAmount, uint256 borrowerAmount) = _splitCollateral(settlementPrice);
        collateralForLender = lenderAmount;
        collateralForBorrower = borrowerAmount;
        status = LoanStatus.SettledNormally;

        emit LoanSettled(settlementPrice, borrowerAmount, lenderAmount);
    }

    /// @notice Claims collateral owed to the borrower after normal settlement.
    function claimBorrower() external nonReentrant {
        if (status != LoanStatus.SettledNormally) {
            revert NotSettled();
        }
        if (msg.sender != borrower) {
            revert NotBorrower();
        }
        if (borrowerClaimed) {
            revert AlreadyClaimed();
        }

        borrowerClaimed = true;
        uint256 amount = collateralForBorrower;
        if (amount > 0) {
            IERC20(collateralToken).safeTransfer(borrower, amount);
        }

        emit BorrowerClaimed(borrower, amount);
    }

    /// @notice Claims collateral owed to the lender after normal settlement.
    function claimLender() external nonReentrant {
        if (status != LoanStatus.SettledNormally) {
            revert NotSettled();
        }
        if (msg.sender != lender) {
            revert NotLender();
        }
        if (lenderClaimed) {
            revert AlreadyClaimed();
        }

        lenderClaimed = true;
        uint256 amount = collateralForLender;
        if (amount > 0) {
            IERC20(collateralToken).safeTransfer(lender, amount);
        }

        emit LenderClaimed(lender, amount);
    }

    function _ensureExpired() internal {
        if (!initialized) {
            revert InvalidParams();
        }
        if (status == LoanStatus.Refinanced || status == LoanStatus.SettledNormally) {
            revert AlreadyFinalized();
        }
        if (status == LoanStatus.Expired) {
            return;
        }
        if (block.timestamp < expiry) {
            revert NotExpired();
        }

        (uint256 price, bool valid) = IOracleAdapter(oracleAdapter).getPrice(oracleData, expiry);
        if (!valid || price == 0) {
            revert InvalidOracle();
        }

        settlementPrice = price;
        refiEligible = _isRefiEligible(price);
        status = LoanStatus.Expired;

        emit LoanExpired(price, refiEligible, expiry + refiGracePeriod);
    }

    function _decodeRefiData(bytes calldata refiData_) internal pure returns (RefiData memory) {
        if (refiData_.length == 0) {
            return RefiData({enabled: false, adapter: address(0), gracePeriod: 0, maxLtvBps: 0, adapterData: ""});
        }
        return abi.decode(refiData_, (RefiData));
    }

    function _isRefiEligible(uint256 price) internal view returns (bool) {
        if (!refiEnabled) {
            return false;
        }
        uint256 collateralValue = Math.mulDiv(collateralAmount, price, 1);
        uint256 capValue = Math.mulDiv(collateralAmount, callStrike, 1);
        return collateralValue >= repaymentAmount && collateralValue <= capValue;
    }

    function _withinRefiSafetyLimit() internal view returns (bool) {
        if (refiMaxLtvBps == 0) {
            return true;
        }
        uint256 collateralValue = Math.mulDiv(collateralAmount, settlementPrice, 1);
        uint256 maxBorrow = Math.mulDiv(collateralValue, refiMaxLtvBps, BPS_DENOMINATOR);
        return repaymentAmount <= maxBorrow;
    }

    function _splitCollateral(uint256 price) internal view returns (uint256 lenderAmount, uint256 borrowerAmount) {
        uint256 collateralValue = Math.mulDiv(collateralAmount, price, 1);
        uint256 capValue = Math.mulDiv(collateralAmount, callStrike, 1);

        if (collateralValue < repaymentAmount) {
            lenderAmount = collateralAmount;
            borrowerAmount = 0;
            return (lenderAmount, borrowerAmount);
        }

        if (collateralValue <= capValue) {
            lenderAmount = Math.mulDiv(repaymentAmount, 1, price, Math.Rounding.Ceil);
            if (lenderAmount > collateralAmount) {
                lenderAmount = collateralAmount;
            }
            borrowerAmount = collateralAmount - lenderAmount;
            return (lenderAmount, borrowerAmount);
        }

        uint256 borrowerCapValue = 0;
        if (capValue > repaymentAmount) {
            borrowerCapValue = capValue - repaymentAmount;
        }
        borrowerAmount = borrowerCapValue == 0 ? 0 : Math.mulDiv(borrowerCapValue, 1, price);
        if (borrowerAmount > collateralAmount) {
            borrowerAmount = collateralAmount;
        }
        lenderAmount = collateralAmount - borrowerAmount;
        return (lenderAmount, borrowerAmount);
    }
}
