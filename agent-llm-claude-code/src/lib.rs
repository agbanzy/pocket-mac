//! Drive the agent from your **Claude subscription** instead of a metered API key, by shelling out
//! to the Claude Code CLI in headless mode (`claude -p`). Claude Code is included with Pro and Max,
//! and it authenticates as you, so no `ANTHROPIC_API_KEY` is involved.
//!
//! ## How it differs from the API client
//!
//! The Messages API gives us native `tool_use` blocks. The CLI does not — it is an agent wrapping a
//! model, and it answers in prose. So this adapter:
//!
//! 1. writes the newest screenshot to a temp file and points the CLI at it (verified: headless
//!    Claude Code reads image files and describes them accurately),
//! 2. asks for **one** action as strict JSON, and
//! 3. parses that back into the `tool_use` block the agent loop expects.
//!
//! Honest trade-offs, since they decide whether you'd want this:
//!
//! * **Slower.** Every turn spawns a process and pays the CLI's own startup and context, so expect
//!   seconds of overhead per step on top of model latency.
//! * **Less precise.** JSON-in-prose is more fragile than a native tool call; malformed output is
//!   recovered where it can be and reported otherwise, never silently mis-clicked.
//! * **Its own harness.** Claude Code injects its own system prompt and tools, so behaviour won't
//!   match the raw API exactly.
//!
//! Use it when you'd rather spend a subscription you already pay for than per-token API credit.

use agent_core::{
    AgentError, ContentBlock, ImageSource, LlmClient, LlmRequest, LlmResponse, Result, Usage,
};
use async_trait::async_trait;
use base64::Engine as _;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Stdio;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

