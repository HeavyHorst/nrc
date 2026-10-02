#!/usr/bin/env python3
"""Render the CPU-explicit message-history benchmark as a static Portal."""

import argparse
import html
import json
import statistics
from pathlib import Path


TOPOLOGY_LABELS = {
    "hot_owner_parallel_sqlite": "Hot owner / SQLite parallel",
    "hot_owner_single_cpu": "Hot owner / one CPU each",
    "scale_out_matched_cpus": "Matched logical-CPU scale-out",
}


def median(rows, workload, topology, backend, metric):
    values = [
        row[metric] for row in rows
        if row["workload"] == workload and row["topology"] == topology and row["backend"] == backend
        and row[metric] is not None
    ]
    return statistics.median(values) if values else None


def owner_extreme_median(rows, metric, extreme):
    values = [
        extreme(owner[metric] for owner in row["owner_results"])
        for row in rows
        if row["workload"] == "sealed"
        and row["topology"] == "scale_out_matched_cpus"
        and row["backend"] == "nrc"
    ]
    return statistics.median(values)


def fmt_rate(value):
    return f"{value / 1000:.1f}k" if value >= 1000 else f"{value:.0f}"


def bar_chart(title, subtitle, groups, formatter=fmt_rate):
    values = [value for _, series in groups for _, value in series if value is not None]
    maximum = max(values) if values else 1
    parts = [f'<section class="panel"><h2>{html.escape(title)}</h2><p>{html.escape(subtitle)}</p>']
    for group, series in groups:
        parts.append(f'<h3>{html.escape(group)}</h3>')
        for label, value in series:
            css = "nrc" if label.startswith("NRC") or "owner" in label.lower() else "sqlite"
            width = 100 * value / maximum if value is not None else 0
            formatted = formatter(value) if value is not None else "N/A"
            parts.append(
                f'<div class="metric"><span>{label}</span><div class="track"><div class="bar {css}" '
                f'style="width:{width:.2f}%"></div><b>{formatted}</b></div></div>'
            )
    parts.append("</section>")
    return "".join(parts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = json.loads(args.results.read_text())
    rows = data["rows"]
    topologies = list(TOPOLOGY_LABELS)
    cpu_count = len(data["logical_cpus"])

    active_groups = [
        (TOPOLOGY_LABELS[topology], [
            (backend.upper() if backend == "nrc" else "SQLite", median(rows, "active", topology, backend, "pages_s"))
            for backend in ("nrc", "sqlite")
        ]) for topology in topologies
    ]
    sealed_idle_groups = [
        (TOPOLOGY_LABELS[topology], [
            (backend.upper() if backend == "nrc" else "SQLite", median(rows, "sealed", topology, backend, "baseline_pages_s"))
            for backend in ("nrc", "sqlite")
        ]) for topology in topologies
    ]
    sealed_loaded_groups = [
        (TOPOLOGY_LABELS[topology], [
            (backend.upper() if backend == "nrc" else "SQLite", median(rows, "sealed", topology, backend, "loaded_pages_s"))
            for backend in ("nrc", "sqlite")
        ]) for topology in topologies
    ]
    write_groups = [
        (TOPOLOGY_LABELS[topology], [
            (backend.upper() if backend == "nrc" else "SQLite", median(rows, "sealed", topology, backend, "achieved_msg_s"))
            for backend in ("nrc", "sqlite")
        ]) for topology in topologies
    ]
    latency_topologies = topologies[:2]
    active_latency_groups = [
        (TOPOLOGY_LABELS[topology], [
            (backend.upper() if backend == "nrc" else "SQLite", median(rows, "active", topology, backend, "descending_p95_us"))
            for backend in ("nrc", "sqlite")
        ]) for topology in latency_topologies
    ]
    sealed_latency_groups = [
        (TOPOLOGY_LABELS[topology], [
            (backend.upper() if backend == "nrc" else "SQLite", median(rows, "sealed", topology, backend, "loaded_descending_p95_us"))
            for backend in ("nrc", "sqlite")
        ]) for topology in latency_topologies
    ]
    owner_label = f"{cpu_count} independent NRC owners"
    owner_page_groups = [(owner_label, [
        ("Slowest owner", owner_extreme_median(rows, "loaded_pages_s", min)),
        ("Fastest owner", owner_extreme_median(rows, "loaded_pages_s", max)),
    ])]
    owner_write_groups = [(owner_label, [
        ("Slowest owner", owner_extreme_median(rows, "achieved_msg_s", min)),
        ("Fastest owner", owner_extreme_median(rows, "achieved_msg_s", max)),
    ])]
    owner_elapsed_groups = [(owner_label, [
        ("Shortest owner", owner_extreme_median(rows, "loaded_elapsed_s", min) * 1000),
        ("Longest owner", owner_extreme_median(rows, "loaded_elapsed_s", max) * 1000),
    ])]
    flush_groups = [(TOPOLOGY_LABELS[topology], [
        ("NRC submit + commit", median(rows, "sealed", topology, "nrc", "submit_commit_p95_us")),
        ("NRC commit + publish", median(rows, "sealed", topology, "nrc", "commit_publish_p95_us")),
    ]) for topology in latency_topologies]
    wal_groups = [(f"{TOPOLOGY_LABELS[topology]} · write n≈{median(rows, 'sealed', topology, 'nrc', 'wal_write_samples'):,.0f}/run · fsync n≈{median(rows, 'sealed', topology, 'nrc', 'wal_fsync_samples'):,.0f}/run", [
        ("NRC WAL write()", median(rows, "sealed", topology, "nrc", "wal_write_p95_us")),
        ("NRC WAL fsync()", median(rows, "sealed", topology, "nrc", "wal_fsync_p95_us")),
    ]) for topology in latency_topologies]
    max_groups = [(TOPOLOGY_LABELS[topology], [
        ("NRC descending-page maximum", median(rows, "sealed", topology, "nrc", "loaded_descending_max_us")),
        ("NRC submit + commit maximum", median(rows, "sealed", topology, "nrc", "submit_commit_max_us")),
        ("NRC commit + publish maximum", median(rows, "sealed", topology, "nrc", "commit_publish_max_us")),
    ]) for topology in latency_topologies]

    charts = "".join((
        bar_chart("Active-history page capacity", "10k target messages, five distractors per target, 256-byte content.", active_groups),
        bar_chart("Sealed-history capacity / idle", "100k conversation-clustered messages, 1 KiB content, warm-cache pages capped at 100 messages / 96 KiB.", sealed_idle_groups),
        bar_chart("Sealed-history capacity / 25k writes offered", f"The same read workload while appending to another conversation for {data['loaded_duration_seconds']:g} seconds; actual completed pages are counted.", sealed_loaded_groups),
        bar_chart("Achieved retained writes", f"One SQLite writer thread versus {data.get('nrc_writer_connections_per_owner', 4)} writer connections per NRC owner ({cpu_count * data.get('nrc_writer_connections_per_owner', 4)} at scale-out); the aggregate offer is divided across owners.", write_groups),
        bar_chart("NRC scale-out owner page spread", "Median slowest and fastest owner rates across fixed-duration loaded runs; no owner stops after a preset page count.", owner_page_groups),
        bar_chart("NRC scale-out owner write spread", f"Median slowest and fastest owner achieved rates; each owner receives {data['write_rate'] / cpu_count:,.0f} msg/s of the aggregate offer.", owner_write_groups),
        bar_chart("NRC scale-out owner elapsed spread", "Median shortest and longest owner elapsed times, including completion of the final in-flight page wave.", owner_elapsed_groups, lambda value: f"{value:,.1f} ms"),
        bar_chart("NRC owning-worker write-turn p95", "Submit + commit includes request staging, WAL commit, index publication, ACKs, and broadcasts. Commit + publish excludes request staging; lower is better. Scale-out is omitted because owner p95s are not mergeable.", flush_groups, lambda value: f"{value:,.0f} µs"),
        bar_chart("NRC WAL I/O p95 · median run p95", "One store per process. write() measures the synchronous batch syscall. Async fsync measures submission through CQ callback when the 1-second or 100 MiB threshold fires; with n=2, p95 is the run maximum. Scale-out is omitted because owner p95s are not mergeable.", wal_groups, lambda value: f"{value:,.0f} µs"),
        bar_chart("NRC maximum observed latency · median run maximum", "The async-fsync experiment targets rare stalls below p95 frequency. These are median per-run maxima, not distribution percentiles; scale-out is omitted.", max_groups, lambda value: f"{value:,.0f} µs"),
        bar_chart("Active descending p95", "Median process p95 page latency; lower is better. Scale-out omitted because NRC worker p95s are not mergeable.", active_latency_groups, lambda value: f"{value:,.0f} µs"),
        bar_chart("Loaded sealed descending p95", "NRC ends when the complete frame becomes visible to the simulated client; SQLite ends after direct query-row consumption. Median process p95 under the 25k msg/s offer; lower is better. Scale-out omitted because NRC worker p95s are not mergeable.", sealed_latency_groups, lambda value: f"{value:,.0f} µs"),
    ))

    table_rows = []
    for workload, metric in (("active", "pages_s"), ("sealed", "baseline_pages_s"), ("sealed", "loaded_pages_s")):
        for topology in topologies:
            nrc = median(rows, workload, topology, "nrc", metric)
            sqlite = median(rows, workload, topology, "sqlite", metric)
            table_rows.append(
                f"<tr><td>{workload}</td><td>{TOPOLOGY_LABELS[topology]}</td>"
                f"<td>{nrc:,.0f}</td><td>{sqlite:,.0f}</td><td>{nrc / sqlite:.2f}×</td></tr>"
            )

    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NRC-300 / CPU-Explicit Message History</title>
<style>
:root{{--bg:#0a0a0a;--panel:#0f0f0f;--ember:#2a1208;--border:#5a2810;--amber:#fcb300;--dim:#9a7a28;--cyan:#00aeef;--white:#f6e8bc}}*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--amber);font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}}header{{padding:25px 32px;background:var(--ember);border-bottom:2px solid var(--border);display:flex;justify-content:space-between}}.eyebrow{{color:var(--cyan);letter-spacing:.14em;text-transform:uppercase;font-size:12px}}h1{{margin:4px 0 0;font-size:28px}}main{{max-width:1200px;margin:auto;padding:24px;display:grid;grid-template-columns:1fr 1fr;gap:16px}}.intro,.table,.method{{grid-column:1/-1}}.panel{{border:1px solid var(--border);background:var(--panel);padding:20px}}h2{{margin:0;text-transform:uppercase;font-size:16px}}h3{{color:var(--white);font-size:12px;margin:20px 0 7px}}p{{color:var(--dim)}}.metric{{display:flex;gap:10px;align-items:center;margin:6px 0}}.metric>span{{width:116px}}.track{{height:28px;position:relative;flex:1;background:#1d1208}}.bar{{height:100%}}.nrc{{background:var(--cyan)}}.sqlite{{background:var(--amber)}}.track b{{position:absolute;left:8px;top:4px;color:var(--white);text-shadow:0 1px 2px #000,0 0 3px #000}}table{{width:100%;border-collapse:collapse;color:var(--white)}}th,td{{padding:9px;border-bottom:1px solid #2a1a0a;text-align:right}}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){{text-align:left}}th{{color:var(--dim)}}code{{color:var(--white)}}footer{{padding:18px 32px;border-top:1px solid var(--border);color:var(--dim)}}@media(max-width:760px){{main{{grid-template-columns:1fr}}.intro,.table,.method{{grid-column:auto}}header{{display:block}}}}
</style></head><body>
<header><div><div class="eyebrow">NRC-300 / controlled topology</div><h1>MESSAGE HISTORY · CPU-EXPLICIT</h1></div><div>{data['generated_at']}<br>{data['runs']} independent repetitions</div></header>
<main><section class="panel intro"><h2>What changed</h2><p>The old graph mixed one hot NRC owner with parallel SQLite reader threads. This report retains that explicitly non-CPU-equal directional case, adds a one-logical-CPU comparison, and adds matched {cpu_count}-logical-CPU scale-out using independent NRC workers/workspaces. SQLite is one process with one connection per reader thread—not separate SQLite processes.</p></section>
{charts}
<section class="panel table"><h2>Median page-capacity ratios</h2><table><thead><tr><th>Workload</th><th>Topology</th><th>NRC pages/s</th><th>SQLite pages/s</th><th>NRC / SQLite</th></tr></thead><tbody>{''.join(table_rows)}</tbody></table></section>
<section class="panel method"><h2>Method</h2><p>Base commit <code>{data['base_commit']}</code>; dirty source: <code>{data['worktree_dirty']}</code>; benchmark-source SHA-256: <code>{data['benchmark_source_sha256']}</code>. Logical CPUs: <code>{data['logical_cpus']}</code>. Idle and active phases use {data['rounds']} synchronized page waves per process. The loaded sealed phase runs synchronized waves for {data['loaded_duration_seconds']:g} seconds and counts actual completed work; scale-out throughput divides summed work by the shared makespan. Pages are limited to 100 messages and 96 KiB; values are medians of {data['runs']} independent process runs. NRC includes production retained-history handlers, protocol serialization/parsing, io_uring, and simulated delivery. SQLite measures warmed prepared indexed queries directly. SQLite uses WAL mode and <code>synchronous=NORMAL</code>. The matched scale-out case uses one pinned NRC process as an owning-worker surrogate per independent workspace; it tests partitioned scale-out, not one hot conversation. NRC's loaded sealed phase follows its idle phase in one process/store; SQLite uses separately seeded fresh processes for those phases.</p></section></main>
<footer>nrc · CPU TOPOLOGY IS PART OF THE RESULT</footer></body></html>"""
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "index.html").write_text(document)
    (args.output / "results.json").write_text(json.dumps(data, indent=2) + "\n")


if __name__ == "__main__":
    main()
