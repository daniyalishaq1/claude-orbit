#!/bin/zsh -f
# Claude Orbit installer. Safe to re-run. `./install.sh --uninstall` reverses everything
# except your accounts in ~/.claude-accounts (delete that folder yourself if you want).
set -u
REPO=${0:A:h}
BIN=$HOME/.local/bin
ZSHRC=$HOME/.zshrc
CONDUCTOR_SETTINGS=${CONDUCTOR_SETTINGS:-$HOME/.conductor/settings.toml}
AGENT_LABEL=local.claude-orbit.menubar
AGENT=$HOME/Library/LaunchAgents/$AGENT_LABEL.plist
APP_DEST=$HOME/Applications/Claude\ Orbit.app
MARK_BEGIN="# >>> claude-orbit >>>"
MARK_END="# <<< claude-orbit <<<"
HOOK=$REPO/shell/claude-orbit.zsh
# Names used before the project was called Claude Orbit; cleaned up on install and uninstall.
OLD_AGENT_LABEL=local.claude-accounts.menubar
OLD_APP=$HOME/Applications/Claude\ Accounts.app
OLD_MARK_BEGIN="# >>> claude-accounts >>>"
OLD_MARK_END="# <<< claude-accounts <<<"
STAMP=$(date +%Y%m%d-%H%M%S)

say() { print -r -- "• $*"; }
backup() { [[ -f $1 && ! -f $1.bak-$STAMP ]] && cp -p "$1" "$1.bak-$STAMP"; }

# Removes one marked block (and the blank line before it) from ~/.zshrc, if it is there.
strip_block() {
  grep -qF "$1" $ZSHRC 2>/dev/null || return 1
  /usr/bin/python3 -I -c 'import re,sys; p=sys.argv[1]; s=open(p).read(); b,e=map(re.escape,sys.argv[2:4]); open(p,"w").write(re.sub("\n?"+b+"\n.*?"+e+"\n?", "", s, flags=re.S))' \
    $ZSHRC "$1" "$2"
}

remove_old_names() {
  launchctl bootout gui/$UID/$OLD_AGENT_LABEL >/dev/null 2>&1
  rm -f $HOME/Library/LaunchAgents/$OLD_AGENT_LABEL.plist
  [[ -d $OLD_APP ]] && { pkill -f "$OLD_APP/Contents/MacOS/" >/dev/null 2>&1; rm -rf "$OLD_APP"; }
  if grep -qF "$OLD_MARK_BEGIN" $ZSHRC 2>/dev/null; then backup $ZSHRC; strip_block "$OLD_MARK_BEGIN" "$OLD_MARK_END"; fi
}

stop() { print -u2 -r -- ""; print -u2 -r -- "✗ $1"; shift; for l in "$@"; do print -u2 -r -- "  $l"; done; exit 1; }

