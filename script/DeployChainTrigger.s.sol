// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SimpleServiceManager} from "../src/contracts/SimpleServiceManager.sol";

/**
 * @title DeployChainTrigger
 * @notice Deploys two SimpleServiceManager contracts for the chain-trigger test.
 *
 * chain-responder and chain-caller each need their own service manager so the
 * WAVS node can independently track each service.  No trigger or submit contracts
 * are needed — both services use submit:none (no on-chain result submission).
 *
 * Usage:
 *   forge script script/DeployChainTrigger.s.sol \
 *     --rpc-url http://localhost:8545 --broadcast
 */
contract DeployChainTrigger is Script {
    uint256 internal _privateKey =
        vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

    function run() external {
        vm.startBroadcast(_privateKey);

        // Service manager for chain-responder (the callee)
        SimpleServiceManager responderSM = new SimpleServiceManager();
        responderSM.setThresholdWeight(1);
        responderSM.setTotalWeight(100);

        // Service manager for chain-caller (the orchestrator)
        SimpleServiceManager callerSM = new SimpleServiceManager();
        callerSM.setThresholdWeight(1);
        callerSM.setTotalWeight(100);

        vm.stopBroadcast();

        console.log("RESPONDER_SM_ADDR=%s", address(responderSM));
        console.log("CALLER_SM_ADDR=%s", address(callerSM));
    }
}
