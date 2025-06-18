// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/LibDiamond.sol";
import "../../interfaces/IERC173.sol";

contract OwnershipFacet is IERC173 {
    /// @notice Get the address of the owner
    /// @return owner_ The address of the owner
    function owner() external view override returns (address owner_) {
        owner_ = LibDiamond.contractOwner();
    }

    /// @notice Transfer ownership to a new address
    /// @param _newOwner The address of the new owner
    function transferOwnership(address _newOwner) external override {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(_newOwner);
    }

    /// @notice Relinquish ownership of the contract
    /// Security note: Leaves contract without an owner
    /// Can only be called by the current owner
    function renounceOwnership() external {
        LibDiamond.enforceIsContractOwner();
        LibDiamond.setContractOwner(address(0));
    }
}