// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract BNPLAttestationOracle {
    struct Attestation {
        uint256 creditLimit;
        uint256 creditScore;   // e.g., 0-1000
        bool kycVerified;
        uint256 utilizedLimit; 
        address attestor;      // who issued this attestation
        uint256 updatedAt;     // timestamp
    }

    // Mapping: borrower => attestation
    mapping(address => Attestation) public attestations;
    mapping(address => bool) public allowedBNPLPools;

    // Trusted attestors
    mapping(address => bool) public trustedAttestors;

    // Events
    event AttestationUpdated(address indexed borrower, uint256 creditLimit, uint256 creditScore, bool kycVerified, address indexed attestor);
    event AttestorAdded(address indexed attestor);
    event AttestorRemoved(address indexed attestor);
    event UsedCreditUpdated(address indexed borrower, uint256 newUsedCredit);

    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    modifier onlyTrustedAttestor() {
        require(trustedAttestors[msg.sender], "not a trusted attestor");
        _;
    }

     modifier onlyPool() {
        require(allowedBNPLPools[msg.sender], "not BNPL pool");
        _;
    }

    function setAllowedPool(address pool, bool allowed) external onlyTrustedAttestor {
        allowedBNPLPools[pool] = allowed;
    }


    // Owner can add/remove trusted attestors
    function addTrustedAttestor(address attestor) external onlyOwner {
        trustedAttestors[attestor] = true;
        emit AttestorAdded(attestor);
    }

    function removeTrustedAttestor(address attestor) external onlyOwner {
        trustedAttestors[attestor] = false;
        emit AttestorRemoved(attestor);
    }

    // Attestor sets attestation for borrower
    function setAttestation(
        address borrower,
        uint256 creditLimit,
        uint256 creditScore,
        bool kycVerified
    ) external onlyTrustedAttestor {
        attestations[borrower] = Attestation({
            creditLimit: creditLimit,
            creditScore: creditScore,
            kycVerified: kycVerified,
            utilizedLimit: 0,
            attestor: msg.sender,
            updatedAt: block.timestamp
        });

        emit AttestationUpdated(borrower, creditLimit, creditScore, kycVerified, msg.sender);
    }

    // ========================
    //     CREDIT UTILIZATION
    // ========================

    function increaseUsedCredit(address borrower, uint256 amount)
        external
        onlyPool
    {
        Attestation storage a = attestations[borrower];
        require(a.kycVerified, "not KYC verified");
        require(a.utilizedLimit + amount <= a.creditLimit, "exceeds credit limit");

        a.utilizedLimit += amount;
        a.updatedAt = block.timestamp;

        emit UsedCreditUpdated(borrower, a.utilizedLimit);
    }

    function decreaseUsedCredit(address borrower, uint256 amount)
        external
        onlyPool
    {
        Attestation storage a = attestations[borrower];
        require(a.utilizedLimit >= amount, "underflow");

        a.utilizedLimit -= amount;
        a.updatedAt = block.timestamp;

        emit UsedCreditUpdated(borrower, a.utilizedLimit);
    }

    // View function for BNPL pool
    function getAttestation(address borrower) external view returns (uint256 creditLimit, 
    uint256 creditScore, bool kycVerified, uint256 utilizedLimit, address attestor, uint256 updatedAt) {
        Attestation memory a = attestations[borrower];
        return (a.creditLimit, a.creditScore, a.kycVerified, a.utilizedLimit, a.attestor, a.updatedAt);
    }
}
