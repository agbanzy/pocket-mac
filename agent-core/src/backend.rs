//! The OS seam. Each platform (macOS, Windows, Android) implements `ComputerBackend`; the agent
//! loop is identical across all of them. Coordinates are model-space (the screenshot's space) —
//! the backend maps them to native pixels/points, so the core never touches display geometry.

use crate::types::{Action, Result, Screenshot};
use async_trait::async_trait;

#[async_trait]
pub trait ComputerBackend: Send + Sync {
    /// Capture, downscale, and encode the screen. The returned width/height define the coordinate
    /// space the model (and every `Action`) uses.
    async fn capture(&self) -> Result<Screenshot>;

    /// Execute one action. Returns `Some(text)` for read-only actions that report data instead of
    /// causing a screen change (e.g. `cursor_position`), otherwise `None`.
    async fn execute(&self, action: &Action) -> Result<Option<String>>;

    /// Model-space dimensions, used to build the computer-tool definition.
    fn model_size(&self) -> (u32, u32);
}

/// The computer-use tool definition (`computer_20251124`) for a given model-space size.
pub fn computer_tool_schema(width: u32, height: u32, enable_zoom: bool) -> serde_json::Value {
    let mut v = serde_json::json!({
        "type": "computer_20251124",
        "name": "computer",
        "display_width_px": width,
        "display_height_px": height,
        "display_number": 1,
    });
    if enable_zoom {
        v["enable_zoom"] = serde_json::Value::Bool(true);
    }
    v
}
