// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAgenticCommerce} from "interfaces/agentic-commerce/IAgenticCommerce.sol";
import {IACPHook} from "interfaces/agentic-commerce/IACPHook.sol";

/// @title AgenticCommerce
/// @notice ERC-8183 Agentic Commerce Protocol implementation.
///         A job escrow market where a trusted evaluator (WAVS) settles disputes
///         between clients and provider agents.
///
/// @dev State machine per job:
///         Open → Funded → Submitted → {Completed, Rejected}
///                  ↓          ↓
///               Rejected   Expired (timeout — anyone can trigger)
///
///      The evaluator is the ONLY entity that can call complete() or reject()
///      once a job is in Submitted state. For this demo, evaluator = WAVS
///      aggregator's AgenticCommerceEvaluator contract.
contract AgenticCommerce is IAgenticCommerce {
    using SafeERC20 for IERC20;

    // =========================================================================
    // Storage
    // =========================================================================

    IERC20 private immutable _paymentToken;

    uint256 private _jobCount;

    mapping(uint256 => Job) private _jobs;

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(address paymentToken_) {
        require(paymentToken_ != address(0), "ACP: zero token address");
        _paymentToken = IERC20(paymentToken_);
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyClient(uint256 jobId) {
        require(msg.sender == _jobs[jobId].client, "ACP: not client");
        _;
    }

    modifier onlyProvider(uint256 jobId) {
        require(msg.sender == _jobs[jobId].provider, "ACP: not provider");
        _;
    }

    modifier inStatus(uint256 jobId, JobStatus expected) {
        require(_jobs[jobId].status == expected, "ACP: wrong status");
        _;
    }

    // =========================================================================
    // Job lifecycle
    // =========================================================================

    /// @inheritdoc IAgenticCommerce
    function createJob(
        address provider,
        address evaluator,
        uint64 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256 jobId) {
        require(evaluator != address(0), "ACP: zero evaluator");

        jobId = ++_jobCount;

        _jobs[jobId] = Job({
            client:      msg.sender,
            provider:    provider,
            evaluator:   evaluator,
            hook:        hook,
            description: description,
            budget:      0,
            expiredAt:   expiredAt,
            status:      JobStatus.Open
        });

        emit JobCreated(jobId, msg.sender, provider, evaluator, description, expiredAt);
    }

    /// @inheritdoc IAgenticCommerce
    function setProvider(uint256 jobId, address provider)
        external
        onlyClient(jobId)
        inStatus(jobId, JobStatus.Open)
    {
        _jobs[jobId].provider = provider;
    }

    /// @inheritdoc IAgenticCommerce
    function setBudget(uint256 jobId, uint256 amount)
        external
        inStatus(jobId, JobStatus.Open)
    {
        Job storage job = _jobs[jobId];
        require(
            msg.sender == job.client || msg.sender == job.provider,
            "ACP: not client or provider"
        );
        job.budget = amount;
        emit BudgetSet(jobId, amount);
    }

    /// @inheritdoc IAgenticCommerce
    function fund(uint256 jobId, uint256 expectedBudget)
        external
        onlyClient(jobId)
        inStatus(jobId, JobStatus.Open)
    {
        Job storage job = _jobs[jobId];
        require(job.budget > 0, "ACP: budget not set");
        require(job.budget == expectedBudget, "ACP: budget mismatch");
        require(job.provider != address(0), "ACP: provider not set");

        job.status = JobStatus.Funded;

        // Pull tokens from client into this contract (escrow)
        _paymentToken.safeTransferFrom(msg.sender, address(this), job.budget);

        emit JobFunded(jobId, job.budget);
    }

    /// @inheritdoc IAgenticCommerce
    function submit(uint256 jobId, bytes32 deliverable)
        external
        onlyProvider(jobId)
        inStatus(jobId, JobStatus.Funded)
    {
        _jobs[jobId].status = JobStatus.Submitted;

        _callHook(jobId, IAgenticCommerce.submit.selector, abi.encode(deliverable), true);
        emit JobSubmitted(jobId, msg.sender, deliverable);
        _callHook(jobId, IAgenticCommerce.submit.selector, abi.encode(deliverable), false);
    }

    /// @inheritdoc IAgenticCommerce
    function complete(uint256 jobId, bytes32 reason)
        external
        inStatus(jobId, JobStatus.Submitted)
    {
        Job storage job = _jobs[jobId];
        require(msg.sender == job.evaluator, "ACP: not evaluator");

        job.status = JobStatus.Completed;

        _callHook(jobId, IAgenticCommerce.complete.selector, abi.encode(reason), true);

        // Release escrow to provider
        _paymentToken.safeTransfer(job.provider, job.budget);

        emit JobCompleted(jobId, msg.sender, reason);
        _callHook(jobId, IAgenticCommerce.complete.selector, abi.encode(reason), false);
    }

    /// @inheritdoc IAgenticCommerce
    function reject(uint256 jobId, bytes32 reason) external {
        Job storage job = _jobs[jobId];

        if (job.status == JobStatus.Open) {
            // Client can reject their own unfunded job
            require(msg.sender == job.client, "ACP: not client");
        } else if (job.status == JobStatus.Funded || job.status == JobStatus.Submitted) {
            // Only evaluator can reject funded/submitted jobs
            require(msg.sender == job.evaluator, "ACP: not evaluator");
        } else {
            revert("ACP: wrong status");
        }

        job.status = JobStatus.Rejected;

        _callHook(jobId, IAgenticCommerce.reject.selector, abi.encode(reason), true);

        // Refund escrow to client (if funded)
        if (job.budget > 0 && _paymentToken.balanceOf(address(this)) >= job.budget) {
            _paymentToken.safeTransfer(job.client, job.budget);
        }

        emit JobRejected(jobId, msg.sender, reason);
        _callHook(jobId, IAgenticCommerce.reject.selector, abi.encode(reason), false);
    }

    /// @inheritdoc IAgenticCommerce
    function claimRefund(uint256 jobId) external {
        Job storage job = _jobs[jobId];
        require(
            job.status == JobStatus.Funded || job.status == JobStatus.Submitted,
            "ACP: wrong status"
        );
        require(job.expiredAt > 0 && block.timestamp >= job.expiredAt, "ACP: not expired");

        job.status = JobStatus.Expired;

        // Refund to client — NOT hookable by design (safety guarantee)
        _paymentToken.safeTransfer(job.client, job.budget);

        emit JobExpired(jobId);
    }

    // =========================================================================
    // View functions
    // =========================================================================

    /// @inheritdoc IAgenticCommerce
    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    /// @inheritdoc IAgenticCommerce
    function getJobCount() external view returns (uint256) {
        return _jobCount;
    }

    /// @inheritdoc IAgenticCommerce
    function paymentToken() external view returns (address) {
        return address(_paymentToken);
    }

    // =========================================================================
    // Internal
    // =========================================================================

    function _callHook(uint256 jobId, bytes4 selector, bytes memory data, bool isBefore) internal {
        address hook = _jobs[jobId].hook;
        if (hook == address(0)) return;
        if (isBefore) {
            IACPHook(hook).beforeAction(jobId, selector, data);
        } else {
            IACPHook(hook).afterAction(jobId, selector, data);
        }
    }
}
