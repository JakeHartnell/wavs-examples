// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title IdentityRegistry
/// @notice Non-upgradeable ERC-8004 Identity Registry for local Anvil testing.
///         Mirrors the interface of the official IdentityRegistryUpgradeable
///         deployed on mainnet/Sepolia, without the UUPS/proxy complexity.
///
/// @dev The official deployments use UUPS proxies + reinitializer(2). For local
///      Anvil iteration we use a plain ERC721 that anyone can mint from.
///
///      On-chain identity: each agent is an ERC-721 NFT.
///      agentId = tokenId (0-indexed, incremented on each register())
///
///      Compatible addresses (Sepolia):
///        Identity:    0x8004A818BFB912233c491871b3d84c89A494BD9e
///        Reputation:  0x8004B663056A597Dffe9eCcC1965A193B7388713
contract IdentityRegistry is ERC721URIStorage, Ownable {
    // =========================================================================
    // Events (matching official contract)
    // =========================================================================

    event Registered(uint256 indexed agentId, string agentURI, address indexed owner);
    event URIUpdated(uint256 indexed agentId, string newURI, address indexed updatedBy);

    // =========================================================================
    // Storage
    // =========================================================================

    uint256 private _lastId;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor() ERC721("AgentIdentity", "AGENT") Ownable(msg.sender) {}

    // =========================================================================
    // Registration
    // =========================================================================

    /// @notice Register a new agent (mints NFT to caller)
    function register() external returns (uint256 agentId) {
        agentId = _lastId++;
        _safeMint(msg.sender, agentId);
        emit Registered(agentId, "", msg.sender);
    }

    /// @notice Register with a metadata URI
    function register(string memory agentURI) external returns (uint256 agentId) {
        agentId = _lastId++;
        _safeMint(msg.sender, agentId);
        _setTokenURI(agentId, agentURI);
        emit Registered(agentId, agentURI, msg.sender);
    }

    // =========================================================================
    // Compatibility helpers
    // =========================================================================

    /// @notice Mirrors the official contract's authorization check
    function isAuthorizedOrOwner(address spender, uint256 agentId)
        external view returns (bool)
    {
        address owner = ownerOf(agentId);
        return spender == owner
            || isApprovedForAll(owner, spender)
            || getApproved(agentId) == spender;
    }

    function getLastId() external view returns (uint256) {
        return _lastId;
    }
}