install_all() {
  local major=${$(sw_vers -productVersion 2>/dev/null)%%.*}
  [[ -n $major && $major -lt 14 ]] && stop "Claude Orbit needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."
  if [[ -z ${INSTALL_SKIP_BUILD:-} ]] && ! xcrun --find swiftc >/dev/null 2>&1; then
    stop "Apple's Command Line Tools are needed to build the menu-bar app." \
         "1. Run:  xcode-select --install" \
         "2. Click Install in the window that opens and wait for it to finish (a few minutes)." \
         "3. Run ./install.sh again."
  fi

  mkdir -p $BIN
  for f in claude-switch claude-for-conductor; do ln -sfn $REPO/bin/$f $BIN/$f; done
  say "Linked claude-switch and claude-for-conductor into $BIN"

  remove_old_names
  # One line in ~/.zshrc loads the hook. If this folder was moved, point the line at its new place.
  if ! grep -qF "source \"$HOOK\"" $ZSHRC 2>/dev/null; then
    backup $ZSHRC
    strip_block "$MARK_BEGIN" "$MARK_END"
    printf '\n%s\nsource "%s"\n%s\n' "$MARK_BEGIN" "$HOOK" "$MARK_END" >> $ZSHRC
    say "Added the account hook to $ZSHRC (open a new terminal to use it)"
  fi

  if [[ -f $CONDUCTOR_SETTINGS ]]; then
    local want="claude_code_executable_path = \"$BIN/claude-for-conductor\""
    if grep -q '^claude_code_executable_path' $CONDUCTOR_SETTINGS; then
      grep -qxF "$want" $CONDUCTOR_SETTINGS || say "Conductor already uses a custom Claude path; left it alone"
    else
      backup $CONDUCTOR_SETTINGS
      # top-level keys must come before the first [table]
      /usr/bin/awk -v line="$want" 'done == 0 && /^\[/ { print line; print ""; done = 1 } { print } END { if (done == 0) print line }' \
        $CONDUCTOR_SETTINGS > $CONDUCTOR_SETTINGS.tmp && mv $CONDUCTOR_SETTINGS.tmp $CONDUCTOR_SETTINGS
      say "Pointed Conductor at the account-aware launcher (restart Conductor once)"
    fi
  fi

  if [[ -z ${INSTALL_SKIP_BUILD:-} ]]; then
    local log=${TMPDIR:-/tmp}/claude-orbit-build.log
    $REPO/app/build.sh >$log 2>&1 || { tail -15 $log >&2; stop "Building the menu-bar app failed. The full output is in $log"; }
    mkdir -p $HOME/Applications
    rm -rf "$APP_DEST"; /usr/bin/ditto "$REPO/app/build/Claude Orbit.app" "$APP_DEST"
    say "Installed $APP_DEST"
  fi

  mkdir -p ${AGENT:h}
  cat > $AGENT <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_LABEL</string>
  <key>ProgramArguments</key><array><string>$APP_DEST/Contents/MacOS/ClaudeOrbit</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
  launchctl bootout gui/$UID/$AGENT_LABEL >/dev/null 2>&1
  pkill -f "$APP_DEST/Contents/MacOS/ClaudeOrbit" >/dev/null 2>&1   # never run two copies
  sleep 0.5
  launchctl bootstrap gui/$UID $AGENT >/dev/null 2>&1
  say "Menu-bar app starts at login"

  $BIN/claude-switch setup >/dev/null 2>&1 || mkdir -p $HOME/.claude-accounts
  say "Installed."
  if ! PATH=$PATH:$BIN:/opt/homebrew/bin:/usr/local/bin command -v claude >/dev/null 2>&1; then
    print -r -- ""
    print -r -- "Claude Code itself isn't installed yet. Get it from https://claude.com/claude-code, then carry on below."
  fi
  print -r -- ""
  print -r -- "Next:"
  print -r -- "  1. Click the new Claude Orbit icon in the menu bar (top right of your screen)."
  print -r -- "  2. Choose Add Account…, give it a name, press Log In… and approve in your browser."
  print -r -- "  3. Do the same for each account, then press Done."
  print -r -- ""
  print -r -- "Open a new terminal window to use the cnext and claude-switch commands."
  print -r -- "Keep this folder ($REPO): the app and the commands run from it."
}

uninstall_all() {
  remove_old_names
  launchctl bootout gui/$UID/$AGENT_LABEL >/dev/null 2>&1
  launchctl unsetenv CLAUDE_CONFIG_DIR >/dev/null 2>&1
  rm -f $AGENT
  rm -rf "$APP_DEST"
  local keep_wrapper=""
  if [[ -f $CONDUCTOR_SETTINGS ]]; then
    # drop our key however it is formatted, plus the blank line we added after it
    /usr/bin/python3 -I -c 'import re,sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(re.sub(r"(?m)^claude_code_executable_path\s*=\s*\"[^\"]*claude-for-conductor\"[ \t]*\n(\n)?", "", s))' $CONDUCTOR_SETTINGS
    if grep -q 'claude-for-conductor' $CONDUCTOR_SETTINGS; then
      keep_wrapper=1
      say "Couldn't remove the Conductor setting in $CONDUCTOR_SETTINGS; kept claude-for-conductor so Conductor keeps working"
    fi
  fi
  for f in claude-switch claude-for-conductor; do
    [[ $f == claude-for-conductor && -n $keep_wrapper ]] && continue
    [[ -L $BIN/$f && $(readlink $BIN/$f) == $REPO/bin/$f ]] && rm -f $BIN/$f
  done
  strip_block "$MARK_BEGIN" "$MARK_END"   # exactly what install added: one blank line + the marked block
  say "Uninstalled. Your accounts are still in ~/.claude-accounts."
}

case ${1:-} in
  --uninstall) uninstall_all ;;
  "") install_all ;;
  *) print -u2 "usage: install.sh [--uninstall]"; exit 2 ;;
esac
