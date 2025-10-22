// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../libs/ReentrancyGuard.sol";

interface ITRC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface ILoanVaultCoreV3 {
    struct SweepParams {
        address borrower;
        address tokenToBorrow;
        address merchantAddr;
        uint256 depositAmount;
    }
    function sweepCollateral(SweepParams calldata p) external;
    function getVaultBalance(address borrower, address token) external view returns (uint256);
}

interface ILiquidityPool {
    function pullFunds(address token, address to, uint256 amount) external;
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

contract LoanManagerV15 is ReentrancyGuard {
   

    // External contracts
    IAccessControl public accessControl;
    ILiquidityPool public liquidityPool;
    ILoanVaultCoreV3 public vault;
    IBorderlessCreditNFT public creditNFT;

    // Pause state
    bool public paused;

    // Fees (bps)
    uint256 public merchantFeeBps = 800;
    uint256 public platformFeeOfTotalBps = 100;
    uint256 public lenderIncomeOfTotalBps = 700;
    address public platformFeeAddress;
    address public lenderPoolIncomeAddress;

    struct Loan {
        address borrower;
        address token;
        address merchant;
        uint256 principal;
        uint256 outstanding;
        uint256 startedAt;
        uint256 installmentsPaid;
        uint256 fee;
        bool active;
    }

    mapping(address => Loan) public loans;
    address[] private borrowers; // track loan borrowers
    mapping(address => bool) private hasLoan; // prevent duplicates

    // Events
    event LoanRequested(address indexed borrower, uint256 requestedAmount);
    event LoanApproved(address indexed borrower, uint256 totalAmount, address indexed token, address indexed merchant, uint256 settleAmount);
    event BorrowerRepayment(address indexed borrower, address indexed token, uint256 amount);
    event LoanRepaid(address indexed borrower);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    modifier onlyAdmin() {
        require(accessControl.isAdmin(msg.sender), "LoanManager: not admin");
        _;
    }

    modifier onlyCreditOfficer() {
        require(accessControl.isCreditOfficer(msg.sender), "LoanManager: not credit officer");
        _;
    }

    modifier onlyCreditOfficerOrAdmin() {
        require(accessControl.isCreditOfficer(msg.sender) || accessControl.isAdmin(msg.sender), "LoanManager: not credit officer or admin");
        _;
    }

    

    modifier whenNotPaused() {
        require(!paused, "LoanManager: paused");
        _;
    }

    constructor(
        address _accessControl,
        address _liquidityPool,
        address _vault,
        address _creditNFT,
        address _platformFeeAddr,
        address _lenderPoolIncomeAddr
    ) {
        require(_accessControl != address(0) && _liquidityPool != address(0) &&
                _vault != address(0) && _creditNFT != address(0) &&
                _platformFeeAddr != address(0) && _lenderPoolIncomeAddr != address(0),
                "LoanManager: zero address");

        accessControl = IAccessControl(_accessControl);
        liquidityPool = ILiquidityPool(_liquidityPool);
        vault = ILoanVaultCoreV3(_vault);
        creditNFT = IBorderlessCreditNFT(_creditNFT);
        platformFeeAddress = _platformFeeAddr;
        lenderPoolIncomeAddress = _lenderPoolIncomeAddr;
        paused = false;
    }

    // --- Pause functions ---
    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- Admin setters ---
    function setFeeAddresses(address _platformFeeAddr, address _lenderPoolIncomeAddr) external onlyAdmin {
        require(_platformFeeAddr != address(0) && _lenderPoolIncomeAddr != address(0), "LoanManager: zero addr");
        platformFeeAddress = _platformFeeAddr;
        lenderPoolIncomeAddress = _lenderPoolIncomeAddr;
    }

    function setMerchantFeeBps(uint256 _bps) external onlyAdmin {
        require(_bps <= 2000, "LoanManager: max 20%");
        merchantFeeBps = _bps;
    }

    function setPlatformAndLenderFeeSplits(uint256 _platformBps, uint256 _lenderBps) external onlyAdmin {
        require(_platformBps + _lenderBps == merchantFeeBps, "LoanManager: split mismatch");
        platformFeeOfTotalBps = _platformBps;
        lenderIncomeOfTotalBps = _lenderBps;
    }

    // --- Loan request & approval ---
    function requestLoan(address tokenToBorrow, uint256 requestedAmount) external whenNotPaused {
        require(tokenToBorrow != address(0), "LoanManager: zero token");
        require(!loans[msg.sender].active, "LoanManager: one loan at a time");

        uint16 score = creditNFT.getCreditScoreByBorrower(msg.sender);
        uint256 nftLimit = creditNFT.getCreditLimitByBorrower(msg.sender);

        require(score > 0, "LoanManager: invalid score");
        require(requestedAmount > 0 && requestedAmount <= nftLimit, "LoanManager: exceeds credit limit");

        uint256 vaultBalance = vault.getVaultBalance(msg.sender, tokenToBorrow);
        uint256 requiredCollateral = (requestedAmount * 34) / 10000;
        require(vaultBalance >= requiredCollateral, "LoanManager: insufficient collateral");
        //ITRC20(tokenToBorrow).transferFrom(msg.sender, address(liquidityPool), requiredCollateral);

        // Low-level TRC20 transferFrom
        /*(bool success, bytes memory data) = tokenToBorrow.call(
            abi.encodeWithSelector(ITRC20(tokenToBorrow).transferFrom.selector, msg.sender, address(this), amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");
        */

        emit LoanRequested(msg.sender, requiredCollateral);
    }

    function approveAndDisburse(
        address borrower,
        address tokenToBorrow,
        uint256 totalAmount,
        uint256 depositAmount,
        uint256 fee,
        address merchantAddr
    ) external onlyCreditOfficerOrAdmin nonReentrant whenNotPaused {
        require(!_isPrivileged(borrower), "Privileged cannot borrow");
        require(borrower != address(0) && merchantAddr != address(0), "Zero addr");
        require(!loans[borrower].active, "Existing loan");
        require(totalAmount > 0, "Zero amount");

        uint16 score = creditNFT.getCreditScoreByBorrower(borrower);
        uint256 nftLimit = creditNFT.getCreditLimitByBorrower(borrower);
        require(score > 0 && totalAmount <= nftLimit, "Invalid amount");

        uint256 vaultBalance = vault.getVaultBalance(borrower, tokenToBorrow);
        require(vaultBalance >= depositAmount, "Vault: insufficient balance");

        uint256 borrowerPart = (totalAmount * 34) / 10000;
        uint256 lenderPart = totalAmount - borrowerPart;
        uint256 merchantSettleAmt = totalAmount - fee - depositAmount;
        uint256 settleAmount = depositAmount + merchantSettleAmt;

        // Sweep collateral from vault to merchant
        ILoanVaultCoreV3.SweepParams memory p = ILoanVaultCoreV3.SweepParams({
            borrower: borrower,
            tokenToBorrow: tokenToBorrow,
            merchantAddr: merchantAddr,
            depositAmount: depositAmount
        });
        vault.sweepCollateral(p);

        // Pull lender funds from liquidity pool
        if (lenderPart > 0) {
            liquidityPool.pullFunds(tokenToBorrow, merchantAddr, merchantSettleAmt);
        }

        // Record loan
        Loan storage L = loans[borrower];
        L.borrower = borrower;
        L.token = tokenToBorrow;
        L.merchant = merchantAddr;
        L.principal = totalAmount;
        L.outstanding = totalAmount - depositAmount;
        L.startedAt = block.timestamp;
        L.installmentsPaid = depositAmount;
        L.fee = fee;
        L.active = true;

        if (!hasLoan[L.borrower]) {
            hasLoan[L.borrower] = true;
            borrowers.push(L.borrower);
        }
        

        emit LoanApproved(borrower, totalAmount, tokenToBorrow, merchantAddr,settleAmount);
    }

    // --- Repayments ---
    function repay(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Zero amount");
        Loan storage L = loans[msg.sender];
        require(L.active && token == L.token, "Invalid loan/token");

        uint256 payAmount = amount > L.outstanding ? L.outstanding : amount;
        //ITRC20(token).transferFrom(msg.sender, address(liquidityPool), payAmount);

         // Low-level TRC20 transferFrom
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(ITRC20(token).transferFrom.selector, msg.sender, address(liquidityPool), payAmount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");

        L.outstanding -= payAmount;
        L.installmentsPaid += payAmount;
        emit BorrowerRepayment(msg.sender, token, payAmount);

        if (L.outstanding == 0) {
            L.active = false;
            emit LoanRepaid(msg.sender);
        }
    }

    // --- Keeper/Admin liquidation ---
    function liquidateDue(address borrower, uint256 amountNeeded) external nonReentrant whenNotPaused {
        require(accessControl.isKeeper(msg.sender) || accessControl.isAdmin(msg.sender), "Unauthorized");
        Loan storage L = loans[borrower];
        require(L.active, "No active loan");

        if (amountNeeded >= L.outstanding) {
            L.outstanding = 0;
            L.active = false;
            emit LoanRepaid(borrower);
        } else {
            L.outstanding -= amountNeeded;
        }
    }

    // --- Loan getters ---
    function getLoanDetails(address borrower) external view returns (
        address loanBorrower,
        address token,
        address merchant,
        uint256 principal,
        uint256 outstanding,
        uint256 startedAt,
        uint256 installmentsPaid,
        uint256 fee,
        bool active
    ) {
        Loan memory L = loans[borrower];
        return (L.borrower, L.token, L.merchant, L.principal, L.outstanding, L.startedAt, L.installmentsPaid, L.fee, L.active);
    }

    function outstandingOf(address borrower) external view returns (uint256) {
        return loans[borrower].outstanding;
    }

    function _isPrivileged(address user) internal view returns (bool) {
        return accessControl.isAdmin(user) || accessControl.isCreditOfficer(user);
    }

    /// @notice Aggregate loan statistics (gas heavy if many loans)
    function getLoanStats()
        external
        view
        returns (
            uint256 totalPrincipal,
            uint256 totalOutstanding,
            uint256 totalPaid,
            uint256 totalFees,
            uint256 activeCount,
            uint256 totalCount
        )
    {
        totalCount = borrowers.length;

        for (uint256 i = 0; i < totalCount; i++) {
            Loan storage L = loans[borrowers[i]];
            totalPrincipal += L.principal;
            totalOutstanding += L.outstanding;
            totalPaid += L.installmentsPaid;
            totalFees += L.fee;
            if (L.active) activeCount++;
        }
    }

    /// @notice Returns all borrower addresses
    function getAllBorrowers() external view returns (address[] memory) {
        return borrowers;
    }


}
