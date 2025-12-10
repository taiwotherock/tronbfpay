// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract ReserveValidationModule {
    address public reserveValidator;

    event ReserveValidated(uint256 totalSupply);

    // Internal function called after mint to validate reserves
    function _validateReserves(uint256 currentTotalSupply) internal virtual {
        if (reserveValidator != address(0)) {
            (bool success, bytes memory data) = reserveValidator.staticcall(
                abi.encodeWithSignature("validate(uint256)", currentTotalSupply)
            );
            require(success, "RESERVE_VALIDATION_FAILED");
            
            // Optional: decode response if validator returns a boolean
            bool validated = abi.decode(data, (bool));
            require(validated, "RESERVE_NOT_SUFFICIENT");
        }

        emit ReserveValidated(currentTotalSupply);
    }

    // Admin can set the reserve validator contract
    function setReserveValidator(address validator) external virtual {
        reserveValidator = validator;
    }
}
