pragma solidity ^0.5.4;

contract EscrowVaultProxy {
    // Address of the implementation contract
    address public implementation;
    address public admin;

    constructor(address _implementation) public {
        implementation = _implementation;
        admin = msg.sender;
    }

    // Only admin can upgrade implementation
    function upgradeTo(address newImplementation) public {
        require(msg.sender == admin, "Only admin");
        require(newImplementation != address(0), "Invalid address");
        implementation = newImplementation;
    }

    // Fallback delegates all calls to implementation
    function() external payable {
        address impl = implementation;
        require(impl != address(0), "Implementation not set");

        assembly {
            // Copy calldata to memory
            calldatacopy(0x0, 0x0, calldatasize)

            // Delegatecall to implementation
            let result := delegatecall(gas, impl, 0x0, calldatasize, 0x0, 0)

            // Copy returned data
            let size := returndatasize
            returndatacopy(0x0, 0x0, size)

            // Forward return / revert
            switch result
            case 0 { revert(0x0, size) }
            default { return(0x0, size) }
        }
    }
}
