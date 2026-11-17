"""Read a complete `nrc chronicle status` JSON response; never mutate NRC.

Exit 0: no warning, 1: operational warning, 2: malformed/incompatible status.
Optional previous snapshot and elapsed seconds detect a stalled backlog.
No provider calls, credentials, note bodies or automatic remediation.
"""

import argparse
import json
import sys


COUNTERS = ("pending", "processing", "failed", "acknowledged", "gap_count",
            "expired", "raw_bytes", "calls", "input_tokens", "output_tokens")


def validate(value):
    if not isinstance(value, dict) or value.get("status") != "ok":
        raise ValueError("expected successful Chronicle status")
    if type(value.get("enabled")) is not bool:
        raise ValueError("missing capture state")
    for key in COUNTERS:
        if type(value.get(key)) is not int or value[key] < 0:
            raise ValueError("missing or invalid counter: " + key)
    return value


def warnings(current, previous=None, elapsed=0):
    result = []
    if not current["enabled"]:
        result.append("capture_disabled")
    if current["failed"]:
        result.append("failed_or_parked_inputs")
    if current["expired"]:
        result.append("expired_inputs_await_cleanup")
    if current["input_tokens"] >= 7_200_000 or current["output_tokens"] >= 450_000:
        result.append("daily_token_budget_above_90_percent")
    if previous is not None:
        if current["gap_count"] > previous["gap_count"]:
            result.append("new_lost_inputs")
        # Calls reset at UTC midnight. A reset or disappearing counters cannot
        # establish a stall; compare only within a nondecreasing counter window.
        keys = ("calls", "acknowledged", "gap_count")
        if (elapsed >= 600 and current["pending"] > 0 and
                previous["pending"] > 0 and
                all(current[k] == previous[k] for k in keys) and
                current["pending"] >= previous["pending"]):
            result.append("backlog_without_observed_progress_10m")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--previous", help="previous status JSON from the same workspace and UTC day")
    parser.add_argument("--elapsed-seconds", type=int, default=0)
    args = parser.parse_args()
    try:
        if args.elapsed_seconds < 0:
            raise ValueError("elapsed seconds must be nonnegative")
        current = validate(json.load(sys.stdin))
        previous = None
        if args.previous:
            with open(args.previous, encoding="utf-8") as source:
                previous = validate(json.load(source))
        alerts = warnings(current, previous, args.elapsed_seconds)
    except (ValueError, OSError):
        print(json.dumps({"status": "invalid_status"}))
        return 2
    print(json.dumps({"status": "warning" if alerts else "ok", "warnings": alerts,
                      "counters": {key: current[key] for key in COUNTERS}}))
    return int(bool(alerts))


if __name__ == "__main__":
    sys.exit(main())
