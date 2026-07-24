//! Core value types shared across the agent, backends, and tools.

use serde::{Deserialize, Serialize};

/// A downscaled screenshot ready to hand to the model. The backend owns capture, downscaling, and
/// encoding (per-OS), so the core stays pixel-agnostic.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Screenshot {
    /// Base64 image payload.
    pub data_base64: String,
    /// e.g. "image/jpeg".
    pub media_type: String,
    /// Model-space width the coordinates are expressed in.
    pub width: u32,
    /// Model-space height.
    pub height: u32,
}

/// A single computer action the model asked for, already parsed from the tool_use input. Coordinates
/// are in model space (the screenshot's space); the backend maps them to native pixels/points.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Action {
    Screenshot,
    Wait { duration: f64 },
    CursorPosition,
    MouseMove { coordinate: [i32; 2] },
    LeftClick { coordinate: [i32; 2], #[serde(default)] text: Option<String> },
    RightClick { coordinate: [i32; 2], #[serde(default)] text: Option<String> },
    MiddleClick { coordinate: [i32; 2], #[serde(default)] text: Option<String> },
    DoubleClick { coordinate: [i32; 2], #[serde(default)] text: Option<String> },
    TripleClick { coordinate: [i32; 2], #[serde(default)] text: Option<String> },
    LeftClickDrag { start_coordinate: [i32; 2], coordinate: [i32; 2] },
    Scroll { coordinate: [i32; 2], scroll_direction: String, scroll_amount: i32,
             #[serde(default)] text: Option<String> },
    Key { text: String },
    HoldKey { text: String, #[serde(default)] duration: f64 },
    Type { text: String },
}

impl Action {
    /// Whether the model expects a fresh screenshot afterwards (everything except pure reads).
    pub fn returns_screenshot(&self) -> bool {
        !matches!(self, Action::CursorPosition)
    }

    /// Focus-changing actions need a short settle before the verification shot; reads/moves don't.
    pub fn needs_settle(&self) -> bool {
        matches!(
            self,
            Action::Key { .. } | Action::Type { .. } | Action::LeftClick { .. }
                | Action::DoubleClick { .. } | Action::TripleClick { .. } | Action::LeftClickDrag { .. }
        )
    }
}

/// A progress event streamed to the controller (phone / web) as the task runs. Mirrors the wire
/// `TaskEventKind` in PocketMacKit so the Swift/TS/Kotlin clients render it directly.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    Started,
    Thinking,
    Action,
    Done,
    Error,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TaskEvent {
    pub kind: EventKind,
    pub text: String,
}

#[derive(Debug, thiserror::Error)]
pub enum AgentError {
    #[error("llm error: {0}")]
    Llm(String),
    #[error("backend error: {0}")]
    Backend(String),
    #[error("tool error: {0}")]
    Tool(String),
    #[error("store error: {0}")]
    Store(String),
    #[error("cancelled")]
    Cancelled,
    #[error("step limit reached")]
    StepLimit,
}

pub type Result<T> = std::result::Result<T, AgentError>;
