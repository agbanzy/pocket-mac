//! Anthropic Messages API implementation of [`agent_core::LlmClient`].
//!
//! Places prompt-cache breakpoints on the stable prefix (system + last tool + first turn's last
//! block) exactly as the Swift agent does, so the growing screenshot history is re-read from cache
//! each turn — the 30–70% TTFT win. Emits the computer-use beta header the request carries.

use agent_core::{AgentError, ContentBlock, LlmClient, LlmRequest, LlmResponse, Result, Usage};
use async_trait::async_trait;
use serde_json::{json, Value};

const ENDPOINT: &str = "https://api.anthropic.com/v1/messages";

pub struct AnthropicClient {
    api_key: String,
    http: reqwest::Client,
}

impl AnthropicClient {
    pub fn new(api_key: impl Into<String>) -> Self {
        Self { api_key: api_key.into(), http: reqwest::Client::new() }
    }
}

fn ephemeral() -> Value {
    json!({ "type": "ephemeral" })
}

/// Build the request JSON, placing cache breakpoints when `req.cache`. Pure + testable — no network.
pub fn build_body(req: &LlmRequest) -> Result<Value> {
    let mut messages = serde_json::to_value(&req.messages).map_err(|e| AgentError::Llm(e.to_string()))?;

    let system = if req.cache {
        json!([{ "type": "text", "text": req.system, "cache_control": ephemeral() }])
    } else {
        json!(req.system)
    };

    let mut tools = req.tools.clone();
    if req.cache {
        if let Some(last) = tools.last_mut() {
            last["cache_control"] = ephemeral();
        }
    }

    // Cache the fixed base: the first user turn (task + first screenshot) never changes.
    if req.cache {
        if let Some(first_content) = messages
            .as_array_mut()
            .and_then(|a| a.first_mut())
            .and_then(|m| m.get_mut("content"))
            .and_then(|c| c.as_array_mut())
        {
            if let Some(last_block) = first_content.last_mut() {
                last_block["cache_control"] = ephemeral();
            }
        }
    }

    Ok(json!({
        "model": req.model,
        "max_tokens": req.max_tokens,
        "system": system,
        "tools": tools,
        "messages": messages,
    }))
}

#[async_trait]
impl LlmClient for AnthropicClient {
    async fn complete(&self, req: &LlmRequest) -> Result<LlmResponse> {
        let body = build_body(req)?;

        let mut rb = self
            .http
            .post(ENDPOINT)
            .header("x-api-key", &self.api_key)
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json");
        if let Some(beta) = &req.beta {
            rb = rb.header("anthropic-beta", beta.clone());
        }

        let resp = rb.json(&body).send().await.map_err(|e| AgentError::Llm(e.to_string()))?;
        let status = resp.status();
        let val: Value = resp.json().await.map_err(|e| AgentError::Llm(e.to_string()))?;

        if !status.is_success() {
            let msg = val.get("error").and_then(|e| e.get("message")).and_then(|m| m.as_str()).unwrap_or("");
            return Err(AgentError::Llm(format!("{status}: {msg}")));
        }

        let content: Vec<ContentBlock> =
            serde_json::from_value(val.get("content").cloned().unwrap_or_else(|| json!([])))
                .map_err(|e| AgentError::Llm(e.to_string()))?;
        let stop_reason = val.get("stop_reason").and_then(|v| v.as_str()).unwrap_or("").to_string();
        let usage: Usage = val
            .get("usage")
            .cloned()
            .and_then(|u| serde_json::from_value(u).ok())
            .unwrap_or_default();

        Ok(LlmResponse { content, stop_reason, usage })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_core::Message;

    fn req(cache: bool) -> LlmRequest {
        LlmRequest {
            model: "claude-opus-4-8".into(),
            max_tokens: 4096,
            system: "sys".into(),
            tools: vec![json!({"type":"computer_20251124","name":"computer"})],
            messages: vec![Message::user(vec![
                ContentBlock::text("do it"),
                ContentBlock::text("frame"),
            ])],
            beta: Some("computer-use-2025-11-24".into()),
            cache,
        }
    }

    #[test]
    fn caching_places_three_breakpoints() {
        let b = build_body(&req(true)).unwrap();
        assert!(b["system"][0]["cache_control"]["type"] == "ephemeral");
        assert!(b["tools"][0]["cache_control"]["type"] == "ephemeral");
        assert!(b["messages"][0]["content"][1]["cache_control"]["type"] == "ephemeral");
    }

    #[test]
    fn no_cache_keeps_plain_system() {
        let b = build_body(&req(false)).unwrap();
        assert!(b["system"].is_string());
        assert!(b["tools"][0].get("cache_control").is_none());
    }
}
