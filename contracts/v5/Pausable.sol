// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./Ownable.sol";

/** PAUSABLE */
contract Pausable is Ownable {
    bool public paused;
    modifier whenNotPaused() { require(!paused, "PAUSED"); _; }
    modifier whenPaused() { require(paused, "NOT_PAUSED"); _; }
    function pause() external onlyOwner { paused = true; }
    function unpause() external onlyOwner { paused = false; }
}