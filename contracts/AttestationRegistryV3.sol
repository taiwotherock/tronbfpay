// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title AttestationRegistry
 * @notice Gas-optimized multi-admin registry to record verified user attestations on-chain.
 * @dev Optimized for Solidity 0.8.23 (TRON TVM compatible)
 */
contract AttestationRegistryV3 {
    address public immutable owner;
    mapping(address => bool) private _admins;
    mapping(address => bool) private _verified;

    event AdminUpdated(address indexed admin, bool added);
    event AttestationUpdated(address indexed user, bool verified);

    constructor() {
        owner = msg.sender;
        _admins[msg.sender] = true; // Owner is initial admin
        emit AdminUpdated(msg.sender, true);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAdmin() {
        require(_admins[msg.sender], "Only admin");
        _;
    }

    /**
     * @notice Adds or removes an admin in one call (owner only).
     * @dev Saves gas vs separate add/remove functions.
     * @param admin Address of the admin.
     * @param add True to add, false to remove.
     */
    function updateAdmin(address admin, bool add) external onlyOwner {
        require(admin != address(0), "Invalid address");
        if (add) {
            if (!_admins[admin]) {
                _admins[admin] = true;
                emit AdminUpdated(admin, true);
            }
        } else {
            if (_admins[admin] && admin != owner) {
                _admins[admin] = false;
                emit AdminUpdated(admin, false);
            }
        }
    }

    /**
     * @notice Sets the verification status of a user.
     * @param user The address to update.
     * @param status True if verified, false otherwise.
     */
    function setVerified(address user, bool status) external onlyAdmin {
        require(user != address(0), "Invalid user");
        if (_verified[user] != status) {
            _verified[user] = status;
            emit AttestationUpdated(user, status);
        }
    }

    /**
     * @notice Checks if a user is verified.
     */
    function isVerified(address user) external view returns (bool) {
        return _verified[user];
    }

    /**
     * @notice Checks if an address is an admin.
     */
    function isAdmin(address account) external view returns (bool) {
        return _admins[account];
    }
}