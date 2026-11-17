# Claude Orbit: zsh integration. Sourced from ~/.zshrc.
# Before every prompt, point CLAUDE_CONFIG_DIR at the active account, so every new
# `claude` uses whichever account the menu bar / claude-switch selected.

# claude-switch is linked into ~/.local/bin; make sure this terminal can find it.
[[ :$PATH: == *:$HOME/.local/bin:* ]] || export PATH=$PATH:$HOME/.local/bin

_claude_accounts_env() {
  local home=${CLAUDE_ACCOUNTS_HOME:-$HOME/.claude-accounts}
  [[ -r $home/active ]] || return 0
  local id=$(<$home/active)
  id=${id//[[:space:]]/}
  if [[ -n $id && -d $home/$id ]]; then
    export CLAUDE_CONFIG_DIR=$home/$id
  else
    unset CLAUDE_CONFIG_DIR
    print -u2 "claude-orbit: active account folder missing ($id). Run: claude-switch setup"
  fi
}

# Remember which account this terminal's last `claude` ran on, so `cnext` can tell whether
# another terminal (or Conductor) already moved everyone to the next account.
_claude_accounts_preexec() {
  [[ $1 == claude || $1 == "claude "* ]] && _claude_accounts_last=${CLAUDE_CONFIG_DIR:t}
}

# Out of usage? Move to the next account and pick the conversation back up.
cnext() {
  claude-switch next ${_claude_accounts_last:+--from=$_claude_accounts_last} || return
  _claude_accounts_env
  _claude_accounts_last=${CLAUDE_CONFIG_DIR:t}
  claude --continue "$@"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _claude_accounts_env
add-zsh-hook preexec _claude_accounts_preexec
_claude_accounts_env
