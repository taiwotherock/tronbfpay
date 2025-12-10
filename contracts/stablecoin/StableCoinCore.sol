// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./ReserveValidationModule.sol";
import "./RolesModule.sol";
import "./BlacklistModule.sol";
import "./WhitelistModule.sol";

contract StableCoinCore is ReserveValidationModule,RolesModule, WhitelistModule, BlacklistModule {

    string public name;
    string public symbol;
    uint8 public decimals;
    bool public paused;
    address public priceOracle;

    event Paused(address indexed admin);
    event Unpaused(address indexed admin);


    uint256 public cap; // default: no cap
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;


    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event CapUpdated(uint256 newCap);
    event PriceOracleUpdated(address indexed oldOracle, address indexed newOracle);
      
    uint256 private _locked = 1;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address initialAdmin, uint256 initialSupply) {
        require(initialAdmin != address(0), "ZERO_ADMIN");
        name = _name;
        symbol = _symbol;
        decimals = _decimals;


        isAdmin[initialAdmin] = true;
        emit AdminAdded(initialAdmin);


        if (initialSupply > 0) {
        totalSupply = initialSupply;
        balanceOf[initialAdmin] = initialSupply;
        emit Transfer(address(0), initialAdmin, initialSupply);
        }
    }

    modifier onlyAdminHook() {
        require(isAdmin[msg.sender], "NOT_ADMIN");
        _;
    }

    // Set or update max cap
    function setCap(uint256 newCap) external onlyAdminHook {
        require(newCap >= totalSupply, "NEW_CAP_LESS_THAN_SUPPLY");
        cap = newCap;
        emit CapUpdated(newCap);
    }

    function pause() external onlyAdminHook { paused = true; emit Paused(msg.sender); }
    function unpause() external onlyAdminHook { paused = false; emit Unpaused(msg.sender); }


    function _isPaused() internal view returns (bool) { return paused; }

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    function setPriceOracle(address oracle) external onlyAdminHook {
        require(oracle != address(0), "INVALID_ORACLE_ADDRESS");

        address old = priceOracle;
        priceOracle = oracle;

        emit PriceOracleUpdated(old, oracle);
    }


    function _beforeTransferChecks(address from, address to) internal view virtual {
        require(to != address(0), "TRC20: transfer to zero");
        require(!isBlacklisted(from) && !isBlacklisted(to), "TRC20: blacklisted");
        //require(!_isFrozen(from) && !_isFrozen(to), "TRC20: frozen");
        if (!isWhitelisted(from) && !isWhitelisted(to)) {
            require(!_isPaused(), "TRC20: paused");
        }
    }


    function _transferInternal(address from, address to, uint256 amount) internal virtual {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "TRC20: insufficient balance");
        unchecked { balanceOf[from] = bal - amount; }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }


    function _approveInternal(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "TRC20: zero address");
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }


    function transfer(address to, uint256 amount) external virtual returns (bool) {
        _beforeTransferChecks(msg.sender, to);
        _transferInternal(msg.sender, to, amount);
        return true;
    }


    function approve(address spender, uint256 amount) external virtual returns (bool) {
        require(!isBlacklisted(msg.sender), "owner blacklisted");
        require(isWhitelisted(msg.sender), "Address not whitelisted");
        require(!paused, "paused");
        _approveInternal(msg.sender, spender, amount);
        return true;
    }


    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        _beforeTransferChecks(from, to);
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "TRC20: allowance exceeded");
        unchecked { allowance[from][msg.sender] = allowed - amount; }
        emit Approval(from, msg.sender, allowance[from][msg.sender]);
        _transferInternal(from, to, amount);
        return true;
    }



    function _requireValidMintSigner(address signer) internal view  {
        require(isMinter[signer] || isAdmin[signer], "SIGNER_NOT_MINTER");
    }


    function _requireValidBurnSigner(address signer) internal view  {
        require(isBurner[signer] || isAdmin[signer], "SIGNER_NOT_BURNER");
    }


    function _applyPermit(address owner, address spender, uint256 value) internal  {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }


    // ------------------- Admin mint/burn -------------------
    function adminMint(address to, uint256 amount) external onlyAdminHook nonReentrant {
        require(isMinter[msg.sender] || isAdmin[msg.sender], "NOT_AUTH_MINT");
        _mintFromModule(to, amount);
    }


    function adminBurn(address from, uint256 amount) external onlyAdminHook nonReentrant {
        require(isBurner[msg.sender] || isAdmin[msg.sender], "NOT_AUTH_BURN");
        _burnFromModule(from, amount);
    }


    // ------------------- Public mint/burn -------------------
    function mint(address to, uint256 amount) external nonReentrant {
        require(!paused, "MINT_PAUSED");
        require(isMinter[msg.sender] || isAdmin[msg.sender], "NOT_AUTH_MINT");
        _mintFromModule(to, amount);
    }

    function _mintFromModule(address to, uint256 amount) internal  {
        // Enforce maximum supply cap
        require(totalSupply + amount <= cap, "CAP_EXCEEDED");

        // Core mint logic (updates balance and totalSupply, emits Transfer event)
        _mintInternal(to, amount);

        // Post-mint external reserve validation
        _validateReserves(totalSupply);
    }

    function _mintInternal(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: mint to zero");
        
        // Check blacklist/freeze
        require(!isBlacklisted(to), "ERC20: mint to blacklisted");
        //require(!isFrozen(to), "ERC20: mint to frozen address");
        require(!paused, "BURN_PAUSED");
        
        // Update balances and total supply
        balanceOf[to] += amount;
        totalSupply += amount;
        
        // Emit standard ERC20 Transfer event from zero address
        emit Transfer(address(0), to, amount);
    }



    function burn(uint256 amount) external nonReentrant {
        _burnFromModule(msg.sender, amount);
    }


    function burnFrom(address from, uint256 amount) external nonReentrant {
        require(isBurner[msg.sender] || isAdmin[msg.sender], "NOT_AUTH_BURN");
        
        _burnFromModule(from, amount);
    }

    // Internal burn called by modules, enforces pause check
    function _burnFromModule(address from, uint256 amount) internal  {
        
        _burnInternal(from, amount);
    }

    // Core burn logic with blacklist/whitelist/freeze enforcement
    function _burnInternal(address from, uint256 amount) internal virtual {
        require(from != address(0), "ERC20: burn from zero");
        require(!isBlacklisted(from), "ERC20: burn from blacklisted");
        //require(!isFrozen(from), "ERC20: burn from frozen");
        require(!paused, "BURN_PAUSED");

        uint256 bal = balanceOf[from];
        require(bal >= amount, "ERC20: insufficient balance");
        unchecked { balanceOf[from] = bal - amount; }
        totalSupply -= amount;

        emit Transfer(from, address(0), amount);
    }


   

}
