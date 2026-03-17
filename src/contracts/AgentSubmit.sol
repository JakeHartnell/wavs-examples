// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";
import {ITypes} from "interfaces/ITypes.sol";

/// @title AgentSubmit - Receives and stores verified LLM agent results with on-chain tool call audit trail
/// @notice Part of the llm-agent example demonstrating the Verifiable Agent Tool Protocol (VATP).
///         Every tool call made by the agent (argsHash + resultHash) is recorded immutably on-chain.
contract AgentSubmit is ITypes, IWavsServiceHandler {
    struct ToolCall {
        string toolName;
        bytes32 argsHash;
        bytes32 resultHash;
    }

    /// @dev Must match the ABI layout of `LLMResult` in the Rust component (lib.rs sol! block).
    struct LLMResult {
        uint64 triggerId;
        string response;
        bytes32 responseHash;
        ToolCall[] toolCalls;
    }

    mapping(TriggerId => string) public responses;
    mapping(TriggerId => bytes32) public responseHashes;
    mapping(TriggerId => bool) public isComplete;
    mapping(TriggerId => ToolCall[]) private _toolCalls;

    IWavsServiceManager private _serviceManager;

    event AgentResponseReceived(
        TriggerId indexed triggerId,
        string response,
        bytes32 responseHash,
        uint256 toolCallCount
    );

    constructor(IWavsServiceManager serviceManager) {
        _serviceManager = serviceManager;
    }

    function handleSignedEnvelope(Envelope calldata envelope, SignatureData calldata signatureData) external {
        _serviceManager.validate(envelope, signatureData);
        DataWithId memory dataWithId = abi.decode(envelope.payload, (DataWithId));
        LLMResult memory result = abi.decode(dataWithId.data, (LLMResult));
        TriggerId tid = TriggerId.wrap(result.triggerId);

        responses[tid] = result.response;
        responseHashes[tid] = result.responseHash;
        isComplete[tid] = true;

        for (uint256 i = 0; i < result.toolCalls.length; i++) {
            _toolCalls[tid].push(result.toolCalls[i]);
        }

        emit AgentResponseReceived(tid, result.response, result.responseHash, result.toolCalls.length);
    }

    function getResponse(TriggerId triggerId) external view returns (string memory response, bytes32 hash) {
        return (responses[triggerId], responseHashes[triggerId]);
    }

    /// @notice Returns the cryptographic audit trail for all tool calls made during agent execution.
    /// @dev argsHash = keccak256(JSON args), resultHash = keccak256(JSON result)
    function getToolCalls(TriggerId triggerId) external view returns (ToolCall[] memory) {
        return _toolCalls[triggerId];
    }

    function getServiceManager() external view returns (address) {
        return address(_serviceManager);
    }
}
