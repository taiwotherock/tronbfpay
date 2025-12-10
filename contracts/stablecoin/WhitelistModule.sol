// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title WhitelistModule
 * @notice Provides address-level whitelisting integrated with ERC20Core hooks.
 */
contract WhitelistModule {
    mapping(address => bool) public whitelisted;

    event Whitelisted(address indexed account);
    event UnWhitelisted(address indexed account);

    // Internal methods to add/remove whitelisted addresses
    function _addWhitelist(address account) internal virtual {
        whitelisted[account] = true;
        emit Whitelisted(account);
    }

    function _removeWhitelist(address account) internal virtual {
        whitelisted[account] = false;
        emit UnWhitelisted(account);
    }

    // Public view to check if an address is whitelisted
    function isWhitelisted(address account) public view virtual returns (bool) {
        return whitelisted[account];
    }
}

