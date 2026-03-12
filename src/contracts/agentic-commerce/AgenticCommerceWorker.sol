// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";
import {IAgenticCommerce} from "interfaces/agentic-commerce/IAgenticCommerce.sol";

/// @title AgenticCommerceWorker
/// @notice WAVS submit handler that acts as the ERC-8183 provider/worker.
///
/// @dev The WAVS aggregator collects operator signatures and calls
///      handleSignedEnvelope() on this contract. This contract is set as
///      job.provider when creating jobs, so it has authority to call
///      acp.submitWithResult().
///
///      Payload format (ABI-encoded):
///        (uint256 jobId, bytes32 deliverable, string resultUri)
///
///      deliverable = keccak256(llm_output)
///      resultUri   = URL where the LLM output can be fetched (e.g. paste.rs)
contract AgenticCommerceWorker is IWavsServiceHandler {
    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidPayload();
    error InvalidJob();

    // =========================================================================
    // Events
    // =========================================================================

    event WorkerSubmitted(
        uint256 indexed jobId,
        bytes32 deliverable,
        string  resultUri
    );

    // =========================================================================
    // Storage
    // =========================================================================

    IWavsServiceManager private immutable _serviceManager;
    IAgenticCommerce    private immutable _acp;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(IWavsServiceManager serviceManager_, IAgenticCommerce acp_) {
        require(address(serviceManager_) != address(0), "ACW: zero service manager");
        require(address(acp_) != address(0), "ACW: zero acp");
        _serviceManager = serviceManager_;
        _acp = acp_;
    }

    // =========================================================================
    // IWavsServiceHandler
    // =========================================================================

    /// @inheritdoc IWavsServiceHandler
    function handleSignedEnvelope(
        IWavsServiceHandler.Envelope calldata envelope,
        IWavsServiceHandler.SignatureData calldata signatureData
    ) external {
        // Verify quorum of operator signatures
        _serviceManager.validate(envelope, signatureData);

        // Decode the worker's result.
        // Using only fixed-size types (uint256, bytes32) to avoid ABI edge cases
        // with dynamic string encoding across WASM/EVM boundaries.
        // resultUri is logged via WorkerSubmitted event but not passed on-chain.
        (uint256 jobId, bytes32 deliverable) =
            abi.decode(envelope.payload, (uint256, bytes32));

        if (jobId == 0) revert InvalidJob();

        emit WorkerSubmitted(jobId, deliverable, "");

        _acp.submit(jobId, deliverable);
    }

    // =========================================================================
    // View
    // =========================================================================

    function getServiceManager() external view returns (address) {
        return address(_serviceManager);
    }

    function getACP() external view returns (address) {
        return address(_acp);
    }
}
