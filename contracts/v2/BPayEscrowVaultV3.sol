// SPDX-License-Identifier: MIT
pragma solidity >=0.4.22 <0.9.0;

import "../TRC20.sol";

interface IAttestationRegistry {
    function isVerified(address user) external view returns (bool);
}

/**
 * @title BPayEscrowVault
 * @notice Gas-optimized escrow vault for TRON USDT transfers with a single off-chain reference validation.
 */
contract BPayEscrowVaultV3 {
    TRC20 public immutable usdt;
    IAttestationRegistry public immutable attestations;

    struct Escrow {
        address payer;
        address payee;
        uint128 amount;
        uint64 expiry;
        bool released;
        bytes32 offchainRef;
    }

    mapping(bytes32 => Escrow) private _escrows;
    mapping(bytes32 => bytes32) private _refToEscrowId;
    mapping(bytes32 => bool) private _usedRefs;
    bytes32[] private _escrowIds;

    event EscrowFunded(
        bytes32 indexed escrowId,
        address indexed payer,
        address indexed payee,
        uint128 amount,
        uint64 expiry,
        bytes32 offchainRef
    );
    event EscrowReleased(bytes32 indexed escrowId, address indexed payee, uint128 amount);
    event EscrowRefunded(bytes32 indexed escrowId, address indexed payer, uint128 amount);

    constructor(address _usdt, address _attestations) {
        require(_usdt != address(0) && _attestations != address(0), "Invalid addr");
        usdt = TRC20(_usdt);
        attestations = IAttestationRegistry(_attestations);
    }

    modifier onlyExisting(bytes32 escrowId) {
        require(_escrows[escrowId].payer != address(0), "No escrow");
        _;
    }

    function fund(
        bytes32 escrowId,
        address payer,
        address payee,
        uint128 amount,
        uint64 expiry,
        bytes32 offchainRef
    ) external {
        require(_escrows[escrowId].payer == address(0), "Exists");
        require(!_usedRefs[offchainRef], "Ref used");
        require(payer != address(0) && payee != address(0), "Bad addr");
        require(amount > 0 && expiry > block.timestamp, "Invalid");
        require(attestations.isVerified(payer), "Unverified");

        _escrows[escrowId] = Escrow({
            payer: payer,
            payee: payee,
            amount: amount,
            expiry: expiry,
            released: false,
            offchainRef: offchainRef
        });
        _usedRefs[offchainRef] = true;
        _refToEscrowId[offchainRef] = escrowId;
        _escrowIds.push(escrowId);

        require(usdt.transferFrom(payer, address(this), amount), "xfer fail");

        emit EscrowFunded(escrowId, payer, payee, amount, expiry, offchainRef);
    }

    function release(bytes32 escrowId) external onlyExisting(escrowId) {
        Escrow storage e = _escrows[escrowId];
        if (e.released) revert("Done");
        require(attestations.isVerified(e.payee), "Unverified");

        e.released = true;
        require(usdt.transfer(e.payee, e.amount), "xfer fail");

        emit EscrowReleased(escrowId, e.payee, e.amount);
    }

    function refund(bytes32 escrowId) external onlyExisting(escrowId) {
        Escrow storage e = _escrows[escrowId];
        if (e.released) revert("Done");
        require(block.timestamp >= e.expiry, "Active");
        require(msg.sender == e.payer, "Not payer");

        e.released = true;
        require(usdt.transfer(e.payer, e.amount), "xfer fail");

        emit EscrowRefunded(escrowId, e.payer, e.amount);
    }

    function getEscrow(bytes32 escrowId) external view returns (Escrow memory) {
        return _escrows[escrowId];
    }

    function getEscrowByRef(bytes32 offchainRef) external view returns (Escrow memory) {
        bytes32 escrowId = _refToEscrowId[offchainRef];
        require(escrowId != 0 && _escrows[escrowId].payer != address(0), "No escrow for ref");
        return _escrows[escrowId];
    }

        // Status enum for clarity
    enum EscrowStatus { Active, Expired, Expiring1m, Expiring5m, Expiring10m }

    function getEscrowsByStatus(EscrowStatus status, uint offset, uint limit) 
        external view returns (bytes32[] memory result, uint count) 
    {
        uint len = _escrowIds.length;
        uint maxSize = limit;
        result = new bytes32[](maxSize);
        count = 0;
        uint nowTs = block.timestamp;

        for (uint i = offset; i < len && count < maxSize; i++) {
            bytes32 id = _escrowIds[i];
            Escrow storage e = _escrows[id];
            if (e.released) continue;

            bool matches = false;
            if (status == EscrowStatus.Active && e.expiry - nowTs > 600) matches = true;
            else if (status == EscrowStatus.Expiring10m && e.expiry - nowTs <= 600 && e.expiry - nowTs > 300) matches = true;
            else if (status == EscrowStatus.Expiring5m && e.expiry - nowTs <= 300 && e.expiry - nowTs > 60) matches = true;
            else if (status == EscrowStatus.Expiring1m && e.expiry - nowTs <= 60 && e.expiry > nowTs) matches = true;
            else if (status == EscrowStatus.Expired && e.expiry <= nowTs) matches = true;

            if (matches) {
                result[count++] = id;
            }
        }

        // Resize array to actual count
        assembly { mstore(result, count) }
    }

}

