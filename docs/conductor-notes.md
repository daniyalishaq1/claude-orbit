# Conductor notes

How [Conductor](https://conductor.build) runs Claude Code, as observed on Conductor 0.94.2. These are the facts
`claude-for-conductor` and `claude-switch conductor-move` rely on.

- Each Conductor Claude chat is a long-lived process:
  `<support>/agent-binaries/claude/<ver>/claude ... --session-id=<id>` or `--resume=<id>`.
  Its environment carries `CONDUCTOR_SESSION_ID=<conductor session id>` (visible with `ps -E`).
- Conductor often ends a chat's process after a turn. The next message starts a new process with `--resume=<id>`,
  through the wrapper, on the account that is active at that moment. So a chat continues on the new account
  at its next message, with its history intact.
- With `claude_code_executable_path` pointing at `claude-for-conductor`, Conductor picks up the setting without
  a restart. Every new chat process carries the active account's `CLAUDE_CONFIG_DIR`.
- Processes without `CONDUCTOR_SESSION_ID` (for example `--chrome-native-host`) are helpers, not chats. They are
  never moved.
- Busy signal: `conductor.db` (opened read-only with `?mode=ro`)
  - `sessions.status`: values seen are `idle`, `waiting` (a turn in flight or waiting on the user) and `error`.
  - `session_state.live_state`: JSON `{"status": "idle", "backgroundTasks": [...]}`. A chat can report
    `idle` while subagents or background shells are still running, so a non-empty `backgroundTasks` counts as busy.
  - **idle** = `sessions.status == 'idle'` AND `live_state.status == 'idle'` (or missing) AND no `backgroundTasks`.

## Not yet verified

Whether stopping a chat process that is still running (the panel's "Move N Conductor Chats", used only for chats
whose process stayed alive) keeps the Conductor UI history intact. Conductor usually ends processes after a turn,
so the button is rarely needed. Try it on a throwaway chat before relying on it.
