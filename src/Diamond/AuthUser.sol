//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {DiamondStorage} from "./DiamondStorage.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Modifiers} from "./Modifiers.sol";

// DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();

contract AuthUser is ERC721URIStorage, Modifiers {
    constructor() ERC721("AuthRWA", "ARWA") {
        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        ds._tokenIdCounter = 0;
        ds.owner = msg.sender; // Set the contract deployer as the owner
    }

    function mintAuthNFT(
        address to,
        string memory _tokenURI,
        uint256 valuation
    ) public onlyOwner returns (uint256) {
        require(to != address(0), "Cannot mint to zero address");
        require(bytes(_tokenURI).length > 0, "Token URI cannot be empty");
        require(valuation > 0, "Valuation must be greater than zero");

        DiamondStorage.VaultState storage ds = DiamondStorage.getStorage();
        uint256 tokenId = ds._tokenIdCounter;

        require(
            ds._tokenIdCounter < type(uint256).max,
            "Token ID counter overflow"
        );
        ds._tokenIdCounter += 1;

        //NFT minting
        _mint(to, tokenId);

        // Store user authentication in diamond storage
        ds.User[to][tokenId].isAuth = true;

        // Store valuation in diamond storage
        ds.User[to][tokenId].amount = valuation;

        // Store token URI in diamond storage
        ds.tokenURIs[tokenId] = _tokenURI;

        // Add this NFT ID to the user's collection
        ds.userNftIds[to].push(tokenId);

        //to store token URL in NFT metadata
        _setTokenURI(tokenId, _tokenURI);

        return tokenId;
    }

    
}
