#!/usr/bin/env python3
"""记录一条雪的自用观察样本。

只读本机状态：App 版本、进程、内存足迹、崩溃报告、审计计数、每日指标和磁盘余量。
不读文件内容、不联网、不改应用数据；唯一写入是追加一行观察记录。

用法：
  python3 scripts/self-use-observation.py
  python3 scripts/self-use-observation.py --print
"""

from __future__ import annotations

import json
import os
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

APP = Path("/Applications/雪.app")
APP_INFO = APP / "Contents" / "Info.plist"
APP_EXECUTABLE = APP / "Contents" / "MacOS" / "SnowSweepApp"
DATA = Path.home() / "Library" / "Application Support" / "雪"
OUT = DATA / "self-use-observation.jsonl"
AUDIT = DATA / "audit.jsonl"
METRICS = DATA / "daily-metrics.jsonl"
CRASH_DIR = Path.home() / "Library" / "Logs" / "DiagnosticReports"


def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=5, check=False
        ).stdout.strip()
    except Exception:
        return ""


def app_version() -> tuple[str, str | None]:
    if not APP_INFO.exists():
        return "未安装", None
    try:
        with APP_INFO.open("rb") as fh:
            info = plistlib.load(fh)
        installed = datetime.fromtimestamp(
            APP.stat().st_mtime, tz=timezone.utc
        ).isoformat()
        return str(info.get("CFBundleShortVersionString", "未知")), installed
    except Exception:
        return "未知", None


def parse_etime(text: str) -> int | None:
    text = text.strip()
    if not text:
        return None
    days = 0
    if "-" in text:
        day_part, text = text.split("-", 1)
        days = int(day_part)
    parts = [int(p) for p in text.split(":")]
    if len(parts) == 3:
        h, m, s = parts
    elif len(parts) == 2:
        h = 0
        m, s = parts
    else:
        return None
    return days * 86400 + h * 3600 + m * 60 + s


def process_state() -> dict:
    pid = run(["pgrep", "-f", str(APP_EXECUTABLE)]).splitlines()
    if not pid:
        return {"running": False, "pid": None, "rss_mb": None,
                "footprint_mb": None, "uptime_seconds": None}
    pid_text = pid[0]
    ps_out = run(["ps", "-o", "rss=,etime=", "-p", pid_text]).strip()
    rss_mb = None
    uptime = None
    if ps_out:
        fields = ps_out.split()
        if fields:
            try:
                rss_mb = round(int(fields[0]) / 1024, 1)
            except ValueError:
                pass
        if len(fields) > 1:
            uptime = parse_etime(fields[1])
    footprint_mb = None
    fp = run(["footprint", "-p", pid_text])
    match = re.search(r"phys_footprint:\s+([0-9.]+)\s+MB", fp)
    if match:
        footprint_mb = float(match.group(1))
    return {"running": True, "pid": int(pid_text), "rss_mb": rss_mb,
            "footprint_mb": footprint_mb, "uptime_seconds": uptime}


def crash_stats() -> tuple[int, int]:
    total = 0
    recent = 0
    now = datetime.now(tz=timezone.utc).timestamp()
    if CRASH_DIR.exists():
        paths = set(CRASH_DIR.glob("*SnowSweep*")) | set(CRASH_DIR.glob("*雪*"))
        for path in paths:
            if path.suffix not in {".ips", ".crash"}:
                continue
            total += 1
            try:
                if now - path.stat().st_mtime <= 86400:
                    recent += 1
            except OSError:
                pass
    return total, recent


def line_count(path: Path) -> int:
    if not path.exists():
        return 0
    try:
        with path.open("rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def audit_stats() -> dict:
    total = 0
    permanent = 0
    failed = 0
    malformed = 0
    last_id = None
    last_hash = None
    if AUDIT.exists():
        try:
            with AUDIT.open(encoding="utf-8") as fh:
                for line in fh:
                    if not line.strip():
                        continue
                    total += 1
                    try:
                        row = json.loads(line)
                    except json.JSONDecodeError:
                        malformed += 1
                        continue
                    if row.get("action") in {"permanentDelete", "permanentDeleteFailed"}:
                        permanent += 1
                    if not row.get("success", True):
                        failed += 1
                    last_id = row.get("id", last_id)
                    last_hash = row.get("sha256", last_hash)
        except OSError:
            pass
    return {"audit_total": total, "audit_permanent_delete": permanent,
            "audit_failed": failed, "audit_malformed": malformed,
            "audit_last_id": last_id, "audit_last_hash": last_hash}


def main() -> int:
    version, installed = app_version()
    crash_total, crash_last_24h = crash_stats()
    stat = os.statvfs("/System/Volumes/Data")
    record = {
        "schema": 1,
        "recorded_at": datetime.now(tz=timezone.utc).astimezone().isoformat(),
        "app_version": version,
        "installed_at": installed,
        **process_state(),
        **audit_stats(),
        "metrics_total": line_count(METRICS),
        "crash_total": crash_total,
        "crash_last_24h": crash_last_24h,
        "disk_free_gb": round(stat.f_bavail * stat.f_frsize / 1024**3, 1),
        "run_mode": run(["defaults", "read", "com.selfuse.xue", "snow.runMode"]) or None,
    }
    DATA.mkdir(parents=True, exist_ok=True)
    with OUT.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
    if "--print" in sys.argv or len(sys.argv) == 1:
        print(json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
