// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IACPHook} from "interfaces/agentic-commerce/IACPHook.sol";
import {IAgenticCommerce} from "interfaces/agentic-commerce/IAgenticCommerce.sol";

/// @notice Minimal ERC-8004 ReputationRegistry interface
interface IReputationRegistry {
    function giveFeedback(
        uint256 agentId,
        int128 value,
        uint8 valueDecimals,
        string calldata tag1,
        string calldata tag2,
        string calldata endpoint,
        string calldata feedbackURI,
        bytes32 feedbackHash
    ) external;
}

/// @title ReputationHook
/// @notice ERC-8183 hook that writes ERC-8004 reputation feedback after job completion.
///
/// @dev Wires the ACP job lifecycle into ERC-8004 reputation:
///      - Job completed → positive feedback for provider (score: 100)
///      - Job rejected  → negative feedback for provider (score: -100)
///
///      The ERC-8004 ReputationRegistry.giveFeedback() requires msg.sender NOT be
///      an authorized owner/operator of the agent (no self-feedback). Since this
///      hook is called from AgenticCommerce, msg.sender = AgenticCommerce address —
///      which should not be the agent owner, satisfying the constraint.
///
///      providerAgentId is stored per provider address in this hook.
///      The deploy script registers providers in the IdentityRegistry and stores
///      their agentIds here before any jobs are funded.
contract ReputationHook is IACPHook {
    // =========================================================================
    // Storage
    // =========================================================================

    IAgenticCommerce     private immutable _acp;
    IReputationRegistry  private immutable _reputationRegistry;

    /// @notice provider address → ERC-8004 agentId
    mapping(address => uint256) private _agentIds;

    address private immutable _owner;

    // =========================================================================
    // Events
    // =========================================================================

    event AgentIdRegistered(address indexed provider, uint256 agentId);

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(IAgenticCommerce acp_, IReputationRegistry reputationRegistry_) {
        require(address(acp_) != address(0), "Hook: zero acp");
        require(address(reputationRegistry_) != address(0), "Hook: zero registry");
        _acp = acp_;
        _reputationRegistry = reputationRegistry_;
        _owner = msg.sender;
    }

    // =========================================================================
    // Admin
    // =========================================================================

    /// @notice Register a provider's ERC-8004 agentId (call from deploy script)
    function registerAgent(address provider, uint256 agentId) external {
        require(msg.sender == _owner, "Hook: not owner");
        _agentIds[provider] = agentId;
        emit AgentIdRegistered(provider, agentId);
    }

    // =========================================================================
    // IACPHook
    // =========================================================================

    /// @dev Before hooks are no-ops for now
    function beforeAction(uint256, bytes4, bytes calldata) external pure override {}

    /// @notice After complete → positive feedback; after reject → negative feedback
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override {
        // Only react to complete and reject
        if (
            selector != IAgenticCommerce.complete.selector &&
            selector != IAgenticCommerce.reject.selector
        ) return;

        IAgenticCommerce.Job memory job = _acp.getJob(jobId);
        uint256 agentId = _agentIds[job.provider];

        // Skip if provider has no registered agentId
        if (agentId == 0) return;

        bool isComplete = selector == IAgenticCommerce.complete.selector;

        // Write reputation: +100 for complete, -100 for reject (both at 0 decimals)
        _reputationRegistry.giveFeedback(
            agentId,
            isComplete ? int128(100) : int128(-100),
            0,              // valueDecimals
            isComplete ? "acp:complete" : "acp:reject",  // tag1
            "wavs",         // tag2
            "",             // endpoint
            "",             // feedbackURI
            bytes32(0)      // feedbackHash
        );
    }

    // =========================================================================
    // View
    // =========================================================================

    function getAgentId(address provider) external view returns (uint256) {
        return _agentIds[provider];
    }
}
