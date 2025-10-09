// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../libs/SafeTRC20.sol";
import "../libs/ReentrancyGuard.sol";

interface IAccessControl {
    function admins(address account) external view returns (bool);
}

/**
 * @title LiquidityPoolV3
 * @notice Gas-optimized TRON liquidity pool for a single token with whitelist & emergency features
 */
contract LiquidityPoolV11 is ReentrancyGuard {
    using SafeTRC20 for ITRC20;

    ITRC20 public immutable tokenA; // USDT
    IAccessControl public immutable accessControl;

    bool public paused;

    mapping(address => uint256) public deposits; // lender => amount (single token)
    uint256 public totalDeposits;

    address[] private depositors;
    mapping(address => bool) private hasDeposited;


    mapping(address => uint256) public shares; // lender -> shares
    uint256 public totalShares;

    mapping(address => bool) public withdrawWhitelist;

    event Deposited(address indexed lender, uint256 amount, uint256 shares);
    event Withdrawn(address indexed lender, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    constructor(address _tokenA, address _accessControl) {
        require(_tokenA != address(0) && _accessControl != address(0), "Invalid addresses");
        tokenA = ITRC20(_tokenA);
        accessControl = IAccessControl(_accessControl);
    }

    modifier onlyAdmin() {
        require(accessControl.admins(msg.sender), "Not admin");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    function pause() external onlyAdmin {
        require(!paused, "Already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAdmin {
        require(paused, "Not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setWithdrawWhitelist(address who, bool allowed) external onlyAdmin {
        withdrawWhitelist[who] = allowed;
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");

        /*uint256 balBefore = tokenA.balanceOf(address(this));
        tokenA.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = tokenA.balanceOf(address(this));
        uint256 received = balAfter - balBefore;
        require(received > 0, "No tokens received");*/

        (bool success, bytes memory data) = address(tokenA).call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Transfer failed");
        uint256 received = amount;

        deposits[msg.sender] += received;
        totalDeposits += received;

        shares[msg.sender] += received;
        totalShares += received;

        emit Deposited(msg.sender, received, received);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        require(withdrawWhitelist[msg.sender], "Not whitelisted");
        require(amount > 0, "Amount must be > 0");
        require(deposits[msg.sender] >= amount, "Insufficient deposit");
        require(shares[msg.sender] >= amount, "Insufficient shares");
        require(tokenA.balanceOf(address(this)) >= amount, "Insufficient liquidity");

        deposits[msg.sender] -= amount;
        totalDeposits -= amount;

        shares[msg.sender] -= amount;
        totalShares -= amount;

        //tokenA.safeTransfer(msg.sender, amount);

        (bool success, bytes memory data) = address(tokenA).call(
            abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRC20 transfer failed");


        emit Withdrawn(msg.sender, amount);
    }

    function pullFunds(address to, uint256 amount) external {
        require(accessControl.admins(msg.sender), "Not authorized");
        //tokenA.safeTransfer(to, amount);
        (bool success, bytes memory data) = address(tokenA).call(
            abi.encodeWithSignature("transfer(address,uint256)", to, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRC20 transfer failed");

    }

    function emergencyWithdraw(address token, address to, uint256 amount) external onlyAdmin {
        //ITRC20(token).safeTransfer(to, amount);

        (bool success, bytes memory data) = address(token).call(
            abi.encodeWithSignature("transfer(address,uint256)", msg.sender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "TRC20 transfer failed");

        emit EmergencyWithdraw(token, to, amount);
    }

    // Returns the total amount of tokenA deposited in the pool 
    function getTotalShares() external view returns (uint256) 
    { 
        return totalShares;
    }

    function getTotalDeposits() external view returns (uint256) 
    { 
        return totalDeposits;
    }

      
}
