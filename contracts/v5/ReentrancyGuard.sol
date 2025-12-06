// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/** REENTRANCY GUARD */
contract ReentrancyGuard {
    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private status;
    constructor() { status = NOT_ENTERED; }
    modifier nonReentrant() {
        require(status != ENTERED, "REENTRANT");
        status = ENTERED;
        _;
        status = NOT_ENTERED;
    }
}