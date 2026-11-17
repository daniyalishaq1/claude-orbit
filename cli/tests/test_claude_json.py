import json
import unittest

from helpers import Sandbox


def read(p):
    return json.loads(p.read_text())


class ClaudeJsonTests(Sandbox, unittest.TestCase):
    def setUp(self):
        self.sb_setup()
        import claude_switch
        self.cs = claude_switch

    def acct_json(self, account_id):
        return self.home / account_id / ".claude.json"

    def test_seed_from_backup_keeps_oauth(self):
        src = self.root / "backup.json"
        src.write_text(json.dumps({"oauthAccount": {"emailAddress": "t@x.io"}, "marker": 7}))
        self.cs.seed_claude_json(self.paths(), "t", src)
        data = read(self.acct_json("t"))
        self.assertEqual(data["oauthAccount"]["emailAddress"], "t@x.io")
        self.assertEqual(data["marker"], 7)

    def test_seed_from_backup_takes_current_prefs_from_home(self):
        self.home_json.write_text(json.dumps({"mcpServers": {"new": 1}, "projects": {"/p": {"t": 1}}}))
        src = self.root / "backup.json"
        src.write_text(json.dumps({"oauthAccount": {"emailAddress": "t@x.io"}, "mcpServers": {"old": 1, "new": 0}}))
        self.cs.seed_claude_json(self.paths(), "t", src)
        data = read(self.acct_json("t"))
        self.assertEqual(data["mcpServers"], {"old": 1, "new": 1})
        self.assertEqual(data["projects"], {"/p": {"t": 1}})
        self.assertEqual(data["oauthAccount"]["emailAddress"], "t@x.io")

    def test_seed_from_home_strips_identity(self):
        self.home_json.write_text(json.dumps({
            "oauthAccount": {"emailAddress": "old@x.io"}, "userID": "u1",
            "modelAccessCache": {"x": 1}, "s1mAccessCache": {}, "cachedGrowthBookFeatures": {},
            "groveConfigCache": {}, "passesEligibilityCache": {}, "orgModelDefaultCache": {},
            "mcpServers": {"figma": {"url": "http://x"}}, "hasCompletedOnboarding": True,
        }))
        self.cs.seed_claude_json(self.paths(), "n", None)
        data = read(self.acct_json("n"))
        self.assertEqual(data, {"mcpServers": {"figma": {"url": "http://x"}}, "hasCompletedOnboarding": True})

    def test_seed_does_not_overwrite_existing(self):
        self.cs.ensure_account_dir(self.paths(), "t")
        self.acct_json("t").write_text('{"keep": 1}')
        src = self.root / "backup.json"
        src.write_text('{"other": 2}')
        self.cs.seed_claude_json(self.paths(), "t", src)
        self.assertEqual(read(self.acct_json("t")), {"keep": 1})

    def test_sync_merges_outgoing_wins(self):
        p = self.paths()
        for i in ("from", "to"):
            self.cs.ensure_account_dir(p, i)
        self.acct_json("to").write_text(json.dumps({
            "oauthAccount": {"emailAddress": "to@x.io"}, "mcpServers": {"a": 1, "b": 1},
            "projects": {"/p1": {"t": 1}}, "numStartups": 3}))
        self.acct_json("from").write_text(json.dumps({
            "oauthAccount": {"emailAddress": "from@x.io"}, "mcpServers": {"b": 2, "c": 2},
            "projects": {"/p2": {"t": 2}}, "numStartups": 99}))
        self.cs.sync_prefs(p, "from", "to")
        self.assertEqual(read(self.acct_json("to")), {
            "oauthAccount": {"emailAddress": "to@x.io"}, "mcpServers": {"a": 1, "b": 2, "c": 2},
            "projects": {"/p1": {"t": 1}, "/p2": {"t": 2}}, "numStartups": 3})

    def test_sync_skips_unreadable_source_without_renaming(self):
        p = self.paths()
        for i in ("from", "to"):
            self.cs.ensure_account_dir(p, i)
        self.acct_json("from").write_text("{half-written")
        self.acct_json("to").write_text(json.dumps({"oauthAccount": {"x": 1}}))
        self.cs.sync_prefs(p, "from", "to")
        self.assertEqual(read(self.acct_json("to")), {"oauthAccount": {"x": 1}})
        self.assertEqual(self.acct_json("from").read_text(), "{half-written")
        self.assertEqual(list((self.home / "from").glob("*.corrupt-*")), [])

    def test_sync_refuses_unreadable_destination_without_touching_it(self):
        p = self.paths()
        for i in ("from", "to"):
            self.cs.ensure_account_dir(p, i)
        self.acct_json("from").write_text(json.dumps({"mcpServers": {"m": 1}}))
        self.acct_json("to").write_text("{half-written")
        with self.assertRaises(self.cs.CLIError) as ctx:
            self.cs.sync_prefs(p, "from", "to")
        self.assertEqual(ctx.exception.code, "config_unreadable")
        self.assertEqual(self.acct_json("to").read_text(), "{half-written")
        self.assertEqual(list((self.home / "to").glob("*.corrupt-*")), [])

    def test_sync_with_missing_source_is_a_no_op(self):
        p = self.paths()
        self.cs.ensure_account_dir(p, "to")
        self.acct_json("to").write_text('{"k": 1}')
        self.cs.sync_prefs(p, "nope", "to")
        self.assertEqual(read(self.acct_json("to")), {"k": 1})

    def test_seed_never_renames_unreadable_home_json(self):
        self.home_json.write_text("{half-written")
        self.cs.seed_claude_json(self.paths(), "n", None)
        self.assertEqual(self.home_json.read_text(), "{half-written")
        self.assertEqual(read(self.acct_json("n")), {})


if __name__ == "__main__":
    unittest.main()
