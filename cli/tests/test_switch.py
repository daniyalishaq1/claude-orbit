import fcntl
import json
import os
import subprocess
import time
import unittest

from helpers import CLI, Sandbox


class SwitchTests(Sandbox, unittest.TestCase):
    def setUp(self):
        self.sb_setup()

    def active(self):
        return (self.home / "active").read_text().strip()

    def test_switch_sets_active_and_launchctl(self):
        self.three_accounts(active="a")
        code, out = self.run_cli("switch", "bravo")
        self.assertEqual(code, 0, out)
        self.assertEqual(out["active"], "b")
        self.assertEqual(out["previous"], "a")
        self.assertEqual(out["email"], "b@example.com")
        self.assertEqual(self.active(), "b")
        self.assertIn(f"launchctl setenv CLAUDE_CONFIG_DIR {self.home / 'b'}", self.stub_calls())

    def test_switch_records_email_and_ready_in_listing(self):
        self.three_accounts(active="a")
        self.run_cli("switch", "c")
        _, out = self.run_cli("list")
        c = out["accounts"][2]
        self.assertEqual((c["email"], c["ready"]), ("c@example.com", True))

    def test_switch_refuses_not_ready_exit_3(self):
        self.three_accounts(active="a", ready=("a",))
        code, out = self.run_cli("switch", "b")
        self.assertEqual(code, 3)
        self.assertEqual(out["code"], "not_logged_in")
        self.assertIn("claude-switch login b", out["error"])
        self.assertEqual(self.active(), "a")

    def test_force_switch_allowed(self):
        self.three_accounts(active="a", ready=("a",))
        code, out = self.run_cli("switch", "b", "--force")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.active(), "b")

    def test_next_wraps_and_skips_not_ready(self):
        self.three_accounts(active="a", ready=("a", "c"))
        self.assertEqual(self.run_cli("next")[1]["active"], "c")
        self.assertEqual(self.run_cli("next")[1]["active"], "a")

    def test_next_with_none_ready_exit_3(self):
        self.three_accounts(active="a", ready=("a",))
        code, out = self.run_cli("next")
        self.assertEqual(code, 3)
        self.assertEqual(self.active(), "a")

    def test_switch_links_shared_and_syncs_prefs_from_previous(self):
        self.three_accounts(active="a")
        (self.shared / "skills").mkdir()
        (self.home / "a" / ".claude.json").write_text(json.dumps({"mcpServers": {"m": 1}}))
        (self.home / "b" / ".claude.json").write_text(json.dumps({"oauthAccount": {"x": 1}}))
        self.run_cli("switch", "b")
        self.assertTrue((self.home / "b" / "skills").is_symlink())
        self.assertEqual(json.loads((self.home / "b" / ".claude.json").read_text()),
                         {"oauthAccount": {"x": 1}, "mcpServers": {"m": 1}})

    def test_concurrent_switches_leave_valid_state(self):
        self.three_accounts(active="a")
        for i in ("a", "b"):
            (self.home / i / ".claude.json").write_text(json.dumps({"mcpServers": {i: 1}}))
        procs = [subprocess.Popen(["/usr/bin/python3", "-I", str(CLI), "switch", "a" if n % 2 else "b", "--json"],
                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for n in range(10)]
        codes = [(p.communicate(timeout=60), p.returncode)[1] for p in procs]
        self.assertTrue(all(c == 0 for c in codes), codes)
        self.assertIn(self.active(), ("a", "b"))
        for i in ("a", "b", "c"):
            f = self.home / i / ".claude.json"
            if f.exists():
                json.loads(f.read_text())  # must parse
        self.assertEqual(list(self.home.rglob("*.tmp")), [])

    def test_next_from_stale_account_does_not_advance(self):
        self.three_accounts(active="b")
        code, out = self.run_cli("next", "--from", "a")   # another shell already moved a -> b
        self.assertEqual(code, 0, out)
        self.assertEqual((out["active"], out["already"]), ("b", True))
        self.assertEqual(self.active(), "b")
        _, out = self.run_cli("next", "--from", "b")
        self.assertEqual(out["active"], "c")

    def test_apply_env_sets_launchctl_for_active(self):
        self.three_accounts(active="c")
        code, _ = self.run_cli("apply-env")
        self.assertEqual(code, 0)
        self.assertIn(f"launchctl setenv CLAUDE_CONFIG_DIR {self.home / 'c'}", self.stub_calls())

    def test_bare_account_name_switches(self):
        self.three_accounts(active="a")
        code, out = self.run_cli("bravo")
        self.assertEqual((code, out["active"]), (0, "b"))

    def test_missing_claude_binary_is_reported(self):
        import os
        self.three_accounts(active="a")
        nobin = self.root / "nobin"
        nobin.mkdir()
        for tool in ("launchctl", "security", "ps", "_log.sh"):
            os.symlink(self.env["PATH"].split(":")[0] + "/" + tool, nobin / tool)
        self.env["PATH"] = f"{nobin}:/usr/bin:/bin"
        code, out = self.run_cli("switch", "b")
        self.assertEqual((code, out["code"]), (8, "claude_not_found"))

    def test_concurrent_status_checks_never_lose_added_accounts(self):
        self.three_accounts(active="a")
        procs = []
        for n in range(8):
            procs.append(subprocess.Popen(["/usr/bin/python3", "-I", str(CLI), "add", f"Extra {n}", "--json"],
                                          env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
            procs.append(subprocess.Popen(["/usr/bin/python3", "-I", str(CLI), "status", "a", "--json"],
                                          env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
        for p in procs:
            p.communicate(timeout=60)
        _, out = self.run_cli("list")
        self.assertEqual(len(out["accounts"]), 11)

    def test_lock_timeout_exit_4(self):
        self.three_accounts(active="a")
        fd = os.open(str(self.home / ".lock"), os.O_CREAT | os.O_RDWR)
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            t = time.monotonic()
            code, out = self.run_cli("switch", "b")
            self.assertEqual(code, 4)
            self.assertLess(time.monotonic() - t, 6.5)
        finally:
            os.close(fd)
        self.assertEqual(self.active(), "a")


if __name__ == "__main__":
    unittest.main()
