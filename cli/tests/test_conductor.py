import json
import os
import sqlite3
import subprocess
import time
import unittest

from helpers import Sandbox


class ConductorMoveTests(Sandbox, unittest.TestCase):
    def setUp(self):
        self.sb_setup()
        self.three_accounts(active="b")
        self.bin = self.conductor / "agent-binaries" / "claude" / "2.1.321" / "claude"
        self.db = self.conductor / "conductor.db"
        self.conductor.mkdir(parents=True)
        con = sqlite3.connect(str(self.db))
        con.execute("create table sessions (id text primary key, status text)")
        con.execute("create table session_state (session_id text primary key, live_state text)")
        con.commit()
        con.close()
        self.lines = []
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None:
                p.kill()
            p.wait()

    def fake_proc(self, session, status="idle", live=None, config_dir=None, exe=None):
        p = subprocess.Popen(["sleep", "60"])
        self.procs.append(p)
        env = f"CONDUCTOR_SESSION_ID={session} HOME=/x"
        if config_dir:
            env += f" CLAUDE_CONFIG_DIR={config_dir}"
        self.lines.append(f"{p.pid} {exe or self.bin} --output-format stream-json --session-id={session} {env}")
        con = sqlite3.connect(str(self.db))
        con.execute("insert into sessions values (?, ?)", (session, status))
        con.execute("insert into session_state values (?, ?)",
                    (session, json.dumps(live if live is not None else {"status": "idle"})))
        con.commit()
        con.close()
        return p

    def write_ps(self):
        (self.stub_out / "ps.out").write_text("\n".join(self.lines) + "\n")

    def alive(self, p):
        time.sleep(0.2)
        return p.poll() is None

    def test_moves_only_idle_old_account_processes(self):
        old = self.fake_proc("s-old", config_dir=self.home / "a")
        legacy = self.fake_proc("s-legacy")  # no CLAUDE_CONFIG_DIR: the pre-migration default slot
        current = self.fake_proc("s-cur", config_dir=self.home / "b")
        self.write_ps()
        code, out = self.run_cli("conductor-move")
        self.assertEqual(code, 0, out)
        self.assertEqual(sorted(out["moved"]), sorted([old.pid, legacy.pid]))
        self.assertFalse(self.alive(old))
        self.assertFalse(self.alive(legacy))
        self.assertTrue(self.alive(current))

    def test_skips_busy(self):
        waiting = self.fake_proc("s-wait", status="waiting", config_dir=self.home / "a")
        bg = self.fake_proc("s-bg", live={"status": "idle", "backgroundTasks": [{"id": "x"}]},
                            config_dir=self.home / "a")
        working = self.fake_proc("s-work", live={"status": "working"}, config_dir=self.home / "a")
        self.write_ps()
        code, out = self.run_cli("conductor-move")
        self.assertEqual(code, 0, out)
        self.assertEqual(out["moved"], [])
        self.assertEqual(sorted(out["skipped_busy"]), sorted([waiting.pid, bg.pid, working.pid]))
        for p in (waiting, bg, working):
            self.assertTrue(self.alive(p))

    def test_ignores_non_conductor_claude(self):
        term = self.fake_proc("s-term", config_dir=self.home / "a", exe="/Users/x/.local/bin/claude")
        self.write_ps()
        code, out = self.run_cli("conductor-move")
        self.assertEqual(out, {"moved": [], "skipped_busy": [], "unsupported": False, "pending": 0})
        self.assertTrue(self.alive(term))

    def test_ignores_helpers_without_a_chat_session(self):
        helper = subprocess.Popen(["sleep", "60"])
        self.procs.append(helper)
        self.lines.append(f"{helper.pid} {self.bin} --chrome-native-host HOME=/x")
        self.write_ps()
        code, out = self.run_cli("conductor-move")
        self.assertEqual(out, {"moved": [], "skipped_busy": [], "unsupported": False, "pending": 0})
        self.assertTrue(self.alive(helper))

    def test_dry_run_kills_nothing(self):
        old = self.fake_proc("s-old", config_dir=self.home / "a")
        self.write_ps()
        code, out = self.run_cli("conductor-move", "--dry-run")
        self.assertEqual(out["moved"], [old.pid])
        self.assertTrue(self.alive(old))

    def test_pending_counts_old_account_chats(self):
        self.fake_proc("s-old", config_dir=self.home / "a")
        self.fake_proc("s-wait", status="waiting", config_dir=self.home / "a")
        self.fake_proc("s-cur", config_dir=self.home / "b")
        self.write_ps()
        code, out = self.run_cli("conductor-move", "--dry-run")
        self.assertEqual(out["pending"], 2)

    def test_unreadable_db_is_unsupported_exit_5(self):
        old = self.fake_proc("s-old", config_dir=self.home / "a")
        self.write_ps()
        self.db.unlink()
        code, out = self.run_cli("conductor-move")
        self.assertEqual(code, 5)
        self.assertEqual(out["code"], "conductor_unsupported")
        self.assertTrue(self.alive(old))


if __name__ == "__main__":
    unittest.main()
