#!/usr/bin/env python3
"""Render WAL and retained-message benchmark results as a static portal."""

import argparse
import html
import json
from pathlib import Path


WORKLOADS = ("wal", "retained", "task", "asset")
COLORS = {"wal": "#00aeef", "retained": "#fcb300", "task": "#40c870", "asset": "#e84040"}
LABELS = {"wal": "Raw WAL", "retained": "Retained message", "task": "Task create", "asset": "Asset create"}
HASH_LABELS = {
    "sha256": "SHA-256",
    "sha512_256": "SHA-512/256",
    "sha3_256": "SHA3-256",
    "blake2s_256": "BLAKE2s-256",
    "blake2b_256": "BLAKE2b-256",
    "sm3": "SM3",
}
HASH_COLORS = {
    "sha256": "#00aeef",
    "sha512_256": "#705820",
    "sha3_256": "#fcb300",
    "blake2s_256": "#40c870",
    "blake2b_256": "#ffb700",
    "sm3": "#e84040",
}


def size_label(value):
    return f"{value // 1024} KiB" if value >= 1024 else f"{value} B"


def rate(value):
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}k"
    return f"{value:.0f}"


def symbol_label(symbol):
    label = symbol.split(":proc(", 1)[0]
    replacements = {
        "sha2::[sha256_impl_hw_intel.odin]::": "sha2::",
        "os::[file_linux.odin]::": "os::",
        "testing::[runner.odin]::": "testing::",
        "mem::[rollback_stack_allocator.odin]::": "mem::",
        "__$hasher$$string": "hash<string>",
        "__$map_get$$map[string]main::Message_Dedup_Value": "map_get<Message_Dedup_Value>",
    }
    for original, concise in replacements.items():
        label = label.replace(original, concise)
    return label


def chart(title, subtitle, summaries, metric, formatter):
    maximum = max(row[metric]["median"] for row in summaries)
    groups = []
    for size in sorted({row["size_bytes"] for row in summaries}):
        bars = []
        for workload in WORKLOADS:
            row = next(item for item in summaries if item["size_bytes"] == size and item["workload"] == workload)
            value = row[metric]["median"]
            width = value / maximum * 100
            spread = f"IQR {formatter(row[metric]['q1'])}–{formatter(row[metric]['q3'])}"
            bars.append(
                f'<div class="bar-row"><span>{LABELS[workload]}</span><div class="track">'
                f'<div class="bar" style="width:{width:.2f}%;background:{COLORS[workload]}"></div>'
                f'<b>{formatter(value)}</b></div><small>{spread}</small></div>'
            )
        groups.append(f'<div class="group"><h3>{size_label(size)} payload</h3>{"".join(bars)}</div>')
    return f'<section class="panel"><h2>{html.escape(title)}</h2><p>{html.escape(subtitle)}</p>{"".join(groups)}</section>'


def perf_panels(profiles):
    parts = []
    for profile in profiles:
        hotspots = profile["hotspots"][:8]
        maximum = max((item["percent"] for item in hotspots), default=1)
        rows = []
        for item in hotspots:
            width = item["percent"] / maximum * 100
            label = symbol_label(item["symbol"])
            rows.append(
                f'<div class="hotspot"><code title="{html.escape(item["symbol"])}">{html.escape(label)}</code>'
                f'<div class="perf-track"><i style="width:{width:.2f}%"></i><b>{item["percent"]:.1f}%</b></div></div>'
            )
        parts.append(
            f'<div class="profile"><h3>{LABELS[profile["workload"]]} · {size_label(profile["size_bytes"])}</h3>'
            f'{"".join(rows)}<a href="{profile["report"]}">full perf report</a></div>'
        )
    return "".join(parts)


