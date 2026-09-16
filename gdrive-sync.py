#!/usr/bin/env python3
"""rclone bisync runner and status helper for the Omarchy Google Drive plugin."""

import argparse
import configparser
import fcntl
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "gdrive-sync"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local" / "state")) / "gdrive-sync"
CONFIG_FILE = CONFIG_DIR / "config.json"
CURRENT_FILE = STATE_DIR / "current.json"
LAST_RUN_FILE = STATE_DIR / "last-run.json"
HISTORY_FILE = STATE_DIR / "history.jsonl"
RESYNC_FLAG = STATE_DIR / "resync-requested"
LOCK_FILE = STATE_DIR / "run.lock"
LOG_DIR = STATE_DIR / "logs"
UNIT_DIR = HOME / ".config" / "systemd" / "user"
UNIT = "gdrive-sync"
RC_ADDR = "127.0.0.1:5573"
BISYNC_CACHE = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "rclone" / "bisync"

KEEP_LOGS = 12
HISTORY_KEEP = 200
HISTORY_SHOW = 8
MAX_ERRORS = 60
MAX_WARNINGS = 20
MAX_FILES = 40

DEFAULT_CONFIG = {
    "remote": "gdrive:",
    "localDir": str(HOME / "GoogleDrive"),
    "intervalSec": 60,
    "extraArgs": ["--drive-skip-gdocs"],
}

FILE_ACTIONS = ("Copied", "Deleted", "Updated modification time", "Moved", "Renamed", "Removed")
CHANGES_RE = re.compile(r"Path(\d):\s+(\d+) changes:\s+(\d+) new,\s+(\d+) modified,\s+(\d+) deleted")


# ---------------------------------------------------------------- file helpers

def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    stored = read_json(CONFIG_FILE)
    if isinstance(stored, dict):
        for key in DEFAULT_CONFIG:
            if key in stored and stored[key] is not None:
                cfg[key] = stored[key]
    cfg["localDir"] = str(Path(str(cfg["localDir"])).expanduser())
    cfg["remote"] = str(cfg["remote"]).strip()
    if not isinstance(cfg["extraArgs"], list):
        cfg["extraArgs"] = list(DEFAULT_CONFIG["extraArgs"])
    try:
        cfg["intervalSec"] = max(30, min(3600, int(cfg["intervalSec"])))
    except (TypeError, ValueError):
        cfg["intervalSec"] = DEFAULT_CONFIG["intervalSec"]
    return cfg


def save_config(cfg):
    write_json(CONFIG_FILE, cfg)


def run_cmd(cmd, timeout=15):
    try:
        done = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return 1, "", str(exc)
    return done.returncode, done.stdout, done.stderr


# ---------------------------------------------------------------- rclone / systemd

def rclone_remotes():
    conf = os.environ.get("RCLONE_CONFIG")
    if not conf:
        conf = str(Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "rclone" / "rclone.conf")
    parser = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        parser.read(conf, encoding="utf-8")
    except (OSError, configparser.Error):
        return []
    return [name + ":" for name in parser.sections()]


def systemctl(*args, timeout=15):
    return run_cmd(["systemctl", "--user", *args], timeout=timeout)


def unit_props(unit, props):
    code, out, _ = systemctl("show", unit, "--property=" + ",".join(props))
    result = {}
    if code != 0:
        return result
    for line in out.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def listing_name(remote, local):
    remote_part = remote.rstrip("/").replace(":", "_").replace("/", "_")
    local_part = str(local).strip("/").replace("/", "_")
    return f"{remote_part}..{local_part}"


def listings_present(cfg):
    name = listing_name(cfg["remote"], cfg["localDir"])
    return (BISYNC_CACHE / f"{name}.path1.lst").exists() and (BISYNC_CACHE / f"{name}.path2.lst").exists()


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
    except (OSError, TypeError, ValueError):
        return False
    return True


