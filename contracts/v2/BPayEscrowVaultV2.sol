pragma solidity ^0.5.4;

import "../TRC20.sol";

interface IAttestationRegistry {
    function isVerified(address user) external view returns (bool);
}

contract BPayEscrowVaultV2 {
    TRC20 public usdt;
    IAttestationRegistry public attestations;

    struct Escrow {
        address payer;
        address payee;
        uint256 amount;
        bool released;
        uint256 expiry;
        bytes32 attestRef;
    }

    mapping(bytes32 => Escrow) public escrows;

    constructor(address _usdt, address _attestations) public {
        usdt = TRC20(_usdt);
        attestations = IAttestationRegistry(_attestations);
    }

    function fund(
        bytes32 escrowId,
        address payer,
        address payee,
        uint256 amount,
        uint256 expiry,
        bytes32 attestRef
    )
        public
    {
        require(attestations.isVerified(payer), "Payer not verified");
        require(usdt.transferFrom(payer, address(this), amount), "Transfer failed");

        escrows[escrowId] = Escrow({
            payer: payer,
            payee: payee,
            amount: amount,
            released: false,
            expiry: expiry,
            attestRef: attestRef
        });
    }

    function release(bytes32 escrowId) public {
        Escrow storage e = escrows[escrowId];
        require(!e.released, "Already released");
        require(attestations.isVerified(e.payee), "Payee not verified");
        e.released = true;
        require(usdt.transfer(e.payee, e.amount), "USDT transfer failed");
    }
}
