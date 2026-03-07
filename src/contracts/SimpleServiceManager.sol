// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";
import {IWavsServiceHandler} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceHandler.sol";

/**
 * @title SimpleServiceManager
 * @notice Minimal PoA service manager for local development and examples.
 *         Stores operator weights set by the owner; validates quorum by summing
 *         the weights of signers present in each submission.
 */
contract SimpleServiceManager is IWavsServiceManager {
    string private _serviceURI;

    mapping(address => uint256) private _operatorWeights;
    uint256 private _thresholdWeight;
    uint256 private _totalWeight;

    /// @inheritdoc IWavsServiceManager
    function validate(
        IWavsServiceHandler.Envelope calldata,
        IWavsServiceHandler.SignatureData calldata signatureData
    ) external view override {
        if (
            signatureData.signers.length == 0
                || signatureData.signers.length != signatureData.signatures.length
        ) {
            revert IWavsServiceManager.InvalidSignatureLength();
        }
        if (!(signatureData.referenceBlock < block.number)) {
            revert IWavsServiceManager.InvalidSignatureBlock();
        }
        if (!_isSorted(signatureData.signers)) {
            revert IWavsServiceManager.InvalidSignatureOrder();
        }

        uint256 signedWeight;
        for (uint256 i = 0; i < signatureData.signers.length; ++i) {
            signedWeight += _operatorWeights[signatureData.signers[i]];
        }

        if (signedWeight == 0) {
            revert IWavsServiceManager.InsufficientQuorumZero();
        }
        if (signedWeight < _thresholdWeight) {
            revert IWavsServiceManager.InsufficientQuorum(signedWeight, _thresholdWeight, _totalWeight);
        }
    }

    // -------------------------------------------------------------------------
    // Owner operations (permissionless for dev/examples)
    // -------------------------------------------------------------------------

    function setOperatorWeight(address operator, uint256 weight) external {
        _operatorWeights[operator] = weight;
    }

    function setThresholdWeight(uint256 weight) external {
        _thresholdWeight = weight;
    }

    function setTotalWeight(uint256 weight) external {
        _totalWeight = weight;
    }

    /// @inheritdoc IWavsServiceManager
    function setServiceURI(string calldata serviceURI) external override {
        _serviceURI = serviceURI;
        emit ServiceURIUpdated(serviceURI);
    }

    // -------------------------------------------------------------------------
    // View functions
    // -------------------------------------------------------------------------

    /// @inheritdoc IWavsServiceManager
    function getServiceURI() external view override returns (string memory) {
        return _serviceURI;
    }

    /// @inheritdoc IWavsServiceManager
    function getOperatorWeight(address operator) external view override returns (uint256) {
        return _operatorWeights[operator];
    }

    function getThresholdWeight() external view returns (uint256) {
        return _thresholdWeight;
    }

    function getTotalWeight() external view returns (uint256) {
        return _totalWeight;
    }

    /// @inheritdoc IWavsServiceManager
    function getLatestOperatorForSigningKey(address signingKey) external pure override returns (address) {
        return signingKey;
    }

    /// @inheritdoc IWavsServiceManager
    function getDelegationManager() external pure override returns (address) { return address(0); }

    /// @inheritdoc IWavsServiceManager
    function getAllocationManager() external pure override returns (address) { return address(0); }

    /// @inheritdoc IWavsServiceManager
    function getStakeRegistry() external pure override returns (address) { return address(0); }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _isSorted(address[] calldata addrs) internal pure returns (bool) {
        for (uint256 i = 1; i < addrs.length; ++i) {
            if (!(addrs[i] > addrs[i - 1])) return false;
        }
        return true;
    }
}
