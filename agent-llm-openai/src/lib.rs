//! Run the agent against any provider that speaks the OpenAI chat-completions shape — **xAI's Grok**
//! (`https://api.x.ai/v1`, vision + tool calling), OpenAI itself, or a local server such as Ollama,
//! LM Studio, or llama.cpp.
//!
//! This is the same [`agent_core::LlmClient`] seam the Anthropic client implements, so Claude and
//! Grok are interchangeable: the phone, the Mac helper, and the Windows CLI each pick a provider and
//! nothing else in the stack changes.
//!
//! One caveat, surfaced rather than hidden: **the model must handle images.** Computer use is a
//! vision task, so a text-only model will connect happily and then flounder. Grok 4.5 and the
//! vision-capable local models are fine; a small text-only local model is not.

use agent_core::{
    AgentError, ContentBlock, ImageSource, LlmClient, LlmRequest, LlmResponse, Result, Usage,
};
use async_trait::async_trait;
use serde_json::{json, Value};

/// A known provider: where it lives, a sensible default model, and whether it needs a key.
#[derive(Clone, Copy, Debug)]
pub struct Provider {
    pub id: &'static str,
    pub base_url: &'static str,
    pub default_model: &'static str,
    /// Remote providers need an API key; local servers ignore it.
    pub needs_key: bool,
    /// Environment variable checked for the key when none is passed explicitly.
    pub key_env: &'static str,
}

/// Grok 4.5 — vision and tool calling, which is what computer use needs.
pub const GROK: Provider = Provider {
    id: "grok",
    base_url: "https://api.x.ai/v1",
    default_model: "grok-4.5",
    needs_key: true,
    key_env: "XAI_API_KEY",
};

pub const OPENAI: Provider = Provider {
    id: "openai",
    base_url: "https://api.openai.com/v1",
    default_model: "gpt-4o",
    needs_key: true,
    key_env: "OPENAI_API_KEY",
};

pub const OLLAMA: Provider = Provider {
    id: "ollama",
    base_url: "http://127.0.0.1:11434/v1",
    default_model: "llama3.2-vision",
    needs_key: false,
    key_env: "",
};

pub const LM_STUDIO: Provider = Provider {
    id: "lm-studio",
    base_url: "http://127.0.0.1:1234/v1",
    default_model: "local-model",
    needs_key: false,
    key_env: "",
};

pub const LLAMA_CPP: Provider = Provider {
    id: "llama.cpp",
    base_url: "http://127.0.0.1:8080/v1",
    default_model: "local-model",
    needs_key: false,
    key_env: "",
};

pub const PROVIDERS: &[Provider] = &[GROK, OPENAI, OLLAMA, LM_STUDIO, LLAMA_CPP];

/// Look a provider up by id, e.g. "grok".
pub fn provider(id: &str) -> Option<Provider> {
    PROVIDERS.iter().copied().find(|p| p.id.eq_ignore_ascii_case(id))
}

/// The local-only subset, for discovery.
pub const WELL_KNOWN: &[(&str, &str)] = &[
    ("ollama", OLLAMA.base_url),
    ("lm-studio", LM_STUDIO.base_url),
    ("llama.cpp", LLAMA_CPP.base_url),
];

/// A local server that answered, and the models it offers.
#[derive(Clone, Debug)]
pub struct LocalServer {
    pub id: String,
    pub base_url: String,
    pub models: Vec<String>,
}

