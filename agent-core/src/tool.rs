//! The tool seam. The computer tool is built into the loop (it needs the backend + capture); this
//! registry holds *additional* tools — chiefly MCP servers' tools — that the model can call by name.

use crate::llm::ContentBlock;
use crate::types::Result;
use async_trait::async_trait;
use std::sync::Arc;

#[async_trait]
pub trait Tool: Send + Sync {
    /// The tool name the model calls.
    fn name(&self) -> &str;
    /// The JSON tool definition (`{name, description, input_schema}`) advertised to the model.
    fn schema(&self) -> serde_json::Value;
    /// Run the tool with the model's input; return the `tool_result` content blocks.
    async fn call(&self, input: &serde_json::Value) -> Result<Vec<ContentBlock>>;
}

/// A name-addressed set of extra tools. MCP servers register their tools here (see `mcp`).
#[derive(Default, Clone)]
pub struct ToolRegistry {
    tools: Vec<Arc<dyn Tool>>,
}

impl ToolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, tool: Arc<dyn Tool>) {
        self.tools.push(tool);
    }

    /// Tool definitions to append to the request's `tools` array.
    pub fn schemas(&self) -> Vec<serde_json::Value> {
        self.tools.iter().map(|t| t.schema()).collect()
    }

    pub fn find(&self, name: &str) -> Option<Arc<dyn Tool>> {
        self.tools.iter().find(|t| t.name() == name).cloned()
    }

    pub fn is_empty(&self) -> bool {
        self.tools.is_empty()
    }
}
