//! The one agent loop, shared by every platform: capture → ask the model → run the action on this
//! machine → repeat, streaming progress and persisting the task. Depends only on the seams
//! (`ComputerBackend`, `LlmClient`, `ToolRegistry`, `TaskStore`, `Emitter`), never on an OS or HTTP.

use crate::backend::{computer_tool_schema, ComputerBackend};
use crate::llm::{ContentBlock, LlmClient, LlmRequest, Message};
use crate::task::{TaskStatus, TaskStore};
use crate::tool::ToolRegistry;
use crate::types::{Action, AgentError, EventKind, Result, TaskEvent};
use async_trait::async_trait;
use std::sync::atomic::{AtomicBool, Ordering};

/// Streams progress to the controller (phone/web). A platform impl forwards these over the wire.
#[async_trait]
pub trait Emitter: Send + Sync {
    async fn emit(&self, event: TaskEvent);
}

#[derive(Clone, Debug)]
pub struct AgentConfig {
    pub model: String,
    pub max_tokens: u32,
    pub max_iterations: usize,
    pub beta: String,
    /// How many recent screenshots to keep before eliding older ones (bounds token cost).
    pub keep_images: usize,
    /// Persona/instructions prepended to the system prompt (the "JARVIS" layer plugs in here).
    pub persona: Option<String>,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            model: "claude-opus-4-8".into(),
            max_tokens: 4096,
            max_iterations: 60,
            beta: "computer-use-2025-11-24".into(),
            keep_images: 3,
            persona: None,
        }
    }
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        s.chars().take(n).collect()
    }
}

fn system_prompt(cfg: &AgentConfig, w: u32, h: u32) -> String {
    let mut s = String::new();
    if let Some(p) = &cfg.persona {
        s.push_str(p);
        s.push_str("\n\n");
    }
    s.push_str(&format!(
        "You operate a real computer on the user's behalf via the computer tool. Screenshots are \
         {w}x{h} px; give coordinates in that space. Use the platform's own conventions for \
         shortcuts. Work in small steps; after each action take a screenshot and verify. When the \
         task is complete, stop and give a one-line summary. If unsure or the task is risky, say so \
         instead of guessing."
    ));
    s
}

fn describe(action: &Action) -> String {
    match action {
        Action::Type { text } => format!("typed \"{}\"", truncate(text, 40)),
        Action::Key { text } => format!("pressed {text}"),
        Action::Scroll { scroll_direction, .. } => format!("scrolled {scroll_direction}"),
        Action::LeftClick { coordinate, .. } => format!("clicked {coordinate:?}"),
        Action::Screenshot => "took a screenshot".into(),
        other => format!("{other:?}"),
    }
}

/// Replace all but the last `keep` images (in user turns / tool_results) with a text stub.
fn prune_images(messages: &mut [Message], keep: usize) {
    // Collect (message idx, block idx, inner idx or None) of every image, in order.
    let mut spots: Vec<(usize, usize, Option<usize>)> = Vec::new();
    for (mi, msg) in messages.iter().enumerate() {
        if msg.role != "user" {
            continue;
        }
        for (bi, block) in msg.content.iter().enumerate() {
            match block {
                ContentBlock::Image { .. } => spots.push((mi, bi, None)),
                ContentBlock::ToolResult { content, .. } => {
                    for (ii, inner) in content.iter().enumerate() {
                        if matches!(inner, ContentBlock::Image { .. }) {
                            spots.push((mi, bi, Some(ii)));
                        }
                    }
                }
                _ => {}
            }
        }
    }
    if spots.len() <= keep {
        return;
    }
    for &(mi, bi, ii) in &spots[..spots.len() - keep] {
        match ii {
            None => messages[mi].content[bi] = ContentBlock::text("[screenshot elided]"),
            Some(ii) => {
                if let ContentBlock::ToolResult { content, .. } = &mut messages[mi].content[bi] {
                    content[ii] = ContentBlock::text("[screenshot elided]");
                }
            }
        }
    }
}

struct Ctx<'a> {
    store: &'a dyn TaskStore,
    emitter: &'a dyn Emitter,
    id: String,
}

impl<'a> Ctx<'a> {
    async fn emit(&self, kind: EventKind, text: impl Into<String>) {
        let ev = TaskEvent { kind, text: text.into() };
        let _ = self.store.append(&self.id, &ev).await;
        self.emitter.emit(ev).await;
    }
}