/// Probe the well-known ports and report whatever is actually running, so a controller can offer
/// "use the local model" only when there is one. Short timeout: this runs on a UI path.
pub async fn discover() -> Vec<LocalServer> {
    let Ok(http) = reqwest::Client::builder()
        .timeout(std::time::Duration::from_millis(700))
        .build()
    else {
        return Vec::new();
    };
    let mut found = Vec::new();
    for (id, base) in WELL_KNOWN {
        let Ok(resp) = http.get(format!("{base}/models")).send().await else { continue };
        if !resp.status().is_success() {
            continue;
        }
        let Ok(body) = resp.json::<Value>().await else { continue };
        let models = body
            .get("data")
            .and_then(|d| d.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|m| m.get("id").and_then(|i| i.as_str()).map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        found.push(LocalServer { id: id.to_string(), base_url: base.to_string(), models });
    }
    found
}

pub struct OpenAiCompatClient {
    base_url: String,
    model: String,
    api_key: Option<String>,
    http: reqwest::Client,
}

/// Kept for callers that only ever wanted a local server.
pub type LocalClient = OpenAiCompatClient;

impl OpenAiCompatClient {
    pub fn new(base_url: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            base_url: base_url.into(),
            model: model.into(),
            api_key: None,
            // Local models on modest hardware are slow, and Grok reasons for a while; a short
            // timeout would look like a crash.
            http: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(300))
                .build()
                .unwrap_or_default(),
        }
    }

    pub fn with_key(mut self, key: impl Into<String>) -> Self {
        let key = key.into();
        if !key.is_empty() {
            self.api_key = Some(key);
        }
        self
    }

    /// Build from a preset, falling back to the provider's key environment variable. `model` of
    /// `None` uses the provider's default.
    pub fn from_provider(p: Provider, model: Option<&str>, key: Option<&str>) -> Result<Self> {
        let key = key
            .map(str::to_string)
            .or_else(|| if p.key_env.is_empty() { None } else { std::env::var(p.key_env).ok() })
            .unwrap_or_default();
        if p.needs_key && key.is_empty() {
            return Err(AgentError::Llm(format!(
                "{} needs an API key — set {} or pass one explicitly",
                p.id, p.key_env
            )));
        }
        Ok(Self::new(p.base_url, model.unwrap_or(p.default_model)).with_key(key))
    }
}

