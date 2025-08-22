// SPDX-License-Identifier: MIT
pragma solidity ^0.5.4;
import "./TRC20.sol";

contract FeeSplitter {
    address public owner;
    TRC20 public usdt;
    address public merchant;
    address public platform;
    address public reserve;
    uint16 public platformBps;
    uint16 public reserveBps;

    event Split(uint256 gross, uint256 toMerchant, uint256 toPlatform, uint256 toReserve);

    constructor(TRC20 _usdt, address _platform, address _reserve) public {
        owner = msg.sender;
        usdt = _usdt; platform = _platform; reserve = _reserve;
        platformBps = 60; reserveBps = 20;
    }
    modifier onlyOwner(){ require(msg.sender == owner, "not owner"); _; }
    function setMerchant(address m) external onlyOwner { merchant = m; }
    function setBps(uint16 _plat, uint16 _res) external onlyOwner { platformBps = _plat; reserveBps = _res; }

    function split(uint256 amount) external {
        uint256 p = amount * platformBps / 10_000;
        uint256 r = amount * reserveBps / 10_000;
        uint256 m = amount - p - r;
        require(usdt.transfer(merchant, m), "m xfer");
        if (p > 0) require(usdt.transfer(platform, p), "p xfer");
        if (r > 0) require(usdt.transfer(reserve, r), "r xfer");
        emit Split(amount, m, p, r);
    }
}
