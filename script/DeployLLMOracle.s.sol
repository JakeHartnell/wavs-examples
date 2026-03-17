// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SimpleTrigger} from "../src/contracts/WavsTrigger.sol";
import {AgentSubmit} from "../src/contracts/AgentSubmit.sol";
import {SimpleServiceManager} from "../src/contracts/SimpleServiceManager.sol";

/**
 * @title DeployLLMOracle
 * @notice Deploys the contracts needed for the llm-agent example.
 *
 *   SimpleTrigger        — users call addTrigger(string) to submit a prompt
 *   SimpleServiceManager — validates operator signatures; stores service URI
 *   AgentSubmit          — receives verified agent results with on-chain tool call audit trail
 *
 * Usage (local Anvil):
 *   forge script script/DeployLLMOracle.s.sol --rpc-url http://localhost:8545 --broadcast
 *
 * The deployer private key is read from $PRIVATE_KEY (defaults to Anvil account 0).
 */
contract DeployLLMOracle is Script {
    uint256 internal _privateKey =
        vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

    function run() external {
        vm.startBroadcast(_privateKey);

        // 1. Deploy service manager first (submit contract needs its address)
        SimpleServiceManager serviceManager = new SimpleServiceManager();

        // 2. Deploy trigger and agent submit contracts
        SimpleTrigger trigger = new SimpleTrigger();
        AgentSubmit agentSubmit = new AgentSubmit(serviceManager);

        // 3. Configure quorum: single operator, threshold = 1
        serviceManager.setThresholdWeight(1);
        serviceManager.setTotalWeight(100);

        vm.stopBroadcast();

        // Output addresses for scripts to capture
        console.log("TRIGGER_ADDR=%s", address(trigger));
        console.log("SERVICE_MANAGER_ADDR=%s", address(serviceManager));
        console.log("AGENT_SUBMIT_ADDR=%s", address(agentSubmit));
    }
}