/// Translate our content blocks into OpenAI chat parts.
fn to_openai_content(blocks: &[ContentBlock]) -> Value {
    let mut parts = Vec::new();
    for b in blocks {
        match b {
            ContentBlock::Text { text } => parts.push(json!({"type": "text", "text": text})),
            ContentBlock::Image { source: ImageSource::Base64 { media_type, data } } => {
                parts.push(json!({
                    "type": "image_url",
                    "image_url": { "url": format!("data:{media_type};base64,{data}") }
                }));
            }
            ContentBlock::ToolResult { content, .. } => {
                for inner in content {
                    match inner {
                        ContentBlock::Text { text } => {
                            parts.push(json!({"type": "text", "text": text}))
                        }
                        ContentBlock::Image {
                            source: ImageSource::Base64 { media_type, data },
                        } => parts.push(json!({
                            "type": "image_url",
                            "image_url": { "url": format!("data:{media_type};base64,{data}") }
                        })),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    Value::Array(parts)
}

fn to_openai_messages(system: &str, messages: &[agent_core::Message]) -> Vec<Value> {
    let mut out = vec![json!({"role": "system", "content": system})];
    for m in messages {
        // An assistant turn that called tools must replay as `tool_calls`, and each result as its
        // own `tool` message — otherwise the server sees an orphaned result and rejects the request.
        let tool_uses: Vec<&ContentBlock> = m
            .content
            .iter()
            .filter(|b| matches!(b, ContentBlock::ToolUse { .. }))
            .collect();
        if m.role == "assistant" && !tool_uses.is_empty() {
            let calls: Vec<Value> = tool_uses
                .iter()
                .filter_map(|b| match b {
                    ContentBlock::ToolUse { id, name, input } => Some(json!({
                        "id": id, "type": "function",
                        "function": { "name": name, "arguments": input.to_string() }
                    })),
                    _ => None,
                })
                .collect();
            out.push(json!({"role": "assistant", "content": null, "tool_calls": calls}));
            continue;
        }

        let results: Vec<&ContentBlock> = m
            .content
            .iter()
            .filter(|b| matches!(b, ContentBlock::ToolResult { .. }))
            .collect();
        if !results.is_empty() {
            for r in results {
                if let ContentBlock::ToolResult { tool_use_id, content, .. } = r {
                    out.push(json!({
                        "role": "tool",
                        "tool_call_id": tool_use_id,
                        "content": to_openai_content(content),
                    }));
                }
            }
            continue;
        }

        out.push(json!({"role": m.role, "content": to_openai_content(&m.content)}));
    }
    out
}

/// Our tool schemas are Anthropic-shaped; wrap them as OpenAI functions. The built-in computer tool
/// carries no `input_schema` (the provider supplies it), so give it an explicit one — without that
/// the model is handed a function with no parameters to fill in.
fn to_openai_tools(tools: &[Value]) -> Vec<Value> {
    tools
        .iter()
        .map(|t| {
            let name = t.get("name").and_then(|n| n.as_str()).unwrap_or("tool");
            let schema = t.get("input_schema").cloned().unwrap_or_else(|| {
                json!({
                    "type": "object",
                    "properties": {
                        "action": {"type": "string"},
                        "coordinate": {"type": "array", "items": {"type": "integer"}},
                        "start_coordinate": {"type": "array", "items": {"type": "integer"}},
                        "text": {"type": "string"},
                        "scroll_direction": {"type": "string"},
                        "scroll_amount": {"type": "integer"},
                        "duration": {"type": "number"}
                    },
                    "required": ["action"]
                })
            });
            json!({
                "type": "function",
                "function": {
                    "name": name,
                    "description": t.get("description").and_then(|d| d.as_str()).unwrap_or(""),
                    "parameters": schema
                }
            })
        })
        .collect()
}

#[async_trait]
impl LlmClient for OpenAiCompatClient {
    async fn complete(&self, req: &LlmRequest) -> Result<LlmResponse> {
        let body = json!({
            "model": self.model,
            "max_tokens": req.max_tokens,
            "messages": to_openai_messages(&req.system, &req.messages),
            "tools": to_openai_tools(&req.tools),
        });

        let mut rb = self.http.post(format!("{}/chat/completions", self.base_url));
        if let Some(key) = &self.api_key {
            rb = rb.bearer_auth(key);
        }
        let resp = rb
            .json(&body)
            .send()
            .await
            .map_err(|e| AgentError::Llm(format!("local model at {}: {e}", self.base_url)))?;
        let status = resp.status();
        let val: Value = resp.json().await.map_err(|e| AgentError::Llm(e.to_string()))?;
        if !status.is_success() {
            let msg = val.get("error").map(|e| e.to_string()).unwrap_or_default();
            return Err(AgentError::Llm(format!("{status}: {msg}")));
        }

        let choice = val
            .get("choices")
            .and_then(|c| c.as_array())
            .and_then(|a| a.first())
            .ok_or_else(|| AgentError::Llm("local model returned no choices".into()))?;
        let message = choice.get("message").cloned().unwrap_or_else(|| json!({}));

        let mut content = Vec::new();
        if let Some(text) = message.get("content").and_then(|c| c.as_str()) {
            if !text.is_empty() {
                content.push(ContentBlock::text(text));
            }
        }
        let mut used_tool = false;
        if let Some(calls) = message.get("tool_calls").and_then(|c| c.as_array()) {
            for call in calls {
                let f = call.get("function").cloned().unwrap_or_else(|| json!({}));
                let name = f.get("name").and_then(|n| n.as_str()).unwrap_or("").to_string();
                // Arguments arrive as a JSON *string*, and a small local model may emit malformed
                // JSON — fall back to an empty object rather than failing the whole turn.
                let input: Value = f
                    .get("arguments")
                    .and_then(|a| a.as_str())
                    .and_then(|s| serde_json::from_str(s).ok())
                    .unwrap_or_else(|| json!({}));
                let id = call.get("id").and_then(|i| i.as_str()).unwrap_or("call_0").to_string();
                content.push(ContentBlock::ToolUse { id, name, input });
                used_tool = true;
            }
        }

        let stop_reason = if used_tool { "tool_use" } else { "end_turn" }.to_string();
        let usage = val
            .get("usage")
            .map(|u| Usage {
                input_tokens: u.get("prompt_tokens").and_then(|v| v.as_u64()).unwrap_or(0),
                output_tokens: u.get("completion_tokens").and_then(|v| v.as_u64()).unwrap_or(0),
                ..Usage::default()
            })
            .unwrap_or_default();

        Ok(LlmResponse { content, stop_reason, usage })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_core::Message;

    #[test]
    fn images_become_data_urls() {
        let blocks = vec![
            ContentBlock::text("look"),
            ContentBlock::Image {
                source: ImageSource::Base64 { media_type: "image/jpeg".into(), data: "AAA".into() },
            },
        ];
        let v = to_openai_content(&blocks);
        assert_eq!(v[0]["type"], "text");
        assert_eq!(v[1]["type"], "image_url");
        assert_eq!(v[1]["image_url"]["url"], "data:image/jpeg;base64,AAA");
    }

    #[test]
    fn screenshots_inside_tool_results_survive_the_translation() {
        // The agent returns every screenshot inside a tool_result; if that image were dropped the
        // model would be driving blind after the first step.
        let blocks = vec![ContentBlock::tool_result(
            "c1",
            vec![
                ContentBlock::text("screenshot"),
                ContentBlock::Image {
                    source: ImageSource::Base64 {
                        media_type: "image/jpeg".into(),
                        data: "ZZZ".into(),
                    },
                },
            ],
            false,
        )];
        let v = to_openai_content(&blocks);
        assert_eq!(v[1]["type"], "image_url");
        assert!(v[1]["image_url"]["url"].as_str().unwrap().ends_with("ZZZ"));
    }

    #[test]
    fn tool_calls_and_results_map_to_openai_roles() {
        let messages = vec![
            Message::user(vec![ContentBlock::text("do it")]),
            Message::assistant(vec![ContentBlock::ToolUse {
                id: "c1".into(),
                name: "computer".into(),
                input: json!({"action": "screenshot"}),
            }]),
            Message::user(vec![ContentBlock::tool_result(
                "c1",
                vec![ContentBlock::text("ok")],
                false,
            )]),
        ];
        let out = to_openai_messages("sys", &messages);
        assert_eq!(out[0]["role"], "system");
        assert_eq!(out[1]["role"], "user");
        assert_eq!(out[2]["role"], "assistant");
        assert_eq!(out[2]["tool_calls"][0]["function"]["name"], "computer");
        assert_eq!(out[3]["role"], "tool");
        assert_eq!(out[3]["tool_call_id"], "c1");
    }

    #[test]
    fn grok_preset_points_at_xai_and_needs_a_key() {
        let g = provider("grok").expect("grok preset");
        assert_eq!(g.base_url, "https://api.x.ai/v1");
        assert_eq!(g.default_model, "grok-4.5");
        assert!(g.needs_key);
        // Without a key we must fail loudly rather than fire an unauthenticated request.
        // (No `unwrap_err` — the client deliberately has no Debug impl, because deriving one on a
        // struct holding an API key is exactly how keys end up in logs.)
        match OpenAiCompatClient::from_provider(g, None, Some("")) {
            Err(e) => assert!(e.to_string().contains("XAI_API_KEY"), "unexpected: {e}"),
            Ok(_) => panic!("a keyless Grok client should not be constructible"),
        }
        assert!(matches!(OpenAiCompatClient::from_provider(g, None, Some("xai-test")), Ok(_)));
    }

    #[test]
    fn local_providers_need_no_key() {
        let o = provider("ollama").expect("ollama preset");
        assert!(!o.needs_key);
        assert!(matches!(OpenAiCompatClient::from_provider(o, Some("llava"), None), Ok(_)));
    }

    #[test]
    fn the_builtin_computer_tool_gets_a_schema() {
        let tools = vec![json!({"type": "computer_20251124", "name": "computer"})];
        let out = to_openai_tools(&tools);
        assert_eq!(out[0]["function"]["name"], "computer");
        assert_eq!(out[0]["function"]["parameters"]["required"][0], "action");
    }
}
