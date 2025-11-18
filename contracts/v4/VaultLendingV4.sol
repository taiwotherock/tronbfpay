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

interface IBNPLAttestationOracle {
    function getAttestation(address borrower) external view returns (
        uint256 creditLimit,
        uint256 creditScore,
        bool kycVerified,
        uint256 utilizedLimit,
        address attestor,
        uint256 updatedAt
    );

    function increaseUsedCredit(address borrower, uint256 amount) external;
    function decreaseUsedCredit(address borrower, uint256 amount) external;
}


contract VaultLendingV4 {

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
        bool disbursed;
        uint256 repaidFee;  
        uint256 lastPaymentTs;
        uint256 maturityDate;
        LoanStatus status;
    }

     // ====== Timelock ======
    struct Timelock {
        uint256 amount;
        address token;      // address(0) for ETH
        address to;
        uint256 unlockTime;
        bool executed;
    }

   // ====== Loan Struct ======
    enum LoanStatus { None, Active, Closed, Defaulted, WrittenOff }
   
    string public name;
    string public symbol;
    uint8 public immutable decimals = 6; // TRON-based tokens often 6 decimals

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    ITRC20 public depositToken;
    

    uint256 private nextLoanId = 1;
    IAccessControlModule public immutable accessControl;
    IBNPLAttestationOracle public attestationOracle;
    bool public paused;
    uint256 private _locked;
    uint256 private _platformFee;
    uint256 private _lenderFee;

    // Percentage rates use 1e6 = 100% (e.g. 2.5% = 25_000)
    uint256 private _platformFeeRate;           // e.g. 20_000 = 2%
    uint256 private _lenderFeeRate;             // e.g. 10_000 = 1%
    uint256 private _depositContributionPercent; // e.g. 100_000 = 10%

     // ====== Pool Stats ======
    uint256 public poolCash;
    uint256 public totalPrincipalOutstanding;

    uint256 public reserveBalance;      // reserve for bad debt (wei)
    uint256 public totalDistributableEarnings; // earnings available (interest minus reserve cuts), included in poolCash
     // platform treasury where platform fees will be sent on withdraw
    address public platformTreasury;
    uint256 private loanCounter = 0;
    uint256 private totalDisbursedToMerchant = 0;
    uint256 private _minCreditScore = 80;
  
    uint256 public constant FEE_BASE = 1e6; // 100%
    uint256 public reserveRateBP = 500; // basis points: 500 = 5%
    uint256 public writeOffDays = 180;   // days after which loan may be written off
    uint256 public constant BP_DIVISOR = 10000;
    uint256 public constant DECIMAL_MULTIPLIER = 1e6;


    // Loan tracking
    mapping(bytes32 => Loan) public loans;
    mapping(address => bytes32[]) private borrowerLoans;
    mapping(bytes32 => uint256) private loanIndex;
    //mapping(bytes32 => uint256) internal loanIndex;
    bytes32[] public loanRefs;

    // Vault & pool tracking
    mapping(address => mapping(address => uint256)) public vault;            // vault[user][token]
    mapping(address => mapping(address => uint256)) public lenderContribution; // lender[token]
    mapping(address => uint256) public totalPoolContribution;               // total principal per token
    mapping(address => mapping(address => uint256)) public merchantFund; 
    mapping(address => uint256) private totalMerchantFund;
     
    uint256 constant FEE_PRECISION = 1e6;

    // Borrower & lender tracking
    mapping(address => bool) private isBorrower;
    address[] private borrowers;
    address token;

    mapping(address => bool) private isLender;
    address[] private lenders;

    // Events
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);
    
    event LoanCreated(bytes32 ref, address borrower, uint256 principal, uint256 fee, 
    uint256 depositAmount, uint256 lenderFundDeducted, uint256 merchantSettledFund);

    event LoanDisbursed(bytes32 loanId, address borrower, uint256 amount);
    event LoanRepaid(bytes32 ref, address borrower, uint256 amount);
    event LoanClosed(bytes32 loanId, address borrower);
    event LoanDefaulted(bytes32 indexed loanId,address indexed borrower, uint256 indexed outstanding);
    event LoanWrittenOff(bytes32 indexed loanId, uint256 indexed lossCoveredByReserve, uint256 indexed lossToPool);

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
  
    constructor(
        address _accessControl,
        address _depositToken,
        address _platformTreasury,
        address _attestationOracle,
        string memory _name,
        string memory _symbol
    ) {
         require(_accessControl != address(0), "Invalid access control");
        accessControl = IAccessControlModule(_accessControl);
        depositToken = ITRC20(_depositToken);
        platformTreasury = _platformTreasury;
        attestationOracle = IBNPLAttestationOracle(_attestationOracle);
        token = _depositToken;
        name = _name;
        symbol = _symbol;
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
        require(loans[ref].status == LoanStatus.Active, "Loan not active");
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

    function setFeeRate(uint256 platformFeeRate, uint256 lenderFeeRate,uint256 ) external onlyAdmin {
        require(platformFeeRate + lenderFeeRate <= 1e6, "Invalid fee setup");
        _platformFeeRate = platformFeeRate;
        _lenderFeeRate = lenderFeeRate;
        emit FeeRateChanged(platformFeeRate, lenderFeeRate);
    }

    function setDepositContributionPercent(uint256 depositContributionPercent) external onlyAdmin {
        _depositContributionPercent = depositContributionPercent;
        emit DepositContributionChanged(depositContributionPercent);
    }

      // ====== LP Token Accounting ======
    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function _shareBalance(address from) internal view returns (uint256) {
        return balanceOf[from];
    }

    // -----------------------
    // NAV & share price
    // -----------------------
    /// @notice NAV = poolCash + outstanding principal + reserve
    function _nav() internal view returns (uint256) {
        return poolCash + totalPrincipalOutstanding + reserveBalance;
    }

    function nav() external view returns (uint256) {
        return _nav();
    }

    function _getShareForAsset(uint256 amount) internal view returns (uint256)
    {
        uint256 supply = totalSupply;
        uint256 nav2 = _nav();

        uint256 shares;
        if (supply == 0 || nav2 == 0) {
            shares = amount; //* (10 ** decimals);
        } else {
            shares = (amount * supply) / nav2;
        }
        return shares;
    }

    function _getAssetForShare(uint256 sharesToBurn) internal view returns (uint256)
    {
        uint256 supply = totalSupply;
        uint256 nav2 = _nav();
        uint256 amount = (poolCash * sharesToBurn) / supply;
        return amount;
    }

    /// @notice share price scaled by 1e18
    /*function sharePrice() external view returns (uint256) {
        if (totalSupply == 0) return DECIMAL_MULTIPLIER;
        return (_nav() * DECIMAL_MULTIPLIER) / totalSupply;
    }*/


    /* ========== VAULT FUNCTIONS ========== */

    function deposit(uint256 amount) external returns (uint256 sharesMinted) {
        require(amount > 0, "Amount must be > 0");
        
        depositToken.transferFrom(msg.sender, address(this), amount);
        //require(depositToken.transferFrom(msg.sender, address(this), amount), "transfer failed");

        uint256 shares = _getShareForAsset(amount);
        _mint(msg.sender, shares);
         // --- Update multi-token pool variables ---
                        
        vault[msg.sender][token] += amount;       // user’s deposited balance
        lenderContribution[msg.sender][token] += amount;  // lender contribution

        poolCash += amount; // overall pool cash for NAV

         if (!isLender[msg.sender]) {
            lenders.push(msg.sender);
            isLender[msg.sender] = true;
        }
        emit Deposit(msg.sender, shares);
        return shares;
    }

    //

    function withdraw(uint256 sharesToBurn) external
       whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) nonReentrant 
      {
        
        //address token = depositToken;
        //uint256 sharesToBurn = balanceOf[from];
        require(sharesToBurn > 0, "zero shares");
        require(sharesToBurn >= balanceOf[msg.sender] , "Insufficient share");
        
        //require(vault[msg.sender][token] >= amount, "Insufficient vault balance");
        require(_getTotalOutstanding(msg.sender) == 0, "has outstanding loan");

        uint256 totalAssets = _nav();
                
        //require(sharesToBurn <= balanceOf[msg.sender], "insufficient shares");

        //assets = (share * totalAsset)/totalSupply of shares
        //shares = (asset * totalSupply)/totalAsset

       //uint256 amount = (sharesToBurn * totalAssets) / totalSupply; 

        //(num + supply - 1) / supply; // ceil

        // Update lender contribution and pool
        
        uint256 supply = totalSupply;
        uint256 amount = (poolCash * sharesToBurn) / supply;
        require(amount > 0, "nothing to withdraw");
        require(vault[msg.sender][token] >= amount, "insufficient vault balance");
        vault[msg.sender][token] -= amount;

        _burn(msg.sender, sharesToBurn);
        poolCash -= amount;
 
        // ITRC20 tokenA = ITRC20(token);
        // Safe transfer with inline revert check
         ITRC20 tokenA = ITRC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, msg.sender, amount)
         );
        require(success, "failed withdrawal");
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

    function createLoan(bytes32 ref, address merchant, uint256 principal,
     uint256 fee, uint256 depositAmount, address borrower,uint256 maturitySeconds)
     external onlyCreditOfficer {

        require(poolCash >= principal, "insufficient pool cash");
        require(whitelist[borrower], "Borrower not whitelisted");
        require(whitelist[merchant], "Merchant not whitelisted");
        require(vault[borrower][token] >= depositAmount, "Insufficient vault balance");
        require(merchant != address(0), "Invalid merchant");

         // ---- Calculate components ----
        uint256 platformFee = (principal * _platformFeeRate) / BP_DIVISOR;
        uint256 lenderFee = (principal * _lenderFeeRate) / BP_DIVISOR;
        uint256 depositRequired = (principal * _depositContributionPercent) / BP_DIVISOR;
        require(depositAmount >= depositRequired, "Deposit too low");

        uint256 shareSpent = _getShareForAsset(depositAmount);
        require(shareSpent > 0, "No share for borrower");

        (
            uint256 creditLimit,
            uint256 creditScore,
            bool kycVerified,
            uint256 utilizedLimit,
            address attestor,
            uint256 updatedAt
        ) = attestationOracle.getAttestation(borrower);

        require(kycVerified, "not KYC verified");
        require(creditScore >= _minCreditScore, "credit too low");
        require(utilizedLimit + principal <= creditLimit, "credit limit exceeded");
        
        uint256 lenderFundDeducted = principal - depositAmount;
        uint256 merchantSettledFund = principal - platformFee - lenderFee;

        // lender and platform earn fee from deposit made, some part of deposit is earmarket for reserve
        uint256 platformFeeEarn = (depositAmount * _platformFeeRate) / BP_DIVISOR;
        uint256 lenderFeeEarn = (depositAmount * _lenderFeeRate) / BP_DIVISOR;

        if (reserveRateBP > 0) {
            uint256 reserveCut = (lenderFeeEarn * reserveRateBP) / BP_DIVISOR;
            reserveBalance += reserveCut;
            lenderFeeEarn = lenderFeeEarn - reserveCut;
        }
       
        Loan storage l = loans[ref];
        l.ref = ref;
        l.borrower = borrower;
        l.token = token;
        l.merchant = merchant;
        l.principal = principal;
        l.outstanding = principal - depositAmount;
        l.startedAt = block.timestamp;
        l.installmentsPaid = 0;
        l.fee = platformFee + lenderFee;
        l.totalPaid = depositAmount;
        l.status = LoanStatus.Active;
        l.repaidFee = platformFeeEarn + lenderFeeEarn;
        l.disbursed = false;
        l.maturityDate = block.timestamp + maturitySeconds;
        l.lastPaymentTs = block.timestamp;

        loanCounter++;
        loanRefs.push(ref);
        loanIndex[ref] = loanRefs.length - 1;

        // ---- Update storage ----
        _platformFee += platformFeeEarn;
        _lenderFee += lenderFeeEarn; //lender fee earned
        merchantFund[merchant][token] += merchantSettledFund;
        totalMerchantFund[token] += merchantSettledFund;
        poolCash -= principal; // merchantSettledFund;

        // Disburse principal to borrower vault
        //vault[msg.sender][token] += principal;
        vault[borrower][token] -= depositAmount;
        lenderContribution[borrower][token] -= depositAmount;

        loanRefs.push(ref);
        loanIndex[ref] = loanRefs.length - 1;
        totalPrincipalOutstanding += (principal - depositAmount);
        _burn(borrower, shareSpent);
        
        //totalPoolContribution[token] -= depositAmount

       emit LoanCreated(ref, borrower, principal, fee,depositAmount,lenderFundDeducted,merchantSettledFund);
      
    }

    function withdrawMerchantFund() external 
    whenNotPaused notBlacklisted(msg.sender) onlyWhitelisted(msg.sender) nonReentrant  {
        address merchant = msg.sender;
       
        uint256 available = merchantFund[merchant][token];
        require(available > 0, "No funds to withdraw");

        // Reset balance BEFORE external call (prevents reentrancy)
        merchantFund[merchant][token] = 0;
        totalMerchantFund[token] -= available;
        totalDisbursedToMerchant += available;
       
        // Execute safe TRC20 transfer
        ITRC20 tokenA = ITRC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, merchant, available)
         );
        require(success, "Token transfer failed");
        poolCash -= available;

        emit MerchantWithdrawn(merchant, token, available);
    }

    function repayLoan(bytes32 ref, uint256 amount, address borrower) external nonReentrant  {
        Loan storage loan = loans[ref];
        require(loan.status == LoanStatus.Closed, "Loan is closed");
        require(loan.borrower == borrower, "Not borrower address");
        require(amount > 0, "Amount must be > 0");
        require(loan.outstanding > 0, "Outstanding must be > 0");

        uint256 remaining = amount;
        ITRC20(loan.token).transferFrom(msg.sender, address(this), remaining);
        
         // ---- 2. Fee split ----
        uint256 platformFee = (amount * _platformFeeRate) / 1e6;
        uint256 lenderFee = (amount * _lenderFeeRate) / 1e6;
        uint256 netAmount = amount - platformFee - lenderFee;

        attestationOracle.decreaseUsedCredit(loan.borrower, amount);

        _platformFee += platformFee;
        _lenderFee += lenderFee;
        totalPrincipalOutstanding -= amount;
        poolCash += amount;
         
        loan.outstanding -= amount;
        loan.totalPaid += amount;
        loan.repaidFee += platformFee + lenderFee;
        totalPrincipalOutstanding -= amount;

        if (loan.outstanding == 0) {
            loan.status = LoanStatus.Closed;
            _removeLoanFromBorrower(borrower, ref);
            emit LoanClosed(ref, msg.sender);
        }

        emit LoanRepaid(ref, msg.sender, amount);
    }

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
   
    function withdrawPlatformFees(uint256 amount) external 
       whenNotPaused notBlacklisted(msg.sender) onlyAdmin {
       
        require(amount > 0, "zero");
        require(amount <=_platformFee , "exceeds accrued");
        _platformFee -= amount;
        //poolCash -= amount;

         // Execute safe TRC20 transfer
        ITRC20 tokenA = ITRC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector,platformTreasury , amount)
         );
        require(success, "platform fee transfer failed");
        emit FeesWithdrawn(platformTreasury, token, amount);
    }

     /// @notice Mark a loan as defaulted (called by owner/credit officer after delinquency)
    function markDefault(bytes32 ref) external onlyCreditOfficer whenNotPaused {
        Loan storage loan = loans[ref];
        require(loan.status == LoanStatus.Active, "not active");
        loan.status = LoanStatus.Defaulted;
        emit LoanDefaulted(ref, loan.borrower, loan.outstanding);
    }

    /// @notice Write off a defaulted loan. Uses reserve first, then poolCash. Reduces NAV.
    function writeOffLoan(bytes32 ref) external onlyCreditOfficer whenNotPaused nonReentrant {
        Loan storage loan = loans[ref];
        require(loan.status == LoanStatus.Defaulted, "not defaulted");

        uint256 loss = loan.outstanding;
        if (loss == 0) {
            loan.status = LoanStatus.WrittenOff;
            emit LoanWrittenOff(ref, 0, 0);
            return;
        }

        // zero out outstanding
        loan.outstanding = 0;
        loan.status = LoanStatus.WrittenOff;

        // reduce totalPrincipalOutstanding
        if (totalPrincipalOutstanding >= loss) {
            totalPrincipalOutstanding -= loss;
        } else {
            totalPrincipalOutstanding = 0;
        }

        uint256 coveredByReserve = 0;
        uint256 lossToPool = 0;

        // consume reserve
        if (reserveBalance >= loss) {
            reserveBalance -= loss;
            coveredByReserve = loss;
            lossToPool = 0;
        } else {
            coveredByReserve = reserveBalance;
            uint256 remaining = loss - reserveBalance;
            reserveBalance = 0;

            // consume poolCash
            if (poolCash >= remaining) {
                poolCash -= remaining;
                lossToPool = remaining;
            } else {
                // if insufficient poolCash, consume what's left and remaining is implicit NAV reduction
                lossToPool = poolCash;
                poolCash = 0;
                // implicit remaining loss reduces future NAV (because outstanding was already removed)
            }
        }

        emit LoanWrittenOff(ref, coveredByReserve, lossToPool);
    }


    function _removeLoanFromBorrower(bytes32 ref) internal {
        uint256 index = loanIndex[ref];
        uint256 lastIndex = loanRefs.length - 1;

        if (index != lastIndex) {
            bytes32 lastRef = loanRefs[lastIndex];
            loanRefs[index] = lastRef;
            loanIndex[lastRef] = index;
        }

        loanRefs.pop();
        delete loanIndex[ref];
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
            if (l.status == LoanStatus.Active) {
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

     
    // -----------------------
    // 7️⃣ totalPrincipalOutstanding()
    // -----------------------
    function getTotalPrincipalOutstanding() external view returns (uint256) {
        return totalPrincipalOutstanding;
    }

    function fetchDashboardView() external view returns ( uint256 noOfLoans, uint256 poolBalance,
    uint256 totalPrincipal, uint256 poolCashTotal,uint256 totalPaidToMerchant,
    uint256 totalReserveBalance,
    uint256 totalPlatformFees,uint256 totalLenderFees,uint256 totalPastDue) {
        
        noOfLoans = loanRefs.length;
        totalPlatformFees = _platformFee;
        totalLenderFees = _lenderFee;
        poolBalance = _nav();
        totalPastDue = 0;
        totalPaidToMerchant = totalDisbursedToMerchant;
        poolCashTotal = poolCash;
        totalPrincipal= totalPrincipalOutstanding;
        totalReserveBalance = reserveBalance;
        //totalPrincipalOutstanding,totalDisbursedToMerchant,poolCash,reserveBalance


        for (uint256 i = 0; i < noOfLoans; i++) {
            Loan storage l = loans[loanRefs[i]];
            if (l.status == LoanStatus.Active && block.timestamp > l.maturityDate) {
                totalPastDue += l.outstanding;
                
            }
        }
    }

    function fetchRateSettings() external view returns ( uint256 lenderFeeRate, uint256 platformFeeRate,uint256 depositContributionRate, uint256 defaultBaseRate) {
        
        lenderFeeRate = _lenderFeeRate;
        platformFeeRate = _platformFeeRate;
        depositContributionRate = _depositContributionPercent;
        defaultBaseRate = reserveRateBP;
        
    }

    function getShareWorth(uint256 share) external view returns ( uint256 amount) {
        
        uint256 supply = totalSupply;
        amount = (poolCash * share) / supply;
        
    }

    function getVaultBalance(address borrower, address token) external view returns (uint256) {
        return vault[borrower][token];
    }

    function isWhitelisted(address user) external view returns (bool) {
        return whitelist[user];
    }
}
