// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ITRC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}


    // --- Events ---
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event OverdraftPosted(bytes32 indexed ref, address borrower, uint256 creditLimit);
    event DebitTransactionPosted(bytes32 indexed paymentRef, bytes32 indexed creditRef, uint256 fiatAmount, uint256 tokenAmount,uint256 rate);
    event PaymentMarkedPaid(bytes32 indexed paymentRef, bytes32 indexed creditRef, uint256 amount, uint256 fiatAmount, uint256 rate, address indexed by);
    event PaymentApproved(bytes32 indexed paymentRef, bytes32 indexed creditRef);
    event FundsWithdrawn(address indexed borrower, bytes32 indexed creditRef, uint256 fiatAmount);
    event TokenPricePosted(address indexed token, uint256 price);
    event BorrowerWhitelisted(address borrower, bool whitelisted);
    event ManagerToggled(address manager, bool enabled);
    event CreditOfficerToggled(address officer, bool enabled);
    event VaultAdminChanged(address indexed oldAdmin, address indexed newAdmin);
    event PausedContract();
    event UnpausedContract();
    event DailyFeePosted(bytes32 indexed creditRef,uint256 amount);
    event DailyBulkFeePosted(uint256 totalFee,uint256 amount);
    event PlatformFeeWithdrawn(address receiver, uint256 amount);
    event CreditLimitAdjusted(bytes32 indexed ref, bytes32 indexed tranRef, bool topup, uint256  fiatAmount, uint256  feeBps, uint256  fiatRate);
    event RescueEnabled(uint256 allowedAfter);
    event RescueExecuted(address token, address to, uint256 amount);

    struct Overdraft {
        bytes32 ref;
        uint256 creditLimit; // fiat units
        uint256 availableLimit;
        uint256 utilizedLimit;
        uint256 fee; // bps
        uint256 expiry;
        address borrower;
        address lender;
        uint256 tokenAmount;
        uint256 tokenToFiatRate;
        bool exists;
    }

    struct DebitTransaction {
        bytes32 creditRef;
        uint256 fiatAmount;
        uint256 amount; // generic amount (token units or fiat - business-defined)
        uint256 rate;   // rate at time of transaction
        address payer;
        bool markedPaid;
        bool approved;
        uint256 approveReleaseTimestamp;
        bool exists; 
    }

    struct RepaymentTransaction {
        bytes32 tranRef;
        address borrower;
        uint256 amount;
        uint256 fiatAmount;
        uint256 rate;
        bytes32 creditRef;
        bool exists;
        bool approved; 
        address postedBy;
    }

    struct CreditLimitAdjustment {
        bytes32 creditRef;
        bytes32 tranRef;
        bool topup;
        uint256 amount;
        uint256 fiatAmount;
        uint256 rate;
        bool exists;
        bool approved; 
    }

    // --- State ---
   


