#!/usr/bin/python3 -I
"""claude-switch: switch Claude Code between accounts.

Each account is its own CLAUDE_CONFIG_DIR under ~/.claude-accounts/<id>/; Claude Code
keeps a separate keychain item per config dir, so switching never touches secrets.
See "How it works" in README.md.
"""
import argparse
import contextlib
import errno
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional

COLORS = ("violet", "teal", "amber", "rose", "blue", "green")


# --------------------------------------------------------------------------- errors
class CLIError(Exception):
    exit_code = 1
    code = "error"


class UnknownAccount(CLIError):
    exit_code = 2
    code = "unknown_account"


class UsageError(CLIError):
    exit_code = 2
    code = "usage"


class NotLoggedIn(CLIError):
    exit_code = 3
    code = "not_logged_in"


class LockTimeout(CLIError):
    exit_code = 4
    code = "lock_timeout"


class WrongAccount(CLIError):
    exit_code = 6
    code = "wrong_account"


class LoginTimeout(CLIError):
    exit_code = 7
    code = "login_timeout"


class ClaudeNotFound(CLIError):
    exit_code = 8
    code = "claude_not_found"


class ConfigUnreadable(CLIError):
    exit_code = 9
    code = "config_unreadable"


class ConductorUnsupported(CLIError):
    exit_code = 5
    code = "conductor_unsupported"


class UpdateBlocked(CLIError):
    exit_code = 10
    code = "update_blocked"


# --------------------------------------------------------------------------- paths
class Paths:
    def __init__(self, home, shared, home_json, swap_backup, conductor_support, conductor_settings,
                 repo=None, installer=None):
        # The copy of this project the commands run from (a git clone), and its installer.
        self.repo = Path(repo) if repo else Path(__file__).resolve().parent.parent
        self.installer = Path(installer) if installer else self.repo / "install.sh"
        self.home = Path(home)
        self.shared = Path(shared)
        self.home_json = Path(home_json)
        self.swap_backup = Path(swap_backup)
        self.conductor_support = Path(conductor_support)
        self.conductor_settings = Path(conductor_settings)

    @classmethod
    def from_env(cls, env=None) -> "Paths":
        env = os.environ if env is None else env
        user_home = Path(env.get("HOME") or Path.home())

        def get(name, default):
            return Path(os.path.expanduser(env.get(name) or str(default)))

        return cls(
            home=get("CLAUDE_ACCOUNTS_HOME", user_home / ".claude-accounts"),
            shared=get("CLAUDE_SHARED_HOME", user_home / ".claude"),
            home_json=get("CLAUDE_HOME_JSON", user_home / ".claude.json"),
            swap_backup=get("CLAUDE_SWAP_BACKUP", user_home / ".claude-swap-backup"),
            conductor_support=get("CONDUCTOR_SUPPORT",
                                  user_home / "Library/Application Support/com.conductor.app"),
            conductor_settings=get("CONDUCTOR_SETTINGS", user_home / ".conductor/settings.toml"),
            repo=env.get("CLAUDE_ACCOUNTS_REPO"),
            installer=env.get("CLAUDE_ACCOUNTS_INSTALLER"),
        )

    def account_dir(self, account_id: str) -> Path:
        return self.home / account_id


