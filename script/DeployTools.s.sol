// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Script, console} from "forge-std/Script.sol";
import {SimpleTrigger} from "../src/contracts/WavsTrigger.sol";
import {SimpleSubmit} from "../src/contracts/WavsSubmit.sol";
import {SimpleServiceManager} from "../src/contracts/SimpleServiceManager.sol";

/**
 * @title DeployTools
 * @notice Deploys shared contracts for weather-oracle and crypto-price tool services.
 *
 * One service manager is shared by both workflows (one signing key, one operator registration).
 * Each tool gets its own trigger + SimpleSubmit contract.
 *
 * Usage:
 *   forge script script/DeployTools.s.sol --rpc-url http://localhost:8545 --broadcast
 */
contract DeployTools is Script {
    uint256 internal _privateKey =
        vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));

    function run() external {
        vm.startBroadcast(_privateKey);

        // One service manager shared by both tool workflows
        SimpleServiceManager sm = new SimpleServiceManager();
        sm.setThresholdWeight(1);
        sm.setTotalWeight(100);

        // weather workflow
        SimpleTrigger weatherTrigger = new SimpleTrigger();
        SimpleSubmit weatherSubmit = new SimpleSubmit(sm);

        // crypto_price workflow
        SimpleTrigger cryptoTrigger = new SimpleTrigger();
        SimpleSubmit cryptoSubmit = new SimpleSubmit(sm);

        vm.stopBroadcast();

        console.log("TOOLS_SM_ADDR=%s", address(sm));
        console.log("WEATHER_TRIGGER_ADDR=%s", address(weatherTrigger));
        console.log("WEATHER_SUBMIT_ADDR=%s", address(weatherSubmit));
        console.log("CRYPTO_TRIGGER_ADDR=%s", address(cryptoTrigger));
        console.log("CRYPTO_SUBMIT_ADDR=%s", address(cryptoSubmit));
    }
}
