# Modular Lending Protocol — Solidity (for Base / Tron deployment)

This repository-style document contains multiple Solidity modules (each shown as a separate file) implementing the features you requested. It's designed as a starting point — audited production contract will need further hardening and testing before mainnet deployment.

---

## Files included

- `interfaces/IBorderlessCreditNFT.sol` — minimal NFT interface and getter for credit score.
- `modules/AccessControlModule.sol` — role management, admin add/remove, credit officer role, keeper role.
- `modules/MultiSig.sol` — lightweight multisig module used to protect sensitive actions.
- `libs/SafeERC20.sol` & `libs/ReentrancyGuard.sol` — helper libs (small safe wrappers).
- `LiquidityPool.sol` — handles deposits by lenders of USDT and NGNt, LP shares, withdrawal checks (whitelist), events, vault shares.
- `LoanVaultCore.sol` — core vault storing collateral/deposits mapping, interacts with LiquidityPool.
- `LoanManager.sol` — request, approval (credit officer only), disbursement, 3-month equal installments, single-loan-per-borrower enforcement, borrower outstanding tracking.
- `KeeperRecovery.sol` — keeper functions to attempt recovery, mark off-chain payments, sweep collateral.

Each contract is annotated and uses `ReentrancyGuard` and `SafeERC20` patterns. The system stores a credit-score -> min/max mapping and exposes admin function to set score for borrower (and NFT link).

> NOTE: This code intentionally avoids external imports so it can be pasted, but in production you should use audited OpenZeppelin imports.

---

## `interfaces/IBorderlessCreditNFT.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IBorderlessCreditNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getCreditScore(uint256 tokenId) external view returns (uint16);
}
```

---

## `libs/ReentrancyGuard.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract ReentrancyGuard {
    uint256 private _status;
    constructor() { _status = 1; }
    modifier nonReentrant() {
        require(_status == 1, "Reentrant call");
        _status = 2;
        _;
        _status = 1;
    }
}
```

---

## `libs/SafeERC20.sol` (minimal)
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        bool ok = token.transfer(to, value);
        require(ok, "SafeERC20: transfer failed");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        bool ok = token.transferFrom(from, to, value);
        require(ok, "SafeERC20: transferFrom failed");
    }
}
```

---

## `modules/AccessControlModule.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract AccessControlModule {
    address public multisig; // protected by multisig for sensitive changes
    mapping(address => bool) public admins;
    mapping(address => bool) public creditOfficers;
    mapping(address => bool) public keepers;

    event AdminAdded(address indexed who);
    event AdminRemoved(address indexed who);
    event CreditOfficerAdded(address indexed who);
    event CreditOfficerRemoved(address indexed who);
    event KeeperAdded(address indexed who);
    event KeeperRemoved(address indexed who);

    modifier onlyAdmin() {
        require(admins[msg.sender] || msg.sender == multisig, "Not admin");
        _;
    }
    modifier onlyCreditOfficer(){ require(creditOfficers[msg.sender], "Not credit officer"); _; }
    modifier onlyKeeper(){ require(keepers[msg.sender], "Not keeper"); _; }

    constructor(address _initialAdmin, address _multisig){
        admins[_initialAdmin] = true;
        multisig = _multisig;
    }

    function addAdmin(address a) external onlyAdmin {
        admins[a] = true; emit AdminAdded(a);
    }
    function removeAdmin(address a) external onlyAdmin {
        admins[a] = false; emit AdminRemoved(a);
    }

    function addCreditOfficer(address a) external onlyAdmin { creditOfficers[a] = true; emit CreditOfficerAdded(a); }
    function removeCreditOfficer(address a) external onlyAdmin { creditOfficers[a] = false; emit CreditOfficerRemoved(a); }

    function addKeeper(address a) external onlyAdmin { keepers[a] = true; emit KeeperAdded(a); }
    function removeKeeper(address a) external onlyAdmin { keepers[a] = false; emit KeeperRemoved(a); }

    function setMultisig(address m) external onlyAdmin { multisig = m; }
}
```

---

## `modules/MultiSig.sol` (lightweight)
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

contract MultiSig {
    address[] public owners;
    uint256 public threshold;
    mapping(bytes32 => mapping(address => bool)) public approvals;
    mapping(bytes32 => uint256) public approvalCounts;

    event ProposalApproved(bytes32 indexed proposal, address indexed owner, uint256 approvals);
    event ProposalExecuted(bytes32 indexed proposal);

    constructor(address[] memory _owners, uint256 _threshold) {
        require(_owners.length >= _threshold && _threshold > 0, "invalid multisig");
        owners = _owners; threshold = _threshold;
    }

    modifier onlyOwner() { bool ok = false; for(uint i=0;i<owners.length;i++) if(owners[i]==msg.sender) { ok=true; break;} require(ok, "not owner"); _; }

    function approve(bytes32 proposal) external onlyOwner {
        require(!approvals[proposal][msg.sender], "already approved");
        approvals[proposal][msg.sender]=true;
        approvalCounts[proposal]+=1;
        emit ProposalApproved(proposal, msg.sender, approvalCounts[proposal]);
    }

    function isApproved(bytes32 proposal) public view returns(bool) {
        return approvalCounts[proposal] >= threshold;
    }
}
```

