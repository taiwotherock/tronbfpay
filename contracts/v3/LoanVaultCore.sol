// SPDX-License-Identifier: MIT
pragma solidity ^0.5.4;

import "../libs/ReentrancyGuard.sol";
import "../libs/SafeTRC20.sol";

interface ILiquidityPool {
    function pullFunds(address token, address to, uint256 amount) external;
}

interface IAccessControl {
    function isAdmin(address user) external view returns (bool);
}


contract LoanVaultCore is ReentrancyGuard {
    using SafeTRC20 for ITRC20;

    address public accessControl;
    address public liquidityPool;
    bool public paused;

    // borrower -> token collateral amount
    mapping(address => mapping(address => uint256)) public collateral;

    event CollateralDeposited(address indexed who, address indexed token, uint256 amount);
    event CollateralRemoved(address indexed who, address indexed token, uint256 amount);

    constructor(address _accessControl, address _liquidityPool) public 
    { 
        require(_accessControl != address(0), "LoanVaultCore: zero accessControl");
        require(_liquidityPool != address(0), "LoanVaultCore: zero liquidityPool");

        accessControl=_accessControl; 
        liquidityPool=_liquidityPool; 
         paused = false;
    }

    // --- modifiers ---
    modifier whenNotPaused() {
        require(!paused, "LoanVaultCore: paused");
        _;
    }

    modifier onlyAuthorized() {
        require(_isAuthorized(msg.sender), "LoanVaultCore: not authorized");
        _;
    }

    // --- pause control ---
    function pause() external onlyAuthorized {
        require(!paused, "LoanVaultCore: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAuthorized {
        require(paused, "LoanVaultCore: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    function depositCollateral(address token, uint256 amount) external nonReentrant {

        require(token != address(0), "LoanVaultCore: zero token");
        require(amount > 0, "LoanVaultCore: zero amount");

        ITRC20(token).safeTransferFrom(msg.sender, address(this), amount);
        collateral[msg.sender][token] += amount;
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function removeCollateral(address borrower, address token, uint256 amount) external {
        // Only LoanManager (authorized via AccessControl) can remove collateral on liquidation or refund.
       
       require(token != address(0), "LoanVaultCore: zero token");
        require(borrower != address(0), "LoanVaultCore: zero borrower");
        require(amount > 0, "LoanVaultCore: zero amount");

        // Authorization check
        require(_isAuthorized(msg.sender), "LoanVaultCore: not authorized");

        // Sufficient collateral check
        require(collateral[borrower][token] >= amount, "LoanVaultCore: insufficient collateral");

        // Update state first (prevent reentrancy)
        collateral[borrower][token] -= amount;


        ITRC20(token).safeTransfer(msg.sender, amount);
        emit CollateralRemoved(borrower, token, amount);
    }

    // helper to sweep collateral to repay loan
    function sweepCollateral(address to, address token, uint256 amount) external {
        require(token != address(0), "LoanVaultCore: zero token");
        require(borrower != address(0), "LoanVaultCore: zero borrower");
        require(amount > 0, "LoanVaultCore: zero amount");

        // Authorization check
        require(_isAuthorized(msg.sender), "LoanVaultCore: not authorized");

        // Sufficient collateral check
        require(collateral[borrower][token] >= amount, "LoanVaultCore: insufficient collateral");

        // Update state before external call
        collateral[borrower][token] -= amount;

        ITRC20(token).safeTransfer(msg.sender, amount);
        emit CollateralRemoved(to, token, amount);
    }

    /// @dev Internal authorization helper
    function _isAuthorized(address user) internal view returns (bool) {
        require(accessControl != address(0), "LoanVaultCore: accessControl not set");
        return IAccessControl(accessControl).isAdmin(user);
    }

    /// @notice Change access control contract (only admin)
    function setAccessControl(address _accessControl) external nonReentrant {
        require(_accessControl != address(0), "LoanVaultCore: zero address");
        require(_isAuthorized(msg.sender), "LoanVaultCore: not authorized");
        accessControl = _accessControl;
    }

    /// @notice Change liquidity pool address (only admin)
    function setLiquidityPool(address _liquidityPool) external nonReentrant {
        require(_liquidityPool != address(0), "LoanVaultCore: zero address");
        require(_isAuthorized(msg.sender), "LoanVaultCore: not authorized");
        liquidityPool = _liquidityPool;
    }
}