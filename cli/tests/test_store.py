import json
import unittest

from helpers import Sandbox


class StoreTests(Sandbox, unittest.TestCase):
    def setUp(self):
        self.sb_setup()

    def test_list_empty(self):
        code, out = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertEqual(out, {"active": None, "accounts": []})

    def test_list_reports_active_and_dirs(self):
        self.three_accounts(active="b", ready=())
        code, out = self.run_cli("list")
        self.assertEqual(code, 0)
        self.assertEqual(out["active"], "b")
        self.assertEqual([a["id"] for a in out["accounts"]], ["a", "b", "c"])
        self.assertEqual(out["accounts"][1]["dir"], str(self.home / "b"))
        self.assertEqual(out["accounts"][0]["label"], "Alpha One")
        self.assertEqual(out["accounts"][0]["color"], "violet")

    def test_lookup_by_label_case_insensitive(self):
        self.three_accounts(active="a", ready=())
        import claude_switch
        store = claude_switch.Store(self.paths())
        self.assertEqual(store.account("alpha one")["id"], "a")
        self.assertEqual(store.account("C")["id"], "c")

    def test_unknown_account_exit_2(self):
        self.three_accounts(active="a")
        code, out = self.run_cli("switch", "nobody")
        self.assertEqual(code, 2)
        self.assertEqual(out["code"], "unknown_account")

    def test_save_is_atomic(self):
        self.three_accounts(active="a", ready=())
        import claude_switch
        store = claude_switch.Store(self.paths())
        before = (self.home / "accounts.json").read_text()
        with self.assertRaises(TypeError):
            store.save({"version": 1, "accounts": [{"id": object()}]})
        self.assertEqual((self.home / "accounts.json").read_text(), before)
        self.assertEqual(list(self.home.glob("*.tmp*")), [])

    def test_slugify(self):
        import claude_switch
        self.assertEqual(claude_switch.slugify("Work Account 2"), "work-account-2")
        self.assertEqual(claude_switch.slugify("  Jane  Doe! "), "jane-doe")

    def test_text_list_marks_active_and_not_signed_in(self):
        self.three_accounts(active="a", ready=("a",))
        self.run_cli("status", "a")
        data = json.loads((self.home / "accounts.json").read_text())
        data["accounts"][1]["email"] = "b@example.com"
        (self.home / "accounts.json").write_text(json.dumps(data))
        code, out = self.run_cli("list", json_out=False)
        lines = out.splitlines()
        self.assertTrue(lines[0].startswith("●") and "a@example.com" in lines[0], lines)
        self.assertIn("b@example.com", lines[1])
        self.assertIn("not signed in", lines[1])
        self.assertIn("not signed in", lines[2])

    def test_dir_prints_active_dir(self):
        self.three_accounts(active="c", ready=())
        code, out = self.run_cli("dir", json_out=False)
        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), str(self.home / "c"))


if __name__ == "__main__":
    unittest.main()
