# 🏦 VaultLendingV6 - BNPL Lending Vault for Cross-Border E-commerce

**Author:** Borderless Fuse Pay Team  
**Version:** v6  
**Solidity:** ^0.8.23  

---

## 📖 Summary

`VaultLendingV6` is a **Buy-Now-Pay-Later (BNPL) lending vault** designed for **cross-border e-commerce payments**.  
It allows **lenders to deposit funds**, **merchants to receive payments**, and **borrowers to access BNPL loans**. The contract manages fees, repayments, and risk via a **credit attestation oracle**.

---

## ⚙️ Key Modules & Features

### 1️⃣ Core ERC4626 Vault
- **Deposit & Withdraw** funds with proportional **shares**.  
- Tracks **total assets, shares, pool cash, and lender balances**.  
- Supports **cooldown periods** for withdrawals and **max withdrawal limits**.  

### 2️⃣ BNPL Loan Management
- **Create loans** for whitelisted borrowers & merchants.  
- **Repay loans** with principal + fees (platform fee & lender fee).  
- **Mark defaults** & **write off loans** using the credit officer role.  
- Integrates with **attestation oracle** for credit limit & KYC verification.  

### 3️⃣ Fee Management
- **Platform fees** go to treasury.  
- **Lender fees** are distributed proportionally to depositors.  
- **Reserve balance** is maintained from lender fees for risk coverage.  
- Lenders can **claim accrued fees** anytime.

### 4️⃣ Access Control
- **Vault Manager:** Admin privileges (whitelist users, set treasury, pause/unpause).  
- **Credit Officer:** Manages loan creation, defaults, and write-offs.  
- **Whitelisted users:** Only approved users can deposit, withdraw, or interact with loans.  

### 5️⃣ Security Features
- **Non-reentrant functions** to prevent reentrancy attacks.  
- **Paused state** to halt operations if needed.  
- **Accounting invariant** to ensure on-chain balances match expected totals.  
- **Credit Officer** to approve and create each loan
- **Whitelist** Withdrawal can only happen to whitelisted address
- **Daily Limit and Cap Withdrawal** Daily maximum limit and maximum withdrawal limit is enforced  

### 6️⃣ Utility Functions
- **Get vault stats, loan data, and lender balances** for transparency.  
- **Sweep non-asset tokens** accidentally sent to the contract.  
- Convert **assets ↔ shares** for vault accounting.  

---

## 📌 Usage

- **Deposit:** Users deposit tokens to earn fees.  
- **Withdraw:** Users withdraw tokens proportionally to their shares.  
- **Create Loan:** Credit officer creates a BNPL loan for a whitelisted borrower.  
- **Repay Loan:** Borrower repays principal + fees.  
- **Claim Fees:** Lenders claim accrued lender fees.  
- **Withdraw Merchant:** Merchants withdraw receivables from completed loans.  

---

## 💡 Notes

- Loans are strictly controlled by the **credit attestation oracle**.  
- All monetary operations enforce **pool liquidity** and **fee distribution**.  
- Maximum withdrawal per transaction is limited to **20% of pool** by default.  
- Only whitelisted users can interact with sensitive operations.

---

## 🔒 Security
- Uses **nonReentrant** modifier on critical functions.  
- Implements **access control roles** for sensitive actions.  
- Includes **pausable functionality** in case of emergency.  

---

## 🛠️ Deployment

- Requires ERC20 token for asset.  
- Requires BNPL attestation oracle address.  
- Set platform treasury, vault manager, and credit officer addresses.  
- Initialize vault name, symbol, and token decimals.

---

## 🎯 Summary

This contract provides a **secure, flexible, and transparent BNPL lending vault** for global e-commerce, balancing **lender incentives, borrower risk, and merchant payments**.

---

## 📄 License

**MIT License**  
