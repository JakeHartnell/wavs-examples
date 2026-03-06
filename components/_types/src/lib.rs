/// Shared types used across wavs-examples components.
///
/// Keep these minimal and focused on cross-example interoperability.
/// Example-specific types should live in the example's own module.
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Agent task queue
// ---------------------------------------------------------------------------

/// A task posted to the on-chain agent task queue.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct AgentTask {
    /// Unique task ID (set by the trigger contract).
    pub task_id: u64,
    /// The kind of work being requested.
    pub kind: AgentTaskKind,
    /// ISO-8601 timestamp when the task was created.
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "type", content = "params")]
pub enum AgentTaskKind {
    /// Fetch data from a URL and return the body.
    Fetch { url: String },
    /// Run a prompt through a local inference endpoint.
    Infer { prompt: String, seed: u64 },
    /// Echo the input back (useful for testing).
    Echo { message: String },
}

/// The result of processing an AgentTask.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct AgentTaskResult {
    pub task_id: u64,
    pub success: bool,
    pub output: String,
    pub completed_at: String,
}

// ---------------------------------------------------------------------------
// Agent memory
// ---------------------------------------------------------------------------

/// A memory entry an agent wants to store verifiably.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct MemoryEntry {
    /// The agent's identifier (e.g. wallet address or name).
    pub agent_id: String,
    /// Arbitrary key for this memory.
    pub key: String,
    /// The value being stored.
    pub value: String,
    /// Optional TTL in seconds (0 = permanent).
    pub ttl_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct MemoryEntryResult {
    pub agent_id: String,
    pub key: String,
    pub stored: bool,
}

// ---------------------------------------------------------------------------
// Generic feed / oracle
// ---------------------------------------------------------------------------

/// A generic data point from any feed.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub struct DataPoint {
    pub feed: String,
    pub value: String,
    pub timestamp: String,
    pub source: String,
}
