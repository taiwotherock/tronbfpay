// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface ILiquidityPool {
    function pullFunds(address token, address to, uint256 amount) external;
}

interface ITRC20 {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

interface IAccessControl {
    function isAdmin(address user) external view returns (bool);
}

contract LoanVaultCoreV11 {
    address public accessControl;
    address public liquidityPool;
    bool public paused;

    struct SweepParams {
        address borrower;
        address tokenToBorrow;
        address merchantAddr;
        uint256 depositAmount;
    }

    // borrower => token => collateral amount
    mapping(address => mapping(address => uint256)) public collateral;

    event CollateralDeposited(address indexed who, address indexed token, uint256 amount);
    event CollateralSweep(address indexed who, address indexed token, uint256 amount);
    event Paused(address indexed by);
    event Unpaused(address indexed by);
    event EmergencyWithdraw(address indexed token, address indexed to, uint256 amount);

    modifier onlyAuthorized() {
        require(_isAuthorized(msg.sender), "LoanVaultCore: not authorized");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "LoanVaultCore: paused");
        _;
    }

    constructor(address _accessControl, address _liquidityPool) {
        require(_accessControl != address(0), "zero accessControl");
        require(_liquidityPool != address(0), "zero liquidityPool");
        accessControl = _accessControl;
        liquidityPool = _liquidityPool;
        paused = false;
    }

    function pause() external onlyAuthorized {
        require(!paused, "already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyAuthorized {
        require(paused, "not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    function depositCollateral(address token, uint256 amount) external whenNotPaused {
        require(token != address(0), "zero token");
        require(amount > 0, "zero amount");

        uint256 allowed = ITRC20(token).allowance(msg.sender, address(this));
        require(allowed >= amount, "insufficient allowance");

        uint256 bal = ITRC20(token).balanceOf(msg.sender);
        require(bal >= amount, "insufficient balance");

        // Low-level TRC20 transferFrom
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(ITRC20(token).transferFrom.selector, msg.sender, address(this), amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");

        collateral[msg.sender][token] += amount;
        emit CollateralDeposited(msg.sender, token, amount);
    }

    function removeCollateral(address borrower, address token, uint256 amount) external onlyAuthorized {
        require(token != address(0) && borrower != address(0), "zero address");
        require(amount > 0, "zero amount");
        require(collateral[borrower][token] >= amount, "insufficient collateral");

        collateral[borrower][token] -= amount;

        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(ITRC20.transferFrom.selector, address(this), msg.sender, amount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");

        emit CollateralSweep(borrower, token, amount);
    }

    function sweepCollateral(SweepParams calldata p) external onlyAuthorized {
        require(p.tokenToBorrow != address(0) && p.borrower != address(0) && p.merchantAddr != address(0), "zero address");
        require(p.depositAmount > 0, "zero amount");
        require(collateral[p.borrower][p.tokenToBorrow] >= p.depositAmount, "insufficient collateral");

        collateral[p.borrower][p.tokenToBorrow] -= p.depositAmount;

        (bool success, bytes memory data) = p.tokenToBorrow.call(
            abi.encodeWithSelector(ITRC20.transferFrom.selector, address(this), p.merchantAddr, p.depositAmount)
        );
        require(success && (data.length == 0 || abi.decode(data, (bool))), "transfer failed");

        emit CollateralSweep(p.borrower, p.tokenToBorrow, p.depositAmount);
    }

    function setAccessControl(address _accessControl) external onlyAuthorized {
        require(_accessControl != address(0), "zero address");
        accessControl = _accessControl;
    }

    function setLiquidityPool(address _liquidityPool) external onlyAuthorized {
        require(_liquidityPool != address(0), "zero address");
        liquidityPool = _liquidityPool;
    }

    function getVaultBalance(address borrower, address token) external view returns (uint256) {
        return collateral[borrower][token];
    }

    function _isAuthorized(address user) internal view returns (bool) {
        return accessControl != address(0) && IAccessControl(accessControl).isAdmin(user);
    }
}
