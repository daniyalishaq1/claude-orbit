import os
import unittest

from helpers import Sandbox


class LinkTests(Sandbox, unittest.TestCase):
    def setUp(self):
        self.sb_setup()
        import claude_switch
        self.cs = claude_switch
        (self.shared / "settings.json").write_text("{}")
        (self.shared / "skills").mkdir()
        (self.shared / "projects").mkdir()
        (self.shared / "policy-limits.json").write_text("{}")  # org-specific: must NOT be shared

    def entry(self, name):
        return self.home / "acct" / name

    def test_links_only_existing_shared_entries(self):
        p = self.paths()
        self.cs.ensure_account_dir(p, "acct")
        linked = self.cs.link_shared(p, "acct")
        self.assertEqual(sorted(linked), ["projects", "settings.json", "skills"])
        for name in ("settings.json", "skills", "projects"):
            self.assertTrue(self.entry(name).is_symlink(), name)
            self.assertEqual(os.readlink(self.entry(name)), str(self.shared / name))
        self.assertFalse(self.entry("policy-limits.json").exists())

    def test_account_dir_is_private(self):
        d = self.cs.ensure_account_dir(self.paths(), "acct")
        self.assertEqual(d.stat().st_mode & 0o777, 0o700)

    def test_relink_is_idempotent(self):
        p = self.paths()
        self.cs.link_shared(p, "acct")
        self.assertEqual(self.cs.link_shared(p, "acct"), [])

    def test_new_shared_entry_linked_later(self):
        p = self.paths()
        self.cs.link_shared(p, "acct")
        (self.shared / "agents").mkdir()
        self.assertEqual(self.cs.link_shared(p, "acct"), ["agents"])
        self.assertTrue(self.entry("agents").is_symlink())

    def test_older_real_file_moved_aside_not_clobbered(self):
        p = self.paths()
        self.cs.ensure_account_dir(p, "acct")
        self.entry("settings.json").write_text("x")
        os.utime(self.entry("settings.json"), (1_000_000, 1_000_000))  # older than the shared copy
        self.cs.link_shared(p, "acct")
        self.assertTrue(self.entry("settings.json").is_symlink())
        backups = list((self.home / "acct").glob("settings.json.pre-link-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "x")
        self.assertEqual((self.shared / "settings.json").read_text(), "{}")

    def test_newer_real_file_is_promoted_to_shared(self):
        # e.g. Claude Code rewrote settings.json atomically, replacing our symlink with a file
        p = self.paths()
        self.cs.ensure_account_dir(p, "acct")
        os.utime(self.shared / "settings.json", (1_000_000, 1_000_000))
        self.entry("settings.json").write_text('{"model": "new"}')
        self.cs.link_shared(p, "acct")
        self.assertTrue(self.entry("settings.json").is_symlink())
        self.assertEqual((self.shared / "settings.json").read_text(), '{"model": "new"}')
        backups = list(self.shared.glob("settings.json.pre-promote-*"))
        self.assertEqual([b.read_text() for b in backups], ["{}"])

    def test_entry_missing_from_shared_is_moved_into_shared(self):
        # e.g. Claude Code created agents/ or CLAUDE.md inside an account folder
        p = self.paths()
        self.cs.ensure_account_dir(p, "acct")
        (self.entry("agents")).mkdir()
        (self.entry("agents") / "a.md").write_text("agent")
        self.entry("CLAUDE.md").write_text("notes")
        self.cs.link_shared(p, "acct")
        self.assertEqual((self.shared / "agents" / "a.md").read_text(), "agent")
        self.assertEqual((self.shared / "CLAUDE.md").read_text(), "notes")
        self.assertTrue(self.entry("agents").is_symlink())
        self.assertTrue(self.entry("CLAUDE.md").is_symlink())

    def test_wrong_symlink_repointed(self):
        p = self.paths()
        self.cs.ensure_account_dir(p, "acct")
        os.symlink("/nonexistent/elsewhere", self.entry("skills"))
        self.assertEqual(self.cs.link_shared(p, "acct"), ["projects", "settings.json", "skills"])
        self.assertEqual(os.readlink(self.entry("skills")), str(self.shared / "skills"))


if __name__ == "__main__":
    unittest.main()
