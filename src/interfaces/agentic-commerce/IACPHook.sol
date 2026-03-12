// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IACPHook
/// @notice Optional per-job hook contract for extending ERC-8183 Agentic Commerce Protocol
/// @dev Before hooks can block actions; after hooks trigger side-effects.
///      claimRefund is deliberately not hookable — safety mechanism can't be blocked.
interface IACPHook {
    /// @notice Called before a state-changing action
    /// @param jobId The job being acted upon
    /// @param selector The function selector of the action (e.g. complete.selector)
    /// @param data Additional context (ABI-encoded action parameters)
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external;

    /// @notice Called after a state-changing action completes
    /// @param jobId The job being acted upon
    /// @param selector The function selector of the action
    /// @param data Additional context (ABI-encoded action parameters)
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external;
}
