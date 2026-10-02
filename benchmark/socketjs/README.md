# SocketJS Comparable Benchmark

This folder provides a Socket.IO baseline that mirrors the NRC benchmark workload shape:

1. N clients connect.
2. Clients subscribe to a configurable set of conversations.
3. Clients send periodic messages with ack-based RTT measurement.
4. Broadcast receives are counted per client.

## Install

```bash
cd benchmark/socketjs
npm install
```

## Run

```bash
# Start managed Socket.IO server + benchmark clients
node benchmark.js --startServer --auth --users=1000 --workspaces=1 --duration=60
```

## Notes

1. Default URL is `ws://127.0.0.1:8081` to avoid colliding with NRC on `8080`.
2. JWT settings default to the same values used by e2e (`dev-insecure-nrc-jwt-secret`, issuer `nrc-tailscale-proxy`, audience `nrc`).
3. This is a baseline for directional comparison, not protocol-level equivalence with NRC binary framing.
