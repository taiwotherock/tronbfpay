// SPDX-License-Identifier: MIT
pragma solidity ^0.5.4;

import "../libs/SafeTRC20.sol";
import "../libs/ReentrancyGuard.sol";

contract LiquidityPool is ReentrancyGuard {
    using SafeTRC20 for ITRC20;

    ITRC20 public tokenA; // USDT
    address public accessControl;
    bool public paused;

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

    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    constructor(address _tokenA, address _accessControl){
        tokenA = ITRC20(_tokenA); 
        accessControl = _accessControl;
        paused = false;
    }

    modifier onlyAdmin(){
        (bool ok, bytes memory data) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        if(data.length>0) { bool isAdmin = abi.decode(data,(bool)); require(isAdmin, "not admin"); } else { require(false, "accesscontrol call failed"); }
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Vault: paused");
        _;
    }

    // pause / unpause (circuit-breaker)
    function pause() external onlyAdmin {
        require(!paused, "Vault: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        require(paused, "Vault: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }


    function setWithdrawWhitelist(address who, bool allowed) external {
        // only admin via AccessControl should set, for simplicity allow accessControl to call
        (bool ok,) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        require(ok, "not admin"); // best-effort check
        withdrawWhitelist[who]=allowed;
    }

    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(token == address(tokenA), "Vault: invalid token");
        require(amount > 0, "Vault: amount must be > 0");

        ITRC20 t = ITRC20(tokenA);

        // Check balance before
        uint256 before = t.balanceOf(address(this));

        // Transfer in tokens
        SafeTRC20.safeTransferFrom(t, msg.sender, address(this), amount);

        // Check actual received
        uint256 after = t.balanceOf(address(this));
        require(after >= before, "Vault: invalid transfer");
        uint256 received = after - before;
        require(received > 0, "Vault: no tokens received");

        // Update accounting using received amount
        deposits[msg.sender][token] += received;
        totalDeposits[token] += received;
        shares[msg.sender][token] += received;
        totalShares[token] += received;

        emit Deposited(msg.sender, token, received, received);
    }

    function withdraw(address token, uint256 amount) 
    external 
    nonReentrant 
    whenNotPaused 
    onlySupported(token) 
    {
        require(token == address(tokenA), "Vault: invalid token");
        require(withdrawWhitelist[msg.sender], "Vault: not whitelisted");
        require(amount > 0, "Vault: amount must be > 0");
        require(deposits[msg.sender][token] >= amount, "Vault: insufficient deposit");
        require(shares[msg.sender][token] >= amount, "Vault: insufficient shares");

        ITRC20 t = ITRC20(token);

        // Check vault balance before withdrawal
        uint256 vaultBalance = t.balanceOf(address(this));
        require(vaultBalance >= amount, "Vault: insufficient vault liquidity");

        // --- Update accounting before external transfer (Reentrancy Safe) ---
        deposits[msg.sender][token] -= amount;
        totalDeposits[token] -= amount;

        shares[msg.sender][token] -= amount;
        totalShares[token] -= amount;

        // --- Transfer tokens out (external call after state updates) ---
        SafeTRC20.safeTransfer(t, msg.sender, amount);

        emit Withdrawn(msg.sender, token, amount);
    }


    // allow vault/loanmanager to pull funds for disbursement
    function pullFunds(address token, address to, uint256 amount) external {
        // cheap access control: only AccessControl contract or LoanManager should call
        (bool ok, ) = accessControl.call(abi.encodeWithSignature("admins(address)", msg.sender));
        require(ok, "not authorized");
        ITRC20(token).safeTransfer(to, amount);
    }
}