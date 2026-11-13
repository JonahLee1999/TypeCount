#!/usr/bin/env python3
"""Low-overhead process CPU/RSS sampling; does not read input or app content."""
import argparse
import json
from pathlib import Path
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--pid", type=int)
parser.add_argument("--seconds", type=float, default=15)
parser.add_argument("--output", type=Path)
args = parser.parse_args()
if args.seconds < 1 or args.seconds > 60:
    parser.error("--seconds must be between 1 and 60")
pid = args.pid or int(subprocess.check_output(
    ["pgrep", "-f", "^/Applications/字迹.app/Contents/MacOS/TypeCount$"], text=True).strip().splitlines()[0])

def sample():
    values = subprocess.check_output(["ps", "-p", str(pid), "-o", "time=,rss="], text=True).strip().split()
    fields = values[0].split(":")
    cpu = float(fields[-1]) + float(fields[-2]) * 60
    if len(fields) == 3:
        cpu += float(fields[0]) * 3600
    return cpu, int(values[1])

start_cpu, start_rss = sample()
start_time = time.monotonic()
time.sleep(args.seconds)
end_cpu, end_rss = sample()
elapsed = time.monotonic() - start_time
report = {
    "pid": pid,
    "elapsed_seconds": round(elapsed, 2),
    "cpu_percent_from_cpu_time": round(100 * (end_cpu - start_cpu) / elapsed, 2),
    "rss_mib": round(end_rss / 1024, 2),
    "rss_start_mib": round(start_rss / 1024, 2),
    "note": "Short process sample; RSS is resident memory, and CPU depends on foreground activity."
}
payload = json.dumps(report, ensure_ascii=False, indent=2)
if args.output:
    args.output.write_text(payload + "\n")
print(payload)
