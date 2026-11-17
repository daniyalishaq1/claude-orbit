"""Test sandbox: temp dirs for every path the CLI touches, stubbed external tools on PATH."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLI = HERE.parent / "claude_switch.py"
STUBS = HERE / "stubs"

sys.path.insert(0, str(HERE.parent))


class Sandbox:
    """unittest mixin. Call self.sb_setup() in setUp."""

    def sb_setup(self):
        self.root = Path(tempfile.mkdtemp(prefix="cs-test-")).resolve()
        self.addCleanup(shutil.rmtree, self.root, True)
        self.home = self.root / "accounts"
        self.shared = self.root / "shared"
        self.shared.mkdir()
        self.home_json = self.root / "home.claude.json"
        self.swap = self.root / "swap"
        self.conductor = self.root / "conductor"
        self.stub_out = self.root / "stub-out"
        self.stub_out.mkdir()
        self.log = self.root / "stub.log"
        self.env = dict(os.environ)
        self.env.pop("CLAUDE_CONFIG_DIR", None)
        self.env.update({
            "CLAUDE_ACCOUNTS_HOME": str(self.home),
            "CLAUDE_SHARED_HOME": str(self.shared),
            "CLAUDE_HOME_JSON": str(self.home_json),
            "CLAUDE_SWAP_BACKUP": str(self.swap),
            "CONDUCTOR_SUPPORT": str(self.conductor),
            "CONDUCTOR_SETTINGS": str(self.root / "conductor-settings.toml"),
            "PATH": f"{STUBS}:{os.environ['PATH']}",
            "STUB_LOG": str(self.log),
            "STUB_DIR_OUT": str(self.stub_out),
            "HOME": str(self.root / "fakehome"),
            "USER": "tester",
        })
        (self.root / "fakehome").mkdir()

    def run_cli(self, *args, json_out=True, timeout=30):
        argv = ["/usr/bin/python3", "-I", str(CLI), *args]
        if json_out:
            argv.append("--json")
        p = subprocess.run(argv, env=self.env, capture_output=True, text=True, timeout=timeout)
        out = p.stdout
        if json_out and out.strip():
            try:
                out = json.loads(out)
            except ValueError:
                pass
        return p.returncode, out

    def stub_calls(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    # fixtures -----------------------------------------------------------
    def write_accounts(self, accounts, active=None):
        self.home.mkdir(exist_ok=True)
        (self.home / "accounts.json").write_text(json.dumps({"version": 1, "accounts": accounts}))
        if active:
            (self.home / "active").write_text(active + "\n")
        for a in accounts:
            (self.home / a["id"]).mkdir(exist_ok=True)

    def mark_ready(self, account_id, email):
        d = self.home / account_id
        d.mkdir(parents=True, exist_ok=True)
        (d / ".stub-auth").write_text(json.dumps({"loggedIn": True, "email": email}))

    def three_accounts(self, active="a", ready=("a", "b", "c")):
        accts = [
            {"id": "a", "label": "Alpha One", "email": None, "color": "violet"},
            {"id": "b", "label": "Bravo", "email": None, "color": "teal"},
            {"id": "c", "label": "Charlie", "email": None, "color": "amber"},
        ]
        self.write_accounts(accts, active)
        for i in ready:
            self.mark_ready(i, f"{i}@example.com")
        return accts

    def paths(self):
        import claude_switch
        return claude_switch.Paths.from_env(self.env)
