// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// TRC20 Interface
interface ITRC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address  to, uint256 value) external returns (bool);
    function transferFrom(address from, address  to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

// SafeTRC20 Library
library SafeTRC20 {
    function safeTransfer(ITRC20 token, address  to, uint256 value) internal {
        bool ok = token.transfer(to, value);
        require(ok, "SafeTRC20: transfer failed");
    }

    function safeTransferFrom(ITRC20 token, address from, address  to, uint256 value) internal {
        bool ok = token.transferFrom(from, to, value);
        require(ok, "SafeTRC20: transferFrom failed");
    }
}
