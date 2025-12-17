// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title A buy-now-pay-later lending vault for cross-border e-commerce payment
/// @author Borderless Fuse Pay Team
/// @notice End users can deposit assets, lenders earn fees, borrowers take BNPL loans, merchants receive funds
/// @dev Designed as an ERC4626-style vault with BNPL loan logic

interface ITRC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
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

contract VaultLendingV6 {
    struct Loan {
        bytes32 ref;
        address borrower;
        address merchant;
        uint256 principal;
        uint256 outstanding;
        uint256 startedAt;
        uint256 installmentsPaid;
        uint256 fee;
        uint256 totalPaid;
        bool disbursed;
        uint256 repaidFee;
        uint256 lastPaymentTs;
        uint256 maturityDate;
        LoanStatus status;
    }

    enum LoanStatus { None, Active, Closed, Defaulted, WrittenOff }

    /*//////////////////////////////////////////////////////////////
    METADATA
    //////////////////////////////////////////////////////////////*/
    string public name;
    string public symbol;
    uint8 public constant decimals = 6;

    ITRC20 public immutable asset;
    address public immutable token;
    IBNPLAttestationOracle public oracle;

    /*//////////////////////////////////////////////////////////////
    ERC4626 CORE
    //////////////////////////////////////////////////////////////*/
    uint256 public totalShares;
    mapping(address => uint256) public balanceOf;
    uint256 public poolCash;
    uint256 public totalPrincipalOutstanding;
    uint256 public reserveBalance;

    /*//////////////////////////////////////////////////////////////
    EXTERNAL ESCROWS
    //////////////////////////////////////////////////////////////*/
    uint256 public platformFees;
    address public platformTreasury;
    address public vaultManager;
    address public creditOfficer;
    uint256 public lenderFees;
    mapping(address => uint256) public merchantReceivable;
    mapping(address => uint256) public accruedLenderFees;
    uint256 public accLenderFeePerShare;
    mapping(address => uint256) public lenderFeeDebt;
    mapping(address => uint256) public lastWithdrawTs;

    uint256 public constant WITHDRAW_COOLDOWN = 1 days;
    uint256 public maxWithdrawBP = 2_000; // 20% of pool per withdrawal

    /*//////////////////////////////////////////////////////////////
    FEES
    //////////////////////////////////////////////////////////////*/
    uint256 public platformFeeRate = 100; // 1%
    uint256 public lenderFeeRate = 700; // 7%
    uint256 public reserveRateBP = 500; // 50% of lender fee
    uint256 public minCreditScore = 80;
    uint256 private _depositContributionPercent = 3000; // 30%
    uint256 public loanCounter;

    uint256 public constant BP = 10_000;
    uint256 public immutable tokenDecimal;
    uint256 public DECIMAL_DIVISOR;

    /*//////////////////////////////////////////////////////////////
    LOANS
    //////////////////////////////////////////////////////////////*/
    mapping(bytes32 => Loan) public loans;
    mapping(address => bool) public whitelist;

    /*//////////////////////////////////////////////////////////////
    SECURITY
    //////////////////////////////////////////////////////////////*/
    bool public paused;
    uint256 private _lock = 1;

    modifier nonReentrant() {
        require(_lock == 1, "REENTRANT");
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyAdmin() {
        require(msg.sender == vaultManager, "Not Admin");
        _;
    }

    modifier onlyCreditOfficer() {
        require(msg.sender == creditOfficer, "Not Credit Officer");
        _;
    }

    modifier onlyWhitelisted(address user) {
        require(whitelist[user], "User not whitelisted");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    /*//////////////////////////////////////////////////////////////
    EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event LoanCreated(bytes32 indexed id, address borrower, uint256 principal);
    event LoanRepaid(bytes32 indexed id, uint256 amount);
    event LoanWrittenOff(bytes32 indexed id, uint256 loss);
    event Whitelisted(address indexed user, bool status);
    event MerchantWithdrawn(address indexed merchant, uint256 amount);
    event PlatformFeesWithdrawn(address treasury, uint256 amount);

    /*//////////////////////////////////////////////////////////////
    CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        address _asset,
        address _oracle,
        address _platformTreasury,
        address _vaultManager,
        address _creditOfficer,
        uint256 _tokenDecimal,
        string memory _name,
        string memory _symbol
    ) {
        asset = ITRC20(_asset);
        token = _asset;
        oracle = IBNPLAttestationOracle(_oracle);
        platformTreasury = _platformTreasury;
        vaultManager = _vaultManager;
        creditOfficer = _creditOfficer;
        name = _name;
        symbol = _symbol;
        tokenDecimal = _tokenDecimal;
        DECIMAL_DIVISOR = 10 ** _tokenDecimal;
    }

    /*//////////////////////////////////////////////////////////////
    ERC4626 LOGIC
    //////////////////////////////////////////////////////////////*/
    function setWhitelist(address user, bool status) external onlyAdmin {
        whitelist[user] = status;
        emit Whitelisted(user, status);
    }

    function totalAssets() public view returns (uint256) {
        return poolCash + totalPrincipalOutstanding + reserveBalance + platformFees + lenderFees;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return totalShares == 0 ? assets : (assets * totalShares) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return totalShares == 0 ? shares : (shares * totalAssets()) / totalShares;
    }

    function deposit(uint256 assets, address receiver) external whenNotPaused nonReentrant returns (uint256 shares) {
        require(assets > 0, "ZERO_ASSETS");
        shares = convertToShares(assets);
        require(shares > 0, "ZERO_SHARES");
        _updateLender(receiver);
        require(asset.transferFrom(msg.sender, address(this), assets), "transfer failed");

        poolCash += assets;
        totalShares += shares;
        balanceOf[receiver] += shares;
        _registerLender(receiver);

        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) external whenNotPaused nonReentrant onlyWhitelisted(msg.sender) returns (uint256 shares) {
        require(msg.sender == owner, "NOT_OWNER");
        _updateLender(owner);

        shares = convertToShares(assets);
        require(balanceOf[owner] >= shares, "NO_SHARES");
        require(poolCash >= assets, "NO_LIQUIDITY");
        require(block.timestamp >= lastWithdrawTs[owner] + WITHDRAW_COOLDOWN, "WITHDRAW_COOLDOWN");
        lastWithdrawTs[owner] = block.timestamp;

        uint256 maxAllowed = (poolCash * maxWithdrawBP) / BP;
        require(assets <= maxAllowed, "WITHDRAW_TOO_LARGE");

        balanceOf[owner] -= shares;
        totalShares -= shares;
        poolCash -= assets;

        (bool success, ) = address(asset).call(abi.encodeWithSelector(asset.transfer.selector, receiver, assets));
        require(success, "failed withdrawal");

        _enforceInvariant();
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    /*//////////////////////////////////////////////////////////////
    BNPL LOGIC
    //////////////////////////////////////////////////////////////*/
    function createLoan(bytes32 ref, address borrower, address merchant,
        uint256 principal, uint256 fee, uint256 depositAmount, uint256 maturitySeconds
    ) external onlyCreditOfficer whenNotPaused nonReentrant {
        require(loans[ref].status == LoanStatus.None, "EXISTS");
        require(poolCash >= principal, "INSUFFICIENT_POOL");
        require(merchant != address(0), "Invalid merchant");
        require(whitelist[merchant], "Merchant Not whitelisted");

        (uint256 creditLimit, uint256 score, bool kycVerified,
            uint256 utilizedLimit,
            address attestor,
            uint256 updatedAt) 
        = oracle.getAttestation(borrower);
        require(kycVerified, "Kyc not verified");
        require(score >= minCreditScore, "credit score too low");
        require(utilizedLimit + principal <= creditLimit, "credit limit exceeded");
        //require(block.timestamp - updatedAt <= 1 days, "ORACLE_STALE");

        uint256 platformFeeEarn = (principal * platformFeeRate) / BP;
        uint256 lenderFeeEarn = (principal * lenderFeeRate) / BP;
        uint256 disbursed = principal - platformFeeEarn - lenderFeeEarn;
        uint256 depositRequired = (principal * _depositContributionPercent) / BP;

        require(depositAmount >= depositRequired, "Deposit too low");
        require(fee == platformFeeEarn + lenderFeeEarn, "fee mismatch");

        poolCash -= principal;
        totalPrincipalOutstanding += principal;

        platformFees += platformFeeEarn;
        merchantReceivable[merchant] += disbursed;
        loanCounter += 1;

        uint256 reserveCut = (lenderFeeEarn * reserveRateBP) / BP;
        reserveBalance += reserveCut;
        uint256 distributableLenderFee = lenderFeeEarn - reserveCut;
        lenderFees += distributableLenderFee;
        _distributeLenderFees(distributableLenderFee);

        Loan storage l = loans[ref];
        l.ref = ref;
        l.borrower = borrower;
        l.merchant = merchant;
        l.principal = principal;
        l.outstanding = principal - depositAmount;
        l.startedAt = block.timestamp;
        l.installmentsPaid = 1;
        l.fee = fee;
        l.totalPaid = depositAmount;
        l.status = LoanStatus.Active;
        l.repaidFee = 0;
        l.maturityDate = block.timestamp + maturitySeconds;
        l.lastPaymentTs = block.timestamp;
        l.disbursed = true;

        oracle.increaseUsedCredit(borrower, principal);
        emit LoanCreated(ref, borrower, principal);
    }

    function repayLoan(bytes32 id, uint256 amount) external whenNotPaused nonReentrant {
        Loan storage l = loans[id];
        require(l.status == LoanStatus.Active, "NOT_ACTIVE");
        require(amount > 0 && amount <= l.outstanding, "INVALID_AMOUNT");
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer failed");

        uint256 pf = (amount * platformFeeRate) / BP;
        uint256 lf = (amount * lenderFeeRate) / BP;
        uint256 principalPaid = amount - pf - lf;

        platformFees += pf;
        uint256 reserveCut = (lf * reserveRateBP) / BP;
        reserveBalance += reserveCut;
        uint256 distributableLenderFee = lf - reserveCut;
        lenderFees += distributableLenderFee;
        _distributeLenderFees(distributableLenderFee);

        l.outstanding -= principalPaid;
        l.totalPaid += amount;
        l.repaidFee += pf + lf;
        l.installmentsPaid += 1;
        l.lastPaymentTs = block.timestamp;
        totalPrincipalOutstanding -= principalPaid;
        poolCash += principalPaid;

        oracle.decreaseUsedCredit(l.borrower, principalPaid);

        if (l.outstanding == 0) {
            l.status = LoanStatus.Closed;
            emit LoanRepaid(id, amount);
        }
    }

    function markDefault(bytes32 id) external onlyCreditOfficer nonReentrant whenNotPaused {
        require(loans[id].status == LoanStatus.Active, "not active");
        loans[id].status = LoanStatus.Defaulted;
    }

    function writeOffLoan(bytes32 id) external onlyCreditOfficer nonReentrant whenNotPaused {
        Loan storage l = loans[id];
        require(l.status == LoanStatus.Defaulted, "NOT_DEFAULT");

        uint256 loss = l.outstanding;
        l.outstanding = 0;
        totalPrincipalOutstanding -= loss;

        if (reserveBalance >= loss) {
            reserveBalance -= loss;
        } else {
            uint256 rem = loss - reserveBalance;
            reserveBalance = 0;
            poolCash -= rem;
        }

        l.status = LoanStatus.WrittenOff;
        emit LoanWrittenOff(id, loss);
    }

    /*//////////////////////////////////////////////////////////////
    WITHDRAWALS
    //////////////////////////////////////////////////////////////*/
    function withdrawMerchant(address merchant) external nonReentrant whenNotPaused onlyWhitelisted(msg.sender) {
        uint256 amt = merchantReceivable[merchant];
        require(amt > 0, "NONE");
        require(msg.sender == merchant, "NOT_MERCHANT");
        merchantReceivable[merchant] = 0;

        (bool success, ) = address(asset).call(abi.encodeWithSelector(asset.transfer.selector, merchant, amt));
        require(success, "failed withdrawal");
        _enforceInvariant();
        emit MerchantWithdrawn(merchant, amt);
    }

    function withdrawPlatformFees(uint256 amt) external onlyAdmin nonReentrant whenNotPaused {
        require(amt <= platformFees, "EXCEEDS");
        platformFees -= amt;

        (bool success, ) = address(asset).call(abi.encodeWithSelector(asset.transfer.selector, platformTreasury, amt));
        require(success, "failed withdrawal");
        _enforceInvariant();
        emit PlatformFeesWithdrawn(platformTreasury, amt);
    }

    /*//////////////////////////////////////////////////////////////
    LENDER FEE ACCOUNTING
    //////////////////////////////////////////////////////////////*/
    function _distributeLenderFees(uint256 feeAmount) internal {
        if (feeAmount == 0 || totalShares == 0) return;
        accLenderFeePerShare += (feeAmount * DECIMAL_DIVISOR) / totalShares;
    }

    function _updateLender(address lender) internal {
        uint256 shares = balanceOf[lender];
        if (shares == 0) {
            lenderFeeDebt[lender] = accLenderFeePerShare;
            return;
        }

        uint256 accumulated = (shares * accLenderFeePerShare) / DECIMAL_DIVISOR;
        uint256 debt = lenderFeeDebt[lender];

        if (accumulated > debt) {
            accruedLenderFees[lender] += (accumulated - debt);
        }

        lenderFeeDebt[lender] = accumulated;
    }

    function claimLenderFees() external nonReentrant whenNotPaused onlyWhitelisted(msg.sender) {
        _updateLender(msg.sender);
        uint256 amount = accruedLenderFees[msg.sender];
        require(amount > 0, "NO_FEES");

        accruedLenderFees[msg.sender] = 0;
        lenderFees -= amount;

        (bool success, ) = address(asset).call(abi.encodeWithSelector(asset.transfer.selector, msg.sender, amount));
        require(success, "Fee transfer failed");
        _enforceInvariant();
    }

    function _enforceInvariant() internal view {
        uint256 accounted = poolCash + reserveBalance + platformFees + lenderFees;
        require(asset.balanceOf(address(this)) >= accounted, "ACCOUNTING_MISMATCH");
    }

    /*//////////////////////////////////////////////////////////////
    ADMIN
    //////////////////////////////////////////////////////////////*/
    function setFees(uint256 pf, uint256 lf, uint256 reserveBP, uint256 depositContributionPercent) external onlyCreditOfficer nonReentrant whenNotPaused {
        require(pf > 0 && lf > 0 && pf + lf <= BP, "BAD_FEES");
        require(reserveBP > 0 && reserveBP < BP, "Reserve rate invalid");
        require(depositContributionPercent > 0 && depositContributionPercent <= BP, "Must be <= 100%");
        platformFeeRate = pf;
        lenderFeeRate = lf;
        reserveRateBP = reserveBP;
        _depositContributionPercent = depositContributionPercent;
    }

    function setPlatformTreasury(address treasury) external onlyAdmin nonReentrant whenNotPaused {
        platformTreasury = treasury;
    }

    function pause() external onlyAdmin { paused = true; }
    function unpause() external onlyAdmin { paused = false; }

    /*//////////////////////////////////////////////////////////////
    HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function _registerLender(address lender) internal {
        // optional: track lenders list if needed
    }
}
