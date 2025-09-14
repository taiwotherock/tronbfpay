// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../libs/ReentrancyGuard.sol";
import "../libs/SafeTRC20.sol";

interface ITRC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface ILiquidityPool {
    function pullFunds(address token, address to, uint256 amount) external;
}

interface ILoanVaultCore {
    function collateral(address borrower, address token) external view returns (uint256);
}

interface IBorderlessCreditNFT {
    function getCreditScoreByBorrower(address borrower) external view returns (uint16);
    function getCreditLimitByBorrower(address borrower) external view returns (uint256);
}

interface IAccessControl {
    function isAdmin(address user) external view returns (bool);
    function isCreditOfficer(address user) external view returns (bool);
    function isKeeper(address user) external view returns (bool);
}

contract LoanManager is ReentrancyGuard {
    using SafeTRC20 for ITRC20;

    address public accessControl;
    ILiquidityPool public liquidityPool;
    ILoanVaultCore public vault;
    IBorderlessCreditNFT public creditNFT;
    bool public paused;

    struct Loan {
        address borrower;
        address token;
        uint256 principal;
        uint256 outstanding;
        uint256 startedAt;
        uint8 installmentsPaid;
        uint8 totalInstallments;
        bool active;
        uint256 installmentAmount;
    }

    mapping(address => Loan) public loans;
    mapping(uint16 => uint256) public minByScore;
    mapping(uint16 => uint256) public maxByScore;

    event LoanRequested(address indexed borrower, uint256 requestedAmount);
    event LoanApproved(address indexed borrower, uint256 amount, address token);
    event Repayment(address indexed borrower, uint256 amount, uint8 installmentNo);
    event LoanRepaid(address indexed borrower);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    modifier onlyCreditOfficer() {
        require(_isCreditOfficer(msg.sender), "LoanManager: not credit officer");
        _;
    }

    modifier onlyAdmin() {
        require(_isAdmin(msg.sender), "LoanManager: not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "LoanManager: paused");
        _;
    }

    constructor(address _accessControl, address _liquidityPool, address _vault, address _creditNFT) {
        require(_accessControl != address(0), "LoanManager: zero accessControl");
        require(_liquidityPool != address(0), "LoanManager: zero liquidityPool");
        require(_vault != address(0), "LoanManager: zero vault");
        require(_creditNFT != address(0), "LoanManager: zero creditNFT");

        accessControl = _accessControl;
        liquidityPool = ILiquidityPool(_liquidityPool);
        vault = ILoanVaultCore(_vault);
        creditNFT = IBorderlessCreditNFT(_creditNFT);
        paused = false;
    }

    // --- pause control ---
    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- admin functions ---
    function setLimitsForScore(uint16 score, uint256 minAmt, uint256 maxAmt) external onlyAdmin {
        require(minAmt <= maxAmt, "LoanManager: min > max");
        minByScore[score] = minAmt;
        maxByScore[score] = maxAmt;
    }

    // --- borrower functions ---
    function requestLoan(address tokenToBorrow, uint256 requestedAmount) external whenNotPaused {
        require(tokenToBorrow != address(0), "LoanManager: zero token");
        require(!loans[msg.sender].active, "LoanManager: one loan at a time");

        // fetch credit score & limit from NFT
        uint16 score = creditNFT.getCreditScoreByBorrower(msg.sender);
        uint256 limit = creditNFT.getCreditLimitByBorrower(msg.sender);

        require(requestedAmount > 0, "LoanManager: zero amount");
        require(score > 0, "LoanManager: invalid credit score");
        require(requestedAmount <= limit, "LoanManager: exceeds credit limit");

        uint256 minAmt = minByScore[score];
        uint256 maxAmt = maxByScore[score];
        require(requestedAmount >= minAmt && requestedAmount <= maxAmt, "LoanManager: amount out of bounds");

        // collateral requirement: 30% of requested amount
        uint256 requiredCollateral = (requestedAmount * 30) / 100;
        uint256 coll = vault.collateral(msg.sender, tokenToBorrow);
        require(coll >= requiredCollateral, "LoanManager: insufficient collateral");

        emit LoanRequested(msg.sender, requestedAmount);
    }

    function approveAndDisburse(address borrower, address tokenToBorrow, uint256 amount)
        external
        onlyCreditOfficer
        nonReentrant
        whenNotPaused
    {
        require(borrower != address(0), "LoanManager: zero borrower");
        require(!loans[borrower].active, "LoanManager: existing loan");
        require(amount > 0, "LoanManager: zero amount");

        // fetch credit score & limit from NFT
        uint16 score = creditNFT.getCreditScoreByBorrower(borrower);
        uint256 limit = creditNFT.getCreditLimitByBorrower(borrower);
        require(score > 0, "LoanManager: invalid score");
        require(amount <= limit, "LoanManager: exceeds credit limit");

        uint8 installments = 3;
        uint256 installmentAmount = amount / installments;

        loans[borrower] = Loan({
            borrower: borrower,
            token: tokenToBorrow,
            principal: amount,
            outstanding: amount,
            startedAt: block.timestamp,
            installmentsPaid: 0,
            totalInstallments: installments,
            active: true,
            installmentAmount: installmentAmount
        });

        liquidityPool.pullFunds(tokenToBorrow, borrower, amount);

        emit LoanApproved(borrower, amount, tokenToBorrow);
    }

    function repay(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "LoanManager: zero amount");

        Loan storage L = loans[msg.sender];
        require(L.active, "LoanManager: no active loan");
        require(token == L.token, "LoanManager: wrong token");

        if (amount > L.outstanding) amount = L.outstanding;

        ITRC20(token).safeTransferFrom(msg.sender, address(this), amount);

        L.outstanding -= amount;
        L.installmentsPaid += 1;

        emit Repayment(msg.sender, amount, L.installmentsPaid);

        if (L.outstanding == 0) {
            L.active = false;
            emit LoanRepaid(msg.sender);
        }
    }

    function outstandingOf(address borrower) external view returns (uint256) {
        return loans[borrower].outstanding;
    }

    function liquidateDue(address borrower, uint256 amountNeeded) external nonReentrant whenNotPaused {
        bool isKeeper = _isKeeper(msg.sender);
        bool isAdmin = _isAdmin(msg.sender);
        require(isKeeper || isAdmin, "LoanManager: unauthorized");

        Loan storage L = loans[borrower];
        require(L.active, "LoanManager: no active loan");

        if (amountNeeded >= L.outstanding) {
            L.outstanding = 0;
            L.active = false;
            emit LoanRepaid(borrower);
        } else {
            L.outstanding -= amountNeeded;
        }
    }

    // --- internal helpers ---
    function _isAdmin(address user) internal view returns (bool) {
        return IAccessControl(accessControl).isAdmin(user);
    }

    function _isCreditOfficer(address user) internal view returns (bool) {
        return IAccessControl(accessControl).isCreditOfficer(user);
    }

    function _isKeeper(address user) internal view returns (bool) {
        return IAccessControl(accessControl).isKeeper(user);
    }
}
