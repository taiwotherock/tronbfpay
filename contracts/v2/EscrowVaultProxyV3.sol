// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract EscrowVaultProxyV3 {
    // Address of the implementation contract
    address public implementation;
    address public admin;

    constructor(address _implementation) {
        require(_implementation != address(0), "Invalid implementation");
        implementation = _implementation;
        admin = msg.sender;
    }

    // Only admin can upgrade implementation
    function upgradeTo(address newImplementation) external {
        require(msg.sender == admin, "Only admin");
        require(newImplementation != address(0), "Invalid address");
        implementation = newImplementation;
    }

    // Fallback delegates all calls to implementation
    fallback() external payable {
        address impl = implementation;
        require(impl != address(0), "Implementation not set");

        assembly {
            // Copy calldata to memory
            calldatacopy(0x0, 0x0, calldatasize())

            // Delegatecall to implementation
            let result := delegatecall(gas(), impl, 0x0, calldatasize(), 0x0, 0)

            // Copy returned data
            let size := returndatasize()
            returndatacopy(0x0, 0x0, size)

            // Forward return / revert
            switch result
            case 0 { revert(0x0, size) }
            default { return(0x0, size) }
        }
    }

    // Optional: receive plain TRX transfers
    receive() external payable {}
}
