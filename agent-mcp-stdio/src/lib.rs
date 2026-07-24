//! MCP stdio transport implementing [`agent_core::McpClient`]. Spawns an MCP server as a child
//! process and speaks newline-delimited JSON-RPC 2.0 over its stdio. Once registered via
//! `agent_core::register_mcp_server`, every one of the server's tools becomes callable by the agent
//! alongside the built-in computer tool — files, browsers, calendars, arbitrary APIs.

use agent_core::{AgentError, McpClient, McpToolDef, Result};
use async_trait::async_trait;
use serde_json::{json, Value};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

pub struct McpStdioClient {
    id: String,
    next_id: AtomicU64,
    io: Mutex<Io>,
    _child: Child,
}

struct Io {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl McpStdioClient {
    /// Spawn the server and complete the MCP `initialize` handshake.
    pub async fn spawn(id: impl Into<String>, program: &str, args: &[&str]) -> Result<Self> {
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| AgentError::Tool(format!("spawn mcp server '{program}': {e}")))?;
        let stdin = child.stdin.take().ok_or_else(|| AgentError::Tool("no stdin".into()))?;
        let stdout = BufReader::new(child.stdout.take().ok_or_else(|| AgentError::Tool("no stdout".into()))?);
        let client = Self {
            id: id.into(),
            next_id: AtomicU64::new(1),
            io: Mutex::new(Io { stdin, stdout }),
            _child: child,
        };
        client.initialize().await?;
        Ok(client)
    }

    async fn write_line(io: &mut Io, msg: &Value) -> Result<()> {
        let line = format!("{}\n", msg);
        io.stdin.write_all(line.as_bytes()).await.map_err(|e| AgentError::Tool(e.to_string()))?;
        io.stdin.flush().await.map_err(|e| AgentError::Tool(e.to_string()))?;
        Ok(())
    }

    /// Send a request and read newline-delimited replies until the matching id arrives (skipping
    /// server-initiated notifications / other ids).
    async fn rpc(&self, method: &str, params: Value) -> Result<Value> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let req = json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params });
        let mut io = self.io.lock().await;
        Self::write_line(&mut io, &req).await?;
        loop {
            let mut buf = String::new();
            let n = io.stdout.read_line(&mut buf).await.map_err(|e| AgentError::Tool(e.to_string()))?;
            if n == 0 {
                return Err(AgentError::Tool("mcp server closed the connection".into()));
            }
            let v: Value = match serde_json::from_str(buf.trim()) {
                Ok(v) => v,
                Err(_) => continue,
            };
            if v.get("id").and_then(|i| i.as_u64()) == Some(id) {
                if let Some(err) = v.get("error") {
                    return Err(AgentError::Tool(format!("mcp error: {err}")));
                }
                return Ok(v.get("result").cloned().unwrap_or(Value::Null));
            }
        }
    }

    async fn notify(&self, method: &str, params: Value) -> Result<()> {
        let msg = json!({ "jsonrpc": "2.0", "method": method, "params": params });
        let mut io = self.io.lock().await;
        Self::write_line(&mut io, &msg).await
    }

    async fn initialize(&self) -> Result<()> {
        self.rpc(
            "initialize",
            json!({
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": { "name": "pocket-mac-agent", "version": "0.1.0" }
            }),
        )
        .await?;
        self.notify("notifications/initialized", json!({})).await?;
        Ok(())
    }
}

#[async_trait]
impl McpClient for McpStdioClient {
    fn server_id(&self) -> &str {
        &self.id
    }

    async fn list_tools(&self) -> Result<Vec<McpToolDef>> {
        let res = self.rpc("tools/list", json!({})).await?;
        let tools = res.get("tools").and_then(|t| t.as_array()).cloned().unwrap_or_default();
        Ok(tools
            .iter()
            .filter_map(|t| {
                Some(McpToolDef {
                    name: t.get("name")?.as_str()?.to_string(),
                    description: t.get("description").and_then(|d| d.as_str()).unwrap_or("").to_string(),
                    input_schema: t.get("inputSchema").cloned().unwrap_or_else(|| json!({ "type": "object" })),
                })
            })
            .collect())
    }

    async fn call_tool(&self, name: &str, args: &Value) -> Result<String> {
        let res = self.rpc("tools/call", json!({ "name": name, "arguments": args })).await?;
        // MCP results are an array of content parts; flatten the text parts.
        let mut out = String::new();
        if let Some(parts) = res.get("content").and_then(|c| c.as_array()) {
            for p in parts {
                if let Some(t) = p.get("text").and_then(|t| t.as_str()) {
                    out.push_str(t);
                    out.push('\n');
                }
            }
        }
        if out.is_empty() {
            out = res.to_string();
        }
        Ok(out)
    }
}
