#!/bin/zsh
# zsh tests for shell/claude-orbit.zsh and bin/claude-for-conductor
REPO=${0:A:h:h:h}
RESULTS=$(mktemp /tmp/cs-shell-results-XXXXXX)
check() { local name=$1; shift; if "$@"; then print "PASS $name" >> $RESULTS; else print "FAIL $name" >> $RESULTS; print -u2 "FAIL: $name"; fi; }

new_sandbox() {
  T=$(mktemp -d /tmp/cs-shell-XXXXXX); T=${T:A}; print -r -- $T >> $RESULTS.dirs
  export CLAUDE_ACCOUNTS_HOME=$T/accounts CLAUDE_SHARED_HOME=$T/shared CLAUDE_HOME_JSON=$T/home.json
  export CLAUDE_SWAP_BACKUP=$T/swap CONDUCTOR_SUPPORT=$T/conductor STUB_LOG=$T/stub.log STUB_DIR_OUT=$T/out
  export HOME=$T/home
  mkdir -p $CLAUDE_ACCOUNTS_HOME/{a,b} $CLAUDE_SHARED_HOME $HOME $STUB_DIR_OUT
  print '{"version":1,"accounts":[{"id":"a","label":"A","email":null,"color":"violet"},{"id":"b","label":"B","email":null,"color":"teal"}]}' > $CLAUDE_ACCOUNTS_HOME/accounts.json
  print a > $CLAUDE_ACCOUNTS_HOME/active
  for i in a b; do print '{"loggedIn": true}' > $CLAUDE_ACCOUNTS_HOME/$i/.stub-auth; done
  export PATH=$REPO/cli/tests/stubs:$REPO/bin:$ORIG_PATH
}
ORIG_PATH=$PATH

# --- precmd exports active
( new_sandbox; source $REPO/shell/claude-orbit.zsh
  _claude_accounts_env
  check test_precmd_exports_active test "$CLAUDE_CONFIG_DIR" = "$CLAUDE_ACCOUNTS_HOME/a"
  check test_precmd_hook_registered test "${precmd_functions[(Ie)_claude_accounts_env]}" -gt 0
  )

# --- cnext uses the new account even with a stale exported env
( new_sandbox; source $REPO/shell/claude-orbit.zsh
  export CLAUDE_CONFIG_DIR=$CLAUDE_ACCOUNTS_HOME/a
  cnext "keep going" >/dev/null 2>&1
  check test_cnext_uses_new_account_even_with_stale_env \
    grep -qF "claude CLAUDE_CONFIG_DIR=$CLAUDE_ACCOUNTS_HOME/b --continue keep going" $STUB_LOG
  )

# --- cnext continues on the current account if another shell already switched
( new_sandbox; source $REPO/shell/claude-orbit.zsh
  _claude_accounts_env
  _claude_accounts_preexec "claude fix the bug"       # this shell's claude ran on a
  claude-switch switch b >/dev/null 2>&1               # another terminal hit the limit first
  cnext >/dev/null 2>&1
  check test_cnext_does_not_double_switch test "$(<$CLAUDE_ACCOUNTS_HOME/active)" = b
  check test_cnext_continues_on_current grep -qF "claude CLAUDE_CONFIG_DIR=$CLAUDE_ACCOUNTS_HOME/b --continue" $STUB_LOG
  )

# --- missing account dir unsets and warns
( new_sandbox; source $REPO/shell/claude-orbit.zsh
  export CLAUDE_CONFIG_DIR=/somewhere
  print zzz > $CLAUDE_ACCOUNTS_HOME/active
  err=$(_claude_accounts_env 2>&1 >/dev/null; print -r -- "${CLAUDE_CONFIG_DIR-UNSET}")
  _claude_accounts_env 2>/dev/null
  check test_precmd_missing_dir_unsets test "${CLAUDE_CONFIG_DIR-UNSET}" = UNSET
  check test_precmd_missing_dir_warns test "${err#*active account folder missing}" != "$err"
  )

# --- wrapper execs Conductor's binary with args intact
fake_bin() {  # $1 = path; logs env + args one per line
  mkdir -p ${1:h}
  print -r -- '#!/bin/zsh
print -r -- "CFG=$CLAUDE_CONFIG_DIR" >> $STUB_LOG; for a in "$@"; do print -r -- "ARG=$a" >> $STUB_LOG; done; exit 7' > $1
  chmod +x $1
}
( new_sandbox
  fake_bin $CONDUCTOR_SUPPORT/agent-binaries/claude/9.9.9/claude
  mkdir -p $CONDUCTOR_SUPPORT/bin; ln -s $CONDUCTOR_SUPPORT/agent-binaries/claude/9.9.9/claude $CONDUCTOR_SUPPORT/bin/claude
  claude-for-conductor --resume=x "two words"; rc=$?
  check test_wrapper_passes_exit_code test $rc -eq 7
  check test_wrapper_sets_config_dir grep -qxF "CFG=$CLAUDE_ACCOUNTS_HOME/a" $STUB_LOG
  check test_wrapper_args_with_spaces grep -qxF "ARG=two words" $STUB_LOG
  )

# --- wrapper falls back to ~/.local/bin/claude when Conductor's binary is missing
( new_sandbox
  fake_bin $HOME/.local/bin/claude
  claude-for-conductor hi; rc=$?
  check test_wrapper_falls_back_when_conductor_bin_missing grep -qxF "ARG=hi" $STUB_LOG
  )

# --- wrapper never execs itself
( new_sandbox
  fake_bin $HOME/.local/bin/claude
  mkdir -p $CONDUCTOR_SUPPORT/bin; ln -s $REPO/bin/claude-for-conductor $CONDUCTOR_SUPPORT/bin/claude
  timeout 5 claude-for-conductor self; rc=$?
  check test_wrapper_never_execs_itself grep -qxF "ARG=self" $STUB_LOG
  )

passes=$(grep -c '^PASS' $RESULTS); fails=$(grep -c '^FAIL' $RESULTS); rm -f $RESULTS; [[ -f $RESULTS.dirs ]] && { xargs rm -rf < $RESULTS.dirs; rm -f $RESULTS.dirs }
print "shell tests: $passes passed, $fails failed"
(( fails == 0 && passes == 12 ))
