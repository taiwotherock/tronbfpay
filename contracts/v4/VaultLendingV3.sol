// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ITRC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IAccessControlModule {
    function isAdmin(address account) external view returns (bool);
    function isCreditOfficer(address account) external view returns (bool);
}


contract VaultLendingV3 {

    struct Loan {
        bytes32 ref;
        address borrower;
        address token;
        address merchant;
        uint256 principal;
        uint256 outstanding;     // principal + remaining fee
        uint256 startedAt;
        uint256 installmentsPaid;
        uint256 fee;             // remaining fee
        uint256 totalPaid;       // total repaid (principal + fee)
        bool active;
        bool disbursed;
    }

     // ====== Timelock ======
    struct Timelock {
        uint256 amount;
        address token;      // address(0) for ETH
        address to;
        uint256 unlockTime;
        bool executed;
    }


    uint256 private nextLoanId = 1;
    IAccessControlModule public immutable accessControl;
    bool public paused;
    uint256 private _locked;
    uint256 private _platformFee;
    uint256 private _lenderFee;

    // Percentage rates use 1e6 = 100% (e.g. 2.5% = 25_000)
    uint256 private _platformFeeRate;           // e.g. 20_000 = 2%
    uint256 private _lenderFeeRate;             // e.g. 10_000 = 1%
    uint256 private _depositContributionPercent; // e.g. 100_000 = 10%


    // Loan tracking
    mapping(bytes32 => Loan) public loans;
    mapping(address => bytes32[]) private borrowerLoans;
    mapping(bytes32 => uint256) private loanIndex;

    // Vault & pool tracking
    mapping(address => mapping(address => uint256)) public vault;            // vault[user][token]
    mapping(address => mapping(address => uint256)) public lenderContribution; // lender[token]
    mapping(address => uint256) public totalPoolContribution;               // total principal per token
    mapping(address => uint256) public pool; 
    mapping(address => mapping(address => uint256)) public merchantFund; 
    mapping(address => uint256) private totalMerchantFund;
    
                                  // total liquidity including fees

    // Fee tracking (optimized)
    mapping(address => uint256) public cumulativeFeePerToken;               // accumulated fee per 1 token deposited
    mapping(address => mapping(address => uint256)) public feeDebt;         // lender[token] = claimed portion
    uint256 constant FEE_PRECISION = 1e6;

    // Borrower & lender tracking
    mapping(address => bool) private isBorrower;
    address[] private borrowers;

    mapping(address => bool) private isLender;
    address[] private lenders;

    // Events
    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    
    event LoanCreated(bytes32 ref, address borrower, uint256 principal, uint256 fee, 
    uint256 depositAmount, uint256 lenderFundDeducted, uint256 merchantSettledFund);

    event LoanDisbursed(bytes32 loanId, address borrower, uint256 amount);
    event LoanRepaid(bytes32 ref, address borrower, uint256 amount);
    event LoanClosed(bytes32 loanId, address borrower);
    event FeesWithdrawn(address indexed lender, address indexed token, uint256 amount);

    event Paused();
    event Unpaused();
    event Whitelisted(address indexed user, bool status);
    event Blacklisted(address indexed user, bool status);
    event FeeRateChanged(uint256 platformFeeRate, uint256 lenderFeeRate);
    event DepositContributionChanged(uint256 depositContributionPercent);
    event MerchantWithdrawn(address indexed merchant, address indexed token, uint256 amount);
  
    event TimelockCreated(bytes32 indexed id, address token, address to, uint256 amount, uint256 unlockTime);
    event TimelockExecuted(bytes32 indexed id);

    mapping(address => bool) public whitelist;
    mapping(address => bool) public blacklist;
       // ✅ Reentrancy guard per loan
    mapping(bytes32 => bool) private _loanLock;
    


    constructor(address _accessControl) {
        require(_accessControl != address(0), "Invalid access control");
        accessControl = IAccessControlModule(_accessControl);
        _locked = 1;
    }

    // ====== Reentrancy Guard ======
    modifier nonReentrant() {
        require(_locked == 1, "ReentrancyGuard: reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    // ====== Modifiers ======
    modifier onlyAdmin() {
        require(accessControl.isAdmin(msg.sender), "Only admin");
        _;
    }

    modifier onlyCreditOfficer() {
        require(accessControl.isCreditOfficer(msg.sender), "Only credit officer");
        _;
    }

    modifier onlyWhitelisted(address user) {
        require(whitelist[user], "User not whitelisted");
        _;
    }

    modifier notBlacklisted(address user) {
        require(!blacklist[user], "User is blacklisted");
        _;
    }

    modifier loanExists(bytes32 ref) {
        require(loans[ref].borrower != address(0), "Loan does not exist");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract paused");
        _;
    }

    modifier nonReentrantLoan(bytes32 ref) {
        require(!_loanLock[ref], "ReentrancyGuard: loan locked");
        _loanLock[ref] = true;
        _;
        _loanLock[ref] = false;
    }

    modifier onlyActiveLoan(bytes32 ref) {
        require(loans[ref].active, "Loan not active");
        _;
    }

    modifier onlyAuthorized() {
        
         require( accessControl.isAdmin(msg.sender) || accessControl.isCreditOfficer(msg.sender)
        , "permission denied");
        
         _;
    }

    // ====== Admin: Whitelist / Blacklist ======
    function setWhitelist(address user, bool status) external onlyAdmin {
        whitelist[user] = status;
        emit Whitelisted(user, status);
    }

    function setBlacklist(address user, bool status) external onlyAdmin {
        blacklist[user] = status;
        emit Blacklisted(user, status);
    }

    // ====== Admin: Pause / Unpause ======
    function pause() external onlyAdmin {
        paused = true;
        emit Paused();
    }

    function unpause() external onlyAdmin {
        paused = false;
        emit Unpaused();
    }

    function setFeeRate(uint256 platformFeeRate, uint256 lenderFeeRate) external onlyAdmin {
        require(platformFeeRate + lenderFeeRate <= 1e6, "Invalid fee setup");
        _platformFeeRate = platformFeeRate;
        _lenderFeeRate = lenderFeeRate;
        emit FeeRateChanged(platformFeeRate, lenderFeeRate);
    }

    function setDepositContributionPercent(uint256 depositContributionPercent) external onlyAdmin {
        _depositContributionPercent = depositContributionPercent;
        emit DepositContributionChanged(depositContributionPercent);
    }

    /* ========== VAULT FUNCTIONS ========== */

    function depositToVault(address token, uint256 amount) external {
        require(amount > 0, "Amount must be > 0");
        ITRC20(token).transferFrom(msg.sender, address(this), amount);

        // Update lender fee debt before increasing contribution
        //feeDebt[msg.sender][token] += (amount * cumulativeFeePerToken[token]) / FEE_PRECISION;

        vault[msg.sender][token] += amount;
        lenderContribution[msg.sender][token] += amount;
        totalPoolContribution[token] += amount;
        pool[token] += amount;

        if (!isLender[msg.sender]) {
            lenders.push(msg.sender);
            isLender[msg.sender] = true;
        }

        emit Deposit(msg.sender, token, amount);
    }

    //

    function withdrawFromVault(address token, uint256 amount) external
    whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) nonReentrant 
      {
        require(vault[msg.sender][token] >= amount, "Insufficient vault balance");
        require(_getTotalOutstanding(msg.sender) == 0, "has outstanding loan" );

        // Update lender contribution and pool
        vault[msg.sender][token] -= amount;
        if (lenderContribution[msg.sender][token] >= amount) {
            lenderContribution[msg.sender][token] -= amount;
            totalPoolContribution[token] -= amount;
            pool[token] -= amount;
        }

         ITRC20 tokenA = ITRC20(token);
        //IERC20(token).transfer(msg.sender, amount);
        // Safe transfer with inline revert check
           (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, msg.sender, amount)
            );

        //_safeTransfer(tokenA, msg.sender, amount);

        emit Withdraw(msg.sender, token, amount);
    }

    function _safeTransfer(ITRC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransfer: failed");
    }

    function _safeTransferFrom(ITRC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) =
            address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeTransferFrom: failed");
    }

    /* ========== LOAN FUNCTIONS ========== */

    function createLoan(bytes32 ref,address token, address merchant, uint256 principal,
     uint256 fee, uint256 depositAmount, address borrower)
     external onlyCreditOfficer {
        require(pool[token] >= principal, "Insufficient pool liquidity");
        require(whitelist[borrower], "Borrower not whitelisted");
        require(whitelist[merchant], "Merchant not whitelisted");
        require(vault[borrower][token] >= depositAmount, "Insufficient vault balance");
        require(merchant != address(0), "Invalid merchant");

         // ---- Calculate components ----
        uint256 platformFee = (principal * _platformFeeRate) / 1e6;
        uint256 lenderFee = (principal * _lenderFeeRate) / 1e6;
        uint256 depositRequired = (principal * _depositContributionPercent) / 1e6;
        require(depositAmount >= depositRequired, "Deposit too low");

        uint256 lenderFundDeducted = principal - depositRequired;
        uint256 merchantSettledFund = principal - platformFee - lenderFee;

        // ---- Update storage ----
        _platformFee += platformFee;
        _lenderFee += lenderFee;
        merchantFund[merchant][token] += merchantSettledFund;
        totalMerchantFund[token] += merchantSettledFund;

        Loan storage l = loans[ref];
        l.ref = ref;
        l.borrower = borrower;
        l.token = token;
        l.merchant = merchant;
        l.principal = principal;
        l.outstanding = principal - depositAmount ;
        l.startedAt = block.timestamp;
        l.installmentsPaid = 0;
        l.fee = fee;
        l.totalPaid = depositAmount;
        l.active = true;
        l.disbursed = false;


        // Track borrower
        loanIndex[ref] = borrowerLoans[borrower].length;
        borrowerLoans[borrower].push(ref);
        if (!isBorrower[borrower]) {
            borrowers.push(borrower);
            isBorrower[borrower] = true;
        }

        // Disburse principal to borrower vault
        pool[token] -= principal;
        //vault[msg.sender][token] += principal;
        vault[borrower][token] -= depositAmount;
        lenderContribution[borrower][token] -= depositAmount;
        
        //totalPoolContribution[token] -= depositAmount

       emit LoanCreated(ref, borrower, principal, fee,depositAmount,lenderFundDeducted,merchantSettledFund);
      
    }

    function withdrawMerchantFund(address token) external 
    whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) nonReentrant  {
        address merchant = msg.sender;
        uint256 available = merchantFund[merchant][token];
        require(available > 0, "No funds to withdraw");

        // Reset balance BEFORE external call (prevents reentrancy)
        merchantFund[merchant][token] = 0;
        totalMerchantFund[token] -= available;

        // Execute safe TRC20 transfer
        ITRC20 tokenA = ITRC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, merchant, available)
         );
        //bool success = ITRC20(token).transfer(merchant, available);
        require(success, "Token transfer failed");

        emit MerchantWithdrawn(merchant, token, available);
    }

    function repayLoan(bytes32 ref, uint256 amount) external nonReentrant  {
        Loan storage loan = loans[ref];
        require(loan.active, "Loan is closed");
        require(loan.borrower == msg.sender, "Not borrower");
        require(amount > 0, "Amount must be > 0");
        require(loan.outstanding > 0, "Outstanding must be > 0");

        uint256 remaining = amount;

        ITRC20(loan.token).transferFrom(msg.sender, address(this), remaining);
        pool[loan.token] += remaining;
        loan.outstanding -= amount;
        loan.totalPaid += amount;

        if (loan.outstanding == 0) {
            loan.active = false;
            _removeLoanFromBorrower(msg.sender, ref);
            emit LoanClosed(ref, msg.sender);
        }

        emit LoanRepaid(ref, msg.sender, amount);
    }

    /*function _addFeeToPool(address token, uint256 feeAmount) internal {
        if (totalPoolContribution[token] == 0) return;
        cumulativeFeePerToken[token] += (feeAmount * FEE_PRECISION) / totalPoolContribution[token];
        pool[token] += feeAmount;
    }*/

    function _removeLoanFromBorrower(address borrower, bytes32 ref) internal {
        uint256 index = loanIndex[ref];
        bytes32 lastRef = borrowerLoans[borrower][borrowerLoans[borrower].length - 1];

        // Replace the removed ref with the last one
        borrowerLoans[borrower][index] = lastRef;
        loanIndex[lastRef] = index;

        // Remove last element and delete index mapping
        borrowerLoans[borrower].pop();
        delete loanIndex[ref];
    }

    /* ========== FEE WITHDRAWAL ========== */

    function getWithdrawableFees(address lender, address token) public view returns (uint256) {
        uint256 contribution = lenderContribution[lender][token];
        if (contribution == 0) return 0;

        uint256 accumulatedFee = (contribution * cumulativeFeePerToken[token]) / FEE_PRECISION;
        uint256 withdrawable = accumulatedFee > feeDebt[lender][token] ? accumulatedFee - feeDebt[lender][token] : 0;
        return withdrawable;
    }

    function withdrawFees(address token) external 
    whenNotPaused notBlacklisted(msg.sender) onlyAdmin {
        uint256 amount = getWithdrawableFees(msg.sender, token);
        require(amount > 0, "No fees to withdraw");

        feeDebt[msg.sender][token] += amount;
        pool[token] -= amount;

        ITRC20(token).transfer(msg.sender, amount);
        emit FeesWithdrawn(msg.sender, token, amount);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getBorrowerStats(address borrower, address token) 
        external 
        view 
        returns (uint256 vaultBalance, uint256 totalPaidToPool) 
    {
        vaultBalance = vault[borrower][token];
        totalPaidToPool = 0;

        bytes32[] memory refs = borrowerLoans[borrower];
        for (uint256 i = 0; i < refs.length; i++) {
            Loan storage loan = loans[refs[i]];
            if (loan.token == token) {
                totalPaidToPool += loan.totalPaid;
            }
        }
    }

    function getLenderStats(address lender, address token) 
        external 
        view 
        returns (
            uint256 deposit,
            uint256 poolShare,
            uint256 totalFeesEarned,
            uint256 feesClaimed
        ) 
    {
        deposit = vault[lender][token];
        feesClaimed = feeDebt[lender][token];

        uint256 contribution = lenderContribution[lender][token];
        uint256 totalAccumulatedFee = (contribution * cumulativeFeePerToken[token]) / FEE_PRECISION;
        totalFeesEarned = totalAccumulatedFee;
        poolShare = deposit + (totalFeesEarned - feesClaimed);
    }

    function getProtocolStats(address token) 
        external 
        view 
        returns (
            uint256 numLenders,
            uint256 numBorrowers,
            uint256 totalLenderDeposits,
            uint256 totalBorrowed,
            uint256 totalOutstanding,
            uint256 totalPaid
        ) 
    {
        numLenders = lenders.length;
        totalLenderDeposits = 0;
        for (uint256 i = 0; i < lenders.length; i++) {
            totalLenderDeposits += vault[lenders[i]][token];
        }

        numBorrowers = borrowers.length;
        totalBorrowed = 0;
        totalOutstanding = 0;
        totalPaid = 0;
        for (uint256 i = 0; i < borrowers.length; i++) {
            bytes32[] memory ids = borrowerLoans[borrowers[i]];
            for (uint256 j = 0; j < ids.length; j++) {
                Loan storage loan = loans[ids[j]];
                if (loan.token == token) {
                    totalBorrowed += loan.principal;
                    totalOutstanding += loan.outstanding;
                    totalPaid += loan.totalPaid;
                }
            }
        }
    }

    function getAllBorrowers() external view returns (address[] memory) {
        return borrowers;
    }

    function getAllLenders() external view returns (address[] memory) {
        return lenders;
    }


        // 🔹 INTERNAL function — reusable inside contract
        function _getTotalOutstanding(address borrower) internal view returns (uint256 totalOutstanding) {
            bytes32[] storage ids = borrowerLoans[borrower];
            uint256 len = ids.length;

            for (uint256 i = 0; i < len; i++) {
                Loan storage l = loans[ids[i]];
                if (l.active) {
                    totalOutstanding += l.outstanding;
                }
            }
        }

        // 🔹 EXTERNAL function — exposed to other contracts or frontends
        function getTotalOutstanding(address borrower) external view returns (uint256) {
            return _getTotalOutstanding(borrower);
        }

   
    function getLoans(address borrower, uint256 offset, uint256 limit) 
        external view returns (Loan[] memory result, uint256 totalLoans, uint256 nextOffset)
    {
        bytes32[] storage ids = borrowerLoans[borrower];
        totalLoans = ids.length;

        if (offset >= totalLoans) {
            // Return empty result if offset is out of bounds
           // return ; // (new Loan()[0] , totalLoans, totalLoans);
        }

        uint256 end = offset + limit;
        if (end > totalLoans) {
            end = totalLoans;
        }

        uint256 length = end - offset;
        result = new Loan[](length);

        for (uint256 i = 0; i < length; i++) {
            result[i] = loans[ids[offset + i]];
        }

        nextOffset = end;
    }

    // ====== Public Read Functions ======
    function getPlatformFeeRate() external view returns (uint256) {
        return _platformFeeRate;
    }

    function getLenderFeeRate() external view returns (uint256) {
        return _lenderFeeRate;
    }

    function getDepositContributionPercent() external view returns (uint256) {
        return _depositContributionPercent;
    }

    function getTotalPlatformFee() external view returns (uint256) {
        return _platformFee;
    }

    function getTotalLenderFee() external view returns (uint256) {
        return _lenderFee;
    }

    function getMerchantFund(address merchant, address token) external view onlyAuthorized() returns (uint256) {
        return merchantFund[merchant][token];
    }
    function getTotalMerchantFund(address token) external view onlyAuthorized() returns (uint256)
     { 
        return totalMerchantFund[token];
     }

     function getLoanData(bytes32 ref)
        external
        view
        returns (
            address borrower,
            address merchant,
            uint256 principal,
            uint256 outstanding,
            uint256 totalPaid
        )
    {
        Loan storage l = loans[ref];
        borrower = l.borrower;
        merchant = l.merchant;
        principal = l.principal;
        outstanding = l.outstanding;
        totalPaid = l.totalPaid;
    }

    function getVaultBalance(address borrower, address token) external view returns (uint256) {
        return vault[borrower][token];
    }

    function isWhitelisted(address user) external view returns (bool) {
        return whitelist[user];
    }
}