/// Is the CLI installed and on PATH? Lets a controller offer this provider only when it exists.
pub fn available() -> bool {
    std::process::Command::new("claude")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

pub struct ClaudeCodeClient {
    /// Optional model override passed through to the CLI (`--model`).
    model: Option<String>,
    binary: String,
}

impl Default for ClaudeCodeClient {
    fn default() -> Self {
        Self::new()
    }
}

impl ClaudeCodeClient {
    pub fn new() -> Self {
        Self { model: None, binary: "claude".into() }
    }

    pub fn with_model(mut self, model: impl Into<String>) -> Self {
        let m = model.into();
        if !m.is_empty() {
            self.model = Some(m);
        }
        self
    }

    /// For tests, or a CLI installed somewhere unusual.
    pub fn with_binary(mut self, path: impl Into<String>) -> Self {
        self.binary = path.into();
        self
    }
}

/// The newest screenshot in the conversation — the one the model must act on.
fn latest_image(req: &LlmRequest) -> Option<(String, String)> {
    let mut found = None;
    for m in &req.messages {
        for b in &m.content {
            match b {
                ContentBlock::Image { source: ImageSource::Base64 { media_type, data } } => {
                    found = Some((media_type.clone(), data.clone()));
                }
                ContentBlock::ToolResult { content, .. } => {
                    for inner in content {
                        if let ContentBlock::Image {
                            source: ImageSource::Base64 { media_type, data },
                        } = inner
                        {
                            found = Some((media_type.clone(), data.clone()));
                        }
                    }
                }
                _ => {}
            }
        }
    }
    found
}

/// Flatten the conversation into a short text history. The CLI takes a single prompt, not a message
/// array, so the loop's state has to be narrated; images are referenced rather than inlined.
fn history(req: &LlmRequest) -> String {
    let mut out = Vec::new();
    for m in &req.messages {
        for b in &m.content {
            match b {
                ContentBlock::Text { text } if !text.is_empty() => {
                    out.push(format!("{}: {}", m.role, text));
                }
                ContentBlock::ToolUse { input, .. } => out.push(format!("assistant did: {input}")),
                ContentBlock::ToolResult { content, .. } => {
                    for inner in content {
                        if let ContentBlock::Text { text } = inner {
                            if !text.is_empty() && text != "[screenshot elided]" {
                                out.push(format!("result: {text}"));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    // Bounded: the CLI pays for every token of this too.
    let tail: Vec<String> = out.iter().rev().take(12).rev().cloned().collect();
    tail.join("\n")
}

fn instructions(system: &str, screenshot: &str, history: &str) -> String {
    format!(
        "{system}\n\n\
         You are one step of an automation loop that controls this computer.\n\
         Read the image at {screenshot} — that is the CURRENT screen.\n\n\
         Conversation so far:\n{history}\n\n\
         Decide the SINGLE next action and reply with ONLY a JSON object — no prose, no code fence.\n\
         To act:  {{\"action\":\"left_click\",\"coordinate\":[x,y]}}\n\
         Others:  screenshot | mouse_move | double_click | right_click | left_click_drag \
         (start_coordinate+coordinate) | scroll (coordinate+scroll_direction+scroll_amount) | \
         key (text, e.g. \"cmd+space\") | type (text) | wait (duration)\n\
         If the task is already complete, reply instead with: {{\"done\":\"one line summary\"}}\n\
         If you cannot proceed, reply with: {{\"error\":\"why\"}}"
    )
}

/// Pull the first complete JSON object out of the CLI's answer. It is told to emit bare JSON, but
/// models wrap output in fences or prose often enough that failing on that would be needlessly
/// brittle. Brace counting is string-aware so a `}` inside a value doesn't truncate the object.
fn extract_json(text: &str) -> Option<Value> {
    if let Ok(v) = serde_json::from_str::<Value>(text.trim()) {
        return Some(v);
    }
    let bytes = text.as_bytes();
    let start = text.find('{')?;
    let mut depth = 0usize;
    let mut in_str = false;
    let mut escaped = false;
    for (i, &c) in bytes.iter().enumerate().skip(start) {
        if in_str {
            match c {
                b'\\' if !escaped => escaped = true,
                b'"' if !escaped => in_str = false,
                _ => escaped = false,
            }
            continue;
        }
        match c {
            b'"' => in_str = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return serde_json::from_str(&text[start..=i]).ok();
                }
            }
            _ => {}
        }
    }
    None
}

/// Turn the CLI's JSON answer into the response shape the agent loop expects.
pub fn to_response(value: Value) -> LlmResponse {
    if let Some(done) = value.get("done").and_then(|d| d.as_str()) {
        return LlmResponse {
            content: vec![ContentBlock::text(done)],
            stop_reason: "end_turn".into(),
            usage: Usage::default(),
        };
    }
    if let Some(err) = value.get("error").and_then(|d| d.as_str()) {
        return LlmResponse {
            content: vec![ContentBlock::text(format!("Cannot proceed: {err}"))],
            stop_reason: "end_turn".into(),
            usage: Usage::default(),
        };
    }
    LlmResponse {
        content: vec![ContentBlock::ToolUse {
            id: "cc_1".into(),
            name: "computer".into(),
            input: value,
        }],
        stop_reason: "tool_use".into(),
        usage: Usage::default(),
    }
}

#[async_trait]
impl LlmClient for ClaudeCodeClient {
    async fn complete(&self, req: &LlmRequest) -> Result<LlmResponse> {
        // The CLI reads images from disk, so the screenshot has to land in a file.
        let (media_type, data) =
            latest_image(req).ok_or_else(|| AgentError::Llm("no screenshot to act on".into()))?;
        let ext = if media_type.contains("png") { "png" } else { "jpg" };
        let path: PathBuf =
            std::env::temp_dir().join(format!("pocketmac-frame-{}.{ext}", std::process::id()));
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data.as_bytes())
            .map_err(|e| AgentError::Llm(format!("bad screenshot: {e}")))?;
        std::fs::write(&path, bytes).map_err(|e| AgentError::Llm(e.to_string()))?;

        let prompt = instructions(&req.system, &path.to_string_lossy(), &history(req));

        let mut cmd = Command::new(&self.binary);
        cmd.arg("-p")
            .arg("--output-format")
            .arg("json")
            // Read is the only tool it needs: it looks at the screenshot, it does not act on the
            // machine. Every action is performed by the agent loop itself.
            .arg("--allowedTools")
            .arg("Read")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(m) = &self.model {
            cmd.arg("--model").arg(m);
        }

        let mut child = cmd.spawn().map_err(|e| {
            AgentError::Llm(format!(
                "could not run '{}': {e}. Is Claude Code installed?",
                self.binary
            ))
        })?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin
                .write_all(prompt.as_bytes())
                .await
                .map_err(|e| AgentError::Llm(e.to_string()))?;
            stdin.shutdown().await.ok();
        }
        let out = child.wait_with_output().await.map_err(|e| AgentError::Llm(e.to_string()))?;
        let _ = std::fs::remove_file(&path);

        if !out.status.success() {
            return Err(AgentError::Llm(format!("claude exited with {}", out.status)));
        }
        let stdout = String::from_utf8_lossy(&out.stdout);
        let envelope: Value = serde_json::from_str(stdout.trim())
            .map_err(|e| AgentError::Llm(format!("claude returned unparseable output: {e}")))?;
        if envelope.get("is_error").and_then(|v| v.as_bool()).unwrap_or(false) {
            return Err(AgentError::Llm(format!(
                "claude reported an error: {}",
                envelope.get("result").map(|r| r.to_string()).unwrap_or_default()
            )));
        }
        let result = envelope
            .get("result")
            .and_then(|r| r.as_str())
            .ok_or_else(|| AgentError::Llm("claude returned no result field".into()))?;

        let action = extract_json(result).ok_or_else(|| {
            AgentError::Llm(format!(
                "could not find JSON in the reply: {}",
                &result[..result.len().min(160)]
            ))
        })?;
        Ok(to_response(action))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use agent_core::Message;

    #[test]
    fn extracts_json_even_when_wrapped_in_prose_or_fences() {
        let bare = r#"{"action":"left_click","coordinate":[10,20]}"#;
        assert_eq!(extract_json(bare).unwrap()["action"], "left_click");

        let fenced =
            "Here you go:\n```json\n{\"action\":\"type\",\"text\":\"hi\"}\n```\nhope that helps";
        assert_eq!(extract_json(fenced).unwrap()["text"], "hi");

        // A brace inside a string must not end the object early.
        let tricky = r#"prefix {"action":"type","text":"a } b"} suffix"#;
        assert_eq!(extract_json(tricky).unwrap()["text"], "a } b");

        assert!(extract_json("no json at all").is_none());
    }

    #[test]
    fn done_and_error_end_the_task_rather_than_acting() {
        let done = to_response(json!({"done": "Opened Notes."}));
        assert_eq!(done.stop_reason, "end_turn");
        let err = to_response(json!({"error": "the window never appeared"}));
        assert_eq!(err.stop_reason, "end_turn");
    }

    #[test]
    fn an_action_becomes_a_computer_tool_use() {
        let r = to_response(json!({"action": "left_click", "coordinate": [5, 6]}));
        assert_eq!(r.stop_reason, "tool_use");
        match &r.content[0] {
            ContentBlock::ToolUse { name, input, .. } => {
                assert_eq!(name, "computer");
                assert_eq!(input["coordinate"][0], 5);
            }
            other => panic!("expected tool_use, got {other:?}"),
        }
    }

    #[test]
    fn the_newest_screenshot_wins() {
        let req = LlmRequest {
            model: "x".into(),
            max_tokens: 10,
            system: "s".into(),
            tools: vec![],
            messages: vec![
                Message::user(vec![ContentBlock::Image {
                    source: ImageSource::Base64 {
                        media_type: "image/jpeg".into(),
                        data: "OLD".into(),
                    },
                }]),
                Message::user(vec![ContentBlock::tool_result(
                    "c1",
                    vec![ContentBlock::Image {
                        source: ImageSource::Base64 {
                            media_type: "image/jpeg".into(),
                            data: "NEW".into(),
                        },
                    }],
                    false,
                )]),
            ],
            beta: None,
            cache: false,
        };
        // Acting on a stale frame is the classic way an agent clicks the wrong thing.
        assert_eq!(latest_image(&req).unwrap().1, "NEW");
    }
}
