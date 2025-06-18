// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DiamondStorage.sol";

contract Modifiers {
    modifier onlyOwner() {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        require(msg.sender == ds.owner, "Not authorized");
        _;
    }
    
    modifier onlyContract() {
        require(msg.sender == address(this), "Only contract can call");
        _;
    }
    
    modifier onlyAuthorizedOperator() {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        require(
            msg.sender == ds.owner || msg.sender == address(this),
            "Not authorized"
        );
        _;
    }
    
    modifier nonReentrantVault() {
        // Implementation of reentrancy guard
        // This would need proper implementation in the diamond pattern
        _;
    }
}