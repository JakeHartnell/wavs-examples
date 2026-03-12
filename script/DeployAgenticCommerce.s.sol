// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {IWavsServiceManager} from "@wavs/src/eigenlayer/ecdsa/interfaces/IWavsServiceManager.sol";

import {MockERC20} from "contracts/agentic-commerce/MockERC20.sol";
import {AgenticCommerce} from "contracts/agentic-commerce/AgenticCommerce.sol";
import {AgenticCommerceEvaluator} from "contracts/agentic-commerce/AgenticCommerceEvaluator.sol";
import {AgenticCommerceWorker} from "contracts/agentic-commerce/AgenticCommerceWorker.sol";
import {ReputationHook} from "contracts/agentic-commerce/ReputationHook.sol";
import {IAgenticCommerce} from "interfaces/agentic-commerce/IAgenticCommerce.sol";

import {IdentityRegistry} from "contracts/erc8004/IdentityRegistry.sol";
import {ReputationRegistry} from "contracts/erc8004/ReputationRegistry.sol";
import {IReputationRegistry} from "contracts/agentic-commerce/ReputationHook.sol";

/// @notice Deploy all Agentic Commerce contracts for local Anvil testing.
///
/// Usage:
///   forge script script/DeployAgenticCommerce.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     -vvv
///
/// Environment variables:
///   SERVICE_MANAGER_ADDR  — WAVS service manager address (from wavs-examples deploy)
///   PROVIDER_ADDR         — Address of the provider/agent wallet
///
/// Outputs (written to stdout, captured by deploy script):
///   MOCK_TOKEN_ADDR, ACP_ADDR, ACE_ADDR, HOOK_ADDR,
///   IDENTITY_REGISTRY_ADDR, REPUTATION_REGISTRY_ADDR,
///   PROVIDER_AGENT_ID
contract DeployAgenticCommerce is Script {
    function run() external {
        address deployer = msg.sender;
        // Optional: separate SMs for worker and evaluator.
        // If not set, both default to SERVICE_MANAGER_ADDR.
        address serviceManager = vm.envAddress("SERVICE_MANAGER_ADDR");
        address workerSM   = vm.envOr("WORKER_SM_ADDR",   serviceManager);
        address evaluatorSM = vm.envOr("EVALUATOR_SM_ADDR", serviceManager);
        address provider = vm.envAddress("PROVIDER_ADDR");

        vm.startBroadcast();

        // ── 1. Payment token ──────────────────────────────────────────────
        MockERC20 token = new MockERC20("Test USDC", "tUSDC", 6);
        console.log("MOCK_TOKEN_ADDR=%s", address(token));

        // Mint to client (deployer) and provider
        token.mint(deployer, 10_000 * 1e6);
        token.mint(provider, 1_000 * 1e6);

        // ── 2. ERC-8004: IdentityRegistry ────────────────────────────────
        // Non-upgradeable version for local Anvil (same interface as the official
        // UUPS contracts deployed on Sepolia/mainnet).
        IdentityRegistry identityRegistry = new IdentityRegistry();
        console.log("IDENTITY_REGISTRY_ADDR=%s", address(identityRegistry));

        // ── 3. ERC-8004: ReputationRegistry ──────────────────────────────
        ReputationRegistry reputationRegistry = new ReputationRegistry(address(identityRegistry));
        console.log("REPUTATION_REGISTRY_ADDR=%s", address(reputationRegistry));

        // ── 4. AgenticCommerce ────────────────────────────────────────────
        AgenticCommerce acp = new AgenticCommerce(address(token));
        console.log("ACP_ADDR=%s", address(acp));

        // ── 5. AgenticCommerceEvaluator (WAVS submit handler) ────────────
        AgenticCommerceEvaluator ace = new AgenticCommerceEvaluator(
            IWavsServiceManager(evaluatorSM),
            IAgenticCommerce(address(acp))
        );
        console.log("ACE_ADDR=%s", address(ace));
        console.log("EVALUATOR_SM_ADDR=%s", evaluatorSM);

        // ── 5b. AgenticCommerceWorker (WAVS worker — autonomous provider) ─
        AgenticCommerceWorker acw = new AgenticCommerceWorker(
            IWavsServiceManager(workerSM),
            IAgenticCommerce(address(acp))
        );
        console.log("ACW_ADDR=%s", address(acw));
        console.log("WORKER_SM_ADDR=%s", workerSM);

        // ── 6. ReputationHook ─────────────────────────────────────────────
        ReputationHook hook = new ReputationHook(
            IAgenticCommerce(address(acp)),
            IReputationRegistry(address(reputationRegistry))
        );
        console.log("HOOK_ADDR=%s", address(hook));

        // ── 7. Register provider as ERC-8004 agent ────────────────────────
        // Provider must register themselves; for the demo we do it as deployer
        // by calling register() with their URI.
        vm.stopBroadcast();

        // Provider self-registers (simulated: broadcast as provider)
        // In the real demo script, we'd prank or use provider's private key.
        // For the deploy script, we just log that the provider needs to register.
        console.log("PROVIDER_ADDR=%s", provider);
        console.log("NOTE: Provider must call identityRegistry.register() to get an agentId");
        console.log("      Then call hook.registerAgent(provider, agentId) to link");
    }
}
