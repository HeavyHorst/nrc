# Local production-style Lighthouse fixture

This Linux fixture runs the optimized Odin server, real ONNX search sidecar, and
production client build behind Nginx. It derives its config from
`docker/nginx/nginx.conf`, retaining Brotli/gzip, cache headers, and routing. No Docker
daemon or production credentials are needed.

All binaries, models, generated config, secrets, and disposable databases live in
ignored `.amp/lighthouse/`. The repository's `data/` is not used. Nginx binds to
loopback port 8000; the auth helper binds to loopback port 8093. The backend and
search use ports 8080 and 8090 and must not be publicly exposed.

**Never deploy this fixture.** It automatically authenticates all visitors as the
ordinary `lighthouse-local` test user. An internal Nginx auth subrequest gets a
fresh five-minute JWT per WebSocket handshake. Random local secrets are stored
with mode 0600, never sent to the browser. In orbs, expose only Nginx through an
Amp-authenticated portal. AI and attachment services are not included; this is
the initial connected chat-screen baseline, not a full deployment or load test.
The fixture returns 503 for `/ai/` rather than reaching another local service.
`.amp/` is excluded from Docker build contexts as well as Git.

## Build (from repository root)

Requires Odin, Go with CGO, Node.js, curl, and Nginx with `http_auth_request` and
the static Brotli module. `.agents/setup` installs these in new orbs; on other
Debian installations use `sudo apt-get install nginx libnginx-mod-http-brotli-static build-essential`.

```bash
mkdir -p .amp/lighthouse/{lib,models}
npm ci --prefix client
npm run build --prefix client
odin build . -o:speed -out:.amp/lighthouse/server

# Versions and model match services/bots/nrc-search/Dockerfile.
curl -fL --retry 3 https://github.com/daulet/tokenizers/releases/download/v1.25.0/libtokenizers.linux-amd64.tar.gz \
  -o .amp/lighthouse/tokenizers.tar.gz
tar -xzf .amp/lighthouse/tokenizers.tar.gz -C .amp/lighthouse/lib
curl -fL --retry 3 https://github.com/microsoft/onnxruntime/releases/download/v1.24.1/onnxruntime-linux-x64-1.24.1.tgz \
  -o .amp/lighthouse/onnxruntime.tgz
tar -xzf .amp/lighthouse/onnxruntime.tgz -C .amp/lighthouse/lib
# About 1.2 GiB; retain these files between rebuilds.
for file in onnx/model.onnx onnx/model.onnx_data tokenizer.json; do
  curl -fL --retry 3 "https://huggingface.co/onnx-community/embeddinggemma-2-ONNX/resolve/daa72c51243991dfcaf9f9137d2c573d8f7790c0/$file" \
    -o ".amp/lighthouse/models/${file##*/}"
done
root="$PWD"
(cd services/bots/nrc-search && CGO_ENABLED=1 CGO_LDFLAGS="-L$root/.amp/lighthouse/lib" \
  go build -o "$root/.amp/lighthouse/search" .)
```

## Run in this orb

```bash
amp orb service start nrc-local-backend --command 'node test/lighthouse-local.mjs backend' --port 8080
amp orb service start nrc-local-auth --command 'node test/lighthouse-local.mjs auth' --port 8093
amp orb service start nrc-local-search --command 'node test/lighthouse-local.mjs search' --port 8090
amp orb service start nrc-local --command 'node test/lighthouse-local.mjs nginx' --port 8000 --portal
```

These supervised services survive orb pause/resume. Open the portal URL printed
by the last command. All visitors share the test identity. On an ordinary local
machine, run each `node` command in its own terminal instead.

Use `amp orb service logs NAME`, `status NAME`, `restart NAME`, or `stop NAME`.
After frontend edits, rebuild `client/dist` before auditing. After backend edits,
stop `nrc-local-backend`, rebuild its binary, then restart it. Restart `nrc-local`
after editing the Nginx config or fixture. Stop all four services before removing
any disposable fixture data; ordinary restarts preserve it.

## Verify and measure

The browser check uses the repository's Playwright installation (`.agents/setup`).

```bash
node test/lighthouse-local.e2e.mjs
mkdir -p .amp/in/artifacts
# Set CHROME_PATH to the installed Chromium binary if not auto-detected.
for i in 1 2 3; do
  npx --yes lighthouse@13.4.1 http://127.0.0.1:8000 \
    --chrome-flags='--headless --no-sandbox' \
    --output=json --output=html \
    --output-path=".amp/in/artifacts/lighthouse-local-$i" --quiet
done
```

Audit loopback, not the portal: the portal adds authentication, network latency,
and a review widget that are not part of NRC. Lighthouse defaults to mobile
simulated throttling and fresh storage per run. Avoid concurrent builds or browser
sessions, and report the median and range rather than one run. The first run can
be slower due to CDN/network variation. Keep the data and visible view consistent
when comparing revisions.

