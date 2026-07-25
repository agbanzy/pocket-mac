# Pocket Mac agent on Windows

The same agent that runs on the Mac, as a single Windows executable. It sees your screen, decides
what to do with Claude, and drives the mouse and keyboard — plus MCP tools and durable task history.

## Install

Download `pocketmac-agent.exe` and put it somewhere on your `PATH`. There is no installer and no
runtime to install: everything is in the one file.

Set your Anthropic API key once:

```powershell
setx ANTHROPIC_API_KEY "sk-ant-..."
```

## Use

```powershell
pocketmac-agent "open Notepad and write today's date"
pocketmac-agent --history          # past tasks and how they ended
pocketmac-agent --persona "Be terse." "summarise what is on screen"
```

Progress streams as it happens:

```
▶ open Notepad and write today's date
… I'll open the Start menu and launch Notepad.
→ pressed cmd
→ typed "notepad"
✔ Notepad is open with today's date.
```

Stop a run with `Ctrl+C`.

## What it needs

- **Windows 10 or 11**, x64.
- **No admin rights.** The agent uses `SendInput` and normal screen capture, so it runs as you.
- Windows may show a SmartScreen warning the first time, because the binary is not yet signed with
  an EV certificate — choose *More info → Run anyway*, or sign it yourself.

**A UAC prompt cannot be automated.** Windows blocks synthetic input to elevated windows by design,
so a task that triggers UAC will stall there; approve it yourself and the agent continues.

## MCP tools

Drop `mcp.json` next to the task history, at `%APPDATA%\PocketMac\mcp.json`:

```json
{ "servers": [
  { "id": "fs", "command": "npx",
    "args": ["-y", "@modelcontextprotocol/server-filesystem", "C:\\Users\\you\\Documents"] }
] }
```

Each server's tools become `fs__read_file` and so on, available to the agent alongside the screen.
A server that fails to start is skipped, never fatal to a task.

Task history lives in `%APPDATA%\PocketMac\tasks`.

## Building it yourself

On Windows, with the MSVC build tools:

```powershell
cargo build --release -p agent-cli
# target\release\pocketmac-agent.exe
```

From macOS or Linux, cross-compile with mingw-w64 (`brew install mingw-w64`):

```bash
cargo build --release -p agent-cli --target x86_64-pc-windows-gnu
# target/x86_64-pc-windows-gnu/release/pocketmac-agent.exe
```

Both produce the same agent; the cross-built one uses the GNU ABI rather than MSVC. `.cargo/config.toml`
already points that target at the mingw linker.
