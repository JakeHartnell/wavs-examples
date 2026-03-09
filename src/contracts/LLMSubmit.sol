// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";
import {ITypes} from "interfaces/ITypes.sol";

/// @title LLMSubmit - Receives and stores verified LLM inference results from WAVS
/// @notice Part of the llm-oracle example demonstrating verifiable AI inference
contract LLMSubmit is ITypes, IWavsServiceHandler {
    struct LLMResult {
        uint64 triggerId;
        string response;
        bytes32 responseHash;
    }

    mapping(TriggerId => string) public responses;
    mapping(TriggerId => bytes32) public responseHashes;
    mapping(TriggerId => bool) public isComplete;

    IWavsServiceManager private _serviceManager;

    event LLMResponseReceived(TriggerId indexed triggerId, string response, bytes32 responseHash);

    constructor(IWavsServiceManager serviceManager) {
        _serviceManager = serviceManager;
    }

    function handleSignedEnvelope(Envelope calldata envelope, SignatureData calldata signatureData) external {
        _serviceManager.validate(envelope, signatureData);
        LLMResult memory result = abi.decode(envelope.payload, (LLMResult));
        TriggerId tid = TriggerId.wrap(result.triggerId);
        responses[tid] = result.response;
        responseHashes[tid] = result.responseHash;
        isComplete[tid] = true;
        emit LLMResponseReceived(tid, result.response, result.responseHash);
    }

    function getResponse(TriggerId triggerId) external view returns (string memory response, bytes32 hash) {
        return (responses[triggerId], responseHashes[triggerId]);
    }

    function getServiceManager() external view returns (address) {
        return address(_serviceManager);
    }
}
