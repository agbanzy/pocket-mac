//! The LLM seam. Content/message types match the Anthropic Messages API wire shape so a platform
//! `LlmClient` impl can serialize them directly; the core never speaks HTTP.

use crate::types::{Result, Screenshot};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};

fn is_false(b: &bool) -> bool {
    !*b
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ImageSource {
    Base64 { media_type: String, data: String },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ContentBlock {
    Text {
        text: String,
    },
    Image {
        source: ImageSource,
    },
    ToolUse {
        id: String,
        name: String,
        input: serde_json::Value,
    },
    ToolResult {
        tool_use_id: String,
        content: Vec<ContentBlock>,
        #[serde(default, skip_serializing_if = "is_false")]
        is_error: bool,
    },
    /// Blocks the model may emit that the core echoes back verbatim (e.g. thinking) but doesn't parse.
    #[serde(other)]
    Unknown,
}

impl ContentBlock {
    pub fn text(s: impl Into<String>) -> Self {
        ContentBlock::Text { text: s.into() }
    }
    pub fn image(shot: &Screenshot) -> Self {
        ContentBlock::Image {
            source: ImageSource::Base64 {
                media_type: shot.media_type.clone(),
                data: shot.data_base64.clone(),
            },
        }
    }
    pub fn tool_result(id: impl Into<String>, content: Vec<ContentBlock>, is_error: bool) -> Self {
        ContentBlock::ToolResult { tool_use_id: id.into(), content, is_error }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: Vec<ContentBlock>,
}

impl Message {
    pub fn user(content: Vec<ContentBlock>) -> Self {
        Message { role: "user".into(), content }
    }
    pub fn assistant(content: Vec<ContentBlock>) -> Self {
        Message { role: "assistant".into(), content }
    }
}

/// One request to the model. `cache` asks the client to place prompt-cache breakpoints on the
/// stable prefix (system + tools + first turn); the client owns where exactly.
#[derive(Clone, Debug)]
pub struct LlmRequest {
    pub model: String,
    pub max_tokens: u32,
    pub system: String,
    /// Tool definition objects (computer tool + any MCP tools), already JSON.
    pub tools: Vec<serde_json::Value>,
    pub messages: Vec<Message>,
    pub beta: Option<String>,
    pub cache: bool,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Usage {
    #[serde(default)]
    pub input_tokens: u64,
    #[serde(default)]
    pub output_tokens: u64,
    #[serde(default)]
    pub cache_read_input_tokens: u64,
    #[serde(default)]
    pub cache_creation_input_tokens: u64,
}

#[derive(Clone, Debug)]
pub struct LlmResponse {
    pub content: Vec<ContentBlock>,
    pub stop_reason: String,
    pub usage: Usage,
}

/// Implemented by a platform crate (e.g. an Anthropic-over-reqwest client). The core depends only
/// on this trait, so it stays HTTP-free and portable.
#[async_trait]
pub trait LlmClient: Send + Sync {
    async fn complete(&self, req: &LlmRequest) -> Result<LlmResponse>;
}
