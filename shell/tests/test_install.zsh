#!/bin/zsh -f
# Tests install.sh against a sandbox HOME (no build, stubbed launchctl/osascript).
REPO=${0:A:h:h:h}
T=$(mktemp -d /tmp/cs-install-XXXXXX); T=${T:A}
fails=0; passes=0
check() { local n=$1; shift; if "$@"; then (( passes++ )); else (( fails++ )); print -u2 "FAIL: $n"; fi; }
export HOME=$T STUB_LOG=$T/stub.log STUB_DIR_OUT=$T/out INSTALL_SKIP_BUILD=1
export PATH=$REPO/cli/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin
mkdir -p $T/out $T/.conductor
print '# my zshrc\nalias ll="ls -l"' > $T/.zshrc
print '"$schema" = "https://example/schema.json"\ncodex_provider = "default"\n\n[git]\nbranch_prefix_type = "x"' > $T/.conductor/settings.toml
cp $T/.zshrc $T/zshrc.orig; cp $T/.conductor/settings.toml $T/settings.orig

$REPO/install.sh >/dev/null 2>&1; rc1=$?
$REPO/install.sh >/dev/null 2>&1; rc2=$?
check install_exit_ok test $rc1 -eq 0 -a $rc2 -eq 0
check links_cli test "$(readlink $T/.local/bin/claude-switch)" = "$REPO/bin/claude-switch"
check links_wrapper test "$(readlink $T/.local/bin/claude-for-conductor)" = "$REPO/bin/claude-for-conductor"
check zshrc_block_once test "$(grep -c 'claude-orbit.zsh' $T/.zshrc)" -eq 1
check zshrc_keeps_user_lines grep -q 'alias ll="ls -l"' $T/.zshrc
check conductor_key_once test "$(grep -c '^claude_code_executable_path' $T/.conductor/settings.toml)" -eq 1
# key must be top-level: before the first [table]
key_line=$(grep -n '^claude_code_executable_path' $T/.conductor/settings.toml | cut -d: -f1)
table_line=$(grep -n '^\[git\]' $T/.conductor/settings.toml | cut -d: -f1)
check conductor_key_top_level test "$key_line" -lt "$table_line"
check conductor_keeps_settings grep -q 'branch_prefix_type = "x"' $T/.conductor/settings.toml
check conductor_points_to_wrapper grep -qF "claude_code_executable_path = \"$T/.local/bin/claude-for-conductor\"" $T/.conductor/settings.toml
check backups_made test -n "$(print -l $T/.zshrc.bak-*(N))" -a -n "$(print -l $T/.conductor/settings.toml.bak-*(N))"
check launch_agent_written grep -q 'local.claude-orbit.menubar' $T/Library/LaunchAgents/local.claude-orbit.menubar.plist
check accounts_home_created test -d $T/.claude-accounts
check stops_running_copy grep -q "pkill -f $T/Applications/Claude Orbit.app/Contents/MacOS/ClaudeOrbit" $STUB_LOG

# existing different executable path is respected (not overwritten)
print 'claude_code_executable_path = "/custom/claude"\n[git]\nx = 1' > $T/custom.toml
CONDUCTOR_SETTINGS=$T/custom.toml $REPO/install.sh >/dev/null 2>&1
check conductor_custom_path_respected grep -qx 'claude_code_executable_path = "/custom/claude"' $T/custom.toml

$REPO/install.sh --uninstall >/dev/null 2>&1
check uninstall_unsets_env grep -q 'launchctl unsetenv CLAUDE_CONFIG_DIR' $STUB_LOG
check uninstall_restores_zshrc diff -q $T/.zshrc $T/zshrc.orig
check uninstall_restores_conductor diff -q $T/.conductor/settings.toml $T/settings.orig
check uninstall_removes_links test ! -e $T/.local/bin/claude-switch -a ! -L $T/.local/bin/claude-switch
check uninstall_removes_agent test ! -e $T/Library/LaunchAgents/local.claude-orbit.menubar.plist
check uninstall_keeps_accounts test -d $T/.claude-accounts

# a hook line left by a copy that lived somewhere else is re-pointed here, and the block from before the rename goes
print '# my zshrc\n\n# >>> claude-accounts >>>\nsource "/old/place/shell/claude-accounts.zsh"\n# <<< claude-accounts <<<\n\n# >>> claude-orbit >>>\nsource "/moved/away/shell/claude-orbit.zsh"\n# <<< claude-orbit <<<' > $T/.zshrc
$REPO/install.sh >/dev/null 2>&1
check moved_hook_repointed grep -qF "source \"$REPO/shell/claude-orbit.zsh\"" $T/.zshrc
check moved_hook_once test "$(grep -c 'claude-orbit.zsh' $T/.zshrc)" -eq 1
check old_name_block_removed test "$(grep -c -e 'claude-accounts >>>' -e 'claude-accounts.zsh' $T/.zshrc)" -eq 0
check moved_hook_keeps_user_lines grep -q '# my zshrc' $T/.zshrc
$REPO/install.sh --uninstall >/dev/null 2>&1
check uninstall_after_move_clean test "$(grep -c 'claude-orbit.zsh' $T/.zshrc)" -eq 0

# a reformatted key (no spaces) is still removed on uninstall, and the wrapper is kept if it can't be
mkdir -p $T/.conductor; print "codex_provider = \"default\"\nclaude_code_executable_path=\"$T/.local/bin/claude-for-conductor\"\n[git]\nx = 1" > $T/.conductor/settings.toml
$REPO/install.sh --uninstall >/dev/null 2>&1
check uninstall_removes_reformatted_key test "$(grep -c claude_code_executable_path $T/.conductor/settings.toml)" -eq 0

rm -rf $T
print "install tests: $passes passed, $fails failed"
(( fails == 0 ))
