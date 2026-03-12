// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ValidationTrigger} from "contracts/ValidationTrigger.sol";
import {ValidationSubmit} from "contracts/ValidationSubmit.sol";
import {SimpleServiceManager} from "contracts/SimpleServiceManager.sol";


/// @title DeployErc8004
/// @notice Deploys the three contracts needed for the ERC-8004 WAVS validator example.
///
///   ValidationTrigger     — users call requestValidation(uri, hash) to submit work
///   SimpleServiceManager  — validates operator signatures; stores service URI
///   ValidationSubmit      — receives and stores signed WAVS validation results
///
/// Usage (local Anvil):
///   forge script script/DeployErc8004.s.sol --rpc-url http://localhost:8545 --broadcast
contract DeployErc8004 is Script {
    uint256 internal _privateKey =
        vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

    function run() external {
        vm.startBroadcast(_privateKey);

        // 1. Deploy service manager (submit needs its address)
        SimpleServiceManager serviceManager = new SimpleServiceManager();

        // 2. Deploy trigger and submit contracts
        ValidationTrigger trigger = new ValidationTrigger();
        // Submit contract needs trigger address to look up expected hashes
        ValidationSubmit submit = new ValidationSubmit(serviceManager, trigger);

        // 3. Configure quorum: single operator, threshold = 1
        serviceManager.setThresholdWeight(1);
        serviceManager.setTotalWeight(100);

        vm.stopBroadcast();

        // Output addresses for the deploy script to capture
        console.log("TRIGGER_ADDR=%s", address(trigger));
        console.log("SERVICE_MANAGER_ADDR=%s", address(serviceManager));
        console.log("SUBMIT_ADDR=%s", address(submit));
    }
}