/// Run one task to completion. `cancel` is polled between steps (Stop from the controller).
#[allow(clippy::too_many_arguments)]
pub async fn run(
    cfg: &AgentConfig,
    backend: &dyn ComputerBackend,
    registry: &ToolRegistry,
    llm: &dyn LlmClient,
    store: &dyn TaskStore,
    emitter: &dyn Emitter,
    prompt: &str,
    cancel: &AtomicBool,
) -> Result<String> {
    let id = store.create(prompt).await?;
    store.set_status(&id, TaskStatus::Running).await?;
    let ctx = Ctx { store, emitter, id: id.clone() };
    ctx.emit(EventKind::Started, prompt.to_string()).await;

    let (w, h) = backend.model_size();
    let system = system_prompt(cfg, w, h);
    let mut tools = vec![computer_tool_schema(w, h, true)];
    tools.extend(registry.schemas());

    let first = backend.capture().await?;
    let mut messages = vec![Message::user(vec![
        ContentBlock::text(prompt),
        ContentBlock::image(&first),
    ])];

    for _ in 0..cfg.max_iterations {
        if cancel.load(Ordering::Relaxed) {
            ctx.emit(EventKind::Error, "Stopped.").await;
            store.set_status(&id, TaskStatus::Cancelled).await?;
            return Err(AgentError::Cancelled);
        }

        let req = LlmRequest {
            model: cfg.model.clone(),
            max_tokens: cfg.max_tokens,
            system: system.clone(),
            tools: tools.clone(),
            messages: messages.clone(),
            beta: Some(cfg.beta.clone()),
            cache: true,
        };
        let resp = llm.complete(&req).await?;

        let text: String = resp
            .content
            .iter()
            .filter_map(|b| match b {
                ContentBlock::Text { text } => Some(text.clone()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(" ");
        if !text.is_empty() {
            ctx.emit(EventKind::Thinking, truncate(&text, 240)).await;
        }
        messages.push(Message::assistant(resp.content.clone()));

        if resp.stop_reason != "tool_use" {
            let summary = if text.is_empty() { "Done.".to_string() } else { truncate(&text, 240) };
            ctx.emit(EventKind::Done, summary.clone()).await;
            store.set_status(&id, TaskStatus::Done).await?;
            return Ok(summary);
        }

        let mut results: Vec<ContentBlock> = Vec::new();
        for block in &resp.content {
            let ContentBlock::ToolUse { id: tuid, name, input } = block else { continue };
            if cancel.load(Ordering::Relaxed) {
                ctx.emit(EventKind::Error, "Stopped.").await;
                store.set_status(&id, TaskStatus::Cancelled).await?;
                return Err(AgentError::Cancelled);
            }

            if name == "computer" {
                match serde_json::from_value::<Action>(input.clone()) {
                    Ok(action) => {
                        // The backend settles focus-changing actions before returning, so the
                        // capture below sees the post-action state.
                        let read = backend.execute(&action).await?;
                        ctx.emit(EventKind::Action, describe(&action)).await;
                        if let Some(txt) = read {
                            results.push(ContentBlock::tool_result(tuid, vec![ContentBlock::text(txt)], false));
                        } else {
                            let shot = backend.capture().await?;
                            results.push(ContentBlock::tool_result(
                                tuid,
                                vec![ContentBlock::text("screenshot"), ContentBlock::image(&shot)],
                                false,
                            ));
                        }
                    }
                    Err(e) => results.push(ContentBlock::tool_result(
                        tuid,
                        vec![ContentBlock::text(format!("could not parse action: {e}"))],
                        true,
                    )),
                }
            } else if let Some(tool) = registry.find(name) {
                match tool.call(input).await {
                    Ok(content) => results.push(ContentBlock::tool_result(tuid, content, false)),
                    Err(e) => results.push(ContentBlock::tool_result(
                        tuid,
                        vec![ContentBlock::text(format!("tool error: {e}"))],
                        true,
                    )),
                }
            } else {
                results.push(ContentBlock::tool_result(
                    tuid,
                    vec![ContentBlock::text(format!("unknown tool: {name}"))],
                    true,
                ));
            }
        }

        messages.push(Message::user(results));
        prune_images(&mut messages, cfg.keep_images);
    }

    ctx.emit(EventKind::Error, "Reached the step limit.").await;
    store.set_status(&id, TaskStatus::Failed).await?;
    Err(AgentError::StepLimit)
}
