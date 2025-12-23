// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {LoanVault} from "./LoanVault.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";

contract RFQRouter is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    struct LoanQuote {
        address lender;
        address debtToken;
        address collateralToken;
        uint256 principal;
        uint256 repaymentAmount;
        uint256 minCollateralAmount;
        uint256 expiry;
        uint256 callStrike;
        uint256 putStrike;
        address oracleAdapter;
        bytes32 oracleDataHash;
        bytes32 refiConfigHash;
        uint256 feeBps;
        uint256 deadline;
        uint256 nonce;
    }

    error InvalidSignature();
    error QuoteExpired();
    error LoanExpired();
    error InvalidParams();
    error NonceUsed();
    error OracleDataMismatch();
    error RefiConfigMismatch();
    error InvalidFeeConfig();
    error RefiAdapterNotWhitelisted();

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    event LoanOpened(address indexed borrower, address indexed lender, address vault);
    event FeeConfigUpdated(address indexed feeCollector, uint256 feeBps);
    event RefiAdapterWhitelistUpdated(address indexed adapter, bool allowed);

    bytes32 public constant LOAN_QUOTE_TYPEHASH =
        keccak256(
            "LoanQuote(address lender,address debtToken,address collateralToken,uint256 principal,uint256 repaymentAmount,uint256 minCollateralAmount,uint256 expiry,uint256 callStrike,uint256 putStrike,address oracleAdapter,bytes32 oracleDataHash,bytes32 refiConfigHash,uint256 feeBps,uint256 deadline,uint256 nonce)"
        );
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("ZeroLoansRFQRouter");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    bytes32 public immutable domainSeparator;
    address public feeCollector;
    uint256 public feeBps;
    address public immutable loanVaultImplementation;

    mapping(address => bool) public allowedRefiAdapters;

    mapping(address => mapping(uint256 => bool)) public usedNonces;

    constructor(address feeCollector_, uint256 feeBps_) Ownable(msg.sender) {
        if (feeBps_ > BPS_DENOMINATOR || (feeBps_ > 0 && feeCollector_ == address(0))) {
            revert InvalidFeeConfig();
        }
        domainSeparator = keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
        feeCollector = feeCollector_;
        feeBps = feeBps_;
        loanVaultImplementation = address(new LoanVault(address(this)));
    }

    /// @notice Updates the underwriting fee configuration.
    function setFeeConfig(address feeCollector_, uint256 feeBps_) external onlyOwner {
        if (feeBps_ > BPS_DENOMINATOR || (feeBps_ > 0 && feeCollector_ == address(0))) {
            revert InvalidFeeConfig();
        }
        feeCollector = feeCollector_;
        feeBps = feeBps_;
        emit FeeConfigUpdated(feeCollector_, feeBps_);
    }

    /// @notice Whitelists or removes refinance adapters.
    function setRefiAdapters(address[] calldata adapters, bool allowed) external onlyOwner {
        uint256 len = adapters.length;
        for (uint256 i; i < len; i++) {
            allowedRefiAdapters[adapters[i]] = allowed;
            emit RefiAdapterWhitelistUpdated(adapters[i], allowed);
        }
    }

    /// @notice Opens a loan using a lender-signed RFQ quote.
    function openLoan(
        LoanQuote calldata quote,
        uint256 collateralAmount,
        bytes calldata oracleData,
        bytes calldata refiData,
        bytes calldata signature
    ) external nonReentrant returns (address vault) {
        _validateQuote(quote, collateralAmount, oracleData, refiData);

        bytes32 digest = _hashTypedData(quote);
        address signer = ECDSA.recover(digest, signature);
        if (signer != quote.lender) {
            revert InvalidSignature();
        }

        usedNonces[quote.lender][quote.nonce] = true;
        vault = _deployVault(quote, collateralAmount, oracleData, refiData);
        _collectFee(quote);
        _transferFunds(quote, collateralAmount, vault);

        emit LoanOpened(msg.sender, quote.lender, vault);
        return vault;
    }

    /// @notice Returns the EIP-712 digest of a quote for off-chain signing.
    function getQuoteDigest(LoanQuote calldata quote) external view returns (bytes32) {
        return _hashTypedData(quote);
    }

    /// @notice Computes the expected hash for oracle data used inside a quote.
    function computeOracleDataHash(bytes calldata oracleData) external pure returns (bytes32) {
        return keccak256(oracleData);
    }

    /// @notice Computes the expected hash for refinance configuration used inside a quote.
    function computeRefiConfigHash(bytes calldata refiData) external pure returns (bytes32) {
        return keccak256(refiData);
    }

    /// @notice Previews the underwriting fee for a given principal and expiry at a specific timestamp.
    /// @dev Reverts if expiry is not in the future relative to `atTimestamp`.
    function previewFee(uint256 principal, uint256 expiry, uint256 atTimestamp) external view returns (uint256) {
        if (feeBps == 0 || feeCollector == address(0)) {
            return 0;
        }
        if (expiry <= atTimestamp) {
            revert LoanExpired();
        }
        uint256 duration = expiry - atTimestamp;
        uint256 annualFee = Math.mulDiv(principal, feeBps, BPS_DENOMINATOR);
        return Math.mulDiv(annualFee, duration, SECONDS_PER_YEAR);
    }

    function _deployVault(
        LoanQuote calldata quote,
        uint256 collateralAmount,
        bytes calldata oracleData,
        bytes calldata refiData
    ) internal returns (address vault) {
        vault = Clones.clone(loanVaultImplementation);
        LoanVault(vault).initialize(
            msg.sender,
            quote.lender,
            quote.collateralToken,
            quote.debtToken,
            collateralAmount,
            quote.principal,
            quote.repaymentAmount,
            quote.expiry,
            quote.callStrike,
            quote.putStrike,
            quote.oracleAdapter,
            oracleData,
            refiData
        );
        return vault;
    }

    function _transferFunds(LoanQuote calldata quote, uint256 collateralAmount, address vault) internal {
        IERC20(quote.collateralToken).safeTransferFrom(msg.sender, vault, collateralAmount);
        IERC20(quote.debtToken).safeTransferFrom(quote.lender, msg.sender, quote.principal);
    }

    function _collectFee(LoanQuote calldata quote) internal {
        if (quote.feeBps == 0 || feeCollector == address(0)) {
            return;
        }
        uint256 duration = quote.expiry - block.timestamp;
        uint256 annualFee = Math.mulDiv(quote.principal, quote.feeBps, BPS_DENOMINATOR);
        uint256 fee = Math.mulDiv(annualFee, duration, SECONDS_PER_YEAR);
        if (fee == 0) {
            return;
        }
        IERC20(quote.debtToken).safeTransferFrom(quote.lender, feeCollector, fee);
    }

    function _validateQuote(
        LoanQuote calldata quote,
        uint256 collateralAmount,
        bytes calldata oracleData,
        bytes calldata refiData
    ) internal view {
        if (block.timestamp > quote.deadline) {
            revert QuoteExpired();
        }
        if (block.timestamp >= quote.expiry) {
            revert LoanExpired();
        }
        if (quote.lender == address(0) || quote.debtToken == address(0) || quote.collateralToken == address(0)) {
            revert InvalidParams();
        }
        if (
            quote.principal == 0 ||
            quote.repaymentAmount == 0 ||
            quote.minCollateralAmount == 0 ||
            quote.callStrike == 0 ||
            quote.putStrike == 0 ||
            quote.oracleAdapter == address(0) ||
            quote.feeBps > BPS_DENOMINATOR
        ) {
            revert InvalidParams();
        }
        if (quote.feeBps > 0 && feeCollector == address(0)) {
            revert InvalidFeeConfig();
        }
        if (quote.putStrike >= quote.callStrike) {
            revert InvalidParams();
        }
        if (collateralAmount < quote.minCollateralAmount) {
            revert InvalidParams();
        }
        if (usedNonces[quote.lender][quote.nonce]) {
            revert NonceUsed();
        }
        if (keccak256(oracleData) != quote.oracleDataHash) {
            revert OracleDataMismatch();
        }
        if (keccak256(refiData) != quote.refiConfigHash) {
            revert RefiConfigMismatch();
        }
        if (refiData.length > 0) {
            LoanVault.RefiData memory refi = _decodeRefiData(refiData);
            if (refi.enabled && !allowedRefiAdapters[refi.adapter]) {
                revert RefiAdapterNotWhitelisted();
            }
        }
    }

    function _hashTypedData(LoanQuote calldata quote) internal view returns (bytes32) {
        LoanQuote memory quoteMem = quote;
        bytes32 structHash = keccak256(abi.encode(LOAN_QUOTE_TYPEHASH, quoteMem));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _decodeRefiData(bytes calldata refiData) internal pure returns (LoanVault.RefiData memory) {
        if (refiData.length == 0) {
            return LoanVault.RefiData({
                enabled: false,
                adapter: address(0),
                gracePeriod: 0,
                maxLtvBps: 0,
                adapterData: ""
            });
        }
        return abi.decode(refiData, (LoanVault.RefiData));
    }
}
