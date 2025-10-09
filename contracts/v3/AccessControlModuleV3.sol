// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title AccessControlModuleV3
 * @notice Gas-optimized access control module with multisig governance for TRON/EVM.
 * @dev Designed for Solidity 0.8.23; avoids redundant storage operations and events.
 */
contract AccessControlModuleV3 {
    address public multisig;
    mapping(address => uint8) private _roles; // 1=admin, 2=creditOfficer, 3=keeper (bit flags can be combined)

    event RoleUpdated(address indexed account, uint8 role, bool enabled);
    event MultisigUpdated(address indexed newMultisig);

    uint8 private constant ROLE_ADMIN = 1;
    uint8 private constant ROLE_CREDIT = 2;
    uint8 private constant ROLE_KEEPER = 3;

    modifier onlyAdmin() {
        require(isAdmin(msg.sender) || msg.sender == multisig, "AccessControl: not admin");
        _;
    }
    modifier onlyCreditOfficer() {
        require(isCreditOfficer(msg.sender), "AccessControl: not credit officer");
        _;
    }
    modifier onlyKeeper() {
        require(isKeeper(msg.sender), "AccessControl: not keeper");
        _;
    }

    constructor(address _initialAdmin, address _multisig) {
        require(_initialAdmin != address(0) && _multisig != address(0), "Invalid address");
        _roles[_initialAdmin] = ROLE_ADMIN;
        multisig = _multisig;
        emit RoleUpdated(_initialAdmin, ROLE_ADMIN, true);
        emit MultisigUpdated(_multisig);
    }

    // ===== Admin Functions =====
    function addAdmin(address account) external onlyAdmin {
        _setRole(account, ROLE_ADMIN, true);
    }

    function removeAdmin(address account) external onlyAdmin {
        _setRole(account, ROLE_ADMIN, false);
    }

    function addCreditOfficer(address account) external onlyAdmin {
        _setRole(account, ROLE_CREDIT, true);
    }

    function removeCreditOfficer(address account) external onlyAdmin {
        _setRole(account, ROLE_CREDIT, false);
    }

    function addKeeper(address account) external onlyAdmin {
        _setRole(account, ROLE_KEEPER, true);
    }

    function removeKeeper(address account) external onlyAdmin {
        _setRole(account, ROLE_KEEPER, false);
    }

    function setMultisig(address newMultisig) external onlyAdmin {
        require(newMultisig != address(0), "Invalid address");
        multisig = newMultisig;
        emit MultisigUpdated(newMultisig);
    }

    // ===== Role Checks =====
    function isAdmin(address account) public view returns (bool) {
        return _roles[account] == ROLE_ADMIN;
    }

    function isCreditOfficer(address account) public view returns (bool) {
        return _roles[account] == ROLE_CREDIT;
    }

    function isKeeper(address account) public view returns (bool) {
        return _roles[account] == ROLE_KEEPER;
    }

    // ===== Internal Logic =====
    function _setRole(address account, uint8 role, bool enabled) internal {
        require(account != address(0), "Invalid address");
        if (enabled) {
            _roles[account] = role;
        } else {
            delete _roles[account];
        }
        emit RoleUpdated(account, role, enabled);
    }
}
