// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { Base64 } from "@openzeppelin/contracts/utils/Base64.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { KittyBridge } from "./KittyBridge.sol";

/**
 * @title KittyConnect
 * @author Shikhar Agarwal
 * @notice This contract allows users to buy a cute cat from our branches and mint NFT for buying a cat
 * The NFT will be used to track the cat info and all related data for a particular cat corresponding to their token ids
 */
contract KittyConnect is ERC721 {
    struct CatInfo {
        string catName;
        string breed;
        string image;
        uint256 dob;
        address[] prevOwner;
        address shopPartner;
        uint256 idx;
    }

    // Storage Variables
    uint256 private kittyTokenCounter;
    address private immutable i_kittyConnectOwner;
    mapping(address => bool) private s_isKittyShop;
    address[] private s_kittyShops;
    mapping(address user => uint256[]) private s_ownerToCatsTokenId;
    mapping(uint256 tokenId => CatInfo) private s_catInfo;
    KittyBridge private immutable i_kittyBridge;

    // Events
    event ShopPartnerAdded(address partner);
    event CatMinted(uint256 tokenId, string catIpfsHash);
    event TokensRedeemedForVetVisit(uint256 tokenId, uint256 amount, string remarks);
    event CatTransferredToNewOwner(address prevOwner, address newOwner, uint256 tokenId);
    event NFTBridgeRequestSent(uint256 sourceChainId, uint64 destChainSelector, address destBridge, uint256 tokenId);
    event NFTBridged(uint256 chainId, uint256 tokenId);

    // Modifiers
    modifier onlyKittyConnectOwner() {
        require(msg.sender == i_kittyConnectOwner, "KittyConnect__NotKittyConnectOwner");
        _;
    }

    modifier onlyShopPartner() {
        require(s_isKittyShop[msg.sender], "KittyConnect__NotAPartner");
        _;
    }

    modifier onlyKittyBridge() {
        require(msg.sender == address(i_kittyBridge), "KittyConnect__NotKittyBridge");
        _;
    }

    // Constructor
    constructor(address[] memory initShops, address router, address link) ERC721("KittyConnect", "KC") {
        for (uint256 i = 0; i < initShops.length; i++) {
            s_kittyShops.push(initShops[i]);
            s_isKittyShop[initShops[i]] = true;
        }

        i_kittyConnectOwner = msg.sender;
        i_kittyBridge = new KittyBridge(router, link, msg.sender);
    }
    
    // This function is expected to add shop address
    function addShop(address shopAddress) external onlyKittyConnectOwner {

        // This line marks the shopAddress as a valid kittyShop 
        // by setting its value to true.
        s_isKittyShop[shopAddress] = true;

        // This line adds the shopAddress to the s_kittyShops
        // keeping track of all registered kitty shops.
        s_kittyShops.push(shopAddress);

        // This line emits an event ShopPartnerAdded
        // which passes the shopAddress as a parameter to the event
        emit ShopPartnerAdded(shopAddress);
    }

    // This function is expected to mint a cat NFT and assign it to a new owner
    function mintCatToNewOwner(
        address catOwner, // The Ethereum address of the new cat owner
        string memory catIpfsHash, // A string representing an IPFS hash, likely an image of the cat
        string memory catName, // A string of the cat's name
        string memory breed, // A string specifying the cat's breed
        uint256 dob // An unsigned integer representing the cat's date of birth
        ) 
        external onlyShopPartner 
        {

        // This line is checking if the catOwner is a KittyShop
        // the transaction will revert with the error message "KittyConnect__CatOwnerCantBeShopPartner".
        require(!s_isKittyShop[catOwner], "KittyConnect__CatOwnerCantBeShopPartner");

        // This line assigns tokenId as a current uint value of kittyTokenCounter
        uint256 tokenId = kittyTokenCounter;
        // This line increments the kittyTokenCounter
        kittyTokenCounter++;

        s_catInfo[tokenId] = CatInfo({
            catName: catName,
            breed: breed,
            image: catIpfsHash,
            dob: dob,
            prevOwner: new address[](0),
            shopPartner: msg.sender,
            idx: s_ownerToCatsTokenId[catOwner].length
        });

        s_ownerToCatsTokenId[catOwner].push(tokenId);

        _safeMint(catOwner, tokenId);
        emit CatMinted(tokenId, catIpfsHash);
    }

    // This function is expected to transfer ownership to a new owner
    // by approving the kittyNFT to the new owner
    function safeTransferFrom(
        address currCatOwner, // The address of current cat NFT
        address newOwner, // The address of the new cat NFT 
        uint256 tokenId, // The tokenId of the cat NFT transferred
        bytes memory data
        ) 
        public override onlyShopPartner 
        {

        // This line checks if the currCatOwner is indeed the current owner of the token.
        // If not, it throws an error with the message "KittyConnect__NotKittyOwner".
        require(_ownerOf(tokenId) == currCatOwner, "KittyConnect__NotKittyOwner");

        // This line verifies if the newOwner has been approved to receive this token.
        // If not approved, it throws an error with "KittyConnect__NewOwnerNotApproved".
        require(getApproved(tokenId) == newOwner, "KittyConnect__NewOwnerNotApproved");
        
        // This line updates the ownership info of the cat NFT
        // from the currCatOwner to newOwner, including the tokenID of the cat
        _updateOwnershipInfo(currCatOwner, newOwner, tokenId);

        // This line logs the transfer of a cat NFT 
        // from the currCatOwner to the newOwner, including the tokenId of the cat
        emit CatTransferredToNewOwner(currCatOwner, newOwner, tokenId);

        // This line transfers the cat NFT from the current owner to the new owner
        // identified by tokenId
        _safeTransfer(currCatOwner, newOwner, tokenId, data);
    }

    // This function is expected to bridge kittyNFT from one chain to another
    // by burning the kittyNFT on source chain
    // and minting on the destination chain
    function bridgeNftToAnotherChain(
        uint64 destChainSelector, // The uint64-bit of the destination chain selector
        address destChainBridge, // The address of bridge contract on the destination chain
        uint256 tokenId // The uint256-bit of NFT being bridged
        ) 
        external 
        {
        // This line retrieves the address of the current ownerOf the cat NFT 
        // with the specified tokenId and assigns that retrieved address to the variable catOwner.
        address catOwner = _ownerOf(tokenId);

        // This line checks the caller of the function is thesame as the catOwner
        require(msg.sender == catOwner);

        // This line retrieves the CatInfo struct associated with token
        CatInfo memory catInfo = s_catInfo[tokenId];

        // This line retrieves the idx value from the catInfo structure and stores it in a new uint256 variable called idx
        uint256 idx = catInfo.idx;

        // This line encodes several pieces of data related to a specific cat
        //  into a byte array using abi.encode 
        bytes memory data = abi.encode(catOwner, catInfo.catName, catInfo.breed, catInfo.image, catInfo.dob, catInfo.shopPartner);

        // The _burn(tokenId) function is called to remove the NFT with the specified tokenId from the contract.
        _burn(tokenId);
        // This line deletes all the catInfo associated with the given tokenId from the s_catInfo mapping
        delete s_catInfo[tokenId];

        // This line retrieves the array of tokenIds owned by the caller (msg.sender) from the s_ownerToCatsTokenId mapping
        // and stores it in the userTokenIds variable
        // the array is stored in memory
        uint256[] memory userTokenIds = s_ownerToCatsTokenId[msg.sender];
        // This line retrieves the token ID of the last element in the userTokenIds array 
        // and stores it in the lastItem variable
        uint256 lastItem = userTokenIds[userTokenIds.length - 1];

        s_ownerToCatsTokenId[msg.sender].pop();

        if (idx < (userTokenIds.length - 1)) {
            s_ownerToCatsTokenId[msg.sender][idx] = lastItem;
        }

        // This line emits an event that logs the details of an NFT bridging request
        emit NFTBridgeRequestSent(block.chainid, destChainSelector, destChainBridge, tokenId);
        // This line initiates the bridging of an NFT to another blockchain
        // providing destChainSelector, destChainBridge, data requirements
        i_kittyBridge.bridgeNftWithData(destChainSelector, destChainBridge, data);
    }

    // This function is responsible for minting (creating) an NFT that has been bridged 
    function mintBridgedNFT(bytes memory data) external onlyKittyBridge {
        (
            address catOwner, // The address representing the owner of the cat NFT
            string memory catName, // The name of the cat, string stored in memory
            string memory breed, // The breed of the cat, string stored in memory
            string memory imageIpfsHash, // A hash pointing to an image stored on IPFS
            uint256 dob, // The date of birth of the cat, stored as a uint256-bit value
            address shopPartner // The address of shopPartner to the catNFT
        // This line decodes a byte-encoded data into specific variable types: an address, three strings, a uint256, and another address    
        ) = abi.decode(data, (address, string, string, string, uint256, address));

        // This line assigns the current value of kittyTokenCounter to tokenId
        uint256 tokenId = kittyTokenCounter;
        // increments the value of the kittyTokenCounter by 1
        kittyTokenCounter++;

        // This line assigns a new CatInfo struct to the s_catInfo mapping for a specific tokenId
        s_catInfo[tokenId] = CatInfo({
            catName: catName,
            breed: breed,
            image: imageIpfsHash,
            dob: dob,
            prevOwner: new address[](0),
            shopPartner: shopPartner,
            idx: s_ownerToCatsTokenId[catOwner].length
        });

        // This line triggers an NFTBridged event 
        // which logs the ID of the current blockchain and the token ID of the NFT that was bridged
        emit NFTBridged(block.chainid, tokenId);
        // This line calls the _safeMint function to mint a new NFT and assigns it to the specified catOwner
        _safeMint(catOwner, tokenId);
    }
    
    // This function is expected to update the ownership of the cat NFT
    function _updateOwnershipInfo(
        address currCatOwner, // The address of the current owner of the cat NFT
        address newOwner, // The address that will become the new owner of the cat NFT 
        uint256 tokenId // The tokenId of the cat NFT being transferred.
        ) 
        internal 
        {        
        // This line adds the address of the currCatOwner to the prevOwner array of the CatInfo struct for the given tokenId    
        s_catInfo[tokenId].prevOwner.push(currCatOwner);
        // This line updates the idx field in the CatInfo struct 
        // for the specified tokenId to the length of the array of token IDs owned by newOwner
        s_catInfo[tokenId].idx = s_ownerToCatsTokenId[newOwner].length;
        // This line is used to update the list of token IDs owned by a specific address
        s_ownerToCatsTokenId[newOwner].push(tokenId);
    }

    // This function is expected to provide a base URI for NFTs
    // by returning "data:application/json;base64,"
    function _baseURI() internal pure override returns (string memory) {
        return "data:application/json;base64,";
    }

    // This function is expected to retrieve a tokenURI  
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // This line retrieves the CatInfo struct for the specified tokenId from the s_catInfo mapping
        CatInfo memory catInfo = s_catInfo[tokenId];

        string memory catTokenUri = Base64.encode(
            abi.encodePacked( // concatenates the various pieces of data into a single bytes array
                '{"name": "', catInfo.catName, //  The name of the cat
                '", "breed": "', catInfo.breed, // The breed of the cat
                '", "image": "', catInfo.image, // The image URI of the cat
                '", "dob": ', Strings.toString(catInfo.dob), // The DOB of the cat, converted to a string
                ', "owner": "', Strings.toHexString(_ownerOf(tokenId)), // The address of the current owner of the token, converted to a hexadecimal string 
                '", "shopPartner": "', Strings.toHexString(catInfo.shopPartner), // The address of the shop partner, converted to a hexadecimal string.
                '"}'
            )
        );
        // returns the combination the base URI with the catTokenUri(Base64-encoded) metadata for a specific token
        return string.concat(_baseURI(), catTokenUri);
    }

   
    function getCatAge(uint256 tokenId) external view returns (uint256) {
        return block.timestamp - s_catInfo[tokenId].dob;
    }
    
    function getTokenCounter() external view returns (uint256) {
        return kittyTokenCounter;
    }

    function getKittyConnectOwner() external view returns (address) {
        return i_kittyConnectOwner;
    }

    function getAllKittyShops() external view returns (address[] memory) {
        return s_kittyShops;
    }

    function getKittyShopAtIdx(uint256 idx) external view returns (address) {
        return s_kittyShops[idx];
    }

    function getIsKittyPartnerShop(address partnerShop) external view returns (bool) {
        return s_isKittyShop[partnerShop];
    }

    function getCatInfo(uint256 tokenId) external view returns (CatInfo memory) {
        return s_catInfo[tokenId];
    }

    function getCatsTokenIdOwnedBy(address user) external view returns (uint256[] memory) {
        return s_ownerToCatsTokenId[user];
    }

    function getKittyBridge() external view returns (address) {
        return address(i_kittyBridge);
    }
}
