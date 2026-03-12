// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SimpleTrigger} from "../src/contracts/WavsTrigger.sol";
import {SimpleSubmit} from "../src/contracts/WavsSubmit.sol";
import {SimpleServiceManager} from "../src/contracts/SimpleServiceManager.sol";

/**
 * @title Deploy
 * @notice Deploys the three PoA contracts needed for the echo-poa example.
 *
 *   SimpleTrigger     — users call addTrigger(string) to submit work
 *   SimpleServiceManager — validates operator signatures; stores service URI
 *   SimpleSubmit      — receives and stores signed WAVS output
 *
 * Usage (local Anvil):
 *   forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * The deployer private key is read from $PRIVATE_KEY (defaults to Anvil account 0).
 */
contract Deploy is Script {
    uint256 internal _privateKey =
        vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

    function run() external {
        vm.startBroadcast(_privateKey);

        // 1. Deploy service manager first (submit contract needs its address)
        SimpleServiceManager serviceManager = new SimpleServiceManager();

        // 2. Deploy trigger and submit contracts
        SimpleTrigger trigger = new SimpleTrigger();
        SimpleSubmit submit = new SimpleSubmit(serviceManager);

        // 3. Configure quorum: single operator, threshold = 1
        serviceManager.setThresholdWeight(1);
        serviceManager.setTotalWeight(100);

        vm.stopBroadcast();

        // Output addresses for scripts to capture
        console.log("TRIGGER_ADDR=%s", address(trigger));
        console.log("SERVICE_MANAGER_ADDR=%s", address(serviceManager));
        console.log("SUBMIT_ADDR=%s", address(submit));
    }
}
