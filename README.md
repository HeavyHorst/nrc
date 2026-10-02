# nrc

NRC is a single-node collaboration server written in Odin, with a web client and
a Go CLI. It combines real-time chat and DMs with persistent tasks, notes, files,
customers, appointments and relationships between them. Chat is ephemeral by
default; operators can enable bounded room-message retention. Durable data
belongs to the workspace, not to individual chat rooms.

## Quickstart

The supplied deployment uses Docker Compose and Tailscale authentication.
Before you start, check these requirements:

- An x86-64 Linux host with kernel 5.19 or newer. Docker must permit io_uring.
  Containers use the host kernel. The server container runs privileged.
- Docker Engine with Compose v2 or newer.
- A Tailscale account. Enable MagicDNS and HTTPS certificates in your tailnet.

Clone the repository and create the configuration file:

```sh
git clone https://github.com/HeavyHorst/nrc.git
cd nrc
umask 077
cp .env.example .env
```

Edit `.env` before starting:

- Set **different, randomly generated** `NRC_JWT_SECRET` and `NRC_BOT_SECRET`
  values (for example, run `openssl rand -hex 32` separately for each).
- Set `TS_AUTHKEY` to a Tailscale auth key allowed to join your tailnet. Approve
  the node in Tailscale if your policy requires it. Treat the key as a secret.
- Leave `NRC_MESSAGE_RETENTION=0` for ephemeral chat.

**Every workspace is open to authenticated tailnet identities by default.**
Configure [workspace access](docs/OPERATIONS.md#workspace-access) before you store
private data. Do not expose Nginx, the server or private sidecar APIs directly to users.
Optional [Publish](services/bots/nrc-publish/README.md) has a separate public
listener for approved articles; its administration must stay private.

Start the services and check their logs:

```sh
docker compose --env-file .env -f docker/docker-compose.yml up -d --build
docker compose --env-file .env -f docker/docker-compose.yml logs tailscale-proxy websocket-server
```

Find the new `nrc` node in the Tailscale admin console. Use its actual MagicDNS
name; Tailscale may add a suffix if the name is already in use.
From a device on the same tailnet, open `https://<node>.<tailnet>.ts.net`.
The proxy identifies you through Tailscale. There is no NRC password login.
The web client connects to `workspace1`. Open a chat room and send a message.
Use the task register to create a task that persists across sessions.

The basic stack needs no LLM key or embedding model. Search, AI and metrics are
[optional Compose profiles](docs/OPERATIONS.md#optional-services).

To stop the services, run `docker compose --env-file .env -f docker/docker-compose.yml down`.
This keeps the named volumes. **Do not add `-v`: it deletes stored data.**

## Documentation

- [Concepts](docs/CONCEPTS.md) — workspaces, chat, durable data and relationships
- [Operations](docs/OPERATIONS.md) — configuration, security, optional services and backups
- [Development](docs/DEVELOPMENT.md) — builds, tests and architecture
- [CLI](cli/README.md) and [binary protocol](protocol/README.md)
- [Documentation index](docs/README.md) — detailed references and benchmarks

## License

NRC is licensed under the [MIT License](LICENSE). Third-party components remain
subject to their own license terms. See [third-party notices](THIRD_PARTY_NOTICES.md),
including the separate terms for the optional Search model.
