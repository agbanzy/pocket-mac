//! Find MCP servers the user has already configured for other Claude surfaces, so the agent
//! inherits them instead of asking for the same setup twice.
//!
//! Three sources, in priority order — Pocket Mac's own `mcp.json` wins, then Claude Desktop, then
//! Claude Code. All use the same `{command, args, env}` shape, and duplicates are resolved by name:
//! a server you configured for Pocket Mac deliberately overrides one inherited from elsewhere.

use serde_json::Value;
use std::path::PathBuf;

/// One server to launch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerSpec {
    pub id: String,
    pub command: String,
    pub args: Vec<String>,
    /// Where this came from, so a controller can say "inherited from Claude Code".
    pub origin: &'static str,
}

fn home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// Config files we know about, most-specific first.
fn sources(own_config: Option<PathBuf>) -> Vec<(PathBuf, &'static str)> {
    let mut v = Vec::new();
    if let Some(p) = own_config {
        v.push((p, "Pocket Mac"));
    }
    if let Some(h) = home() {
        v.push((
            h.join("Library/Application Support/Claude/claude_desktop_config.json"),
            "Claude Desktop",
        ));
        v.push((h.join(".claude.json"), "Claude Code"));
    }
    v
}

/// Parse one config file. Accepts both `mcpServers` (Claude's key) and `servers` (ours).
fn parse(value: &Value, origin: &'static str) -> Vec<ServerSpec> {
    let mut out = Vec::new();

    // Claude's shape: { "mcpServers": { "name": { command, args, env } } }
    if let Some(map) = value.get("mcpServers").and_then(|m| m.as_object()) {
        for (name, cfg) in map {
            // Only stdio servers can be launched this way; an HTTP/SSE entry needs a different
            // transport, so skip it rather than spawn something that will never speak.
            let kind = cfg.get("type").and_then(|t| t.as_str()).unwrap_or("stdio");
            if kind != "stdio" {
                continue;
            }
            let Some(command) = cfg.get("command").and_then(|c| c.as_str()) else { continue };
            let args = cfg
                .get("args")
                .and_then(|a| a.as_array())
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            out.push(ServerSpec {
                id: name.clone(),
                command: command.to_string(),
                args,
                origin,
            });
        }
    }

    // Our shape: { "servers": [ { id, command, args } ] }
    if let Some(list) = value.get("servers").and_then(|s| s.as_array()) {
        for cfg in list {
            let (Some(id), Some(command)) = (
                cfg.get("id").and_then(|v| v.as_str()),
                cfg.get("command").and_then(|v| v.as_str()),
            ) else {
                continue;
            };
            let args = cfg
                .get("args")
                .and_then(|a| a.as_array())
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect())
                .unwrap_or_default();
            out.push(ServerSpec { id: id.to_string(), command: command.to_string(), args, origin });
        }
    }

    out
}

/// Every stdio MCP server this machine has configured, de-duplicated by name with earlier sources
/// winning. `own_config` is Pocket Mac's own `mcp.json`, if it has one.
pub fn discover_servers(own_config: Option<PathBuf>) -> Vec<ServerSpec> {
    let mut found: Vec<ServerSpec> = Vec::new();
    for (path, origin) in sources(own_config) {
        let Ok(bytes) = std::fs::read(&path) else { continue };
        let Ok(value) = serde_json::from_slice::<Value>(&bytes) else {
            eprintln!("pocketmac: {} is not valid JSON; ignoring", path.display());
            continue;
        };
        for spec in parse(&value, origin) {
            if !found.iter().any(|s| s.id == spec.id) {
                found.push(spec);
            }
        }
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_claudes_mcp_servers_shape() {
        let cfg = json!({
            "mcpServers": {
                "desktop-commander": { "command": "npx", "args": ["-y", "@wonderwhy-er/desktop-commander"], "type": "stdio" },
                "puppeteer": { "command": "/usr/local/bin/puppeteer-mcp", "type": "stdio" }
            }
        });
        let mut got = parse(&cfg, "Claude Code");
        got.sort_by(|a, b| a.id.cmp(&b.id));
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].id, "desktop-commander");
        assert_eq!(got[0].args, vec!["-y", "@wonderwhy-er/desktop-commander"]);
        assert_eq!(got[1].args, Vec::<String>::new()); // args are optional
        assert_eq!(got[0].origin, "Claude Code");
    }

    #[test]
    fn skips_non_stdio_servers_rather_than_spawning_them() {
        // An HTTP/SSE server has no command to run; launching one would hang forever.
        let cfg = json!({
            "mcpServers": {
                "remote": { "type": "sse", "url": "https://example.com/sse" },
                "local": { "type": "stdio", "command": "npx" }
            }
        });
        let got = parse(&cfg, "test");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, "local");
    }

    #[test]
    fn our_own_config_wins_over_an_inherited_server_of_the_same_name() {
        let dir = std::env::temp_dir().join(format!("pm-mcp-disc-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let own = dir.join("mcp.json");
        std::fs::write(
            &own,
            json!({ "servers": [ { "id": "files", "command": "mine" } ] }).to_string(),
        )
        .unwrap();

        let specs = discover_servers(Some(own));
        let files: Vec<_> = specs.iter().filter(|s| s.id == "files").collect();
        assert_eq!(files.len(), 1, "a name must resolve to exactly one server");
        assert_eq!(files[0].command, "mine");
        assert_eq!(files[0].origin, "Pocket Mac");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
