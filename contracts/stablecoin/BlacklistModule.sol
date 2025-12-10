// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title BlacklistModule (TRON Compatible)
 * @notice Provides address-level blacklisting integrated with ERC20Core hooks.
 */
contract BlacklistModule {
    mapping(address => bool) public blacklisted;

    event Blacklisted(address indexed account);
    event UnBlacklisted(address indexed account);

    // Must be implemented in StablecoinTRON to restrict admin access
    function _requireAdmin() internal view virtual {
        revert("ADMIN_REQUIRED");
    }

    function blacklist(address account) external {
        _requireAdmin();
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) external {
        _requireAdmin();
        blacklisted[account] = false;
        emit UnBlacklisted(account);
    }

    function isBlacklisted(address account) public view returns (bool) {
        return blacklisted[account];
    }
}
