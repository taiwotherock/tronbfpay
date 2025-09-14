
pragma solidity ^0.5.4;

contract AccessControlModule {
    address public multisig; // protected by multisig for sensitive changes
    mapping(address => bool) public admins;
    mapping(address => bool) public creditOfficers;
    mapping(address => bool) public keepers;

    event AdminAdded(address indexed who);
    event AdminRemoved(address indexed who);
    event CreditOfficerAdded(address indexed who);
    event CreditOfficerRemoved(address indexed who);
    event KeeperAdded(address indexed who);
    event KeeperRemoved(address indexed who);

    modifier onlyAdmin() {
        require(admins[msg.sender] || msg.sender == multisig, "Not admin");
        _;
    }
    modifier onlyCreditOfficer(){ require(creditOfficers[msg.sender], "Not credit officer"); _; }
    modifier onlyKeeper(){ require(keepers[msg.sender], "Not keeper"); _; }

    constructor(address _initialAdmin, address _multisig) public {
        admins[_initialAdmin] = true;
        multisig = _multisig;
    }

    function addAdmin(address a) external onlyAdmin {
        admins[a] = true; emit AdminAdded(a);
    }
    function removeAdmin(address a) external onlyAdmin  {
        admins[a] = false; emit AdminRemoved(a);
    }

    function addCreditOfficer(address a) external onlyAdmin { creditOfficers[a] = true; emit CreditOfficerAdded(a); }
    function removeCreditOfficer(address a) external onlyAdmin { creditOfficers[a] = false; emit CreditOfficerRemoved(a); }

    function addKeeper(address a) external onlyAdmin { keepers[a] = true; emit KeeperAdded(a); }
    function removeKeeper(address a) external onlyAdmin { keepers[a] = false; emit KeeperRemoved(a); }

    function setMultisig(address m) external onlyAdmin { multisig = m; }
}