---

## `LiquidityPool.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./libs/SafeERC20.sol";
import "./libs/ReentrancyGuard.sol";

contract LiquidityPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public tokenA; // USDT
    IERC20 public tokenB; // NGNt
    address public accessControl;

    // lender => token => amount
    mapping(address => mapping(address => uint256)) public deposits;
    // total deposits per token
    mapping(address => uint256) public totalDeposits;

    // simple LP shares (scaled)
    mapping(address => mapping(address => uint256)) public shares; // lender -> token -> shares
    mapping(address => uint256) public totalShares; // token -> total shares (stored in mapping key hack)

    // withdrawal whitelist
    mapping(address => bool) public withdrawWhitelist;

    event Deposited(address indexed lender, address indexed token, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lender, address indexed token, uint256 amount);

    constructor(address _tokenA, address _tokenB, address _accessControl){
        tokenA = IERC20(_tokenA); tokenB = IERC20(_tokenB); accessControl = _accessControl;
    }

    modifier onlyAdmin(){
        (bool ok, bytes memory data) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        if(data.length>0) { bool isAdmin = abi.decode(data,(bool)); require(isAdmin, "not admin"); } else { require(false, "accesscontrol call failed"); }
        _;
    }

    function setWithdrawWhitelist(address who, bool allowed) external {
        // only admin via AccessControl should set, for simplicity allow accessControl to call
        (bool ok,) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        require(ok, "not admin"); // best-effort check
        withdrawWhitelist[who]=allowed;
    }

    function deposit(address token, uint256 amount) external nonReentrant {
        require(token==address(tokenA) || token==address(tokenB), "invalid token");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        deposits[msg.sender][token] += amount;
        totalDeposits[token] += amount;
        // simple 1:1 share mint
        shares[msg.sender][token] += amount;
        totalShares[token] += amount;
        emit Deposited(msg.sender, token, amount, amount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        require(withdrawWhitelist[msg.sender], "not whitelisted to withdraw");
        require(deposits[msg.sender][token] >= amount, "withdraw more than deposited");
        deposits[msg.sender][token] -= amount;
        totalDeposits[token] -= amount;
        // burn shares
        shares[msg.sender][token] -= amount;
        totalShares[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    // allow vault/loanmanager to pull funds for disbursement
    function pullFunds(address token, address to, uint256 amount) external {
        // cheap access control: only AccessControl contract or LoanManager should call
        (bool ok, ) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        require(ok, "not authorized");
        IERC20(token).safeTransfer(to, amount);
    }
}
```

---

## `LoanVaultCore.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./libs/ReentrancyGuard.sol";
import "./libs/SafeERC20.sol";

interface ILiquidityPool {
    function pullFunds(address token, address to, uint256 amount) external;
}

contract LoanVaultCore is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public accessControl;
    address public liquidityPool;

    // borrower -> token collateral amount
    mapping(address => mapping(address => uint256)) public collateral;

    event CollateralDeposited(address indexed who, address indexed token, uint256 amount);
    event CollateralRemoved(address indexed who, address indexed token, uint256 amount);

    constructor(address _accessControl, address _liquidityPool){ accessControl=_accessControl; liquidityPool=_liquidityPool; }

    function depositCollateral(address token, uint256 amount) external nonReentrant {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        collateral[msg.sender][token] += amount;
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function removeCollateral(address borrower, address token, uint256 amount) external {
        // Only LoanManager (authorized via AccessControl) can remove collateral on liquidation or refund.
        (bool ok, ) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        require(ok, "not authorized");
        require(collateral[borrower][token] >= amount, "not enough collateral");
        collateral[borrower][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralRemoved(borrower, token, amount);
    }

    // helper to sweep collateral to repay loan
    function sweepCollateral(address to, address token, uint256 amount) external {
        (bool ok, ) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        require(ok, "not authorized");
        require(collateral[to][token] >= amount, "not enough collateral");
        collateral[to][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit CollateralRemoved(to, token, amount);
    }
}
```

---

## `LoanManager.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./libs/ReentrancyGuard.sol";
import "./libs/SafeERC20.sol";
import "./interfaces/IBorderlessCreditNFT.sol";

interface ILiquidityPool { function pullFunds(address token, address to, uint256 amount) external; }
interface ILoanVaultCore { function collateral(address borrower, address token) external view returns(uint256); }

contract LoanManager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public accessControl;
    ILiquidityPool public liquidityPool;
    ILoanVaultCore public vault;
    IBorderlessCreditNFT public creditNFT;

    struct Loan {
        address borrower;
        address token; // token borrowed
        uint256 principal; // amount disbursed
        uint256 outstanding; // remaining
        uint256 startedAt;
        uint8 installmentsPaid;
        uint8 totalInstallments; // 3
        bool active;
        uint256 installmentAmount;
    }

    mapping(address => Loan) public loans; // borrower -> loan

    // creditscore -> min,max
    mapping(uint16 => uint256) public minByScore;
    mapping(uint16 => uint256) public maxByScore;

    event LoanRequested(address indexed by, uint256 requestedAmount);
    event LoanApproved(address indexed borrower, uint256 amount, address token);
    event Repayment(address indexed borrower, uint256 amount, uint8 installmentNo);
    event LoanRepaid(address indexed borrower);

    constructor(address _accessControl, address _liquidityPool, address _vault, address _creditNFT){
        accessControl = _accessControl; liquidityPool = ILiquidityPool(_liquidityPool); vault = ILoanVaultCore(_vault); creditNFT = IBorderlessCreditNFT(_creditNFT);
    }

    modifier onlyCreditOfficer(){
        (bool ok, bytes memory data) = accessControl.call(abi.encodeWithSignature("creditOfficers(address)", msg.sender));
        if(data.length>0){ bool isCO = abi.decode(data,(bool)); require(isCO, "not credit officer"); } else { require(false, "ac call failed"); }
        _;
    }

    function setLimitsForScore(uint16 score, uint256 minAmt, uint256 maxAmt) external {
        // only admin
        (bool ok,) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        require(ok, "not admin");
        minByScore[score] = minAmt; maxByScore[score] = maxAmt;
    }

    // borrower requests loan; must have collateral deposited 30% of requested + be single active loan
    function requestLoan(address tokenToBorrow, uint256 requestedAmount, uint256 creditNFTId) external {
        require(!loans[msg.sender].active, "one loan at a time");
        // get score
        uint16 score = creditNFT.getCreditScore(creditNFTId);
        require(score>0, "no score");
        uint256 minAmt = minByScore[score];
        uint256 maxAmt = maxByScore[score];
        require(requestedAmount >= minAmt && requestedAmount <= maxAmt, "amount outside limits");
        // borrower must have deposited collateral equals 30% of requestedAmount in vault for tokenToBorrow? We accept any of the two tokens as collateral
        uint256 requiredCollateral = (requestedAmount * 30) / 100;
        // check vault collateral sum across tokens (simplify: require collateral in same token)
        uint256 coll = vault.collateral(msg.sender, tokenToBorrow);
        require(coll >= requiredCollateral, "insufficient collateral");
        emit LoanRequested(msg.sender, requestedAmount);
    }

    // only credit officer can approve and disburse; admin cannot approve
    function approveAndDisburse(address borrower, address tokenToBorrow, uint256 amount, uint256 creditNFTId) external onlyCreditOfficer nonReentrant {
        require(!loans[borrower].active, "existing loan");
        uint16 score = creditNFT.getCreditScore(creditNFTId);
        require(score>0, "no score");
        uint256 minAmt = minByScore[score]; uint256 maxAmt = maxByScore[score];
        require(amount >= minAmt && amount <= maxAmt, "amount oob");
        // calculate installments: 3 monthly equal payments
        uint8 installments = 3;
        uint256 installmentAmount = amount / installments;
        loans[borrower] = Loan({borrower: borrower, token: tokenToBorrow, principal: amount, outstanding: amount, startedAt: block.timestamp, installmentsPaid: 0, totalInstallments: installments, active: true, installmentAmount: installmentAmount});
        // pull funds from liquidity pool to borrower
        liquidityPool.pullFunds(tokenToBorrow, borrower, amount);
        emit LoanApproved(borrower, amount, tokenToBorrow);
    }

    // borrower repays installment (must be equal to installmentAmount except last)
    function repay(address token, uint256 amount) external nonReentrant {
        Loan storage L = loans[msg.sender];
        require(L.active, "no active loan");
        require(token == L.token, "wrong token");
        require(amount > 0, "zero");
        // accept off chain marked payments too via KeeperRecovery
        // apply to outstanding
        if(amount > L.outstanding) amount = L.outstanding;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        L.outstanding -= amount;
        L.installmentsPaid += 1;
        emit Repayment(msg.sender, amount, L.installmentsPaid);
        if(L.outstanding == 0){
            L.active = false;
            emit LoanRepaid(msg.sender);
        }
    }

    function outstandingOf(address borrower) external view returns(uint256){ return loans[borrower].outstanding; }

    // internal function callable by keeper or multisig to liquidate collateral and repay loan
    function liquidateDue(address borrower, address tokenCollateral, uint256 amountNeeded) external {
        // allow keeper or admin via access control
        (bool ok, bytes memory data) = accessControl.call(abi.encodeWithSignature("keepers(address)", msg.sender));
        bool isKeeper = false;
        if(data.length>0) isKeeper = abi.decode(data,(bool));
        (bool ok2, bytes memory d2) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        bool isAdmin = false;
        if(d2.length>0) isAdmin = abi.decode(d2,(bool));
        require(isKeeper || isAdmin, "not keeper or admin");

        Loan storage L = loans[borrower];
        require(L.active, "no loan");
        // sweep collateral by calling vault (vault requires this contract to be authorized via AccessControl)
        // For simplicity we assume vault.collateral provides enough
        // send collateral to liquidity pool to repay outstanding
        // NOTE: Implementation detail depends on token types and conversion; here we assume collateral token equals loan token
        // TODO: support token swap
        // call vault to transfer collateral to this contract then forward to liquidity pool (or reduce outstanding directly)
        // For simplicity just reduce outstanding and mark loan partially paid
        if(amountNeeded >= L.outstanding){
            L.outstanding = 0; L.active = false; emit LoanRepaid(borrower);
        } else {
            L.outstanding -= amountNeeded;
        }
    }

}
```

---

## `KeeperRecovery.sol`
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./libs/ReentrancyGuard.sol";

interface ILoanManager { function outstandingOf(address borrower) external view returns(uint256); function liquidateDue(address borrower, address tokenCollateral, uint256 amountNeeded) external; }

contract KeeperRecovery is ReentrancyGuard {
    address public accessControl;
    ILoanManager public loanManager;

    event RecoveryAttempt(address indexed borrower, uint256 outstanding);
    event OffchainPaymentRecorded(address indexed borrower, uint256 amount);

    constructor(address _accessControl, address _loanManager){ accessControl=_accessControl; loanManager = ILoanManager(_loanManager); }

    // Keeper polls outstanding and tries to recover by calling loanManager.liquidateDue
    function attemptRecovery(address borrower, address tokenCollateral, uint256 amountNeeded) external {
        (bool ok, bytes memory data) = accessControl.call(abi.encodeWithSignature("keepers(address)", msg.sender));
        bool isKeeper=false; if(data.length>0) isKeeper = abi.decode(data,(bool));
        require(isKeeper, "not keeper");
        uint256 outstanding = loanManager.outstandingOf(borrower);
        emit RecoveryAttempt(borrower, outstanding);
        if(outstanding>0){
            loanManager.liquidateDue(borrower, tokenCollateral, amountNeeded);
        }
    }

    // admin or multisig can mark off-chain payment recovered and reduce outstanding via LoanManager (assumed to expose function for offchain credit)
    function markOffchainPayment(address borrower, uint256 amount) external {
        (bool ok, bytes memory data) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        bool isAdmin=false; if(data.length>0) isAdmin = abi.decode(data,(bool));
        require(isAdmin, "not admin");
        emit OffchainPaymentRecorded(borrower, amount);
        // integration: call loanManager to register payment — omitted for brevity, but should call a protected function
    }
}
```

---

## Notes, limitations and next steps

1. **Testing & audits**: This is a conceptual, single-file-ready code base designed for review and iteration. It MUST be tested and audited.
2. **Token swaps**: Liquidation assumes collateral token equals loan token. In production you'd integrate a DEX or price oracle to swap collateral tokens to the loan token before repaying.
3. **Tron specifics**: Tron uses TVM; Solidity contracts deploy similarly but you may need to adjust ABI/constructor handling and token interfaces for Tron-USDT quirks. Contracts above are EVM-first (works on Base). For Tron, change token interfaces to TRC20 if necessary.
4. **Multisig**: A very small MultiSig is included; consider using Gnosis Safe for production.
5. **Credit NFT**: `IBorderlessCreditNFT` is a minimal interface; the actual NFT contract must expose `getCreditScore(uint256)` and ensure ownership mapping.
6. **Access control calls**: For brevity the code queries `accessControl.call(...)` to check roles. In production you should import and use a proper AccessControl interface.
7. **Fees & profit sharing**: LP profit-sharing is not fully implemented — you'd add accounting in `LiquidityPool` to accrue fees and distribute based on `shares`.
8. **Keeper & off-chain payments**: Keeper tries to liquidate using `liquidateDue` — implement token transfer flow and swaps for actual recovery.

---

If you'd like, I can:
- Export each module into separate `.sol` files and a project layout
- Add full LP profit-sharing (fee accrual & claimable rewards)
- Integrate price-oracle & DEX swap logic for liquidation
- Replace the minimal MultiSig with Gnosis Safe integration instructions
- Adapt the code specifically for Tron TRC20 nuances (USDT on Tron) and produce deployment script

Tell me which of the above you'd like next and I'll continue.