def hash_chart(hash_data, metric, formatter):
    summaries = hash_data["summaries"]
    maximum = max(row[metric]["median"] for row in summaries)
    groups = []
    for size in hash_data["payload_sizes"]:
        bars = []
        for algorithm in hash_data["algorithms"]:
            row = next(
                item for item in summaries
                if item["payload_bytes"] == size and item["algorithm"] == algorithm
            )
            value = row[metric]["median"]
            width = value / maximum * 100
            spread = f"IQR {formatter(row[metric]['q1'])}–{formatter(row[metric]['q3'])}"
            bars.append(
                f'<div class="bar-row"><span>{HASH_LABELS[algorithm]}</span><div class="track">'
                f'<div class="bar" style="width:{width:.2f}%;background:{HASH_COLORS[algorithm]}"></div>'
                f'<b>{formatter(value)}</b></div><small>{spread}</small></div>'
            )
        groups.append(f'<div class="group"><h3>{size_label(size)} payload</h3>{"".join(bars)}</div>')
    return "".join(groups)


def hash_sections(hash_data):
    if not hash_data:
        return ""
    summaries = hash_data["summaries"]
    smallest = hash_data["payload_sizes"][0]
    largest = hash_data["payload_sizes"][-1]
    fastest_small = max(
        (row for row in summaries if row["payload_bytes"] == smallest),
        key=lambda row: row["hashes_per_s"]["median"],
    )
    fastest_large = max(
        (row for row in summaries if row["payload_bytes"] == largest),
        key=lambda row: row["mib_per_s"]["median"],
    )
    table_rows = []
    for size in hash_data["payload_sizes"]:
        sha = next(
            row for row in summaries
            if row["payload_bytes"] == size and row["algorithm"] == "sha256"
        )["mib_per_s"]["median"]
        for algorithm in hash_data["algorithms"]:
            row = next(
                item for item in summaries
                if item["payload_bytes"] == size and item["algorithm"] == algorithm
            )
            relative = row["mib_per_s"]["median"] / sha
            table_rows.append(
                f'<tr><td>{size_label(size)}</td><td>{HASH_LABELS[algorithm]}</td>'
                f'<td>{row["mib_per_s"]["median"]:,.1f}</td>'
                f'<td>{rate(row["hashes_per_s"]["median"])}</td><td>{relative:.2f}×</td></tr>'
            )
    flags = " ".join(hash_data["build_flags"])
    return f"""
<section class="panel wide"><h2>Hash-chain candidates · optimized build</h2>
<p>Direct Odin core crypto APIs with <code>{html.escape(flags)}</code>. Every iteration initializes a fresh context, copies the previous 32-byte digest into the 52-byte NRC WAL header, and hashes the complete record. Six algorithms retain a 256-bit output and modern collision resistance.</p>
<div class="cards hash-cards">
<div class="card"><span>Fastest · {size_label(smallest)}</span><b>{HASH_LABELS[fastest_small['algorithm']]}</b><small>{rate(fastest_small['hashes_per_s']['median'])} chains/s</small></div>
<div class="card"><span>Fastest · {size_label(largest)}</span><b>{HASH_LABELS[fastest_large['algorithm']]}</b><small>{fastest_large['mib_per_s']['median']:,.0f} MiB/s</small></div>
<div class="card"><span>Digest / chain field</span><b>256 bit</b><small>32 bytes for every candidate</small></div>
<div class="card"><span>Samples</span><b>{hash_data['runs']}×</b><small>independent processes per size</small></div>
</div></section>
<section class="panel"><h2>Hash-chain bandwidth</h2><p>Median complete-record MiB/s; labels show process-level IQR.</p>{hash_chart(hash_data, 'mib_per_s', lambda value: f'{value:,.0f} MiB/s')}</section>
<section class="panel"><h2>Hash-chain rate</h2><p>Median independently initialized and finalized chains per second.</p>{hash_chart(hash_data, 'hashes_per_s', lambda value: f'{rate(value)}/s')}</section>
<section class="panel wide"><h2>Complete hash medians</h2><table><thead><tr><th>Payload</th><th>Algorithm</th><th>MiB/s</th><th>Chains/s</th><th>vs SHA-256</th></tr></thead><tbody>{''.join(table_rows)}</tbody></table>
<p>{html.escape(hash_data['cpu_model'])} · <code>{html.escape(hash_data['odin_version'])}</code>. SHA-256 uses Odin's runtime-selected implementation; results therefore include this host's SHA-NI acceleration. These numbers compare chain computation only and do not include XXH64 or file I/O.</p></section>
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    data = json.loads(args.results.read_text())
    hash_results = args.results.with_name("hash-results.json")
    hash_data = json.loads(hash_results.read_text()) if hash_results.exists() else None
    summaries = data["summaries"]

    fastest = {
        workload: max(
            (row for row in summaries if row["workload"] == workload),
            key=lambda row: row["mib_per_s"]["median"],
        )
        for workload in WORKLOADS
    }

    table_rows = []
    for size in data["sizes_bytes"]:
        for workload in WORKLOADS:
            row = next(item for item in summaries if item["size_bytes"] == size and item["workload"] == workload)
            table_rows.append(
                f'<tr><td>{size_label(size)}</td><td>{LABELS[workload]}</td><td>{row["record_bytes"]:,}</td>'
                f'<td>{row["mib_per_s"]["median"]:,.1f}</td><td>{rate(row["messages_per_s"]["median"])}</td>'
                f'<td>{row["write_calls_per_sample"]:,.0f}</td><td>{row["fsyncs_per_sample"]:,.0f}</td></tr>'
            )

    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>NRC-300 / Storage Write Capacity</title>
<style>
:root{{--bg:#0a0a0a;--panel:#0f0f0f;--ember:#2a1208;--border:#5a2810;--amber:#fcb300;--dim:#9a7a28;--cyan:#00aeef;--white:#f6e8bc;--green:#40c870}}*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--amber);font:14px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace}}header{{padding:26px 32px;background:var(--ember);border-bottom:2px solid var(--border);display:flex;justify-content:space-between;gap:24px}}.eyebrow{{color:var(--cyan);letter-spacing:.14em;text-transform:uppercase;font-size:12px}}h1{{margin:4px 0 0;font-size:29px}}main{{max-width:1280px;margin:auto;padding:24px;display:grid;grid-template-columns:1fr 1fr;gap:16px}}.wide{{grid-column:1/-1}}.panel{{border:1px solid var(--border);background:var(--panel);padding:20px;min-width:0}}h2{{margin:0;text-transform:uppercase;font-size:16px}}h3{{color:var(--white);font-size:12px;margin:19px 0 8px}}p,small{{color:var(--dim)}}.cards{{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-top:16px}}.card{{border-left:3px solid var(--cyan);background:#15100a;padding:14px}}.card:nth-child(even){{border-color:var(--amber)}}.card b{{display:block;color:var(--white);font-size:22px}}.card span{{color:var(--dim);font-size:11px;text-transform:uppercase}}.bar-row{{display:grid;grid-template-columns:125px 1fr 150px;align-items:center;gap:10px;margin:7px 0}}.track{{height:28px;position:relative;background:#1d1208}}.bar{{height:100%;min-width:2px}}.track b{{position:absolute;left:8px;top:4px;color:var(--white);text-shadow:0 1px 3px #000}}.profiles{{display:grid;grid-template-columns:1fr 1fr;gap:20px}}.hotspot{{display:grid;grid-template-columns:minmax(170px,1fr) 180px;align-items:start;gap:8px;margin:6px 0}}.hotspot code{{overflow-wrap:anywhere;color:var(--white);font-size:11px}}.perf-track{{height:20px;position:relative;background:#1d1208}}.perf-track i{{display:block;height:100%;background:var(--green)}}.perf-track b{{position:absolute;left:6px;top:1px;color:var(--white);font-size:11px}}a{{color:var(--cyan)}}table{{width:100%;border-collapse:collapse;color:var(--white)}}th,td{{padding:9px;border-bottom:1px solid #2a1a0a;text-align:right}}th:first-child,td:first-child,th:nth-child(2),td:nth-child(2){{text-align:left}}th{{color:var(--dim)}}code{{color:var(--white)}}footer{{padding:18px 32px;border-top:1px solid var(--border);color:var(--dim)}}@media(max-width:850px){{main{{grid-template-columns:1fr}}.wide{{grid-column:auto}}.cards{{grid-template-columns:1fr 1fr}}.profiles{{grid-template-columns:1fr}}.bar-row{{grid-template-columns:105px 1fr}}.bar-row small{{grid-column:2}}header{{display:block}}}}@media(max-width:520px){{.cards{{grid-template-columns:1fr}}}}
</style></head><body>
<header><div><div class="eyebrow">NRC-300 / storage capacity probe</div><h1>WAL + ENTITY WRITE THROUGHPUT</h1></div><div>{data['generated_at'][:19].replace('T', ' ')} UTC<br>{data['runs']} independent runs / size</div></header>
<main>
<section class="panel wide"><h2>Capacity at a glance</h2><div class="cards">
<div class="card"><span>Peak raw WAL bandwidth</span><b>{fastest['wal']['mib_per_s']['median']:,.0f} MiB/s</b><small>{size_label(fastest['wal']['size_bytes'])} payload</small></div>
<div class="card"><span>Peak retained bandwidth</span><b>{fastest['retained']['mib_per_s']['median']:,.0f} MiB/s</b><small>{size_label(fastest['retained']['size_bytes'])} content · {data['retained_batch_records']}-record batches</small></div>
<div class="card"><span>Peak task bandwidth</span><b>{fastest['task']['mib_per_s']['median']:,.0f} MiB/s</b><small>{size_label(fastest['task']['size_bytes'])} description</small></div>
<div class="card"><span>Peak asset bandwidth</span><b>{fastest['asset']['mib_per_s']['median']:,.0f} MiB/s</b><small>{size_label(fastest['asset']['size_bytes'])} payload</small></div>
</div></section>
{chart('Write bandwidth', 'Median MiB/s of complete WAL record bytes; error labels show process-level IQR.', summaries, 'mib_per_s', lambda value: f'{value:,.0f} MiB/s')}
{chart('Operation / record rate', 'Median completed writes per second. Payload size changes the byte work per operation.', summaries, 'messages_per_s', lambda value: f'{rate(value)}/s')}
{hash_sections(hash_data)}
<section class="panel wide"><h2>perf · exclusive user-space CPU hotspots</h2><p>Software <code>cpu-clock:u</code> sampling at 999 Hz; hardware PMU counters are not exposed by this orb. Percentages are self time, so callees appear separately. Profiles cover the smallest and largest payloads.</p><div class="profiles">{perf_panels(data['profiles'])}</div></section>
<section class="panel wide"><h2>Complete median results</h2><table><thead><tr><th>Payload</th><th>Path</th><th>WAL bytes / record</th><th>MiB/s</th><th>Operations/s</th><th>write() calls</th><th>Timed fsyncs</th></tr></thead><tbody>{''.join(table_rows)}</tbody></table></section>
<section class="panel wide"><h2>Method and interpretation</h2><p>Commit <code>{data['commit']}</code>; dirty source: <code>{data['worktree_dirty']}</code>. {data['cpu_model']} · {data['logical_cpus']} logical CPUs visible · <code>{data['odin_version']}</code>. Each raw-WAL, task, and asset sample writes approximately {data['target_mib_per_sample']} MiB. Retained samples write up to that target and are capped at {data['retained_record_cap']:,} messages to stay within one active segment. Every sample uses a new file and an optimized one-test-thread build. Values are the median and IQR of {data['runs']} separate processes. Cache state: {data['cache_state']}. Durability: {data['durability']}; the results table shows how many threshold fsyncs occurred. Raw WAL uses 128 KiB batches. Retained messages use the production staging, fingerprint, dedup, active-index, payload-cache, and {data['retained_batch_records']}-record flush path. Task and asset creates use the production mutation builder, shard transaction envelope, validation, hash chain, and one transaction flush per operation. Task/asset threshold fsync is serialized by this single-writer benchmark; the server submits it asynchronously. Initialization and final shutdown fsync are outside the timer. These are orb-local capacity results—not dedicated-hardware regression thresholds.</p></section>
</main><footer>NO RELAY CHAT · WAL / MESSAGE / TASK / ASSET</footer></body></html>"""
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "index.html").write_text(document)


if __name__ == "__main__":
    main()
