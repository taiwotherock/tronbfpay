// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract RolesModule {
    mapping(address => bool) public isAdmin;
    mapping(address => bool) public isMinter;
    mapping(address => bool) public isBurner;

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event MinterAdded(address indexed account);
    event MinterRemoved(address indexed account);
    event BurnerAdded(address indexed account);
    event BurnerRemoved(address indexed account);

    modifier onlyAdmin() {
        require(isAdmin[msg.sender], "NOT_ADMIN");
        _;
    }

    // Admin management
    function addAdmin(address account) external onlyAdmin {
        isAdmin[account] = true;
        emit AdminAdded(account);
    }

    function removeAdmin(address account) external onlyAdmin {
        isAdmin[account] = false;
        emit AdminRemoved(account);
    }

    // Minter management
    function addMinter(address account) external onlyAdmin {
        isMinter[account] = true;
        emit MinterAdded(account);
    }

    function removeMinter(address account) external onlyAdmin {
        isMinter[account] = false;
        emit MinterRemoved(account);
    }

    // Burner management
    function addBurner(address account) external onlyAdmin {
        isBurner[account] = true;
        emit BurnerAdded(account);
    }

    function removeBurner(address account) external onlyAdmin {
        isBurner[account] = false;
        emit BurnerRemoved(account);
    }

    // Role checks
    function checkMinter(address account) external view returns (bool) {
        return isMinter[account];
    }

    function checkBurner(address account) external view returns (bool) {
        return isBurner[account];
    }

    function checkAdmin(address account) external view returns (bool) {
        return isAdmin[account];
    }
}
