// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ITypes} from "interfaces/ITypes.sol";

/// @notice Types for the ERC-8004 Validation example
interface IValidationTypes is ITypes {
    /// @notice A pending validation request
    struct ValidationRequest {
        address requester;
        string requestURI;
        bytes32 requestHash;
        bool exists;
    }

    /// @notice The result of a completed validation
    struct ValidationResult {
        bytes32 requestHash;
        uint8 response;   // 0 = fail, 100 = pass, intermediates allowed
        string tag;
        address validator;
        uint256 timestamp;
        bool exists;
    }

    /// @notice Emitted when a user submits a validation request (WAVS trigger)
    event ValidationRequested(
        TriggerId indexed triggerId,
        address indexed requester,
        string requestURI,
        bytes32 requestHash
    );

    /// @notice Emitted when a validation result is recorded by the WAVS submit contract
    event ValidationRecorded(
        TriggerId indexed triggerId,
        bytes32 indexed requestHash,
        uint8 response,
        string tag,
        address validator
    );
}
