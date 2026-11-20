# Remindo

A notch companion for coding agents. Remindo lives in your MacBook's notch and tells you,
with an animated Claude spark, when Claude Code is **cooking**, **needs your approval**,
**has a question**, or **finished**. It reminds you again whenever you switch apps,
change Spaces, or wake the screen while something is still waiting on you.

```
 working        ✳ ▬▬▬▬▬▬ notch ▬▬▬▬▬▬ 2:14
 needs you      ✳ ▬▬▬▬▬▬ notch ▬▬▬▬▬▬ ✋      → drops a card: "Needs your approval · Run: npm install"
 finished       ✳ ▬▬▬▬▬▬ notch ▬▬▬▬▬▬ ✓       → "Finished cooking · Added the login page…" + a sound
```

- **Hover** the notch to see every session. **Click** a session to jump back to its app
  (Terminal, iTerm, VS Code, Cursor, the Claude app…).
- Works for Claude Code in any terminal or IDE, and inside the **Claude desktop app** (Code tab).
- Any other agent can plug in through the `remindo` CLI.

## Install

```bash
./scripts/install.sh
```

This builds the app, puts it in `~/Applications/Remindo.app`, installs the CLI at
`~/.remindo/bin/remindo`, links Claude Code (adds hooks to `~/.claude/settings.json`,
after saving a timestamped backup next to it), and launches Remindo.
Set `REMINDO_SKIP_CLAUDE=1` to skip the linking.

New Claude Code sessions pick up the hooks automatically; restart sessions that were already open.

Try it:

```bash
~/.remindo/bin/remindo test
```

Requirements: macOS 14+, Xcode or the Command Line Tools (Swift 5.10+), and `jq`
(built into macOS 15+) for linking Claude Code.

## The menu bar spark

- Preview every animation
- Remind me when I switch apps or Spaces
- Show live activity while agents work
- Repeat reminders for approvals (every 90 s while you're elsewhere)
- Remind me even inside the agent's app
- Play sounds
- Show on the notch display, or on whichever display is active
- Launch at login
- Link / unlink Claude Code

## Linking other agents

Remindo understands Claude Code style hook JSON from any agent:

```bash
# Any agent that can run a command with hook JSON on stdin
some-agent-hook | ~/.remindo/bin/remindo hook my-agent
```

**Codex CLI**: add to `~/.codex/config.toml`:

```toml
notify = ["/Users/YOU/.remindo/bin/remindo", "hook", "codex"]
```

**Anything else** (scripts, CI, other tools):

```bash
remindo notify --agent my-build --state working --message "Compiling…"
remindo notify --agent my-build --state done --title "Build finished" --message "All tests pass"
remindo notify --agent my-bot --state approval --message "Deploy to production?"
```

States: `working`, `done`, `approval`, `waiting`, `error`, `idle`, `end`.

Raw HTTP (loopback only; needs the `X-Remindo-Client` header and your private token from
`~/.remindo/token`; browser requests are refused):

```bash
curl --noproxy '*' -H 'X-Remindo-Client: me' -H "X-Remindo-Token: $(cat ~/.remindo/token)" \
     --data-urlencode state=done --data-urlencode message=Shipped \
     "http://127.0.0.1:$(cat ~/.remindo/port)/v1/event"
```

## CLI

```
remindo hook <agent> [json]   forward a hook payload (stdin or argument)
remindo notify ...            generic status update
remindo status                what Remindo is tracking
remindo test [scenario]       demo | working | approval | question | done | error
remindo doctor                check the setup
remindo install-claude        link Claude Code
remindo uninstall-claude      unlink Claude Code
```

## How it works

```
Claude Code ──hook──▶ ~/.remindo/bin/remindo ──HTTP 127.0.0.1:47474──▶ Remindo.app ──▶ notch
```

- Hooks used: SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse,
  PostToolUseFailure, PermissionDenied, Notification, Elicitation, Stop, StopFailure,
  SubagentStart, SubagentStop, PreCompact, SessionEnd. The frequent tool hooks run with
  `async: true`, so they never slow Claude down. The CLI never prints anything and always
  exits 0, even when Remindo isn't running.
- Remindo finds the app hosting each session by walking the process tree, so clicking the
  notch brings you back to the right app.
- Esc-interrupted turns are detected from the session transcript, so nothing stays stuck on "cooking".
- Everything stays on your Mac. The server only listens on 127.0.0.1.

## Development

```bash
swift build                                   # debug build
.build/debug/Remindo                          # run without installing
.build/debug/Remindo --snapshot /tmp/remindo  # render every notch state to PNGs
./scripts/build.sh                            # build/Remindo.app
```

Port: `defaults write dev.remindo.Remindo port 47474` (then restart Remindo).

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the Claude Code hooks, the login item, the app, `~/.remindo` and the preferences.
