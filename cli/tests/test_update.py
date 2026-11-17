import subprocess
import time
import unittest

from helpers import Sandbox


class UpdateTests(Sandbox, unittest.TestCase):
    """`claude-switch update` against a throwaway git remote. The real installer is never run."""

    def setUp(self):
        self.sb_setup()
        self.git_env = dict(self.env, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                            GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")
        self.origin = self.root / "origin.git"
        self.author = self.root / "author"     # where "the developer" pushes new versions from
        self.repo = self.root / "install"      # the copy a user installed from
        self.git(self.root, "init", "-q", "--bare", "-b", "main", str(self.origin))
        self.git(self.root, "clone", "-q", str(self.origin), str(self.author))
        (self.author / "VERSION").write_text("1\n")
        self.git(self.author, "add", "VERSION")
        self.git(self.author, "commit", "-q", "-m", "v1")
        self.git(self.author, "push", "-q", "origin", "HEAD:main")
        self.git(self.root, "clone", "-q", str(self.origin), str(self.repo))
        self.marker = self.root / "installer-ran"
        self.installer = self.root / "fake-install.sh"
        self.installer.write_text(f"#!/bin/sh\ncat VERSION > '{self.marker}'\n")
        self.installer.chmod(0o755)
        self.env.update({"CLAUDE_ACCOUNTS_REPO": str(self.repo), "CLAUDE_ACCOUNTS_INSTALLER": str(self.installer)})

    def git(self, cwd, *args):
        return subprocess.run(["git", "-C", str(cwd), *args], env=self.git_env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def publish(self, version):
        (self.author / "VERSION").write_text(f"{version}\n")
        self.git(self.author, "commit", "-q", "-am", f"v{version}")
        self.git(self.author, "push", "-q", "origin", "HEAD:main")

    def wait_for_installer(self):
        deadline = time.time() + 10
        while time.time() < deadline:
            if self.marker.exists() and self.marker.read_text().strip():   # created first, written a moment later
                return self.marker.read_text().strip()
            time.sleep(0.05)
        return None

    def test_up_to_date(self):
        rc, out = self.run_cli("update", "--check")
        self.assertEqual(rc, 0)
        self.assertFalse(out["available"])
        self.assertEqual(out["behind"], 0)
        self.assertIsNone(out["reason"])

    def test_check_reports_a_new_version_without_changing_anything(self):
        before = self.git(self.repo, "rev-parse", "HEAD")
        self.publish(2)
        rc, out = self.run_cli("update", "--check")
        self.assertEqual(rc, 0)
        self.assertTrue(out["available"])
        self.assertEqual(out["behind"], 1)
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), before)
        self.assertFalse(self.marker.exists())

    def test_update_pulls_and_runs_the_installer(self):
        self.publish(2)
        rc, out = self.run_cli("update")
        self.assertEqual(rc, 0)
        self.assertTrue(out["started"])
        self.assertEqual(self.wait_for_installer(), "2")     # installer ran from the updated copy
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), self.git(self.author, "rev-parse", "HEAD"))

    def test_update_does_nothing_when_up_to_date(self):
        rc, out = self.run_cli("update")
        self.assertEqual(rc, 0)
        self.assertFalse(out["started"])
        time.sleep(0.3)
        self.assertFalse(self.marker.exists())

    def test_local_changes_are_never_overwritten(self):
        self.publish(2)
        (self.repo / "VERSION").write_text("mine\n")
        before = self.git(self.repo, "rev-parse", "HEAD")
        rc, out = self.run_cli("update", "--check")
        self.assertTrue(out["available"])
        self.assertEqual(out["reason"], "local_changes")
        rc, out = self.run_cli("update")
        self.assertNotEqual(rc, 0)
        self.assertEqual(out["code"], "update_blocked")
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD"), before)
        self.assertEqual((self.repo / "VERSION").read_text(), "mine\n")
        self.assertFalse(self.marker.exists())

    def test_copy_that_is_not_a_git_clone(self):
        plain = self.root / "plain"
        plain.mkdir()
        self.env["CLAUDE_ACCOUNTS_REPO"] = str(plain)
        rc, out = self.run_cli("update", "--check")
        self.assertEqual(rc, 0)
        self.assertFalse(out["available"])
        self.assertEqual(out["reason"], "not_git")

    def test_offline_is_reported_not_raised(self):
        self.git(self.repo, "remote", "set-url", "origin", str(self.root / "gone.git"))
        rc, out = self.run_cli("update", "--check")
        self.assertEqual(rc, 0)
        self.assertFalse(out["available"])
        self.assertEqual(out["reason"], "offline")


if __name__ == "__main__":
    unittest.main()
