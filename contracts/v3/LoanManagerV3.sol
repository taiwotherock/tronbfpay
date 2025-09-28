// SPDX-License-Identifier: MIT
pragma solidity ^0.5.4;

import "../libs/ReentrancyGuard.sol";
import "../libs/SafeTRC20.sol";

/*
interface ITRC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}*/

interface ILiquidityPool {
    // pull funds from the pool to the `to` address
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

contract LoanManagerV3 is ReentrancyGuard {
    using SafeTRC20 for ITRC20;

    // External system addresses
    address public accessControl;
    ILiquidityPool public liquidityPool;
    ILoanVaultCore public vault;
    IBorderlessCreditNFT public creditNFT;

    bool public paused;

    // Fee configuration (bps = parts per 10,000)
    // merchantFeeBps is 800 = 8% of TOTAL amount
    uint256 public merchantFeeBps = 800; // 8% of totalAmount
    // Splits of the total amount (expressed directly as bps of totalAmount):
    // platform gets 100 bps (1% of total), lender income gets 700 bps (7% of total).
    uint256 public platformFeeOfTotalBps = 100; // 1% of total amount
    uint256 public lenderIncomeOfTotalBps = 700; // 7% of total amount

    address public platformFeeAddress;       // gets the platform 1% (of total)
    address public lenderPoolIncomeAddress;  // gets the lender 7% (of total)

    // Loan record per borrower (one loan at a time)
    struct Loan {
        address borrower;
        address token;
        address merchant;        // NEW: settlement merchant address for this loan
        uint256 principal;       // the lender-funded principal (66% of total)
        uint256 outstanding;     // outstanding principal
        uint256 startedAt;
        uint8 installmentsPaid;
        uint8 totalInstallments; // typically 2 (second + third)
        uint256 installmentAmount;
        bool active;
    }

    struct CreditLimitScale {
        uint256 minScore;
        uint256 maxScore;
        uint256 creditLimit;
    }

    mapping(address => Loan) public loans;
    mapping(uint16 => CreditLimitScale) public creditLimitScales;
    uint16 public scaleCount;

    // Events - full accounting
    event LoanRequested(address indexed borrower, uint256 requestedAmount, address indexed merchant);
    event LoanApproved(address indexed borrower, uint256 totalAmount, address indexed token, address indexed merchant);
    event MerchantSettlement(address indexed token, uint256 amount, address indexed merchant);
    event PlatformFeePosted(address indexed token, uint256 amount, address indexed platformFeeAddr);
    event LenderFeePosted(address indexed token, uint256 amount, address indexed lenderPoolAddr);
    event BorrowerRepayment(address indexed borrower, address indexed token, uint256 amount, uint8 installmentNo);
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

    constructor(
        address _accessControl,
        address _liquidityPool,
        address _vault,
        address _creditNFT,
        address _platformFeeAddr,
        address _lenderPoolIncomeAddr
    ) public {
        require(_accessControl != address(0), "LoanManager: zero accessControl");
        require(_liquidityPool != address(0), "LoanManager: zero liquidityPool");
        require(_vault != address(0), "LoanManager: zero vault");
        require(_creditNFT != address(0), "LoanManager: zero creditNFT");
        require(_platformFeeAddr != address(0), "LoanManager: zero platform fee addr");
        require(_lenderPoolIncomeAddr != address(0), "LoanManager: zero lender income addr");

        accessControl = _accessControl;
        liquidityPool = ILiquidityPool(_liquidityPool);
        vault = ILoanVaultCore(_vault);
        creditNFT = IBorderlessCreditNFT(_creditNFT);
        platformFeeAddress = _platformFeeAddr;
        lenderPoolIncomeAddress = _lenderPoolIncomeAddr;
        paused = false;
    }

    // --- pause controls ---
    function pause() external onlyAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // --- admin setters ---
    function setFeeAddresses(address _platformFeeAddr, address _lenderPoolIncomeAddr) external onlyAdmin {
        require(_platformFeeAddr != address(0) && _lenderPoolIncomeAddr != address(0), "LoanManager: zero addr");
        platformFeeAddress = _platformFeeAddr;
        lenderPoolIncomeAddress = _lenderPoolIncomeAddr;
    }

    function setMerchantFeeBps(uint256 _bps) external onlyAdmin {
        require(_bps <= 2000, "LoanManager: fee too high"); // max 20% safeguard
        merchantFeeBps = _bps;
    }

    function setPlatformAndLenderFeeSplits(uint256 _platformBpsOfTotal, uint256 _lenderIncomeBpsOfTotal) external onlyAdmin {
        require(_platformBpsOfTotal + _lenderIncomeBpsOfTotal == merchantFeeBps, "LoanManager: splits must sum to merchantFeeBps");
        platformFeeOfTotalBps = _platformBpsOfTotal;
        lenderIncomeOfTotalBps = _lenderIncomeBpsOfTotal;
    }

    // --- privileged check helper ---
    function _isAdmin(address user) internal view returns (bool) {
        return IAccessControl(accessControl).isAdmin(user);
    }

    function _isCreditOfficer(address user) internal view returns (bool) {
        return IAccessControl(accessControl).isCreditOfficer(user);
    }

    function _isKeeper(address user) internal view returns (bool) {
        return IAccessControl(accessControl).isKeeper(user);
    }

    function _isPrivileged(address user) internal view returns (bool) {
        return _isAdmin(user) || _isCreditOfficer(user);
    }

    // --- credit limit scales (admin only) ---
    function addCreditLimitScale(uint256 minScore, uint256 maxScore, uint256 creditLimit) public onlyAdmin returns (uint16) {
        require(minScore <= maxScore, "Invalid score range");
        if (scaleCount > 0) {
            require(minScore > creditLimitScales[scaleCount - 1].maxScore, "Scales must not overlap");
        }
        uint16 scaleId = scaleCount;
        creditLimitScales[scaleId] = CreditLimitScale(minScore, maxScore, creditLimit);
        scaleCount++;
        return scaleId;
    }

    function addCreditLimitScalesBatch(uint256[] calldata minScores, uint256[] calldata maxScores, uint256[] calldata creditLimits) external onlyAdmin {
        require(minScores.length == maxScores.length && maxScores.length == creditLimits.length, "Array length mismatch");
        require(minScores.length > 0, "No scales provided");
        for (uint256 i = 0; i < minScores.length; i++) {
            addCreditLimitScale(minScores[i], maxScores[i], creditLimits[i]);
        }
    }

    function updateCreditLimitScale(uint16 scaleId, uint256 newMinScore, uint256 newMaxScore, uint256 newCreditLimit) external onlyAdmin {
        require(scaleId < scaleCount, "Scale does not exist");
        require(newMinScore <= newMaxScore, "Invalid score range");
        if (scaleId > 0) {
            require(newMinScore > creditLimitScales[scaleId - 1].maxScore, "Overlap with previous scale");
        }
        if (scaleId < scaleCount - 1) {
            require(newMaxScore < creditLimitScales[scaleId + 1].minScore, "Overlap with next scale");
        }
        CreditLimitScale storage scale = creditLimitScales[scaleId];
        scale.minScore = newMinScore;
        scale.maxScore = newMaxScore;
        scale.creditLimit = newCreditLimit;
    }

    // Public getter for scale-based credit limit (binary search)
    function getCreditLimitByScore(uint256 score) public view returns (uint256) {
        if (scaleCount == 0) return 0;
        uint16 left = 0;
        uint16 right = scaleCount - 1;
        while (left <= right) {
            uint16 mid = left + (right - left) / 2;
            CreditLimitScale memory scale = creditLimitScales[mid];
            if (score < scale.minScore) {
                if (mid == 0) break;
                right = mid - 1;
            } else if (score > scale.maxScore) {
                left = mid + 1;
            } else {
                return scale.creditLimit;
            }
        }
        return 0;
    }

    // --- borrower loan request (optional step) ---
    // Borrower can request a loan and provide intended merchant address for settlement.
    function requestLoan(address tokenToBorrow, uint256 requestedAmount, address merchantAddr) external whenNotPaused {
        require(!_isPrivileged(msg.sender), "LoanManager: privileged users cannot borrow");
        require(tokenToBorrow != address(0), "LoanManager: zero token");
        require(merchantAddr != address(0), "LoanManager: zero merchant");
        require(!loans[msg.sender].active, "LoanManager: one loan at a time");

        uint16 score = creditNFT.getCreditScoreByBorrower(msg.sender);
        uint256 nftLimit = creditNFT.getCreditLimitByBorrower(msg.sender);
        uint256 scaleMin = getCreditLimitByScore(score);

        require(requestedAmount > 0, "LoanManager: zero amount");
        require(score > 0, "LoanManager: invalid credit score");
        require(requestedAmount <= nftLimit, "LoanManager: exceeds credit limit");
        require(requestedAmount >= scaleMin, "LoanManager: below minimum for score");

        uint256 requiredCollateral = (requestedAmount * 30) / 100;
        uint256 coll = vault.collateral(msg.sender, tokenToBorrow);
        require(coll >= requiredCollateral, "LoanManager: insufficient collateral");

        emit LoanRequested(msg.sender, requestedAmount, merchantAddr);
    }

    /** 
     * approveAndDisburse:
     * - totalAmount: full purchase amount
     * - merchantAddr: settlement address for merchant for this purchase
     *
     * Flow:
     * 1) Borrower pays 34% directly to merchant (contract transfers from borrower -> merchant; borrower must have approved).
     * 2) LiquidityPool provides 66% (pullFunds to this contract).
     * 3) From totalAmount, merchant fee = merchantFeeBps (default 8% of total).
     *    - platform fee = platformFeeOfTotalBps (1% of total)
     *    - lender income = lenderIncomeOfTotalBps (7% of total)
     * 4) Transfer fees to respective fee addresses and transfer remaining lender funds to merchant.
     * 5) Create loan representing outstanding lender principal (66% of total).
     */
    function approveAndDisburse(
        address borrower,
        address tokenToBorrow,
        uint256 totalAmount,
        address merchantAddr
    ) external onlyCreditOfficer nonReentrant whenNotPaused {
        require(!_isPrivileged(borrower), "LoanManager: privileged cannot borrow");
        require(borrower != address(0), "LoanManager: zero borrower");
        require(merchantAddr != address(0), "LoanManager: zero merchant");
        require(!loans[borrower].active, "LoanManager: existing loan");
        require(totalAmount > 0, "LoanManager: zero amount");

        uint16 score = creditNFT.getCreditScoreByBorrower(borrower);
        uint256 nftLimit = creditNFT.getCreditLimitByBorrower(borrower);
        require(score > 0, "LoanManager: invalid score");
        require(totalAmount <= nftLimit, "LoanManager: exceeds credit limit");

        // split amounts
        uint256 borrowerPart = (totalAmount * 34) / 100; // 34% paid by borrower
        uint256 lenderPart = totalAmount - borrowerPart; // 66% funded by lenders

        // fees expressed as bps of totalAmount
        uint256 feeAmount = (totalAmount * merchantFeeBps) / 10000;
        uint256 platformFee = (totalAmount * platformFeeOfTotalBps) / 10000;
        uint256 lenderIncome = (totalAmount * lenderIncomeOfTotalBps) / 10000;
        // sanity: platformFee + lenderIncome should equal feeAmount
        require(platformFee + lenderIncome == feeAmount, "Fee split mismatch");

        // 1) Borrower -> merchant (34%)
        if (borrowerPart > 0) {
            ITRC20(tokenToBorrow).safeTransferFrom(borrower, merchantAddr, borrowerPart);
            emit MerchantSettlement(tokenToBorrow, borrowerPart, merchantAddr);
        }

        // 2) Pull lender funds (66%) from liquidity pool to this contract
        if (lenderPart > 0) {
            liquidityPool.pullFunds(tokenToBorrow, address(this), lenderPart);
        }

        // 3) Distribute fees
        if (platformFee > 0) {
            ITRC20(tokenToBorrow).safeTransfer(platformFeeAddress, platformFee);
            emit PlatformFeePosted(tokenToBorrow, platformFee, platformFeeAddress);
        }
        if (lenderIncome > 0) {
            ITRC20(tokenToBorrow).safeTransfer(lenderPoolIncomeAddress, lenderIncome);
            emit LenderFeePosted(tokenToBorrow, lenderIncome, lenderPoolIncomeAddress);
        }

        // 4) Transfer remainder of lender part to merchant (lenderPart - feeAmount)
        uint256 merchantFromLender = 0;
        if (lenderPart > feeAmount) {
            merchantFromLender = lenderPart - feeAmount;
            ITRC20(tokenToBorrow).safeTransfer(merchantAddr, merchantFromLender);
            emit MerchantSettlement(tokenToBorrow, merchantFromLender, merchantAddr);
        }

        // 5) Create loan for borrower representing lender-funded principal
        //uint8 installments = 2; // second + third repayments
        //uint256 installmentAmount = lenderPart / uint256(installments);

        // Create loan struct (avoid stack too deep by assigning fields individually)
        Loan storage L = loans[borrower];
        L.borrower = borrower;
        L.token = tokenToBorrow;
        L.merchant = merchantAddr;
        L.principal = lenderPart;
        L.outstanding = lenderPart;
        L.startedAt = block.timestamp;
        L.installmentsPaid = 0;
        L.totalInstallments = 2; // second + third repayments
        L.installmentAmount = lenderPart / 2;
        //L.merchantFee = feeAmount;
        //L.platformFee = platformFee;
        //L.lenderIncomeFee = lenderIncome;
        L.active = true;

        emit LoanApproved(borrower, totalAmount, tokenToBorrow, merchantAddr);
    }

    /**
     * repay:
     * Borrower repays installment(s). Funds flow directly into the lenders liquidity pool.
     * Each repayment reduces outstanding; when outstanding reaches 0 loan is closed.
     */
    function repay(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "LoanManager: zero amount");
        Loan storage L = loans[msg.sender];
        require(L.active, "LoanManager: no active loan");
        require(token == L.token, "LoanManager: wrong token");

        uint256 payAmount = amount;
        if (payAmount > L.outstanding) {
            payAmount = L.outstanding;
        }

        // Transfer from borrower into liquidity pool (lenders)
        ITRC20(token).safeTransferFrom(msg.sender, address(liquidityPool), payAmount);

        L.outstanding = L.outstanding - payAmount;
        L.installmentsPaid = L.installmentsPaid + 1;

        emit BorrowerRepayment(msg.sender, token, payAmount, L.installmentsPaid);

        if (L.outstanding == 0) {
            L.active = false;
            emit LoanRepaid(msg.sender);
        }
    }

    // Keeper/admin liquidation helper
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
            L.outstanding = L.outstanding - amountNeeded;
        }
    }

        // Fetch full loan details for a borrower
    function getLoanDetails(address borrower) external view returns (
        address loanBorrower,
        address token,
        address merchant,
        uint256 principal,
        uint256 outstanding,
        uint256 startedAt,
        uint8 installmentsPaid,
        uint8 totalInstallments,
        uint256 installmentAmount,
        bool active
    ) {
        Loan memory L = loans[borrower];
        return (
            L.borrower,
            L.token,
            L.merchant,
            L.principal,
            L.outstanding,
            L.startedAt,
            L.installmentsPaid,
            L.totalInstallments,
            L.installmentAmount,
            L.active
        );
    }


    // Expose outstanding
    function outstandingOf(address borrower) external view returns (uint256) {
        return loans[borrower].outstanding;
    }
}
