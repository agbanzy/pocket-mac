//! Drives the MCP client against a real child process speaking JSON-RPC over stdio, so the
//! handshake, tool discovery, tool invocation, and registration into the agent's `ToolRegistry` are
//! proven rather than assumed. The mock server interleaves a notification and a stale-id reply, so
//! the client's id-matching loop is genuinely exercised.

use agent_core::{register_mcp_server, ContentBlock, McpClient, ToolRegistry};
use agent_mcp_stdio::McpStdioClient;
use std::sync::Arc;

fn mock_server_path() -> String {
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/mock_server.py").to_string()
}

async fn connect() -> McpStdioClient {
    McpStdioClient::spawn("mock", "python3", &[&mock_server_path()])
        .await
        .expect("spawn mock MCP server")
}

#[tokio::test]
async fn discovers_tools_through_the_handshake() {
    let client = connect().await;
    let mut tools = client.list_tools().await.expect("tools/list");
    tools.sort_by(|a, b| a.name.cmp(&b.name));

    assert_eq!(tools.len(), 2);
    assert_eq!(tools[0].name, "add");
    assert_eq!(tools[1].name, "echo");
    assert!(tools[1].description.contains("Echo"));
    // The schema must survive verbatim — the model is shown it.
    assert_eq!(tools[1].input_schema["properties"]["text"]["type"], "string");
}

#[tokio::test]
async fn calls_a_tool_and_flattens_the_result() {
    let client = connect().await;
    let out = client
        .call_tool("echo", &serde_json::json!({ "text": "hi" }))
        .await
        .expect("tools/call");
    assert!(out.contains("echo: hi"), "unexpected: {out}");

    let sum = client
        .call_tool("add", &serde_json::json!({ "a": 2, "b": 40 }))
        .await
        .expect("tools/call add");
    assert!(sum.trim() == "42", "unexpected: {sum}");
}

#[tokio::test]
async fn a_server_error_surfaces_instead_of_hanging() {
    let client = connect().await;
    let err = client
        .call_tool("nope", &serde_json::json!({}))
        .await
        .expect_err("unknown tool should error");
    assert!(err.to_string().contains("no such tool"), "unexpected: {err}");
}

#[tokio::test]
async fn registers_into_the_agent_tool_registry_namespaced() {
    let client: Arc<dyn McpClient> = Arc::new(connect().await);
    let mut registry = ToolRegistry::new();
    let count = register_mcp_server(&mut registry, client).await.expect("register");
    assert_eq!(count, 2);

    // Namespaced so two servers can expose the same bare tool name without colliding.
    let tool = registry.find("mock__echo").expect("mock__echo registered");
    assert!(registry.find("echo").is_none(), "bare name must not be exposed");

    // The schema handed to the model carries the namespaced name.
    assert_eq!(tool.schema()["name"], "mock__echo");

    let blocks = tool.call(&serde_json::json!({ "text": "via registry" })).await.expect("call");
    match &blocks[0] {
        ContentBlock::Text { text } => assert!(text.contains("echo: via registry")),
        other => panic!("expected text block, got {other:?}"),
    }
}
