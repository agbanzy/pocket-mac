//! MCP (Model Context Protocol) seam. An `McpClient` is a live connection to one MCP server
//! (stdio / SSE / streamable-HTTP — the transport lives in a platform crate). `McpTool` adapts a
//! single server tool to the `Tool` trait so it drops straight into the `ToolRegistry`, giving the
//! agent skills beyond the screen: files, browsers, calendars, APIs.

use crate::llm::ContentBlock;
use crate::tool::{Tool, ToolRegistry};
use crate::types::{AgentError, Result};
use async_trait::async_trait;
use std::sync::Arc;

/// One tool advertised by an MCP server.
#[derive(Clone, Debug)]
pub struct McpToolDef {
    pub name: String,
    pub description: String,
    pub input_schema: serde_json::Value,
}

#[async_trait]
pub trait McpClient: Send + Sync {
    /// Human-readable server id (used to namespace tool names as `server__tool`).
    fn server_id(&self) -> &str;
    /// Discover the server's tools.
    async fn list_tools(&self) -> Result<Vec<McpToolDef>>;
    /// Invoke a tool; return its result as text (MCP content parts are flattened to text here).
    async fn call_tool(&self, name: &str, args: &serde_json::Value) -> Result<String>;
}

/// Adapts one MCP server tool to the agent's `Tool` trait.
pub struct McpTool {
    client: Arc<dyn McpClient>,
    /// Namespaced name exposed to the model, e.g. "filesystem__read_file".
    exposed_name: String,
    /// Bare tool name on the server.
    remote_name: String,
    schema: serde_json::Value,
}

impl McpTool {
    fn qualified(server: &str, tool: &str) -> String {
        format!("{server}__{tool}")
    }
}

#[async_trait]
impl Tool for McpTool {
    fn name(&self) -> &str {
        &self.exposed_name
    }

    fn schema(&self) -> serde_json::Value {
        self.schema.clone()
    }

    async fn call(&self, input: &serde_json::Value) -> Result<Vec<ContentBlock>> {
        let out = self
            .client
            .call_tool(&self.remote_name, input)
            .await
            .map_err(|e| AgentError::Tool(format!("{}: {e}", self.exposed_name)))?;
        Ok(vec![ContentBlock::text(out)])
    }
}

/// Discover every tool on an MCP server and register it (namespaced) into the registry.
pub async fn register_mcp_server(registry: &mut ToolRegistry, client: Arc<dyn McpClient>) -> Result<usize> {
    let defs = client.list_tools().await?;
    let count = defs.len();
    for def in defs {
        let exposed = McpTool::qualified(client.server_id(), &def.name);
        let schema = serde_json::json!({
            "name": exposed,
            "description": def.description,
            "input_schema": def.input_schema,
        });
        registry.register(Arc::new(McpTool {
            client: client.clone(),
            exposed_name: exposed,
            remote_name: def.name,
            schema,
        }));
    }
    Ok(count)
}
