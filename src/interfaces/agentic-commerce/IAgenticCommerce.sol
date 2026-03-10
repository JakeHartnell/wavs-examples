// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IAgenticCommerce
/// @notice Interface for the ERC-8183 Agentic Commerce Protocol
/// @dev Implements the job escrow + evaluator attestation pattern for agent commerce.
///      See: https://eips.ethereum.org/EIPS/eip-8183
interface IAgenticCommerce {
    // =========================================================================
    // Enums
    // =========================================================================

    enum JobStatus {
        Open,       // Created, not yet funded
        Funded,     // Budget locked in escrow
        Submitted,  // Provider has submitted deliverable — only evaluator can act
        Completed,  // Evaluator approved — provider paid
        Rejected,   // Evaluator (or client when Open/Funded) rejected — client refunded
        Expired     // Timed out — anyone can trigger refund
    }

    // =========================================================================
    // Structs
    // =========================================================================

    struct Job {
        address client;
        address provider;
        address evaluator;    // Only entity that can complete/reject after Submitted
        address hook;         // Optional hook contract (IACPHook); address(0) = no hook
        string  description;  // Job brief; for the WAVS demo: the URL to verify
        uint256 budget;       // ERC-20 token amount in escrow
        uint64  expiredAt;    // Unix timestamp; 0 = no expiry
        JobStatus status;
    }

    // =========================================================================
    // Events
    // =========================================================================

    /// @notice Emitted when a new job is created
    event JobCreated(
        uint256 indexed jobId,
        address indexed client,
        address indexed provider,
        address evaluator,
        string  description,
        uint64  expiredAt
    );

    /// @notice Emitted when the job budget is updated
    event BudgetSet(uint256 indexed jobId, uint256 budget);

    /// @notice Emitted when client locks funds into escrow
    event JobFunded(uint256 indexed jobId, uint256 budget);

    /// @notice Emitted when the provider submits their deliverable
    /// @dev This is the primary WAVS trigger event.
    ///      deliverable = keccak256 of the provider's claimed work output
    event JobSubmitted(
        uint256 indexed jobId,
        address indexed provider,
        bytes32 deliverable
    );

    /// @notice Emitted when the evaluator marks a job complete (provider paid)
    event JobCompleted(
        uint256 indexed jobId,
        address indexed evaluator,
        bytes32 attestation  // evaluator's computed hash (matches or explains deliverable)
    );

    /// @notice Emitted when the job is rejected (client refunded)
    event JobRejected(
        uint256 indexed jobId,
        address indexed rejector,
        bytes32 reason
    );

    /// @notice Emitted when a timeout refund is triggered
    event JobExpired(uint256 indexed jobId);

    // =========================================================================
    // State-changing functions
    // =========================================================================

    /// @notice Create a new job in Open state
    /// @param provider Agent expected to do the work (can be address(0) for open market)
    /// @param evaluator Trusted evaluator — the WAVS aggregator address or evaluator contract
    /// @param expiredAt Unix timestamp after which claimRefund can be called (0 = no expiry)
    /// @param description Job brief; in WAVS demo encodes the URL to verify
    /// @param hook Optional hook contract; address(0) to skip
    /// @return jobId The new job's ID (1-indexed)
    function createJob(
        address provider,
        address evaluator,
        uint64 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256 jobId);

    /// @notice Update provider assignment (client only, Open state)
    function setProvider(uint256 jobId, address provider) external;

    /// @notice Update job budget (client or provider, Open state)
    function setBudget(uint256 jobId, uint256 amount) external;

    /// @notice Lock funds in escrow — transitions Open → Funded
    /// @param expectedBudget Must match current budget (prevents front-running)
    function fund(uint256 jobId, uint256 expectedBudget) external;

    /// @notice Provider submits deliverable — transitions Funded → Submitted
    /// @param deliverable keccak256 hash of the work output (e.g. keccak256(url_content))
    function submit(uint256 jobId, bytes32 deliverable) external;

    /// @notice Evaluator marks job complete — transitions Submitted → Completed
    /// @param reason Evaluator's attestation hash (e.g. computed hash confirming deliverable)
    function complete(uint256 jobId, bytes32 reason) external;

    /// @notice Reject a job — evaluator (any state), client (Open only)
    function reject(uint256 jobId, bytes32 reason) external;

    /// @notice Anyone can trigger expiry after expiredAt — Funded/Submitted → Expired
    function claimRefund(uint256 jobId) external;

    // =========================================================================
    // View functions
    // =========================================================================

    function getJob(uint256 jobId) external view returns (Job memory);
    function getJobCount() external view returns (uint256);
    function getJobDescription(uint256 jobId) external view returns (string memory);
    function paymentToken() external view returns (address);
}
