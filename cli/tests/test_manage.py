import hashlib
import json
import re
import signal
import subprocess
import time
import unittest

from helpers import CLI

from helpers import Sandbox


class ManageTests(Sandbox, unittest.TestCase):
    def setUp(self):
        self.sb_setup()
        cfg = self.swap / "configs"
        cfg.mkdir(parents=True)
        for n, email in ((1, "ana@example.org"), (2, "bo@example.com"), (3, "cy@work.example")):
            (cfg / f".claude-config-{n}-{email}.json").write_text(json.dumps(
                {"oauthAccount": {"emailAddress": email}, "marker": n}))
        self.home_json.write_text(json.dumps({"oauthAccount": {"emailAddress": "x"}, "mcpServers": {"m": 1}}))
        (self.shared / "skills").mkdir()

    def acct(self, i):
        return json.loads((self.home / i / ".claude.json").read_text())

    def test_setup_has_no_builtin_accounts_and_lists_importable(self):
        code, out = self.run_cli("setup")
        self.assertEqual(code, 0, out)
        self.assertEqual(out["accounts"], [])
        self.assertEqual(sorted(i["email"] for i in out["importable"]),
                         ["ana@example.org", "bo@example.com", "cy@work.example"])
        self.assertTrue(self.home.is_dir())

    def test_import_claudeswitcher_seeds_by_email(self):
        code, out = self.run_cli("import-claudeswitcher", "BO@example.com", "--label", "Bo Work")
        self.assertEqual(code, 0, out)
        self.assertEqual([(a["id"], a["label"], a["email"]) for a in out["accounts"]],
                         [("bo-work", "Bo Work", "bo@example.com")])
        self.assertEqual(self.acct("bo-work")["marker"], 2)
        self.assertTrue((self.home / "bo-work" / "skills").is_symlink())
        _, out = self.run_cli("setup")
        self.assertNotIn("bo@example.com", [i["email"] for i in out["importable"]])

    def test_import_unknown_email_exit_2(self):
        code, out = self.run_cli("import-claudeswitcher", "nobody@example.com")
        self.assertEqual(code, 2)

    def test_add_seeds_fresh_account_from_home_without_identity(self):
        self.run_cli("add", "Fresh One")
        fresh = self.acct("fresh-one")
        self.assertNotIn("oauthAccount", fresh)
        self.assertEqual(fresh["mcpServers"], {"m": 1})

    def test_setup_activates_first_ready_account(self):
        self.run_cli("add", "One")
        self.run_cli("add", "Two")
        (self.home / "one" / ".stub-auth").unlink(missing_ok=True)
        self.mark_ready("two", "two@example.com")
        (self.home / "active").unlink(missing_ok=True)
        _, out = self.run_cli("setup")
        self.assertEqual(out["active"], "two")

    def test_setup_never_activates_unready_account(self):
        self.run_cli("add", "Work")
        code, out = self.run_cli("setup")
        self.assertEqual(code, 0)
        self.assertIsNone(out["active"])
        self.assertFalse(any(c.startswith("launchctl setenv") for c in self.stub_calls()))

    def test_setup_is_idempotent(self):
        self.run_cli("add", "One")
        (self.home / "one" / ".claude.json").write_text('{"edited": true}')
        self.run_cli("setup")
        code, out = self.run_cli("setup")
        self.assertEqual(code, 0)
        self.assertEqual(len(out["accounts"]), 1)
        self.assertEqual(self.acct("one"), {"edited": True})

    def test_add_slugifies_assigns_colors_and_rejects_duplicate_label(self):
        for label in ("One", "Two", "Three"):
            self.run_cli("add", label)
        code, out = self.run_cli("add", "New Person")
        self.assertEqual(code, 0, out)
        self.assertEqual([a["color"] for a in out["accounts"]], ["violet", "teal", "amber", "rose"])
        self.assertEqual(out["accounts"][-1]["id"], "new-person")
        self.assertTrue((self.home / "new-person" / "skills").is_symlink())
        code, out = self.run_cli("add", "new person")
        self.assertEqual(code, 2)

    def test_login_runs_claude_auth_login_with_account_dir(self):
        self.run_cli("add", "Cy")
        (self.home / "cy" / ".stub-login-email").write_text("cy@work.example")
        code, out = self.run_cli("login", "cy")
        self.assertEqual(code, 0, out)
        self.assertEqual(out, {"id": "cy", "ready": True, "email": "cy@work.example"})
        self.assertIn(f"claude CLAUDE_CONFIG_DIR={self.home / 'cy'} auth login", self.stub_calls())

    def test_login_prefills_known_email(self):
        self.run_cli("import-claudeswitcher", "bo@example.com", "--label", "Bo")
        self.run_cli("login", "bo")
        self.assertIn(f"claude CLAUDE_CONFIG_DIR={self.home / 'bo'} auth login --email bo@example.com", self.stub_calls())

    def test_login_as_wrong_account_is_undone(self):
        self.run_cli("import-claudeswitcher", "bo@example.com", "--label", "Bo")
        (self.home / "bo" / ".stub-login-email").write_text("someone@else.example")
        code, out = self.run_cli("login", "bo")
        self.assertEqual(code, 6)
        self.assertEqual(out["code"], "wrong_account")
        self.assertIn("someone@else.example", out["error"])
        self.assertIn("bo@example.com", out["error"])
        self.assertIn(f"claude CLAUDE_CONFIG_DIR={self.home / 'bo'} auth logout", self.stub_calls())
        _, listing = self.run_cli("list")
        self.assertEqual((listing["accounts"][0]["email"], listing["accounts"][0]["ready"]), ("bo@example.com", False))

    def hang_login(self, account_id, seconds="31.71"):
        (self.home / account_id / ".stub-login-hang").write_text(seconds)
        return seconds

    def sleeping(self, seconds):
        return subprocess.run(["pgrep", "-f", f"sleep {seconds}"], capture_output=True).returncode == 0

    def test_abandoned_login_times_out_and_keeps_existing_login(self):
        self.run_cli("add", "Bo")
        self.mark_ready("bo", "bo@example.com")
        secs = self.hang_login("bo")
        t = time.monotonic()
        code, out = self.run_cli("login", "bo", "--timeout", "1")
        self.assertLess(time.monotonic() - t, 6)
        self.assertEqual(code, 7)
        self.assertEqual(out["code"], "login_timeout")
        time.sleep(0.3)
        self.assertFalse(self.sleeping(secs), "browser-wait process left running")
        _, listing = self.run_cli("list")
        self.assertEqual(listing["accounts"][0]["ready"], True)  # old login untouched

    def test_cancelled_login_cleans_up_child(self):
        self.run_cli("add", "Bo")
        secs = self.hang_login("bo", "32.37")
        p = subprocess.Popen(["/usr/bin/python3", "-I", str(CLI), "login", "bo", "--json"], env=self.env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while not self.sleeping(secs) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertTrue(self.sleeping(secs))
        p.send_signal(signal.SIGTERM)
        p.communicate(timeout=5)
        time.sleep(0.3)
        self.assertFalse(self.sleeping(secs), "browser-wait process left running after cancel")

    def test_rename_keeps_id(self):
        self.run_cli("add", "Bo")
        code, out = self.run_cli("rename", "bo", "Bo Renamed")
        self.assertEqual(code, 0)
        self.assertEqual((out["accounts"][0]["id"], out["accounts"][0]["label"]), ("bo", "Bo Renamed"))

    def test_rename_rejects_empty_and_duplicate_labels(self):
        self.run_cli("add", "Bo")
        self.run_cli("add", "Cy")
        for bad in ("", "   ", "!!!"):
            code, out = self.run_cli("rename", "bo", bad)
            self.assertEqual((code, out["code"]), (2, "usage"), bad)
        for dup in ("Cy", "cy", " CY "):
            code, out = self.run_cli("rename", "bo", dup)
            self.assertEqual((code, out["code"]), (2, "usage"), dup)
            self.assertIn("already exists", out["error"])
        _, listing = self.run_cli("list")
        self.assertEqual([a["label"] for a in listing["accounts"]], ["Bo", "Cy"])

    def test_rename_can_change_only_the_case_of_its_own_label(self):
        self.run_cli("add", "Bo")
        code, out = self.run_cli("rename", "bo", "BO")
        self.assertEqual(code, 0, out)
        self.assertEqual(out["accounts"][0]["label"], "BO")

    def test_status_does_not_rewrite_accounts_json_when_nothing_changed(self):
        self.run_cli("add", "Bo")
        self.mark_ready("bo", "bo@example.com")
        self.run_cli("status", "bo")                      # first check records ready + email
        before = (self.home / "accounts.json").stat().st_mtime_ns
        time.sleep(0.05)
        self.run_cli("status", "bo")
        self.assertEqual((self.home / "accounts.json").stat().st_mtime_ns, before,
                         "an unchanged status check rewrote accounts.json (the app's folder watcher would loop)")

    def test_failed_status_check_keeps_previous_signed_in_state(self):
        self.run_cli("add", "Bo")
        self.mark_ready("bo", "bo@example.com")
        self.run_cli("status", "bo")
        (self.home / "bo" / ".stub-status-garbage").write_text("")
        code, out = self.run_cli("status", "bo")
        self.assertEqual((code, out["ready"], out["email"]), (0, True, "bo@example.com"))
        _, listing = self.run_cli("list")
        self.assertTrue(listing["accounts"][0]["ready"])

    def test_definite_not_logged_in_is_still_recorded(self):
        self.run_cli("add", "Bo")
        self.mark_ready("bo", "bo@example.com")
        self.run_cli("status", "bo")
        (self.home / "bo" / ".stub-auth").unlink()
        code, out = self.run_cli("status", "bo")
        self.assertEqual((out["ready"], out["email"]), (False, None))

    def test_wrong_account_login_says_the_old_login_was_replaced(self):
        self.run_cli("import-claudeswitcher", "bo@example.com", "--label", "Bo")
        self.mark_ready("bo", "bo@example.com")
        self.run_cli("status", "bo")
        (self.home / "bo" / ".stub-login-email").write_text("someone@else.example")
        code, out = self.run_cli("login", "bo")
        self.assertEqual((code, out["code"]), (6, "wrong_account"))
        self.assertIn("signed out", out["error"])

    def test_remove_deletes_keychain_item_dir_and_entry_but_not_shared(self):
        (self.shared / "skills" / "x").write_text("keep")
        self.run_cli("add", "Temp")
        code, out = self.run_cli("remove", "temp", "--yes")
        self.assertEqual(code, 0, out)
        self.assertNotIn("temp", [a["id"] for a in out["accounts"]])
        self.assertFalse((self.home / "temp").exists())
        self.assertEqual((self.shared / "skills" / "x").read_text(), "keep")
        svc = "Claude Code-credentials-" + hashlib.sha256(str(self.home / "temp").encode()).hexdigest()[:8]
        self.assertIn(f"security delete-generic-password -s {svc} -a tester", self.stub_calls())

    def test_remove_requires_yes(self):
        self.run_cli("add", "Temp")
        code, _ = self.run_cli("remove", "temp")
        self.assertEqual(code, 2)
        self.assertTrue((self.home / "temp").exists())

    def test_remove_active_refused(self):
        self.run_cli("add", "Bo")
        self.mark_ready("bo", "bo@example.com")
        self.run_cli("setup")
        code, out = self.run_cli("remove", "bo", "--yes")
        self.assertEqual(code, 2)
        self.assertIn("Switch away first", out["error"])

    def test_keychain_service_format(self):
        import claude_switch
        svc = claude_switch.keychain_service(self.home / "x")
        self.assertRegex(svc, r"^Claude Code-credentials-[0-9a-f]{8}$")


if __name__ == "__main__":
    unittest.main()
