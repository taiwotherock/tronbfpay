// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title BorderlessCreditScoreNFT
 * @notice Minimal ERC721-like NFT for credit scores with role-based management
 * @dev Gas optimized for Solidity 0.8.23
 */
contract BorderlessCreditScoreNFTV3 {
    string public constant name = "Borderless Credit Score NFT";
    string public constant symbol = "BCSNFT";

    address public owner;
    address public creditOfficer;
    uint256 private _ownerCount;

    uint256 private _nextTokenId = 1;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) public borrowerToTokenId;

    struct CreditProfile {
        uint16 creditScore;
        uint256 creditLimit;
        address creditOfficer;
        address creditManager;
        uint64 issuedAt;
        bool active;
    }

    mapping(uint256 => CreditProfile) private _creditProfiles;

    event CreditNFTIssued(
        uint256 indexed tokenId,
        address indexed borrower,
        uint16 creditScore,
        uint256 creditLimit,
        address creditOfficer,
        address creditManager,
        uint64 issuedAt
    );

    event CreditNFTUpdated(
        uint256 indexed tokenId,
        uint16 newCreditScore,
        uint256 newCreditLimit,
        address creditOfficer,
        uint64 updatedAt
    );

    event OwnerAdded(address indexed owner);
    event OwnerRemoved(address indexed owner);

    modifier onlyAdmin() {
        require(msg.sender == _owners[0], "Not admin");
        _;
    }

    modifier onlyOwnerOrOfficer() {
        require(msg.sender == owner || msg.sender == creditOfficer, "Not authorized");
        _;
    }

    constructor(address _creditOfficer) {
        require(_creditOfficer != address(0), "Invalid officer");
        owner = msg.sender;
        creditOfficer = _creditOfficer;
    }

    function _exists(uint256 tokenId) internal view returns (bool) {
        return _owners[tokenId] != address(0);
    }

    function balanceOf(address user) external view returns (uint256) {
        return borrowerToTokenId[user] != 0 ? 1 : 0;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(_exists(tokenId), "Token does not exist");
        return _owners[tokenId];
    }

    function _mint(address to, uint256 tokenId) internal {
        _owners[tokenId] = to;
    }

    function issueCreditNFT(
        address borrower,
        uint16 creditScore,
        uint256 creditLimit,
        address _creditOfficer,
        address creditManager
    ) external onlyOwnerOrOfficer returns (uint256) {
        require(borrower != address(0), "Invalid borrower");
        require(borrowerToTokenId[borrower] == 0, "Borrower already has NFT");

        uint256 tokenId = _nextTokenId++;
        _mint(borrower, tokenId);

        _creditProfiles[tokenId] = CreditProfile({
            creditScore: creditScore,
            creditLimit: creditLimit,
            creditOfficer: _creditOfficer,
            creditManager: creditManager,
            issuedAt: uint64(block.timestamp),
            active: true
        });

        borrowerToTokenId[borrower] = tokenId;

        emit CreditNFTIssued(tokenId, borrower, creditScore, creditLimit, _creditOfficer, creditManager, uint64(block.timestamp));
        return tokenId;
    }

    function updateCreditNFT(
        uint256 tokenId,
        uint16 newCreditScore,
        uint256 newCreditLimit,
        address _creditOfficer
    ) external onlyOwnerOrOfficer {
        require(_exists(tokenId), "Token does not exist");
        CreditProfile storage profile = _creditProfiles[tokenId];

        profile.creditScore = newCreditScore;
        profile.creditLimit = newCreditLimit;
        profile.creditOfficer = _creditOfficer;
        profile.issuedAt = uint64(block.timestamp);

        emit CreditNFTUpdated(tokenId, newCreditScore, newCreditLimit, _creditOfficer, uint64(block.timestamp));
    }

    function getCreditScoreByBorrower(address borrower) external view returns (uint16) {
        uint256 tokenId = borrowerToTokenId[borrower];
        require(tokenId != 0, "No NFT for borrower");
        return _creditProfiles[tokenId].creditScore;
    }

    function getCreditLimitByBorrower(address borrower) external view returns (uint256) {
        uint256 tokenId = borrowerToTokenId[borrower];
        require(tokenId != 0, "No NFT for borrower");
        return _creditProfiles[tokenId].creditLimit;
    }

    function getCreditProfileByBorrower(address borrower)
        external
        view
        returns (
            uint16 creditScore,
            uint256 creditLimit,
            address _creditOfficer,
            address creditManager,
            uint64 issuedAt,
            bool active
        )
    {
        uint256 tokenId = borrowerToTokenId[borrower];
        require(tokenId != 0, "No NFT for borrower");
        CreditProfile storage p = _creditProfiles[tokenId];
        return (p.creditScore, p.creditLimit, p.creditOfficer, p.creditManager, p.issuedAt, p.active);
    }

    // Transfers disabled
    function transferFrom(address, address, uint256) external pure {
        revert("Transfers disabled");
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert("Transfers disabled");
    }

 

    // Add new owner
    function addOwner(address newOwner) external onlyAdmin {
        require(newOwner != address(0), "Zero address");
        require(!_isOwner(newOwner), "Already owner");

        _owners[_ownerCount++] = newOwner;
        emit OwnerAdded(newOwner);
    }

    // Remove owner by address (reorders list)
    function removeOwner(address ownerToRemove) external onlyAdmin () {
        uint256 index = _getOwnerIndex(ownerToRemove);
        require(index < _ownerCount, "Invalid index");

        address lastOwner = _owners[_ownerCount - 1];
        if (index != _ownerCount - 1) {
            _owners[index] = lastOwner; // move last into removed slot
        }

        delete _owners[_ownerCount - 1];
        _ownerCount--;

        emit OwnerRemoved(ownerToRemove);
    }

    // Get total owners
    function getOwnerCount() external view returns (uint256) {
        return _ownerCount;
    }

    // Get all owners
    function getAllOwners() external view returns (address[] memory list) {
        list = new address[](_ownerCount);
        for (uint256 i; i < _ownerCount; i++) {
            list[i] = _owners[i];
        }
    }

    // Internal helpers
    function _isOwner(address user) internal view returns (bool) {
        for (uint256 i; i < _ownerCount; i++) {
            if (_owners[i] == user) return true;
        }
        return false;
    }

    function _getOwnerIndex(address user) internal view returns (uint256) {
        for (uint256 i; i < _ownerCount; i++) {
            if (_owners[i] == user) return i;
        }
        revert("Owner not found");
    }
}