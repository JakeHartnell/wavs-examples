// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {AgenticCommerce} from "contracts/agentic-commerce/AgenticCommerce.sol";
import {MockERC20} from "contracts/agentic-commerce/MockERC20.sol";
import {IAgenticCommerce} from "interfaces/agentic-commerce/IAgenticCommerce.sol";

/// @notice Unit tests for the ERC-8183 AgenticCommerce state machine.
contract AgenticCommerceTest is Test {
    AgenticCommerce acp;
    MockERC20       token;

    address client    = address(0xC1);
    address provider  = address(0xBE);
    address evaluator = address(0xE0);   // simulates WAVS aggregator / ACE

    uint256 BUDGET = 100e6; // 100 tUSDC

    function setUp() public {
        token = new MockERC20("Test USDC", "tUSDC", 6);
        acp   = new AgenticCommerce(address(token));

        token.mint(client, 1_000e6);
        vm.prank(client);
        token.approve(address(acp), type(uint256).max);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    function _createAndFund() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = acp.createJob(provider, evaluator, 0, "https://httpbin.org/json", address(0));
        vm.prank(client);
        acp.setBudget(jobId, BUDGET);
        vm.prank(client);
        acp.fund(jobId, BUDGET);
    }

    // ─── Happy path ──────────────────────────────────────────────────────────

    function test_createJob() public {
        vm.prank(client);
        uint256 jobId = acp.createJob(provider, evaluator, 0, "https://httpbin.org/json", address(0));
        assertEq(jobId, 1);
        IAgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(job.client, client);
        assertEq(job.provider, provider);
        assertEq(job.evaluator, evaluator);
        assertEq(uint8(job.status), uint8(IAgenticCommerce.JobStatus.Open));
    }

    function test_fullHappyPath() public {
        uint256 jobId = _createAndFund();
        IAgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgenticCommerce.JobStatus.Funded));
        assertEq(token.balanceOf(address(acp)), BUDGET, "escrow");

        // Provider submits deliverable
        bytes32 deliverable = keccak256("response body");
        vm.prank(provider);
        acp.submit(jobId, deliverable);
        job = acp.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgenticCommerce.JobStatus.Submitted));

        uint256 balBefore = token.balanceOf(provider);

        // WAVS evaluator (ACE contract) calls complete
        vm.prank(evaluator);
        acp.complete(jobId, deliverable);
        job = acp.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgenticCommerce.JobStatus.Completed));
        assertEq(token.balanceOf(provider), balBefore + BUDGET, "provider paid");
        assertEq(token.balanceOf(address(acp)), 0, "escrow empty");
    }

    function test_evaluatorReject() public {
        uint256 jobId = _createAndFund();

        vm.prank(provider);
        acp.submit(jobId, keccak256("wrong hash"));

        uint256 clientBalBefore = token.balanceOf(client);

        vm.prank(evaluator);
        acp.reject(jobId, bytes32("hash mismatch"));

        IAgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint8(job.status), uint8(IAgenticCommerce.JobStatus.Rejected));
        assertEq(token.balanceOf(client), clientBalBefore + BUDGET, "client refunded");
    }

    function test_expiry() public {
        vm.prank(client);
        uint256 jobId = acp.createJob(provider, evaluator, uint64(block.timestamp + 100), "url", address(0));
        vm.prank(client);
        acp.setBudget(jobId, BUDGET);
        vm.prank(client);
        acp.fund(jobId, BUDGET);

        vm.warp(block.timestamp + 101);

        uint256 clientBalBefore = token.balanceOf(client);
        acp.claimRefund(jobId); // anyone can call
        assertEq(token.balanceOf(client), clientBalBefore + BUDGET, "expired refund");
        assertEq(uint8(acp.getJob(jobId).status), uint8(IAgenticCommerce.JobStatus.Expired));
    }

    // ─── Access control ───────────────────────────────────────────────────────

    function test_onlyEvaluatorCanComplete() public {
        uint256 jobId = _createAndFund();
        vm.prank(provider);
        acp.submit(jobId, bytes32(0));

        vm.expectRevert("ACP: not evaluator");
        vm.prank(client);
        acp.complete(jobId, bytes32(0));
    }

    function test_onlyProviderCanSubmit() public {
        uint256 jobId = _createAndFund();
        vm.expectRevert("ACP: not provider");
        vm.prank(client);
        acp.submit(jobId, bytes32(0));
    }

    function test_budgetMismatchReverts() public {
        vm.prank(client);
        uint256 jobId = acp.createJob(provider, evaluator, 0, "url", address(0));
        vm.prank(client);
        acp.setBudget(jobId, BUDGET);
        vm.expectRevert("ACP: budget mismatch");
        vm.prank(client);
        acp.fund(jobId, BUDGET + 1);
    }

    function test_wrongStatusReverts() public {
        vm.prank(client);
        uint256 jobId = acp.createJob(provider, evaluator, 0, "url", address(0));
        vm.prank(client);
        acp.setBudget(jobId, BUDGET);

        // Can't submit before funded
        vm.expectRevert("ACP: wrong status");
        vm.prank(provider);
        acp.submit(jobId, bytes32(0));
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    function test_jobSubmittedEvent() public {
        uint256 jobId = _createAndFund();
        bytes32 deliverable = keccak256("content");

        vm.expectEmit(true, true, false, true);
        emit IAgenticCommerce.JobSubmitted(jobId, provider, deliverable);
        vm.prank(provider);
        acp.submit(jobId, deliverable);
    }

    function test_jobCompletedEvent() public {
        uint256 jobId = _createAndFund();
        bytes32 attestation = keccak256("verified");
        vm.prank(provider);
        acp.submit(jobId, attestation);

        vm.expectEmit(true, true, false, true);
        emit IAgenticCommerce.JobCompleted(jobId, evaluator, attestation);
        vm.prank(evaluator);
        acp.complete(jobId, attestation);
    }
}
