pragma solidity ^0.5.4;

import "./BPayEscrowVault.sol";

contract PaymentRouter {
    BPayEscrowVault public vault;

    constructor(address _vault) public {
        vault = BPayEscrowVault(_vault);
    }

    function routePayment(
        bytes32 orderId,
        address splitter,
        uint256 amount,
        uint256 expiry,
        bytes32 attestRef
    )
        public
    {
        vault.fund(orderId, msg.sender, splitter, amount, expiry, attestRef);
    }

    function releasePayment(bytes32 orderId) public {
        vault.release(orderId);
    }
}
