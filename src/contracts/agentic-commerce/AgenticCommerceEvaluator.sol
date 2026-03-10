// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";
import {IAgenticCommerce} from "interfaces/agentic-commerce/IAgenticCommerce.sol";

/// @title AgenticCommerceEvaluator
/// @notice WAVS submit handler that acts as the ERC-8183 evaluator.
///
/// @dev The WAVS aggregator collects operator signatures and calls
///      handleSignedEnvelope() on this contract. This contract is set as
///      job.evaluator when creating jobs, so it has authority to call
///      acp.complete() and acp.reject().
///
///      Payload format (ABI-encoded):
///        (uint256 jobId, bool isComplete, bytes32 attestation)
///
///      attestation = the evaluator's computed hash:
///        - on complete: keccak256(fetched_url_content) — matches deliverable
///        - on reject:   keccak256(fetched_url_content) — does NOT match
contract AgenticCommerceEvaluator is IWavsServiceHandler {
    // =========================================================================
    // Errors
    // =========================================================================

    error InvalidPayload();
    error InvalidJob();

    // =========================================================================
    // Events
    // =========================================================================

    event EvaluationSubmitted(
        uint256 indexed jobId,
        bool isComplete,
        bytes32 attestation
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
        require(address(serviceManager_) != address(0), "ACE: zero service manager");
        require(address(acp_) != address(0), "ACE: zero acp");
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

        // Decode the component's verdict
        (uint256 jobId, bool isComplete, bytes32 attestation) =
            abi.decode(envelope.payload, (uint256, bool, bytes32));

        if (jobId == 0) revert InvalidJob();

        emit EvaluationSubmitted(jobId, isComplete, attestation);

        if (isComplete) {
            _acp.complete(jobId, attestation);
        } else {
            _acp.reject(jobId, attestation);
        }
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
