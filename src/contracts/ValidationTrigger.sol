// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IValidationTypes} from "interfaces/IValidationTypes.sol";

/// @title ValidationTrigger
/// @notice Accepts validation requests and emits WAVS-compatible NewTrigger events.
///         Anyone can request validation of a URI + hash commitment.
///         The WAVS validator component fetches the URI, verifies the hash, and
///         submits a signed score back on-chain via ValidationSubmit.
///
/// @dev This contract is the "trigger" half of the ERC-8004 WAVS example.
///      It follows the same NewTrigger pattern as WavsTrigger so the standard
///      WAVS trigger machinery picks it up without modification.
contract ValidationTrigger is IValidationTypes {
    /// @notice Auto-incrementing trigger ID counter
    TriggerId public nextTriggerId;

    /// @notice Stored validation requests by trigger ID
    mapping(TriggerId => ValidationRequest) public requests;

    /// @notice All trigger IDs submitted by a given address
    mapping(address => TriggerId[]) internal _requestsByAddress;

    /// @notice Submit a validation request.
    /// @param requestURI  URI pointing to the off-chain content to validate
    /// @param requestHash keccak256 hash of the content at requestURI
    /// @return triggerId  The assigned trigger ID for this request
    function requestValidation(
        string calldata requestURI,
        bytes32 requestHash
    ) external returns (TriggerId triggerId) {
        // Increment and assign trigger ID
        nextTriggerId = TriggerId.wrap(TriggerId.unwrap(nextTriggerId) + 1);
        triggerId = nextTriggerId;

        // Store request
        requests[triggerId] = ValidationRequest({
            requester: msg.sender,
            requestURI: requestURI,
            requestHash: requestHash,
            exists: true
        });
        _requestsByAddress[msg.sender].push(triggerId);

        // Encode as TriggerInfo so WAVS picks it up with standard machinery
        TriggerInfo memory triggerInfo = TriggerInfo({
            triggerId: triggerId,
            creator: msg.sender,
            // data = ABI-encoded (requestURI, requestHash)
            data: abi.encode(requestURI, requestHash)
        });

        emit NewTrigger(abi.encode(triggerInfo));
        emit ValidationRequested(triggerId, msg.sender, requestURI, requestHash);
    }

    /// @notice Returns all trigger IDs submitted by an address
    function requestsByAddress(address addr) external view returns (TriggerId[] memory) {
        return _requestsByAddress[addr];
    }
}
