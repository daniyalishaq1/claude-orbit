# Claude Orbit: notes for Claude

This repository is a small Mac tool that lets one person use several Claude accounts with Claude Code and switch between them from the menu bar. People often ask you to install or fix it for them, and many of them don't code. Explain each step in plain words and say what they will see on screen.

## Installing it for someone

1. Check the Mac: `sw_vers -productVersion` must be 14 or later, and `command -v claude` should find Claude Code. If Claude Code is missing, send them to https://claude.com/claude-code first.
2. The folder should live at `~/claude-orbit` and must stay there: the app and the commands run from it. If it was cloned somewhere temporary, move it before installing.
3. Run `./install.sh` from the folder. It is safe to run again.
4. If it stops with "Apple's Command Line Tools are needed": run `xcode-select --install`, tell the person to click **Install** in the window that opens and to wait until it finishes (several minutes), then run `./install.sh` again. Don't try to work around this.
5. When it finishes, give them the next steps:
   - Click the new Claude Orbit icon in the menu bar, at the top right of the screen.
   - Click **Add Account…**, type a name such as "Work", and sign in to that Claude account in the browser window that opens.
   - Do the same for each other account, then press **Done**.
   - Open a new terminal window before using `cnext` or `claude-switch`.

You can't sign in for them. The browser sign-in is theirs to do.

## Checking that it works

- `pgrep -fl "Claude Orbit.app"` shows the menu-bar app running.
- `~/.local/bin/claude-switch` lists the accounts and marks the active one.
- In a new terminal, `echo $CLAUDE_CONFIG_DIR` points into `~/.claude-accounts/` once an account is signed in.

## Fixing problems

- No menu-bar icon: run `./install.sh` again; then check `launchctl print gui/$UID/local.claude-orbit.menubar`.
- Build failed: the installer prints the last lines of the build log and its path. Read that before changing anything.
- `claude-switch` not found: the terminal was opened before installing. Open a new one. The hook is the marked block in `~/.zshrc`.
- An account shows "Not signed in": `claude-switch login <id>`, or **Log In…** in the menu.
- Updating: `claude-switch update`, or `git pull` then `./install.sh`.
- Removing: `./install.sh --uninstall`. It leaves `~/.claude-accounts` in place.

## Rules

- Never read, copy or edit keychain items or login tokens. The whole design is that Claude Code manages each account's login itself, in its own `CLAUDE_CONFIG_DIR` folder. `README.md` explains this under "How it works".
- Never delete `~/.claude-accounts` or an account folder inside it unless the person asks. Removing an account signs it out.
- `~/.claude` is the shared home that every account links to. Don't move or replace it.

## Working on the code

- `./test.sh` runs every test; nothing real is touched. Run it before you call a change done.
- All account logic is in `cli/claude_switch.py`. The app in `app/Sources` only calls `claude-switch … --json`.
- `app/build.sh` builds the app. The README's Development section explains the preview window used to screenshot the menu; check visual changes there on Liquid Glass, over both a light and a dark backdrop.
