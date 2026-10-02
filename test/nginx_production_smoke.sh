#!/usr/bin/env bash
set -euo pipefail

# Exercises the production Nginx configuration without requiring Docker. Set NGINX_BIN
# when nginx is not installed on PATH (an extracted Debian binary works).
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
nginx_bin=${NGINX_BIN:-$(command -v nginx || true)}
if [[ -z "$nginx_bin" || ! -x "$nginx_bin" ]]; then
    echo "NGINX_BIN must name an executable nginx binary" >&2
    exit 2
fi
[[ -f "$repo_root/client/dist/index.html" ]] || {
    echo "client/dist is missing; run npm run build --prefix client" >&2
    exit 2
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nrc-nginx-smoke.XXXXXX")
nginx_port=$((20000 + $$ % 10000))
ws_port=$((nginx_port + 1))
search_port=$((nginx_port + 2))
ai_port=$((nginx_port + 3))
cleanup() {
    [[ -f "$tmp/nginx.pid" ]] && "$nginx_bin" -p "$tmp" -c nginx.conf -s quit >/dev/null 2>&1 || true
    [[ -n "${mock_pid:-}" ]] && kill "$mock_pid" >/dev/null 2>&1 || true
    wait "${mock_pid:-0}" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT

python3 - "$ws_port" "$search_port" "$ai_port" <<'PY' &
import base64, hashlib, http.server, socketserver, sys, threading

class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_GET(self):
        if self.headers.get("Upgrade", "").lower() == "websocket":
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            return
        body = f"{self.server.label}:{self.path}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *args):
        pass

ports = [(int(sys.argv[1]), "ws"), (int(sys.argv[2]), "search"), (int(sys.argv[3]), "ai")]
servers = []
for port, label in ports:
    server = ReusableTCPServer(("127.0.0.1", port), Handler)
    server.label = label
    servers.append(server)
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
PY
mock_pid=$!

sed \
    -e "s|listen 80;|listen 127.0.0.1:$nginx_port;|" \
    -e "s|root /usr/share/nginx/html;|root $repo_root/client/dist;|" \
    -e "s|http://websocket-server:8080|http://127.0.0.1:$ws_port|" \
    -e "s|http://search:8090|http://127.0.0.1:$search_port|" \
    -e "s|http://ai:8091|http://127.0.0.1:$ai_port|" \
    -e "s|include /etc/nginx/mime.types;|include $tmp/mime.types;|" \
    "$repo_root/docker/nginx/nginx.conf" >"$tmp/nginx.conf"
cp "${NGINX_MIME_TYPES:-$repo_root/../missing-mime-types}" "$tmp/mime.types" 2>/dev/null || \
    cp /etc/nginx/mime.types "$tmp/mime.types" 2>/dev/null || \
    cp "$(dirname "$nginx_bin")/../etc/nginx/mime.types" "$tmp/mime.types" 2>/dev/null || {
        echo "Set NGINX_MIME_TYPES to nginx's mime.types" >&2
        exit 2
    }
sed -i "/^events {/i pid $tmp/nginx.pid;\nerror_log $tmp/error.log;" "$tmp/nginx.conf"
sed -i "/^http {/a\\    access_log $tmp/access.log;\n    client_body_temp_path $tmp/body;\n    proxy_temp_path $tmp/proxy;\n    fastcgi_temp_path $tmp/fastcgi;\n    uwsgi_temp_path $tmp/uwsgi;\n    scgi_temp_path $tmp/scgi;" "$tmp/nginx.conf"
mkdir -p "$tmp/logs" "$tmp/body" "$tmp/proxy" "$tmp/fastcgi" "$tmp/uwsgi" "$tmp/scgi"
"$nginx_bin" -p "$tmp" -c nginx.conf -t
"$nginx_bin" -p "$tmp" -c nginx.conf

base="http://127.0.0.1:$nginx_port"
for _ in {1..50}; do curl -fsS "$base/" >/dev/null 2>&1 && break; sleep .05; done
headers() { curl -sS -D - -o /dev/null "$@" | tr -d '\r'; }
assert_header() { grep -Eiq "^$2: $3$" <<<"$(headers "$1")" || { headers "$1"; echo "missing $2: $3 for $1" >&2; exit 1; }; }

assert_header "$base/" Content-Type 'text/html'
assert_header "$base/" Cache-Control 'no-cache'
assert_header "$base/service-worker.js" Content-Type 'application/javascript'
assert_header "$base/service-worker.js" Cache-Control 'no-cache'

css=$(find "$repo_root/client/dist/assets" -maxdepth 1 -type f -name '*.css' -printf '%f\n' | head -1)
js=$(find "$repo_root/client/dist/assets" -maxdepth 1 -type f -name '*.js' -printf '%f\n' | head -1)
font=$(find "$repo_root/client/dist/assets" -maxdepth 1 -type f -name '*.woff2' -printf '%f\n' | head -1)
for spec in "$css:text/css" "$js:application/javascript" "$font:font/woff2"; do
    file=${spec%%:*}; type=${spec#*:}
    [[ -n "$file" ]] || { echo "missing expected built asset" >&2; exit 1; }
    assert_header "$base/assets/$file" Content-Type "$type"
    assert_header "$base/assets/$file" Cache-Control 'public, max-age=31536000, immutable'
done

gzip_headers=$(headers -H 'Accept-Encoding: gzip' "$base/assets/$css")
grep -Eiq '^Content-Encoding: gzip$' <<<"$gzip_headers" || { echo "$gzip_headers"; echo "CSS was not gzipped" >&2; exit 1; }
missing_headers=$(headers "$base/assets/does-not-exist-deadbeef.js")
grep -Eq '^HTTP/[0-9.]+ 404' <<<"$missing_headers"
! grep -Eiq '^Cache-Control:.*immutable' <<<"$missing_headers"

[[ $(curl -fsS "$base/search/health?ready=1") == 'search:/health?ready=1' ]]
[[ $(curl -fsS "$base/ai/chat?model=x") == 'ai:/chat?model=x' ]]
ws_headers=$(curl --max-time 2 -sS -D - -o /dev/null \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$base/workspace" 2>/dev/null || true)
grep -Eq '^HTTP/[0-9.]+ 101' <<<"$(tr -d '\r' <<<"$ws_headers")"

# A core-only deployment has no sidecar DNS entries. Nginx must still start
# and serve the shell/WebSocket route, returning 502 only for sidecar requests.
"$nginx_bin" -p "$tmp" -c nginx.conf -s quit
for _ in {1..100}; do [[ ! -f "$tmp/nginx.pid" ]] && break; sleep .05; done
sed -i \
    -e "s|http://127.0.0.1:$search_port|http://search-unavailable.invalid:8090|" \
    -e "s|http://127.0.0.1:$ai_port|http://ai-unavailable.invalid:8091|" \
    -e 's|resolver 127.0.0.11|resolver 127.0.0.1:9|' \
    -e 's|resolver_timeout 2s|resolver_timeout 1s|' \
    "$tmp/nginx.conf"
"$nginx_bin" -p "$tmp" -c nginx.conf -t
"$nginx_bin" -p "$tmp" -c nginx.conf
for _ in {1..50}; do curl -fsS "$base/" >/dev/null 2>&1 && break; sleep .05; done
assert_header "$base/" Content-Type 'text/html'
for route in /search/health /ai/health; do
    [[ $(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' "$base$route") == 502 ]]
done
ws_headers=$(curl --max-time 2 -sS -D - -o /dev/null \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$base/workspace" 2>/dev/null || true)
grep -Eq '^HTTP/[0-9.]+ 101' <<<"$(tr -d '\r' <<<"$ws_headers")"

echo "Nginx production smoke checks passed on port $nginx_port"
