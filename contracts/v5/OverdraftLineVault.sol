// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./Ownable.sol";
import "./Pausable.sol";
import "./OverdraftLineVaultStorageV2.sol";
import "./ReentrancyGuard.sol";

contract OverdraftLineVault is Ownable, Pausable, ReentrancyGuard {
    
 
    address token;

    //mapping(address => CollateralPosition) internal _positions;
    mapping(address => uint256) public balances;
    mapping(bytes32 => Overdraft) public overdrafts;
    mapping(bytes32 => CreditLimitAdjustment) public creditLimitAdjustments;
    mapping(address => bool) private hasActiveOverdraft;
    mapping(address => bytes32[]) private borrowerOverdraftRefs;
    mapping(bytes32 => DebitTransaction) public debitTransactions;
    mapping(bytes32 => RepaymentTransaction) public amountsPaid;
    //mapping(address => uint256) public tokenPrice; // token => price (fiat with 18 decimals)
    mapping(address => bool) public borrowerWhitelisted;

    // configuration
    uint256 public activeOverdraftCount;
    uint256 public maximumOverdraftLimit = 1_000_000 * 100;
    uint256 public timelockAfterApproval = 1 days;
    uint256 public globalFeeBps = 50;
    uint256 public maximumDebitAmount = 100_000 * 100;
    uint256 public maximumDailyLimit = 200_000 * 100;
    //uint256 public constant DECIMALS_18 = 1e18;
    uint256 public nativeDecimal; // = 1e18;
    uint256 public tokenDecimal;
    uint256 public tokenToFiatRate;
    uint256 public totalFeeCollected;
    address public platformFeeAddress;
    address public contractOwner;

    mapping(address => mapping(uint256 => uint256)) public dailyUsedByBorrower;
    mapping(bytes32 => mapping(uint256 => bool)) public dailyOverdraftFee;

    // Rescue protection
    uint256 public rescueAllowedAfter; // timestamp when owner may call rescueERC20 (must be paused)

    // --- Roles & governance ---
    address public vaultAdmin; // can manage managers/credit officers, whitelist, set params
    mapping(address => bool) public managers;
    mapping(address => bool) public creditOfficers;

    modifier onlyVaultAdmin() {
        require(msg.sender == vaultAdmin, "vault admin only");
        _;
    }
    modifier onlyManager() {
        require(managers[msg.sender] || msg.sender == vaultAdmin , "manager only");
        _;
    }
    modifier onlyCreditOfficer() {
        require(creditOfficers[msg.sender] || managers[msg.sender] || msg.sender == vaultAdmin , "credit officer only");
        _;
    }

    constructor(address _vaultAdmin, address _token, uint256 _tokenDecimal, uint256 _nativeDecimal ) {
        transferOwnership(msg.sender);
        vaultAdmin = _vaultAdmin;
        token = _token;
        tokenDecimal = _tokenDecimal;
        nativeDecimal = _nativeDecimal;
        contractOwner = msg.sender;
    }
    
    // --- Helpers ---
    function _dayOf(uint256 ts) internal pure returns (uint256) { return ts / 1 days; }

    // --- Role management ---
    function setVaultAdmin(address _newAdmin) external onlyOwner {
        emit VaultAdminChanged(vaultAdmin, _newAdmin);
        vaultAdmin = _newAdmin;
    }
    function toggleManager(address _mgr, bool _enable) external onlyVaultAdmin {
        managers[_mgr] = _enable;
        emit ManagerToggled(_mgr, _enable);
    }
    function toggleCreditOfficer(address _o, bool _enable) external onlyVaultAdmin {
        creditOfficers[_o] = _enable;
        emit CreditOfficerToggled(_o, _enable);
    }

    // --- Pause/unpause ---
    /*function pause() external onlyVaultAdmin {
        _pause();
        emit PausedContract();
    }
    function unpause() external onlyVaultAdmin {
        _unpause();
        emit UnpausedContract();
    }*/

    // SETTER FUNCTIONS (ADMIN ONLY)

    // Set maximum overdraft limit
    function setMaximumOverdraftLimit(uint256 newLimit) external onlyVaultAdmin {
        require(newLimit > 0, "INVALID_LIMIT");
        maximumOverdraftLimit = newLimit;
    }

    // Set timelock (in seconds)
    function setTimelockAfterApproval(uint256 newTimelock) external onlyVaultAdmin {
        require(newTimelock <= 30 days, "TIMELOCK_TOO_LONG");
        timelockAfterApproval = newTimelock;
    }

    // Set fee rate (basis points)
    function setGlobalFeeBps(uint256 newFeeBps) external onlyVaultAdmin {
        require(newFeeBps <= 1000, "FEE_TOO_HIGH"); // max 10%
        globalFeeBps = newFeeBps;
    }

    // Set max debit amount per transaction
    function setMaximumDebitAmount(uint256 newMaxDebit) external onlyVaultAdmin {
        require(newMaxDebit > 0, "INVALID_DEBIT");
        maximumDebitAmount = newMaxDebit;
    }

    // Set daily spending limit
    function setMaximumDailyLimit(uint256 newDailyLimit) external onlyVaultAdmin {
        require(newDailyLimit > 0, "INVALID_DAILY_LIMIT");
        maximumDailyLimit = newDailyLimit;
    }

    // Set daily spending limit
    function setConfigValues(uint256 rate ) external onlyVaultAdmin {
        require(rate > 0, "Invalid rate");
        tokenToFiatRate = rate;
    }

    // Set daily spending limit
    function setRatesAndLimits(uint256 _newDailyLimit, uint256 _newMaxDebit,uint256 _newLimit,uint256 _newFeeBps ) external onlyVaultAdmin {
        require(_newDailyLimit > 0, "INVALID_DAILY_LIMIT");
        require(_newMaxDebit > 0, "INVALID_DEBIT");
        require(_newLimit > 0, "INVALID_LIMIT");
        require(_newFeeBps <= 1000, "FEE_TOO_HIGH");
        
        maximumDebitAmount = _newMaxDebit;
        maximumOverdraftLimit = _newLimit;
        globalFeeBps = _newFeeBps;
        maximumDailyLimit = _newDailyLimit;
       
    }

    // --- Collateral deposit/withdraw ---
    function depositCollateral( uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount > 0");
        // Effects
       
        require(ITRC20(token).transferFrom(msg.sender, address(this), amount), "transfer failed");
        balances[msg.sender] += amount;
       
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function withdrawCollateral(uint256 amount) external whenNotPaused nonReentrant {
    
        _releaseFund(amount, msg.sender);
        emit CollateralWithdrawn(msg.sender, token, amount);
    }

    function releaseFundToLender(uint256 amount,address lender) external whenNotPaused nonReentrant onlyCreditOfficer {
      
      _releaseFund(amount, lender);
      emit CollateralWithdrawn(lender, token, amount);
    }

    function _releaseFund(uint256 amount,address lender) internal  {
        require(amount > 0, "amount > 0");
        require(balances[lender] >= amount, "insufficient collateral");
        require(tokenToFiatRate > 0, "zero rate");
        require(tokenDecimal > 0 , "token decimal not set");
        
      
        //(limitUsed, totalTokenAmount) = _totalUtilizedLimit(msg.sender);
         bytes32[] memory refs = borrowerOverdraftRefs[lender];
         Overdraft storage od = overdrafts[refs[0]];
         if(od.exists)
         {
            uint256 tokenValueUsed = _utilizedAmountInToken(od.utilizedLimit,od.tokenToFiatRate);
            uint256 availableBalance = balances[lender] - tokenValueUsed;
            require(availableBalance >= amount, "insufficient balance");

            uint256 fiatAmt = _collateralTokenAmountInFiat(amount,od.tokenToFiatRate);
            require( (od.creditLimit - fiatAmt) >= 0 , "no credit limit left" );
            require( (od.availableLimit - fiatAmt) >= 0 , "no credit limit left" );
            
            od.creditLimit -= fiatAmt;
            od.availableLimit -= fiatAmt;
         }

        // Effects: reduce first
        balances[lender] -= amount;
       
        //require(ITRC20(token).transfer(lender, amount),"token transfer failed");
        ITRC20 tokenA = ITRC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, lender, amount)
         );
        require(success, "failed withdrawal");
        
    }

    // --- Overdraft management ---
    function postOverdraftLine(
        bytes32 ref,
        uint256 creditLimit,
        uint256 feeBps,
        uint256 expiry,
        address borrower,
        address lender,
        uint256 tokenAmount,
        uint256 _tokenToFiatRate
    ) external whenNotPaused onlyCreditOfficer {
        require(!overdrafts[ref].exists, "ref exists");
        require(creditLimit <= maximumOverdraftLimit, "exceeds maximum overdraft limit");
        require(!hasActiveOverdraft[borrower], "Borrower has overdraft already");
        require(borrower != address(0), "Invalid borrower address");
        require(lender != address(0), "Invalid lender address");
        require(balances[borrower] >= tokenAmount,"insufficient collateral borrower deposit");
        require(feeBps > 0, "Daily rate fee not set");
        require(_tokenToFiatRate > 0, "rate is zero");
        require(tokenAmount > 0, "Token amount is zero");
        require(creditLimit > 0, "Credit Limit is zero");
        require(expiry > 0, "Expiry date is zero");

        overdrafts[ref] = Overdraft({
            ref: ref,
            creditLimit: creditLimit,
            availableLimit: creditLimit,
            utilizedLimit: 0,
            fee: feeBps,
            expiry: expiry,
            borrower: borrower,
            lender: lender,
            tokenAmount: tokenAmount,
            tokenToFiatRate: _tokenToFiatRate,
            exists: true
        });
        hasActiveOverdraft[borrower] = true;
        borrowerOverdraftRefs[borrower].push(ref);
        activeOverdraftCount += 1;
        emit OverdraftPosted(ref, borrower, creditLimit);
    }

    // borrower posts debit transaction (creates a payment against credit)
    function postDebitTransaction(bytes32 paymentRef, uint256 fiatAmount, bytes32 creditRef, uint256 amount, uint256 rate) external whenNotPaused nonReentrant {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        require(msg.sender == od.borrower || managers[msg.sender] || msg.sender == vaultAdmin, "only borrower or vault admin or manager");
        require(fiatAmount > 0, "fiatAmount zero");
        require(fiatAmount <= maximumDebitAmount, "exceeds max debit amount");
        uint256 day = _dayOf(block.timestamp);
        require(dailyUsedByBorrower[od.borrower][day] + fiatAmount <= maximumDailyLimit, "exceeds daily limit");
        require(od.availableLimit >= fiatAmount, "insufficient available limit");
        require(!debitTransactions[paymentRef].exists , "payment exists");

        uint256 tokenValueUsed = _utilizedAmountInToken(od.utilizedLimit,od.tokenToFiatRate);
        require(balances[od.borrower] >= tokenValueUsed, "insufficient collateral");
        uint256 availableBalance = balances[od.borrower] - tokenValueUsed;
        require(availableBalance >= amount, "insufficient balance");

        // Effects
        debitTransactions[paymentRef] = DebitTransaction({
            creditRef: creditRef,
            fiatAmount: fiatAmount,
            amount: amount,
            rate: rate,
            payer: msg.sender,
            markedPaid: false,
            approved: false,
            approveReleaseTimestamp: 0,
            exists: true
        });
        od.availableLimit -= fiatAmount;
        od.utilizedLimit += fiatAmount;
        dailyUsedByBorrower[od.borrower][day] += fiatAmount;

        emit DebitTransactionPosted(paymentRef, creditRef, fiatAmount,amount,rate);
    }

    // manager post repayment paid (records payment as paid and stores AmountPaid)
    function postRepayment(bytes32 paymentRef, address borrower, uint256 fiatAmount, uint256 amount, uint256 rate, bytes32 creditRef) external whenNotPaused onlyManager {
        
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        require(borrower == od.borrower, "not borrower");
        require(!amountsPaid[paymentRef].exists , "payment exists");

        od.availableLimit += fiatAmount;
        od.utilizedLimit -= fiatAmount;
    
        amountsPaid[paymentRef] = RepaymentTransaction({tranRef: paymentRef, borrower: borrower,
        amount: amount, fiatAmount: fiatAmount, rate: rate, creditRef: creditRef, exists:true,
        approved:false,postedBy: msg.sender });

        emit PaymentMarkedPaid(paymentRef, creditRef, amount, fiatAmount, rate, msg.sender);
    }

    // vault admin approves marked payment and starts timelock for borrower withdrawal
    function approveRepayment(bytes32 paymentRef, bytes32 creditRef) external whenNotPaused onlyVaultAdmin {
        RepaymentTransaction storage tp = amountsPaid[paymentRef];
        require(tp.exists, "no payment");
        require(tp.creditRef == creditRef, "credit mismatch");
        //require(du.markedPaid, "not marked");
        require(!tp.approved, "already approved");
        require(tp.postedBy != msg.sender, "same address cannot post and approve");

        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
   
        //od.availableLimit += tp.fiatAmount;
        //od.utilizedLimit -= tp.fiatAmount;
        tp.approved = true;

        //du.approveReleaseTimestamp = block.timestamp + timelockAfterApproval;

        emit PaymentApproved(paymentRef, creditRef);
    }

   
    // whitelist borrower
    function whitelistBorrower(address borrower, bool allowed) external onlyVaultAdmin {
        borrowerWhitelisted[borrower] = allowed;
        emit BorrowerWhitelisted(borrower, allowed);
    }

    // post daily fee and deduct from collateral. Manager only.
    function postDailyFee(bytes32 creditRef) external whenNotPaused nonReentrant onlyManager {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        address borrower = od.borrower;
               
        require(od.utilizedLimit > 0, "no utilized fund");
        
        uint256 day = _dayOf(block.timestamp);
        //daily fee amount
        // daily fee in fiat
        uint256 feeAmtFiat = (od.utilizedLimit * od.fee) / 10000;
        //uint256 feeAmt =  (od.utilizedLimit * od.fee) / 10000;
        // convert fee to token units (6 decimals)
        uint256 feeAmtToken = _utilizedAmountInToken(feeAmtFiat,od.tokenToFiatRate);

        require(!dailyOverdraftFee[od.ref][day], "daily fee already posted");
        require(balances[borrower] >= feeAmtToken, "insufficient collateral balance");
        require(od.availableLimit >= feeAmtFiat, "insufficient available limit");

        // Deduct
        balances[borrower] -= feeAmtToken;
        od.availableLimit -= feeAmtFiat;
        od.utilizedLimit += feeAmtFiat;
        totalFeeCollected += feeAmtToken;
        dailyOverdraftFee[od.ref][day] = true;
        emit DailyFeePosted(creditRef, feeAmtToken);
    }

    function processBulkDailyFee(address borrower) external  {
        bytes32[] memory refs = borrowerOverdraftRefs[borrower];
        uint256 day = _dayOf(block.timestamp);
        uint256 todayFee =0;
    
        for (uint256 i = 0; i < refs.length; i++) {
            Overdraft storage od = overdrafts[refs[i]];
            if (od.exists && !dailyOverdraftFee[od.ref][day]) {
                
                if(od.utilizedLimit > 0 && od.fee > 0) {

                    uint256 feeAmtFiat = (od.utilizedLimit * od.fee) / 10000;
                    uint256 feeAmtToken = _utilizedAmountInToken(feeAmtFiat,od.tokenToFiatRate);
                    
                    balances[borrower] -= feeAmtToken;
                    od.availableLimit -= feeAmtFiat;
                    od.utilizedLimit += feeAmtFiat;
                    totalFeeCollected += feeAmtToken;
                    todayFee += feeAmtToken;
                    dailyOverdraftFee[od.ref][day] = true;
                }
            }
        }

        emit DailyBulkFeePosted(totalFeeCollected, todayFee);
    }

    function withdrawFee(uint256 amount) external whenNotPaused nonReentrant {
        require(totalFeeCollected > 0, " Fee > 0");
        
        totalFeeCollected -= amount;
        ITRC20 tokenA = ITRC20(token);
         (bool success, bytes memory data) = address(tokenA).call(
                abi.encodeWithSelector(tokenA.transfer.selector, platformFeeAddress, amount)
         );
        require(success, "failed withdrawal");
        emit PlatformFeeWithdrawn(platformFeeAddress, amount);
    }

    function modifyOverdraftLine(
        bytes32 ref,
        bytes32 tranRef,
        bool topup,
        uint256 fiatAmount,
        uint256 feeBps,
        uint256 expiry,
        uint256 tokenAmount,
        uint256 _tokenToFiatRate
    ) external whenNotPaused onlyCreditOfficer {

        Overdraft storage od = overdrafts[ref];
        require(od.exists, "no overdraft");
        require(!creditLimitAdjustments[tranRef].exists, "tranref exists");

           creditLimitAdjustments[tranRef] = CreditLimitAdjustment({
                creditRef: ref,
                tranRef: tranRef,
                topup: topup,
                amount: tokenAmount,
                fiatAmount: fiatAmount,
                rate: _tokenToFiatRate,
                exists: true,
                approved: false
            }); 

            if(topup) {
                od.creditLimit += fiatAmount;
                od.availableLimit += fiatAmount;
            }
            else 
            {
                od.creditLimit -= fiatAmount;
                od.availableLimit -= fiatAmount;
            }
            od.fee = feeBps;
            od.expiry = expiry;
            od.tokenToFiatRate = _tokenToFiatRate;

        emit CreditLimitAdjusted( ref, tranRef, topup,  fiatAmount,  feeBps,  _tokenToFiatRate);
           

    }
 
    function _computeHealthFactor(
        uint256 tokenAmount,  // 6 decimals
        uint256 utilizedAmount             // 18 decimals
    )  internal view returns (uint256) {
       
        require(tokenToFiatRate > 0, "RATE_ZERO");       // Ensure rate is set
        require(tokenDecimal > 0, "UTILIZED_ZERO");  
        // Convert collateral to NGN (no decimals added)
        uint256 collateralValue = (tokenAmount * tokenToFiatRate) / tokenDecimal;

        // Scale collateral to 18 decimals to match utilized amount
        collateralValue = collateralValue * nativeDecimal;
        if(utilizedAmount == 0)
           return 100;

        // HF = collateral / utilized, scaled to 1e18
        return collateralValue * 100 / utilizedAmount;
    }

    function computeHealthFactor(uint256 tokenAmount,uint256 utilizedAmount)  external view returns (uint256) {
        return _computeHealthFactor(tokenAmount,utilizedAmount);
    }

    function overdraftLineHealthFactor(bytes32 creditRef)  external view returns (uint256) {
        Overdraft storage od = overdrafts[creditRef];
        require(od.exists, "no overdraft");
        return _computeHealthFactor(od.tokenAmount,od.utilizedLimit);
    }

    function _collateralTokenAmountInFiat(uint256 tokenAmount, uint256 _tokenToFiatRate)  internal view returns (uint256) {
        // GBP = (USDT * 1e18) / rate
        //(usdtAmount6 * rate) / DECIMALS_6
         require(tokenDecimal > 0, "Token Decimal is zero"); // prevent divide by zero
        return (tokenAmount * _tokenToFiatRate) / tokenDecimal;
    }

    function _utilizedAmountInToken(uint256 utilizedAmount, uint256 _tokenToFiatRate)  internal view returns (uint256) {
       require(_tokenToFiatRate > 0, "token to fiat rate is zero"); // prevent divide by zero
       return (utilizedAmount * tokenDecimal) / _tokenToFiatRate;
    }

    function utilizedAmountInToken(uint256 utilizedAmount,uint256 _tokenToFiatRate)  external view returns (uint256) {
       
       require(_tokenToFiatRate > 0, "token to fiat rate is zero");
       return (utilizedAmount * tokenDecimal) / _tokenToFiatRate;
    }

    function _totalUtilizedLimit(address borrower) internal view returns (uint256 totalUtilized, uint256 totalTokenAmount) {
        bytes32[] memory refs = borrowerOverdraftRefs[borrower];

        for (uint256 i = 0; i < refs.length; i++) {
            Overdraft storage od = overdrafts[refs[i]];
            if (od.exists) {
                totalUtilized += od.utilizedLimit;
                totalTokenAmount += od.tokenAmount;
            }
        }
    }

    function getTotalUtilizedLimit(address borrower) external view returns (uint256 totalUtilized,
    uint256 totalTokenAmount) {
       (totalUtilized,totalTokenAmount) = _totalUtilizedLimit(borrower);
    }
    function getUtilizedAmountInToken(uint256 utilizedAmount,uint256 _tokenToFiatRate) external view returns (uint256) {
       
       require(_tokenToFiatRate > 0, "token to fiat rate is zero");
       return (utilizedAmount * tokenDecimal) / _tokenToFiatRate;
    }

    function fetchBorrowerDepositCollateral(address borrower) external view returns (uint256) {
       
       return balances[borrower];
    }

    function fetchOverdraft(bytes32 ref) 
        external 
        view 
        returns (
            bytes32 refOut,
            uint256 creditLimit,
            uint256 availableLimit,
            uint256 utilizedLimit,
            uint256 fee,
            uint256 expiry,
            address borrower,
            address lender,
            uint256 tokenAmount,
            uint256 _tokenToFiatRate,
            uint256 healthFactor,
            uint256 tokenBalance
        ) 
    {
        Overdraft storage od = overdrafts[ref];
        require(od.exists, "OVERDRAFT_NOT_FOUND");
        uint256 hf = _computeHealthFactor(od.tokenAmount,od.utilizedLimit);

        return (
            od.ref,
            od.creditLimit,
            od.availableLimit,
            od.utilizedLimit,
            od.fee,
            od.expiry,
            od.borrower,
            od.lender,
            od.tokenAmount,
            od.tokenToFiatRate,
            hf, 
            balances[od.borrower]
        );
    }

    function fetchDebitTransaction(bytes32 paymentRef) 
        external 
        view 
        returns (
            bytes32 creditRef,
            uint256 fiatAmount,
            uint256 amount,
            uint256 rate,
            address payer,
            bool markedPaid,
            bool approved,
            uint256 approveReleaseTimestamp,
            bool exists
        ) 
    {
        DebitTransaction storage dt = debitTransactions[paymentRef];
        require(dt.exists, "DEBIT_TRANSACTION_NOT_FOUND");

        return (
            dt.creditRef,
            dt.fiatAmount,
            dt.amount,
            dt.rate,
            dt.payer,
            dt.markedPaid,
            dt.approved,
            dt.approveReleaseTimestamp,
            dt.exists
        );
    }

    function fetchRepaymentTransaction(bytes32 tranRef) 
        external 
        view 
        returns (
            bytes32 tranRefOut,
            address borrower,
            uint256 amount,
            uint256 fiatAmount,
            uint256 rate,
            bytes32 creditRef,
            bool exists,
            bool approved
        ) 
    {
        RepaymentTransaction storage rp = amountsPaid[tranRef];
        require(rp.exists, "REPAYMENT_TRANSACTION_NOT_FOUND");

        return (
            rp.tranRef,
            rp.borrower,
            rp.amount,
            rp.fiatAmount,
            rp.rate,
            rp.creditRef,
            rp.exists,
            rp.approved
        );
    }

    function fetchVaultSettings() 
        external 
        view 
        returns (
            uint256 noOfOverdrafts,
            uint256 _maximumOverdraftLimit,
            uint256 _globalFeeBps,
            uint256 _maximumDebitAmount,
            uint256 _maximumDailyLimit,
            uint256 _tokenToFiatRate,
            uint256 _totalFeeCollected,
            uint256 _tokenDecimal
            
        ) 
    {
       
        return (
           
             activeOverdraftCount,
             maximumOverdraftLimit,
             globalFeeBps,
            maximumDebitAmount,
            maximumDailyLimit,
            tokenToFiatRate,
            totalFeeCollected,
            tokenDecimal
        );
    }




    




}