"""Extract Rato Dev AI telemetry records from JA3 game logs into a JSONL file.

The mod can't write files, so each record is printed to the game log as
`[RATOTEL_REC] {json}`. This pulls those lines out.

    python tools/extract_telemetry.py            # newest log only
    python tools/extract_telemetry.py --all      # every log, oldest first
    python tools/extract_telemetry.py -o out.jsonl
"""
import argparse
import json
import os
import sys

GAME_DIR = os.path.join(os.environ.get("APPDATA", ""), "Jagged Alliance 3")
LOG_DIR = os.path.join(GAME_DIR, "logs")
DEFAULT_OUT = os.path.join(GAME_DIR, "RatoTelemetry", "ai_telemetry.jsonl")
PREFIX = "[RATOTEL_REC] "


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--all", action="store_true", help="read every log, not just the newest")
    ap.add_argument("-o", "--out", default=DEFAULT_OUT)
    args = ap.parse_args()

    logs = sorted((os.path.join(LOG_DIR, f) for f in os.listdir(LOG_DIR) if f.endswith(".log")),
                  key=os.path.getmtime)
    if not logs:
        sys.exit(f"no logs in {LOG_DIR}")
    if not args.all:
        logs = logs[-1:]

    records, bad = [], 0
    for path in logs:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                idx = line.find(PREFIX)
                if idx < 0:
                    continue
                payload = line[idx + len(PREFIX):].rstrip("\r\n")
                try:
                    json.loads(payload)
                except ValueError:
                    bad += 1  # truncated line, e.g. the game died mid-write
                    continue
                records.append(payload)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("".join(r + "\n" for r in records))
    print(f"{len(records)} records from {len(logs)} log(s) -> {args.out}"
          + (f" ({bad} unparseable skipped)" if bad else ""))


if __name__ == "__main__":
    main()
