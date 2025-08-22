pragma solidity ^0.5.4;

contract AttestationRegistry {
    address public admin;

    mapping(address => bool) public verified;

    event AttestationAdded(address indexed user, bool status);

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin");
        _;
    }

    function setVerified(address user, bool status) public onlyAdmin {
        verified[user] = status;
        emit AttestationAdded(user, status);
    }

    function isVerified(address user) external view returns (bool) {
        return verified[user];
    }
}
