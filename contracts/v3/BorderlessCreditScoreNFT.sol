// SPDX-License-Identifier: MIT
pragma solidity ^0.5.4;

/// @notice Minimal ERC721 implementation with Ownable included
contract BorderlessCreditScoreNFT {
    string public name = "Borderless Credit Score NFT";
    string public symbol = "BCSNFT";

    address public owner;
    address public creditOfficer;
    uint256 private _nextTokenId = 1;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) public borrowerToTokenId;
    mapping(uint256 => address) private _tokenApprovals;

    struct CreditProfile {
        uint16 creditScore;
        uint256 creditLimit;
        address creditOfficer;
        address creditManager;
        uint256 issuedAt;
        bool active;
    }

    mapping(uint256 => CreditProfile) private _creditProfiles;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event CreditNFTIssued(
        uint256 indexed tokenId,
        address indexed borrower,
        uint16 creditScore,
        uint256 creditLimit,
        address creditOfficer,
        address creditManager,
        uint256 issuedAt
    );

    event CreditNFTUpdated(
        uint256 indexed tokenId,
        uint16 newCreditScore,
        uint256 newCreditLimit,
        address creditOfficer,
        uint256 updatedAt
    );

    modifier onlyOwner() {
        require(msg.sender == owner || msg.sender == creditOfficer, "Not owner");
        _;
    }

    constructor(address _creditOfficer) public {
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

    function _safeMint(address to, uint256 tokenId) internal {
        _owners[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function issueCreditNFT(
        address borrower,
        uint16 creditScore,
        uint256 creditLimit,
        address _creditOfficer,
        address creditManager
    ) external onlyOwner returns (uint256) {
        require(borrower != address(0), "Invalid borrower");
        require(borrowerToTokenId[borrower] == 0, "Borrower already has NFT");

        uint256 tokenId = _nextTokenId;
        _nextTokenId++;

        _safeMint(borrower, tokenId);

        _creditProfiles[tokenId] = CreditProfile({
            creditScore: creditScore,
            creditLimit: creditLimit,
            creditOfficer: _creditOfficer,
            creditManager: creditManager,
            issuedAt: block.timestamp,
            active: true
        });

        borrowerToTokenId[borrower] = tokenId;

        emit CreditNFTIssued(tokenId, borrower, creditScore, creditLimit, creditOfficer, creditManager, block.timestamp);
        return tokenId;
    }

    function updateCreditNFT(
        uint256 tokenId,
        uint16 newCreditScore,
        uint256 newCreditLimit,
        address _creditOfficer
    ) external onlyOwner {
        require(_exists(tokenId), "Token does not exist");

        CreditProfile storage profile = _creditProfiles[tokenId];
        profile.creditScore = newCreditScore;
        profile.creditLimit = newCreditLimit;
        profile.creditOfficer = _creditOfficer;
        profile.issuedAt = block.timestamp;

        emit CreditNFTUpdated(tokenId, newCreditScore, newCreditLimit, creditOfficer, block.timestamp);
    }

    function getCreditScoreByBorrower(address borrower) external view returns (uint16) {
        uint256 tokenId = borrowerToTokenId[borrower];
        require(tokenId != 0, "Borrower has no NFT");
        return _creditProfiles[tokenId].creditScore;
    }

    function getCreditLimitByBorrower(address borrower) external view returns (uint256) {
        uint256 tokenId = borrowerToTokenId[borrower];
        require(tokenId != 0, "Borrower has no NFT");
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
            uint256 issuedAt,
            bool active
        )
    {
        uint256 tokenId = borrowerToTokenId[borrower];
        require(tokenId != 0, "Borrower has no NFT");
        CreditProfile storage p = _creditProfiles[tokenId];
        return (p.creditScore, p.creditLimit, p.creditOfficer, p.creditManager, p.issuedAt, p.active);
    }

    // Restrict transfers
    function transferFrom(address from, address to, uint256 tokenId) external pure {
        require(false, "Transfers disabled"); // only mint/burn allowed
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external pure {
        require(false, "Transfers disabled"); // only mint/burn allowed
    }
}
