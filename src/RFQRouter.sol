// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {LoanVault} from "./LoanVault.sol";

contract RFQRouter is ReentrancyGuard {
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
        address oracleAdapter;
        bytes32 oracleDataHash;
        bytes32 refiConfigHash;
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

    event LoanOpened(address indexed borrower, address indexed lender, address vault);

    bytes32 public constant LOAN_QUOTE_TYPEHASH =
        keccak256(
            "LoanQuote(address lender,address debtToken,address collateralToken,uint256 principal,uint256 repaymentAmount,uint256 minCollateralAmount,uint256 expiry,uint256 callStrike,address oracleAdapter,bytes32 oracleDataHash,bytes32 refiConfigHash,uint256 deadline,uint256 nonce)"
        );
    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("ZeroLoansRFQRouter");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    bytes32 public immutable domainSeparator;

    mapping(address => mapping(uint256 => bool)) public usedNonces;

    constructor() {
        domainSeparator = keccak256(
            abi.encode(_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(this))
        );
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
        _transferFunds(quote, collateralAmount, vault);

        emit LoanOpened(msg.sender, quote.lender, vault);
        return vault;
    }

    /// @notice Returns the EIP-712 digest of a quote for off-chain signing.
    function getQuoteDigest(LoanQuote calldata quote) external view returns (bytes32) {
        return _hashTypedData(quote);
    }

    function _deployVault(
        LoanQuote calldata quote,
        uint256 collateralAmount,
        bytes calldata oracleData,
        bytes calldata refiData
    ) internal returns (address vault) {
        LoanVault loanVault = new LoanVault(address(this));
        loanVault.initialize(
            msg.sender,
            quote.lender,
            quote.collateralToken,
            quote.debtToken,
            collateralAmount,
            quote.principal,
            quote.repaymentAmount,
            quote.expiry,
            quote.callStrike,
            quote.oracleAdapter,
            oracleData,
            refiData
        );
        return address(loanVault);
    }

    function _transferFunds(LoanQuote calldata quote, uint256 collateralAmount, address vault) internal {
        IERC20(quote.collateralToken).safeTransferFrom(msg.sender, vault, collateralAmount);
        IERC20(quote.debtToken).safeTransferFrom(quote.lender, msg.sender, quote.principal);
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
            quote.oracleAdapter == address(0)
        ) {
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
        // TODO: enforce refi adapter whitelist when governance model is defined.
        if (keccak256(refiData) != quote.refiConfigHash) {
            revert RefiConfigMismatch();
        }
    }

    function _hashTypedData(LoanQuote calldata quote) internal view returns (bytes32) {
        LoanQuote memory quoteMem = quote;
        bytes32 structHash = keccak256(abi.encode(LOAN_QUOTE_TYPEHASH, quoteMem));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