def rc_stats():
    req = urllib.request.Request(
        f"http://{RC_ADDR}/core/stats", data=b"{}",
        headers={"Content-Type": "application/json"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=1) as resp:
            data = json.load(resp)
    except Exception:
        return None
    transferring = []
    for item in (data.get("transferring") or [])[:10]:
        transferring.append({
            "name": item.get("name", ""),
            "size": item.get("size", 0),
            "bytes": item.get("bytes", 0),
            "percentage": item.get("percentage", 0),
            "speed": item.get("speed", 0),
            "eta": item.get("eta"),
        })
    keys = ("bytes", "totalBytes", "speed", "transfers", "totalTransfers", "checks",
            "totalChecks", "errors", "lastError", "elapsedTime", "eta", "fatalError")
    stats = {key: data.get(key) for key in keys}
    stats["transferring"] = transferring
    return stats


def notify(title, body, urgency="normal"):
    exe = shutil.which("notify-send")
    if not exe:
        return
    subprocess.Popen([exe, "-a", "Google Drive", "-u", urgency, title, body],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# ---------------------------------------------------------------- log parsing

def parse_log(path):
    errors, warnings, files = [], [], []
    seen = set()
    warning_index = {}
    counts = {"uploaded": 0, "downloaded": 0, "deleted": 0, "other": 0}
    changes = {}
    needs_resync = False
    critical = ""
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return {"errors": [], "warnings": [], "files": [], "counts": counts,
                "changes": changes, "needsResync": False, "headline": ""}
    with fh:
        for line in fh:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            level = str(rec.get("level", ""))
            msg = str(rec.get("msg", "")).strip()
            obj = str(rec.get("object") or "")
            when = str(rec.get("time", ""))
            if level == "error":
                if "--resync" in msg or ("prior" in msg and "listings" in msg):
                    needs_resync = True
                if not critical and ("critical" in msg.lower() or "aborted" in msg.lower()):
                    critical = msg
                key = (msg, obj)
                if key in seen:
                    continue
                seen.add(key)
                if len(errors) < MAX_ERRORS:
                    errors.append({"msg": msg, "object": obj, "time": when})
            elif level in ("warning", "notice"):
                if "Failed to bisync" in msg and not critical:
                    critical = msg
                match = CHANGES_RE.search(msg)
                if match:
                    changes["path" + match.group(1)] = {
                        "total": int(match.group(2)), "new": int(match.group(3)),
                        "modified": int(match.group(4)), "deleted": int(match.group(5)),
                    }
                    continue
                if msg.startswith(("Bisync successful", "Bisync aborted", "Failed to bisync", "Serving remote control")):
                    continue
                grouped = warning_index.get(msg)
                if grouped is not None:
                    grouped["count"] += 1
                    continue
                if len(warnings) < MAX_WARNINGS:
                    entry = {"msg": msg, "object": obj, "time": when, "count": 1}
                    warnings.append(entry)
                    warning_index[msg] = entry
            elif level == "info" and obj and msg.startswith(FILE_ACTIONS):
                direction = "down" if "local" in str(rec.get("objectType", "")) else "up"
                if msg.startswith(("Deleted", "Removed")):
                    counts["deleted"] += 1
                elif msg.startswith("Copied"):
                    counts["downloaded" if direction == "down" else "uploaded"] += 1
                else:
                    counts["other"] += 1
                files.append({"path": obj, "action": msg, "direction": direction, "time": when})
    headline = critical or (errors[-1]["msg"] if errors else "")
    return {
        "errors": errors, "warnings": warnings, "files": files[-MAX_FILES:],
        "counts": counts, "changes": changes, "needsResync": needs_resync, "headline": headline,
    }


def rotate_logs():
    try:
        logs = sorted(LOG_DIR.glob("run-*.log"), key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return
    for old in logs[KEEP_LOGS:]:
        try:
            old.unlink()
        except OSError:
            pass


def append_history(entry):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lines = []
    try:
        with open(HISTORY_FILE, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        pass
    lines.append(json.dumps(entry, ensure_ascii=False))
    lines = lines[-HISTORY_KEEP:]
    tmp = HISTORY_FILE.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, HISTORY_FILE)


def read_history(limit):
    try:
        with open(HISTORY_FILE, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out = []
    for line in reversed(lines[-limit:]):
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


# ---------------------------------------------------------------- systemd units

def unit_texts(interval):
    helper = Path(__file__).resolve()
    service = (
        "[Unit]\n"
        "Description=Google Drive sync (rclone bisync)\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n\n"
        "[Service]\n"
        "Type=oneshot\n"
        f"ExecStart=/usr/bin/python3 {helper} run\n"
        "Nice=10\n"
    )
    timer = (
        "[Unit]\n"
        "Description=Google Drive sync timer\n\n"
        "[Timer]\n"
        "OnBootSec=30s\n"
        "OnStartupSec=30s\n"
        f"OnUnitInactiveSec={interval}s\n"
        "AccuracySec=5s\n\n"
        "[Install]\n"
        "WantedBy=timers.target\n"
    )
    return service, timer


def write_if_changed(path, text):
    try:
        if path.read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return True


def ensure_units(interval, enable=True):
    service_text, timer_text = unit_texts(interval)
    service_path = UNIT_DIR / f"{UNIT}.service"
    timer_path = UNIT_DIR / f"{UNIT}.timer"
    changed = write_if_changed(service_path, service_text)
    changed = write_if_changed(timer_path, timer_text) or changed
    if changed:
        systemctl("daemon-reload")
    props = unit_props(f"{UNIT}.timer", ["UnitFileState", "ActiveState"])
    if enable and props.get("UnitFileState") != "enabled":
        systemctl("enable", "--now", f"{UNIT}.timer")
    elif changed and props.get("ActiveState") == "active":
        systemctl("restart", f"{UNIT}.timer")
    return changed


# ---------------------------------------------------------------- commands

def cmd_status(_args):
    cfg = load_config()
    remotes = rclone_remotes()
    remote_name = cfg["remote"].split(":", 1)[0] + ":"
    local = Path(cfg["localDir"])
    timer = unit_props(f"{UNIT}.timer", ["LoadState", "UnitFileState", "ActiveState"])
    service = unit_props(f"{UNIT}.service", ["ActiveState", "SubState"])

    current = read_json(CURRENT_FILE)
    running = bool(current) and pid_alive(current.get("pid"))
    if current and not running:
        current = None
    if current:
        current = dict(current)
        current["elapsedSec"] = max(0, time.time() - float(current.get("startedAt", time.time())))
        current["progress"] = rc_stats()
        log_path = current.get("log")
        partial = parse_log(log_path) if log_path else None
        current["errors"] = partial["errors"] if partial else []
        current["files"] = partial["files"] if partial else []

    last = read_json(LAST_RUN_FILE)
    needs_resync = bool(last and last.get("needsResync")) or not listings_present(cfg)
    timer_active = timer.get("ActiveState") == "active"
    next_run = None
    if timer_active and not running and last and last.get("endedAt"):
        next_run = float(last["endedAt"]) + cfg["intervalSec"]

    print(json.dumps({
        "ok": True,
        "loaded": True,
        "now": time.time(),
        "rcloneInstalled": shutil.which("rclone") is not None,
        "remoteConfigured": remote_name in remotes,
        "remotes": remotes,
        "config": cfg,
        "localDirExists": local.is_dir(),
        "unitsInstalled": timer.get("LoadState") == "loaded",
        "timerEnabled": timer.get("UnitFileState") == "enabled",
        "timerActive": timer_active,
        "serviceState": service.get("ActiveState", ""),
        "running": running,
        "current": current,
        "lastRun": last,
        "needsResync": needs_resync,
        "nextRunAt": next_run,
        "history": read_history(HISTORY_SHOW),
    }, ensure_ascii=False))
    return 0


def finish_run(result, previous):
    write_json(LAST_RUN_FILE, result)
    append_history({
        "startedAt": result["startedAt"], "endedAt": result["endedAt"],
        "durationSec": result["durationSec"], "ok": result["ok"], "resync": result["resync"],
        "counts": result.get("counts", {}), "errorCount": len(result.get("errors", [])),
        "headline": result.get("headline", ""),
    })
    try:
        CURRENT_FILE.unlink()
    except OSError:
        pass
    rotate_logs()
    was_ok = previous is None or bool(previous.get("ok"))
    if not result["ok"] and was_ok:
        body = result.get("headline") or "Open the Google Drive panel in the bar for details."
        if result.get("needsResync"):
            body = "A resync is required. " + body
        notify("Google Drive sync failed", body, "critical")
    elif result["ok"] and previous is not None and not previous.get("ok"):
        notify("Google Drive sync restored", "Syncing is working again.")


def cmd_run(args):
    cfg = load_config()
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    lock = open(LOCK_FILE, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("skip: a sync is already running")
        return 0

    resync = bool(args.resync) or RESYNC_FLAG.exists()
    try:
        RESYNC_FLAG.unlink()
    except OSError:
        pass

    previous = read_json(LAST_RUN_FILE)
    started = time.time()
    local = Path(cfg["localDir"])
    remote_name = cfg["remote"].split(":", 1)[0] + ":"
    failure = ""
    if shutil.which("rclone") is None:
        failure = "rclone is not installed"
    elif remote_name not in rclone_remotes():
        failure = f"rclone remote \"{remote_name}\" does not exist (run rclone config)"
    elif not local.is_dir():
        failure = f"Local folder not found: {local}"
    if failure:
        ended = time.time()
        finish_run({
            "startedAt": started, "endedAt": ended, "durationSec": ended - started,
            "exitCode": 1, "ok": False, "resync": resync, "log": "",
            "errors": [{"msg": failure, "object": "", "time": ""}], "warnings": [], "files": [],
            "counts": {}, "changes": {}, "needsResync": False, "headline": failure,
        }, previous)
        print(failure, file=sys.stderr)
        return 1

    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(started))
    log_path = LOG_DIR / f"run-{stamp}.log"
    cmd = [
        "rclone", "bisync", cfg["remote"], str(local),
        "--rc", "--rc-addr", RC_ADDR, "--rc-no-auth",
        "--use-json-log", "--log-file", str(log_path), "--log-level", "INFO", "--stats", "0",
        "--recover", "--resilient", "--max-lock", "2m",
        *[str(a) for a in cfg["extraArgs"]],
    ]
    if resync:
        cmd += ["--resync", "--resync-mode", "newer"]

    proc = subprocess.Popen(cmd)
    write_json(CURRENT_FILE, {"pid": proc.pid, "startedAt": started, "resync": resync, "log": str(log_path)})

    def forward(signum, _frame):
        proc.send_signal(signal.SIGINT if signum == signal.SIGINT else signal.SIGTERM)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    code = proc.wait()
    ended = time.time()

    summary = parse_log(log_path)
    if code != 0 and not summary["headline"]:
        summary["headline"] = f"rclone exited with code {code}"
    if code < 0:
        summary["headline"] = "Sync cancelled"
    result = {
        "startedAt": started, "endedAt": ended, "durationSec": ended - started,
        "exitCode": code, "ok": code == 0, "resync": resync, "log": str(log_path),
        **summary,
    }
    if code == 0:
        result["needsResync"] = False
    finish_run(result, previous)
    return 0 if code == 0 else 1


def cmd_apply_settings(args):
    cfg = load_config()
    changed = False
    if args.remote:
        remote = args.remote.strip()
        if ":" not in remote:
            remote += ":"
        if remote != cfg["remote"]:
            cfg["remote"] = remote
            changed = True
    if args.local_dir:
        local = str(Path(args.local_dir).expanduser())
        if local != cfg["localDir"]:
            cfg["localDir"] = local
            changed = True
    if args.interval:
        interval = max(30, min(3600, int(args.interval)))
        if interval != cfg["intervalSec"]:
            cfg["intervalSec"] = interval
            changed = True
    if changed or not CONFIG_FILE.exists():
        save_config(cfg)
    ensure_units(cfg["intervalSec"], enable=not args.no_enable)
    return cmd_status(args)


def cmd_set_folder(args):
    target = Path(args.path).expanduser()
    if not target.is_dir():
        if args.create:
            try:
                target.mkdir(parents=True, exist_ok=True)
            except OSError as exc:
                print(json.dumps({"ok": False, "error": f"Could not create folder: {exc}"}))
                return 1
        else:
            print(json.dumps({"ok": False, "error": "The folder does not exist"}))
            return 1
    cfg = load_config()
    cfg["localDir"] = str(target.resolve())
    save_config(cfg)
    return cmd_status(args)


def cmd_dirs(args):
    path = Path(args.path or HOME).expanduser()
    if not path.is_dir():
        path = HOME
    path = path.resolve()
    dirs = []
    try:
        with os.scandir(path) as it:
            for entry in it:
                if entry.name.startswith("."):
                    continue
                try:
                    if entry.is_dir():
                        dirs.append({"name": entry.name, "path": str(path / entry.name)})
                except OSError:
                    continue
    except OSError:
        pass
    dirs.sort(key=lambda d: d["name"].casefold())
    print(json.dumps({
        "path": str(path),
        "parent": str(path.parent) if path != path.parent else "",
        "dirs": dirs[:500],
    }, ensure_ascii=False))
    return 0


def cmd_sync_now(_args):
    code, _, err = systemctl("start", "--no-block", f"{UNIT}.service")
    if code != 0:
        print(err.strip(), file=sys.stderr)
    return code


def cmd_resync(args):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    RESYNC_FLAG.touch()
    return cmd_sync_now(args)


def cmd_cancel(_args):
    code, _, err = systemctl("stop", f"{UNIT}.service")
    if code != 0:
        print(err.strip(), file=sys.stderr)
    return code


def cmd_pause(_args):
    code, _, err = systemctl("disable", "--now", f"{UNIT}.timer")
    if code != 0:
        print(err.strip(), file=sys.stderr)
    return code


def cmd_resume(_args):
    cfg = load_config()
    ensure_units(cfg["intervalSec"], enable=False)
    code, _, err = systemctl("enable", "--now", f"{UNIT}.timer")
    if code != 0:
        print(err.strip(), file=sys.stderr)
    return code


def cmd_install(_args):
    cfg = load_config()
    if not CONFIG_FILE.exists():
        save_config(cfg)
    ensure_units(cfg["intervalSec"], enable=True)
    print(f"Installed {UNIT}.service and {UNIT}.timer (every {cfg['intervalSec']}s)")
    return 0


def cmd_uninstall(_args):
    systemctl("disable", "--now", f"{UNIT}.timer")
    systemctl("stop", f"{UNIT}.service")
    for name in (f"{UNIT}.timer", f"{UNIT}.service"):
        try:
            (UNIT_DIR / name).unlink()
        except OSError:
            pass
    systemctl("daemon-reload")
    print("Removed systemd units (config and state kept)")
    return 0


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status").set_defaults(func=cmd_status)
    run = sub.add_parser("run")
    run.add_argument("--resync", action="store_true")
    run.set_defaults(func=cmd_run)
    apply = sub.add_parser("apply-settings")
    apply.add_argument("--remote", default="")
    apply.add_argument("--local-dir", default="")
    apply.add_argument("--interval", type=int, default=0)
    apply.add_argument("--no-enable", action="store_true")
    apply.set_defaults(func=cmd_apply_settings)
    folder = sub.add_parser("set-folder")
    folder.add_argument("path")
    folder.add_argument("--create", action="store_true")
    folder.set_defaults(func=cmd_set_folder)
    dirs = sub.add_parser("dirs")
    dirs.add_argument("path", nargs="?", default="")
    dirs.set_defaults(func=cmd_dirs)
    sub.add_parser("sync-now").set_defaults(func=cmd_sync_now)
    sub.add_parser("resync").set_defaults(func=cmd_resync)
    sub.add_parser("cancel").set_defaults(func=cmd_cancel)
    sub.add_parser("pause").set_defaults(func=cmd_pause)
    sub.add_parser("resume").set_defaults(func=cmd_resume)
    sub.add_parser("install").set_defaults(func=cmd_install)
    sub.add_parser("uninstall").set_defaults(func=cmd_uninstall)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