# --------------------------------------------------------------------------- io helpers
def atomic_write_text(path: Path, text: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise


def atomic_write_json(path: Path, data) -> None:
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"  # serialise before touching disk
    atomic_write_text(path, text)


def slugify(label: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", label.strip().lower()).strip("-")


# --------------------------------------------------------------------------- store
class Store:
    def __init__(self, paths: Paths):
        self.paths = paths
        self.file = paths.home / "accounts.json"
        self.active_file = paths.home / "active"

    def load(self) -> dict:
        try:
            data = json.loads(self.file.read_text())
        except FileNotFoundError:
            return {"version": 1, "accounts": []}
        data.setdefault("accounts", [])
        return data

    def save(self, data: dict) -> None:
        atomic_write_json(self.file, data)

    def accounts(self) -> List[dict]:
        return self.load()["accounts"]

    def active(self) -> Optional[str]:
        try:
            value = self.active_file.read_text().strip()
        except FileNotFoundError:
            return None
        return value or None

    def set_active(self, account_id: str) -> None:
        atomic_write_text(self.active_file, account_id + "\n", 0o644)

    def account(self, id_or_label: str) -> dict:
        wanted = id_or_label.strip().lower()
        for a in self.accounts():
            if a["id"] == wanted or a["label"].lower() == wanted:
                return a
        for a in self.accounts():  # single-letter / initials convenience
            if slugify(a["label"]) == slugify(wanted):
                return a
        raise UnknownAccount(f"Unknown account: {id_or_label}")

    def lock(self, timeout: float = 5.0):
        """Serialises switches and account changes."""
        return self._flock(".lock", timeout, "Another switch is in progress; try again.")

    def data_lock(self):
        """Short lock around every accounts.json read-modify-write (separate file: never self-deadlocks)."""
        return self._flock(".data.lock", 10.0, "accounts.json is busy; try again.")

    @contextlib.contextmanager
    def mutate(self):
        with self.data_lock():
            data = self.load()
            before = json.dumps(data, sort_keys=True)
            yield data
            # Writing an unchanged file still fires the app's folder watcher, which refreshes, which
            # re-checks every account, which writes again: an endless loop. Only write real changes.
            if not self.file.exists() or json.dumps(data, sort_keys=True) != before:
                self.save(data)

    @contextlib.contextmanager
    def _flock(self, name: str, timeout: float, message: str):
        self.paths.home.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(self.paths.home / name), os.O_CREAT | os.O_RDWR, 0o600)
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError as e:
                    if e.errno not in (errno.EAGAIN, errno.EACCES, errno.EWOULDBLOCK):
                        raise
                    if time.monotonic() >= deadline:
                        raise LockTimeout(message)
                    time.sleep(0.05)
            yield
        finally:
            os.close(fd)

    def describe(self, a: dict) -> dict:
        return {
            "id": a["id"],
            "label": a["label"],
            "email": a.get("email"),
            "dir": str(self.paths.account_dir(a["id"])),
            "color": a.get("color", COLORS[0]),
            "ready": bool(a.get("ready", False)),
        }

    def listing(self) -> dict:
        return {"active": self.active(), "accounts": [self.describe(a) for a in self.accounts()]}


# --------------------------------------------------------------------------- shared links
SHARED_ENTRIES = (
    "settings.json", "settings.local.json", "CLAUDE.md", "skills", "plugins", "agents",
    "commands", "hooks", "output-styles", "keybindings.json", "projects", "file-history",
    "history.jsonl", "todos", "plans", "paste-cache", "downloads", "chrome",
)


def ensure_account_dir(paths: Paths, account_id: str) -> Path:
    d = paths.account_dir(account_id)
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def link_shared(paths: Paths, account_id: str) -> List[str]:
    """Symlink shared entries into the account dir. Returns names newly linked.

    Claude Code runs with CLAUDE_CONFIG_DIR=<account>, so it may create a shared entry inside the
    account (e.g. CLAUDE.md, agents/) or replace a symlinked file with a real one when it rewrites
    it. Such entries are moved into the shared home so every account sees them; nothing is lost.
    """
    d = ensure_account_dir(paths, account_id)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    linked = []
    for name in SHARED_ENTRIES:
        target = paths.shared / name
        link = d / name
        is_real = os.path.lexists(link) and not link.is_symlink()
        if not os.path.lexists(target):
            if not is_real:
                continue
            paths.shared.mkdir(parents=True, exist_ok=True)
            shutil.move(str(link), str(target))          # adopt: created inside this account
        elif link.is_symlink():
            if os.readlink(link) == str(target):
                continue
            link.unlink()
        elif is_real:
            if link.is_file() and target.is_file() and link.stat().st_mtime > target.stat().st_mtime:
                shutil.move(str(target), str(target.with_name(f"{name}.pre-promote-{stamp}")))
                shutil.move(str(link), str(target))      # promote the newer edit
            else:
                os.rename(link, d / f"{name}.pre-link-{stamp}")
        os.symlink(str(target), link)
        linked.append(name)
    return sorted(linked)


# --------------------------------------------------------------------------- .claude.json
IDENTITY_KEYS = (
    "oauthAccount", "userID", "primaryApiKey", "customApiKeyResponses",
    "isQualifiedForDataSharing", "groveChoiceSeenAt", "hasAvailableSubscription",
    "recommendedSubscription", "managedSettingsNoticeSeenOrg", "penguinModeOrgEnabled",
    "fable51OrgPickMoveDone", "claudeAiMcpEverConnected", "cachedExtraUsageDisabledReason",
    "metricsStatusCacheByPrincipal", "clientDataCacheSlots",
)
# Account/org-scoped caches: Claude Code refetches these, so dropping them is always safe.
IDENTITY_PATTERN = re.compile(r"(Cache$|^cached|^passes|^grove)")
SYNC_KEYS = ("mcpServers", "projects")


def is_identity_key(key: str) -> bool:
    return key in IDENTITY_KEYS or bool(IDENTITY_PATTERN.search(key))


def read_json_file(path: Path) -> Optional[dict]:
    """None if missing. Never renames or rewrites the file: a running Claude Code may be mid-write,
    so retry briefly, then raise ConfigUnreadable."""
    for attempt in range(4):
        try:
            return json.loads(path.read_text())
        except FileNotFoundError:
            return None
        except ValueError:
            time.sleep(0.1)
    raise ConfigUnreadable(f"Can't read {path} right now (it may be mid-write). Try again in a moment.")


def read_json_or_empty(path: Path) -> dict:
    try:
        return read_json_file(path) or {}
    except ConfigUnreadable:
        return {}


def account_json_path(paths: Paths, account_id: str) -> Path:
    return paths.account_dir(account_id) / ".claude.json"


def seed_claude_json(paths: Paths, account_id: str, source: Optional[Path]) -> None:
    target = account_json_path(paths, account_id)
    if target.exists():
        return
    ensure_account_dir(paths, account_id)
    home = read_json_or_empty(paths.home_json)
    if source is not None:
        data = json.loads(Path(source).read_text())
        for key in SYNC_KEYS:  # the backup may be stale; current preferences win
            if isinstance(home.get(key), dict):
                data[key] = {**(data.get(key) or {}), **home[key]}
    else:
        data = {k: v for k, v in home.items() if not is_identity_key(k)}
    atomic_write_json(target, data)


def sync_prefs(paths: Paths, from_id: str, to_id: str) -> None:
    src = read_json_or_empty(account_json_path(paths, from_id))   # unreadable source: skip this sync
    if not src:
        return
    target_path = account_json_path(paths, to_id)
    dst = read_json_file(target_path) or {}   # unreadable destination: raise, touch nothing
    for key in SYNC_KEYS:
        if isinstance(src.get(key), dict):
            merged = dict(dst.get(key) or {})
            merged.update(src[key])
            dst[key] = merged
    atomic_write_json(target_path, dst)


# --------------------------------------------------------------------------- commands
def cmd_list(paths: Paths, args) -> dict:
    return Store(paths).listing()


def cmd_dir(paths: Paths, args) -> str:
    store = Store(paths)
    active = store.active()
    if not active:
        raise UsageError("No active account. Run: claude-switch setup")
    return str(paths.account_dir(active))


def cmd_switch(paths: Paths, args) -> dict:
    return switch(paths, args.target, force=args.force)


def cmd_next(paths: Paths, args) -> dict:
    return switch_next(paths, args.from_id)


def apply_env(paths: Paths) -> dict:
    """Tell launchd (GUI apps) about the active account. The menu-bar app runs this at login."""
    active = Store(paths).active()
    if active:
        subprocess.run(["launchctl", "setenv", "CLAUDE_CONFIG_DIR", str(paths.account_dir(active))],
                       capture_output=True)
    return {"active": active}


def cmd_status(paths: Paths, args) -> dict:
    account = Store(paths).account(args.target)
    ready, email = is_ready(paths, account["id"])
    return {"id": account["id"], "ready": ready, "email": email}


# --------------------------------------------------------------------------- readiness + switching
def child_env(paths: Paths, account_id: str) -> Dict[str, str]:
    env = dict(os.environ)
    env["CLAUDE_CONFIG_DIR"] = str(paths.account_dir(account_id))
    return env


def is_ready(paths: Paths, account_id: str) -> "tuple":
    """Ask Claude Code itself whether this account dir is logged in. Records the result.

    Only a definite answer from `claude auth status` is recorded. If the check itself fails (timeout,
    garbled output) we keep what was recorded before instead of flipping a signed-in account to
    "not signed in" because of one slow moment."""
    ready, email, known = False, None, True
    if paths.account_dir(account_id).is_dir():
        try:
            p = subprocess.run(["claude", "auth", "status", "--json"], env=child_env(paths, account_id),
                               capture_output=True, text=True, timeout=10)
            info = json.loads(p.stdout or "{}")
            if isinstance(info, dict) and "loggedIn" in info:
                ready = bool(info["loggedIn"])
                email = info.get("email")
            else:
                known = False
        except FileNotFoundError:
            raise ClaudeNotFound("Claude Code isn't installed or isn't on PATH (looked for `claude`).")
        except (OSError, ValueError, subprocess.TimeoutExpired):
            known = False
    if not known:
        previous = next((a for a in Store(paths).accounts() if a["id"] == account_id), {})
        return bool(previous.get("ready")), previous.get("email")
    if ready and not email:
        data = read_json_or_empty(account_json_path(paths, account_id))
        email = (data.get("oauthAccount") or {}).get("emailAddress")
    _record(paths, account_id, ready=ready, email=email if ready else None)
    return ready, email


def _record(paths: Paths, account_id: str, ready: bool, email: Optional[str]) -> None:
    with Store(paths).mutate() as data:
        for a in data["accounts"]:
            if a["id"] == account_id:
                a["ready"] = ready
                if email:
                    a["email"] = email


def switch(paths: Paths, target: str, force: bool = False) -> dict:
    store = Store(paths)
    account = store.account(target)
    aid = account["id"]
    ready, email = is_ready(paths, aid)   # slow (runs claude); done before taking the lock
    if not ready and not force:
        raise NotLoggedIn(f"Not logged in: {account['label']}. Run: claude-switch login {aid}")
    with store.lock():
        previous = store.active()
        link_shared(paths, aid)
        if previous and previous != aid:
            sync_prefs(paths, previous, aid)
        store.set_active(aid)
        subprocess.run(["launchctl", "setenv", "CLAUDE_CONFIG_DIR", str(paths.account_dir(aid))],
                       capture_output=True)
    email = email or store.account(aid).get("email")
    return {"active": aid, "label": account["label"], "email": email, "previous": previous, "already": False,
            "message": f"Now on: {account['label']}" + (f" ({email})" if email else "")}


# --------------------------------------------------------------------------- conductor
def _conductor_session_states(paths: Paths) -> Dict[str, bool]:
    """session id -> busy. Raises ConductorUnsupported if Conductor's DB can't be read."""
    db = paths.conductor_support / "conductor.db"
    if not db.is_file():
        raise ConductorUnsupported("Can't read Conductor's state; restart the chat in Conductor instead.")
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
        try:
            rows = con.execute(
                "select s.id, s.status, st.live_state from sessions s "
                "left join session_state st on st.session_id = s.id").fetchall()
        finally:
            con.close()
    except sqlite3.Error as e:
        raise ConductorUnsupported(f"Can't read Conductor's state ({e}); restart the chat in Conductor instead.")
    busy = {}
    for sid, status, live in rows:
        try:
            live = json.loads(live) if live else {}
        except ValueError:
            live = {"status": "unknown"}
        busy[sid] = (status != "idle" or live.get("status", "idle") != "idle"
                     or bool(live.get("backgroundTasks")))
    return busy


def conductor_processes(paths: Paths) -> List[dict]:
    """Conductor's Claude Code processes with the config dir and session each one runs under."""
    prefix = str(paths.conductor_support / "agent-binaries" / "claude") + "/"
    out = subprocess.run(["ps", "-E", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    procs = []
    for line in out.splitlines():
        line = line.strip()
        pid_s, _, command = line.partition(" ")
        if not pid_s.isdigit() or not command.startswith(prefix):
            continue
        tokens = command.split(" ")
        env = dict(t.split("=", 1) for t in tokens if "=" in t and t.split("=", 1)[0].isupper())
        if not env.get("CONDUCTOR_SESSION_ID"):
            continue  # helpers such as --chrome-native-host aren't chats
        procs.append({
            "pid": int(pid_s),
            "config_dir": env.get("CLAUDE_CONFIG_DIR"),  # None = default ~/.claude login
            "session": env.get("CONDUCTOR_SESSION_ID"),
        })
    return procs


def conductor_move(paths: Paths, dry_run: bool = False) -> dict:
    store = Store(paths)
    active = store.active()
    active_dir = str(paths.account_dir(active)) if active else None
    stale = [p for p in conductor_processes(paths) if p["config_dir"] != active_dir]
    result = {"moved": [], "skipped_busy": [], "unsupported": False, "pending": len(stale)}
    if not stale:
        return result
    busy = _conductor_session_states(paths)
    for p in stale:
        if busy.get(p["session"], True):  # unknown session: leave it alone
            result["skipped_busy"].append(p["pid"])
            continue
        if not dry_run:
            with contextlib.suppress(ProcessLookupError):
                os.kill(p["pid"], signal.SIGTERM)
        result["moved"].append(p["pid"])
    return result


# --------------------------------------------------------------------------- account management
def keychain_service(account_dir: Path) -> str:
    """Name of the keychain item Claude Code keeps for a CLAUDE_CONFIG_DIR."""
    return "Claude Code-credentials-" + hashlib.sha256(str(account_dir).encode()).hexdigest()[:8]


CLAUDESWITCHER_BACKUP = re.compile(r"^\.claude-config-\d+-(?P<email>.+@.+)\.json$")


def importable(paths: Paths) -> List[dict]:
    """Accounts saved by ClaudeSwitcher.app that haven't been imported yet."""
    configs = paths.swap_backup / "configs"
    if not configs.is_dir():
        return []
    have = {(a.get("email") or "").lower() for a in Store(paths).accounts()}
    found = []
    for f in sorted(configs.iterdir()):
        m = CLAUDESWITCHER_BACKUP.match(f.name)
        if m and m.group("email").lower() not in have:
            email = m.group("email").lower()
            found.append({"email": email, "label": email.split("@")[0], "source": str(f)})
    return found


def _new_account(paths: Paths, data: dict, label: str, source: Optional[Path],
                 email: Optional[str] = None) -> str:
    label = label.strip()
    aid = slugify(label)
    if not aid:
        raise UsageError("Give the account a name.")
    if any(a["id"] == aid or a["label"].lower() == label.lower() for a in data["accounts"]):
        raise UsageError(f"An account called {label} already exists.")
    color = COLORS[len(data["accounts"]) % len(COLORS)]
    data["accounts"].append({"id": aid, "label": label, "email": email, "color": color})
    ensure_account_dir(paths, aid)
    seed_claude_json(paths, aid, source)
    link_shared(paths, aid)
    return aid


def setup(paths: Paths) -> dict:
    """Idempotent: create the accounts folder, re-link shared entries, pick an active account."""
    store = Store(paths)
    paths.home.mkdir(parents=True, exist_ok=True)
    with store.lock():
        for a in store.accounts():
            link_shared(paths, a["id"])
    accounts = store.accounts()
    if accounts and store.active() not in {a["id"] for a in accounts}:
        # Only ever activate a signed-in account: activating an unready one would log out
        # every terminal, Conductor chat and app until its browser sign-in finished.
        ready = [a["id"] for a in accounts if is_ready(paths, a["id"])[0]]
        if ready:
            switch(paths, ready[0])
    result = store.listing()
    result["importable"] = importable(paths)
    return result


def import_claudeswitcher(paths: Paths, email: str, label: Optional[str]) -> dict:
    match = [i for i in importable(paths) if i["email"] == email.strip().lower()]
    if not match:
        raise UsageError(f"No ClaudeSwitcher account {email} to import.")
    store = Store(paths)
    with store.lock(), store.mutate() as data:
        _new_account(paths, data, label or match[0]["label"], Path(match[0]["source"]), match[0]["email"])
    return store.listing()


def add(paths: Paths, label: str) -> dict:
    store = Store(paths)
    with store.lock(), store.mutate() as data:
        _new_account(paths, data, label, None)
    return store.listing()


LOGIN_TIMEOUT = 180  # seconds to finish signing in before we give up (nothing changes if abandoned)


def _run_login(cmd: List[str], env: Dict[str, str], timeout: float) -> None:
    """Run `claude auth login`, killing it on timeout or when we are cancelled (SIGTERM/SIGINT)."""
    try:
        child = subprocess.Popen(cmd, env=env, stdout=sys.stderr)
    except FileNotFoundError:
        raise ClaudeNotFound("Claude Code isn't installed or isn't on PATH (looked for `claude`).")

    def cancel(signum, frame):
        with contextlib.suppress(ProcessLookupError):
            child.kill()
        child.wait()
        raise SystemExit(128 + signum)

    previous = {s: signal.signal(s, cancel) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        child.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
        raise LoginTimeout("Sign-in wasn't finished in the browser, so nothing changed. Try again any time.")
    finally:
        for s, h in previous.items():
            signal.signal(s, h)


def login(paths: Paths, target: str, timeout: float = LOGIN_TIMEOUT) -> dict:
    account = Store(paths).account(target)
    aid = account["id"]
    ensure_account_dir(paths, aid)
    link_shared(paths, aid)
    # The login flow is interactive (browser); keep our stdout clean for --json.
    expected = (account.get("email") or "").lower() or None
    was_ready = bool(account.get("ready"))
    cmd = ["claude", "auth", "login"] + (["--email", expected] if expected else [])
    try:
        _run_login(cmd, child_env(paths, aid), timeout)
    finally:
        ready, email = is_ready(paths, aid)  # re-check either way: an abandoned login leaves the old one intact
    if ready and expected and email and email.lower() != expected:
        # The browser was signed in to a different Claude account. Undo, so this slot never
        # silently holds the wrong login.
        subprocess.run(["claude", "auth", "logout"], env=child_env(paths, aid), capture_output=True)
        _record(paths, aid, ready=False, email=expected)
        # The login itself already replaced the saved one and Claude Code gives no way to put it back,
        # so say so rather than claim nothing changed.
        signed_out = " It was signed out, because the previous login was replaced." if was_ready else ""
        raise WrongAccount(f"Signed in as {email}, but {account['label']} is {expected}.{signed_out} "
                           f"Switch claude.ai in your browser to {expected} and log in again.")
    return {"id": aid, "ready": ready, "email": email}


def rename(paths: Paths, target: str, label: str) -> dict:
    store = Store(paths)
    label = label.strip()
    if not slugify(label):
        raise UsageError("Give the account a name.")
    with store.lock():
        aid = store.account(target)["id"]
        with store.mutate() as data:
            if any(a["id"] != aid and (a["id"] == slugify(label) or a["label"].lower() == label.lower())
                   for a in data["accounts"]):
                raise UsageError(f"An account called {label} already exists.")
            for a in data["accounts"]:
                if a["id"] == aid:
                    a["label"] = label
    return store.listing()


def remove(paths: Paths, target: str, yes: bool) -> dict:
    store = Store(paths)
    with store.lock():
        account = store.account(target)
        aid = account["id"]
        if not yes:
            raise UsageError(f"This logs out and deletes {account['label']}. Re-run with --yes.")
        if store.active() == aid:
            raise UsageError(f"{account['label']} is the active account. Switch away first.")
        d = paths.account_dir(aid)
        subprocess.run(["security", "delete-generic-password", "-s", keychain_service(d),
                        "-a", os.environ.get("USER", "")], capture_output=True)
        if d.is_dir():
            shutil.rmtree(d)  # symlinks inside are removed, never followed
        with store.mutate() as data:
            data["accounts"] = [a for a in data["accounts"] if a["id"] != aid]
    return store.listing()


def switch_next(paths: Paths, from_id: Optional[str] = None) -> dict:
    """Move to the next signed-in account. With from_id (the account the caller was using), do
    nothing if the active account already moved on — e.g. another terminal hit the same limit first."""
    store = Store(paths)
    accounts = store.accounts()
    if not accounts:
        raise UsageError("No accounts. Run: claude-switch setup")
    ids = [a["id"] for a in accounts]
    active = store.active()
    if from_id and active and active != from_id:
        current = store.account(active)
        return {"active": active, "label": current["label"], "email": current.get("email"),
                "previous": active, "already": True,
                "message": f"Already on {current['label']} (switched elsewhere)"}
    start = ids.index(active) if active in ids else -1
    for step in range(1, len(ids) + 1):
        candidate = ids[(start + step) % len(ids)]
        if candidate == active:
            continue
        if is_ready(paths, candidate)[0]:
            return switch(paths, candidate)
    raise NotLoggedIn("No other account is logged in. Run: claude-switch login <id>")


# --------------------------------------------------------------------------- updates
UPDATE_REASONS = {
    "not_git": "This copy wasn't installed with git, so it can't update itself. Download the latest version to update.",
    "no_upstream": "This copy isn't following a branch on GitHub, so it can't update itself.",
    "offline": "Couldn't reach GitHub. Check your connection and try again.",
    "local_changes": "A new version is available, but this copy has changes of its own. "
                     "Update by hand: git pull, then ./install.sh.",
}


def _git(paths: Paths, *args, timeout=30) -> subprocess.CompletedProcess:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")   # never stop to ask for a password
    return subprocess.run(["git", "-C", str(paths.repo), *args], env=env, capture_output=True, text=True, timeout=timeout)


def update_check(paths: Paths) -> dict:
    """Is there a newer version on GitHub? Fetches, but never changes the installed copy."""
    def answer(reason=None, behind=0, current=None, latest=None):
        available = behind > 0
        if reason:
            message = UPDATE_REASONS[reason]
        elif available:
            message = "A new version is available."
        else:
            message = "You're up to date."
        return {"available": available, "behind": behind, "current": current, "latest": latest,
                "reason": reason, "message": message}

    try:
        if _git(paths, "rev-parse", "--is-inside-work-tree").returncode != 0:
            return answer("not_git")
        current = _git(paths, "rev-parse", "--short", "HEAD").stdout.strip()
        if _git(paths, "rev-parse", "--abbrev-ref", "@{u}").returncode != 0:
            return answer("no_upstream", current=current)
        if _git(paths, "fetch", "--quiet", timeout=25).returncode != 0:
            return answer("offline", current=current)
        behind = int(_git(paths, "rev-list", "--count", "HEAD..@{u}").stdout.strip() or 0)
        latest = _git(paths, "rev-parse", "--short", "@{u}").stdout.strip()
        dirty = bool(_git(paths, "status", "--porcelain", "--untracked-files=no").stdout.strip())
    except subprocess.TimeoutExpired:
        return answer("offline")
    except FileNotFoundError:
        return answer("not_git")
    return answer("local_changes" if behind and dirty else None, behind, current, latest)


def update(paths: Paths, check_only: bool, detach: bool) -> dict:
    """Download the newest version and re-run the installer, which rebuilds and restarts the menu-bar app."""
    info = update_check(paths)
    if check_only:
        return info
    if not info["available"]:
        return dict(info, started=False)
    if info["reason"]:
        raise UpdateBlocked(info["message"])
    if _git(paths, "pull", "--ff-only", "--quiet", timeout=60).returncode != 0:
        raise UpdateBlocked(UPDATE_REASONS["local_changes"])
    if not detach:
        subprocess.run([str(paths.installer)], cwd=str(paths.repo))
        return {"started": True, "message": "Updated."}
    # The installer stops the menu-bar app, which is what asked for the update. Run it in a session of
    # its own so it isn't stopped along with the app.
    paths.home.mkdir(parents=True, exist_ok=True)
    with open(paths.home / "update.log", "w") as log:
        subprocess.Popen([str(paths.installer)], cwd=str(paths.repo), stdin=subprocess.DEVNULL,
                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    return {"started": True, "message": "Updating. The menu-bar app restarts in a moment."}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="claude-switch", description="Switch Claude Code accounts.")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    sub = p.add_subparsers(dest="cmd")
    sub.add_parser("list", help="list accounts (default)").set_defaults(fn=cmd_list)
    sub.add_parser("dir", help="print the active account's config dir").set_defaults(fn=cmd_dir, plain=True)
    s = sub.add_parser("switch", help="switch to an account by id or label")
    s.add_argument("target")
    s.add_argument("--force", action="store_true")
    s.set_defaults(fn=cmd_switch)
    s = sub.add_parser("next", help="switch to the next logged-in account")
    s.add_argument("--from", dest="from_id", help="only advance if this account is still active")
    s.set_defaults(fn=cmd_next)
    sub.add_parser("apply-env", help="re-apply CLAUDE_CONFIG_DIR for GUI apps").set_defaults(fn=lambda p, a: apply_env(p))
    s = sub.add_parser("status", help="check whether an account is logged in")
    s.add_argument("target")
    s.set_defaults(fn=cmd_status)
    sub.add_parser("setup", help="one-time setup (safe to re-run)").set_defaults(fn=lambda p, a: setup(p))
    s = sub.add_parser("import-claudeswitcher", help="import an account saved by ClaudeSwitcher.app")
    s.add_argument("email")
    s.add_argument("--label")
    s.set_defaults(fn=lambda p, a: import_claudeswitcher(p, a.email, a.label))
    s = sub.add_parser("add", help="add an account")
    s.add_argument("label")
    s.set_defaults(fn=lambda p, a: add(p, a.label))
    s = sub.add_parser("login", help="log an account in (opens the browser)")
    s.add_argument("target")
    s.add_argument("--timeout", type=float, default=LOGIN_TIMEOUT, help="seconds to wait for the browser")
    s.set_defaults(fn=lambda p, a: login(p, a.target, a.timeout))
    s = sub.add_parser("rename", help="rename an account")
    s.add_argument("target")
    s.add_argument("label")
    s.set_defaults(fn=lambda p, a: rename(p, a.target, a.label))
    s = sub.add_parser("remove", help="log out and delete an account")
    s.add_argument("target")
    s.add_argument("--yes", action="store_true")
    s.set_defaults(fn=lambda p, a: remove(p, a.target, a.yes))
    s = sub.add_parser("update", help="get the newest version from GitHub and reinstall")
    s.add_argument("--check", action="store_true", help="only say whether a new version is available")
    s.set_defaults(fn=lambda p, a: update(p, a.check, detach=a.json))
    s = sub.add_parser("conductor-move", help="restart idle Conductor chats on the active account")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=lambda p, a: conductor_move(p, a.dry_run))
    return p


def render_text(result) -> str:
    if isinstance(result, str):
        return result
    if isinstance(result, dict) and "accounts" in result:
        lines = []
        for a in result["accounts"]:
            mark = "●" if a["id"] == result.get("active") else " "
            state = " ".join(x for x in (a.get("email"), "" if a.get("ready") else "(not signed in)") if x)
            lines.append(f"{mark} {a['label']:<20} {state}")
        return "\n".join(lines) if lines else "No accounts. Run: claude-switch setup"
    if isinstance(result, dict) and "message" in result:
        return result["message"]
    return json.dumps(result, indent=2)


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    want_json = "--json" in argv
    argv = [a for a in argv if a != "--json"]
    parser = build_parser()
    commands = next(a.choices for a in parser._actions if isinstance(a, argparse._SubParsersAction))
    if argv and not argv[0].startswith("-") and argv[0] not in commands:
        argv.insert(0, "switch")   # `claude-switch work` == `claude-switch switch work`
    args = parser.parse_args(argv)
    args.json = want_json
    if not getattr(args, "fn", None):
        args.fn = cmd_list
    paths = Paths.from_env()
    try:
        result = args.fn(paths, args)
    except CLIError as e:
        if want_json:
            print(json.dumps({"error": str(e), "code": e.code}))
        else:
            print(f"claude-switch: {e}", file=sys.stderr)
        return e.exit_code
    if want_json and not getattr(args, "plain", False):
        print(json.dumps(result))
    else:
        print(render_text(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
