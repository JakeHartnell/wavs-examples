// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";
import {IValidationTypes} from "interfaces/IValidationTypes.sol";

/// @title ValidationSubmit
/// @notice Receives signed WAVS validation results and stores them on-chain.
///         Decodes the payload as (bytes32 requestHash, uint8 response, string tag)
///         and records the result keyed by triggerId.
///
/// @dev This contract is the "submit" half of the ERC-8004 WAVS example.
///      It follows the same handleSignedEnvelope pattern as WavsSubmit but
///      stores richer validation data instead of a bare boolean.
contract ValidationSubmit is IValidationTypes, IWavsServiceHandler {
    /// @notice The WAVS service manager used to verify operator signatures
    IWavsServiceManager private _serviceManager;

    /// @notice Completed validation results keyed by trigger ID
    mapping(TriggerId => ValidationResult) public results;

    constructor(IWavsServiceManager serviceManager) {
        _serviceManager = serviceManager;
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

        // Decode the inner validation result: (requestHash, response, tag)
        (bytes32 requestHash, uint8 response, string memory tag) =
            abi.decode(dataWithId.data, (bytes32, uint8, string));

        // Store result
        results[dataWithId.triggerId] = ValidationResult({
            requestHash: requestHash,
            response: response,
            tag: tag,
            validator: msg.sender,
            timestamp: block.timestamp,
            exists: true
        });

        emit ValidationRecorded(
            dataWithId.triggerId,
            requestHash,
            response,
            tag,
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
