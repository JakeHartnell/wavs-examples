// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IdentityRegistry} from "contracts/erc8004/IdentityRegistry.sol";

/// @title ReputationRegistry
/// @notice Non-upgradeable ERC-8004 Reputation Registry for local Anvil testing.
///         Mirrors the interface of the official ReputationRegistryUpgradeable.
///
/// @dev giveFeedback() prevents self-feedback (same constraint as official contract).
///      getSummary() returns arithmetic average of all feedback for an agent.
contract ReputationRegistry is Ownable {
    // =========================================================================
    // Events (matching official contract)
    // =========================================================================

    event NewFeedback(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64  feedbackIndex,
        int128  value,
        uint8   valueDecimals,
        string  indexed indexedTag1,
        string  tag1,
        string  tag2,
        string  endpoint,
        string  feedbackURI,
        bytes32 feedbackHash
    );

    event FeedbackRevoked(
        uint256 indexed agentId,
        address indexed clientAddress,
        uint64  indexed feedbackIndex
    );

    // =========================================================================
    // Structs
    // =========================================================================

    struct Feedback {
        int128  value;
        uint8   valueDecimals;
        bool    isRevoked;
        string  tag1;
        string  tag2;
    }

    // =========================================================================
    // Storage
    // =========================================================================

    IdentityRegistry private immutable _identityRegistry;

    // agentId → clientAddress → feedbackIndex → Feedback (1-indexed)
    mapping(uint256 => mapping(address => mapping(uint64 => Feedback))) private _feedback;
    // agentId → clientAddress → lastIndex
    mapping(uint256 => mapping(address => uint64)) private _lastIndex;
    // track all clients per agent
    mapping(uint256 => address[]) private _clients;
    mapping(uint256 => mapping(address => bool)) private _clientExists;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address identityRegistry_) Ownable(msg.sender) {
        require(identityRegistry_ != address(0), "Rep: zero identity registry");
        _identityRegistry = IdentityRegistry(identityRegistry_);
    }

    // =========================================================================
    // Feedback
    // =========================================================================

    /// @notice Give feedback for an agent
    /// @dev Mirrors official contract: prevents self-feedback
    function giveFeedback(
        uint256 agentId,
        int128  value,
        uint8   valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external {
        require(valueDecimals <= 18, "Rep: too many decimals");
        require(!_identityRegistry.isAuthorizedOrOwner(msg.sender, agentId), "Rep: self-feedback");

        uint64 currentIndex = ++_lastIndex[agentId][msg.sender];

        _feedback[agentId][msg.sender][currentIndex] = Feedback({
            value:        value,
            valueDecimals: valueDecimals,
            tag1:         tag1,
            tag2:         tag2,
            isRevoked:    false
        });

        if (!_clientExists[agentId][msg.sender]) {
            _clients[agentId].push(msg.sender);
            _clientExists[agentId][msg.sender] = true;
        }

        emit NewFeedback(
            agentId, msg.sender, currentIndex,
            value, valueDecimals,
            tag1, tag1, tag2,
            endpoint, feedbackURI, feedbackHash
        );
    }

    /// @notice Revoke your own feedback
    function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external {
        require(_lastIndex[agentId][msg.sender] >= feedbackIndex, "Rep: no such feedback");
        _feedback[agentId][msg.sender][feedbackIndex].isRevoked = true;
        emit FeedbackRevoked(agentId, msg.sender, feedbackIndex);
    }

    // =========================================================================
    // View
    // =========================================================================

    function getLastIndex(uint256 agentId, address clientAddress)
        external view returns (uint64)
    {
        return _lastIndex[agentId][clientAddress];
    }

    function readFeedback(uint256 agentId, address clientAddress, uint64 feedbackIndex)
        external view returns (Feedback memory)
    {
        return _feedback[agentId][clientAddress][feedbackIndex];
    }

    function getClients(uint256 agentId) external view returns (address[] memory) {
        return _clients[agentId];
    }

    /// @notice Simple count + sum of non-revoked feedback
    function getSummary(
        uint256 agentId,
        address[] calldata,
        string calldata,
        string calldata
    ) external view returns (uint64 count, int128 summaryValue, uint8 summaryValueDecimals) {
        address[] memory clients = _clients[agentId];
        for (uint256 i; i < clients.length; ++i) {
            uint64 last = _lastIndex[agentId][clients[i]];
            for (uint64 j = 1; j <= last; ++j) {
                Feedback storage fb = _feedback[agentId][clients[i]][j];
                if (!fb.isRevoked) {
                    count++;
                    summaryValue += fb.value;
                }
            }
        }
        summaryValueDecimals = 0;
    }

    function getIdentityRegistry() external view returns (address) {
        return address(_identityRegistry);
    }
}