Initial connected baseline (Lighthouse 13.4.1, Chromium 152, September 10, 2026,
2-vCPU/4-GiB orb, one backend worker, empty isolated database): performance
91/97/96 (median 96), accessibility 100, best practices 100, SEO 91.
Median FCP 2.0 s, LCP 2.3 s, TBT 110 ms, CLS 0.047. All three runs passed the
browser-console audit; LCP was `SEARCH LOADED CHAT...`, not a connection error.
SEO exposes the production SPA fallback returning HTML for `/robots.txt`.
This fixture deliberately retains that behavior rather than hiding the finding.

## Compression experiment

The build now emits level-9 gzip siblings for generated HTML/CSS/JS; Nginx uses
`gzip_static` and varies responses on `Accept-Encoding`. The browser check verifies
the precompressed file's length and equality with the uncompressed response.
This does not change decoded content, script order, or the offline cache contract.

Same-day control runs scored 97/97/95; precompression scored 97/95/97. Both medians
are 97, so there is no demonstrated Lighthouse score increase and 100 is not reached.
The measurable gain is transfer size: own HTML/CSS/JS fell from 240,271 to 194,412
bytes (including response headers), a 19% reduction. LCP medians were 2.2 s and
2.1 s respectively; that small timing difference is not conclusive.

Full vendor self-hosting, WebAssembly Zstd, deferred scripts, and a CDN preconnect
were tested and removed because they did not improve the measurements. Splitting
views or CSS into lazy-loaded parts remains a separate, larger change; no runtime
features or security checks were removed to improve the score.

## Brotli follow-up

The build also emits quality-11 `.br` files. Nginx loads the static Brotli module,
serves Brotli when accepted, and falls back to gzip or identity. Tests cover both
HTML and CSS with browser-style headers, Brotli only, `br;q=0`, and identity,
including identical decoded bytes, content lengths, and `Vary: Accept-Encoding`.
The source/decompressed files and service-worker URLs remain unchanged.

Brotli is enabled only for the generated HTML and hashed assets. Other files,
including the service worker and latency worker, retain dynamic gzip even when
the browser also accepts Brotli; the browser check covers this fallback.

Own HTML/CSS/JS payloads total 163,097 bytes with Brotli versus 191,097 with gzip
(14.7% smaller, excluding headers). Three Chromium/Lighthouse 13.4.1 mobile runs
scored 97/97/97, with accessibility and best practices 100, SEO 91. Median FCP
was 1.7 s and LCP 2.2 s. This confirms smaller transfers, not a score increase.

The Docker runtime now uses Alpine 3.23's matching `nginx` and
`nginx-mod-http-brotli` packages instead of mixing a distro module with the
official Nginx image's potentially different ABI. Container logs still go to
stdout/stderr. Docker itself was unavailable in the orb; the Alpine package
installation and production `nginx -t` were checked in a disposable Alpine root
filesystem. Runtime negotiation was verified against the real local Nginx stack.

## Mobile startup layout shift

The mobile shell initially displayed its 52-pixel chat tools row, then hid it when
JavaScript added `mobile-chat-view`. Initializing that existing default state in
HTML removes the jump without changing script order or WebSocket initialization.
The mobile browser regression test holds scripts until the shell has rendered,
checks that tools are collapsed, and verifies that the log's top position does not
change after startup. It failed before the fix and passes for source and build.

Three connected mobile Lighthouse runs after this fix scored 97/97/97. CLS was
0.000018 in all three, down from 0.047. FCP median was 1.53 s (1.36–1.68), LCP
1.95 s (1.80–2.10), and TBT 151 ms (133–155). Timing changes include normal run
variation; the delayed-script geometry test independently confirms the CLS fix.
Accessibility and best practices remain 100, SEO 91. The middle run reports no
forced reflow, but still estimates 890 ms of render-blocking savings and 299 KiB
of unused JavaScript, predominantly the Zstd codec. These estimates are not
additive or proof that removing required functionality would improve the score.

## Startup yielding experiment (removed)

A `scheduler.yield()` boundary after chat initialization scored 98/97/98 with
TBT 104/137/112 ms. Moving the boundary after theme application, and skipping it
for shared or restored non-chat views, avoids intentionally painting the wrong
theme/view. That version scored 97/97/97 with TBT 148/140/117 ms, LCP
2.01/1.95/2.10 s, and unchanged CLS. The small TBT difference overlaps the control
range and does not demonstrate a dependable score improvement, so the change
and its temporary scheduler-specific tests were removed.

Native scheduling, the timer fallback, saved task/note views, backend connection,
and offline upgrades passed browser checks during the experiment. KaTeX remains
synchronous with Markdown rendering and Zstd initialization still precedes the
WebSocket connection; deferring either requires preserving those contracts,
not merely changing their script tags.
