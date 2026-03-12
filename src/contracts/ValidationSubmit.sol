// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";
import {IValidationTypes} from "interfaces/IValidationTypes.sol";
import {ValidationTrigger} from "contracts/ValidationTrigger.sol";

/// @title ValidationSubmit
/// @notice Receives signed WAVS validation results and stores them on-chain.
///
///         The WAVS component fetches the content at requestURI and returns the
///         computed keccak256 hash. This contract compares that hash against the
///         expectedHash stored in the trigger contract and records pass/fail.
///
/// @dev On-chain comparison makes the logic transparent and auditable:
///         response = 100 → computed hash matches expected hash (content integrity verified)
///         response = 0   → hashes differ (content changed since request was made)
contract ValidationSubmit is IValidationTypes, IWavsServiceHandler {
    /// @notice The WAVS service manager used to verify operator signatures
    IWavsServiceManager private _serviceManager;

    /// @notice The trigger contract (used to look up the expected hash for each request)
    ValidationTrigger private _trigger;

    /// @notice Completed validation results keyed by trigger ID
    mapping(TriggerId => ValidationResult) public results;

    constructor(IWavsServiceManager serviceManager, ValidationTrigger trigger) {
        _serviceManager = serviceManager;
        _trigger = trigger;
    }

    /// @inheritdoc IWavsServiceHandler
    function handleSignedEnvelope(
        Envelope calldata envelope,
        SignatureData calldata signatureData
    ) external {
        // Verify the quorum signature
        _serviceManager.validate(envelope, signatureData);

        // Decode the outer DataWithId wrapper
        DataWithId memory dataWithId = abi.decode(envelope.payload, (DataWithId));

        // Decode the inner payload: just the computed hash from the WAVS component
        bytes32 computedHash = abi.decode(dataWithId.data, (bytes32));

        // Look up the expected hash from the trigger contract
        ValidationRequest memory req = _trigger.getRequest(dataWithId.triggerId);
        require(req.exists, "ValidationSubmit: unknown trigger ID");

        // Compare on-chain: 100 = pass, 0 = fail
        uint8 response = (computedHash == req.requestHash) ? 100 : 0;

        // Store result
        results[dataWithId.triggerId] = ValidationResult({
            requestHash: req.requestHash,
            response: response,
            tag: response == 100 ? "hash-integrity:pass" : "hash-integrity:fail",
            validator: msg.sender,
            timestamp: block.timestamp,
            exists: true
        });

        emit ValidationRecorded(
            dataWithId.triggerId,
            req.requestHash,
            response,
            response == 100 ? "hash-integrity:pass" : "hash-integrity:fail",
            msg.sender
        );
    }

    /// @notice Returns true if a validation result has been recorded for the trigger ID
    function isComplete(TriggerId triggerId) external view returns (bool) {
        return results[triggerId].exists;
    }

    /// @notice Returns the validation result for a trigger ID
    function getResult(TriggerId triggerId) external view returns (ValidationResult memory) {
        return results[triggerId];
    }

    /// @notice Returns the service manager address
    function getServiceManager() external view returns (address) {
        return address(_serviceManager);
    }
}
