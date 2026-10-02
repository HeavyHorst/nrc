# NRC CLI

Install Go 1.26 or newer. Build from the repository root:

```sh
go -C cli build -o ../nrc ./cmd/nrc
./nrc --help
```

Run the CLI from an authenticated device on the NRC tailnet. Replace the example
hostname below with your NRC node's actual MagicDNS name. Keep the trailing `/`
on the server URL. Set the server and workspace before you run data commands:

```sh
./nrc config set server 'wss://nrc.YOUR-TAILNET.ts.net/'
./nrc config set workspace workspace1
./nrc task list
```

The proxy uses your Tailscale identity, not a nickname flag. A standalone NRC
server also requires authentication for WebSocket connections.
Configuration is stored in `~/.config/nrc/config.yaml`. Run `nrc config show`
to display it. Commands return JSON by default. Use `--human` for readable
output. Run `nrc <command> --help` to see its flags.
Search and retrieve commands require their corresponding
[optional services](../docs/OPERATIONS.md#optional-services).

The examples below use `nrc`. If the binary is not on PATH, use `./nrc` from
the repository root instead. See [Concepts](../docs/CONCEPTS.md) for when to use
tasks, notes, slices, reminders and appointments.

## Data scope

Rooms and DMs are chat-only. All stored work belongs to the configured workspace.
Changing chat rooms does not change the tasks, notes or other records you see.
Use `--room` only for chat commands, not for data or graph commands.

## Public knowledge-base drafts

`nrc publish` uses `/publish/api/...` on the existing Tailscale proxy. It uses the
configured proxy URL, or `NRC_PUBLISH_URL` as an override of that proxy's base URL.
Run it on a Tailscale-connected machine or tagged runner: no additional agent token
is needed. WhoIs and the workspace policy authorize requests; the backend verifies
the proxy's signed assertion. Do not give agents reviewer credentials or the
infrastructure signing key. They cannot approve or withdraw articles.

```sh
nrc publish list
nrc publish draft --note 41 --slug api-schluessel --title "API-Schlüssel erstellen" \
  --category "API & Integrationen" --kind Anleitung
nrc publish inspect <draft-id> --json
```

Output defaults to JSON. `draft` copies the current note and attachments into a
private snapshot, and returns the service-configured human `review_url` (a relative
path if no reviewer URL is configured). `inspect` compares stored draft
content with the published version and reports an advisory `stale` flag. Only a
reviewer using the browser can publish. Source workspace is fixed by the service
instance, not the CLI's default workspace. After an ambiguous create failure, list
drafts before retrying; creation is not idempotent and is never automatically retried.

## Workspace data commands

```sh
nrc task list
nrc note list
nrc slice list
nrc customer company list
nrc file list
nrc appointment list --from 2026-09-01T00:00:00Z --to 2026-10-01T00:00:00Z
nrc search query "release checklist"
nrc chat send "Ready for review" --room engineering
```

To assign task 356, run `nrc task update 356 --assignee alice`.
Pass `--assignee ""` to clear the assignment. Omit the flag to keep the current
assignment. Run `nrc task get 356` to check the assignee.
A slice's owner does not automatically assign its member tasks.

## Example: connect rollout work

Run this example in a test workspace: it creates records and links.
First create the work and its decision note. To upload the checklist, use a local
file that exists:

```sh
nrc task create "Prepare rollout API" --project Backend
nrc task create "Test rollout UI" --project Webclient
nrc note create "Rollout decision" --content "Release after API and UI checks pass."
nrc file upload ./checklist.pdf --title "Rollout checklist"
```

Use the IDs returned by these commands. The examples below assume task IDs `42`
and `43`, note ID `81` and File record ID `91`. Replace them with your actual IDs.
The File record ID is not the uploaded blob's `att_...` identifier.
Choose a slice name that does not already exist:

```sh
nrc slice create "Customer rollout" --outcome "Customer can use the new release"
nrc slice assign "Customer rollout" --task 42,43 --note 81 --file 91
nrc slice members "Customer rollout"
nrc slice get "Customer rollout"
```

These commands add membership links, not copies. The tasks keep their project
labels and can belong to other slices. Use `slice unassign` to remove a member
without deleting it. Use `slice close` when the outcome is reached; task completion
does not close the slice automatically. Use `slice reopen` to reopen it.

To connect the work to a customer, first find the company ID with
`nrc customer company list`. Replace `7` below with that ID:

```sh
nrc customer link 7 task 42
nrc customer link 7 asset 81
nrc customer link 7 asset 91
nrc customer links 7
```

Customer work links default to `related-to`. Contacts and activities default to
`member-of`. `customer links` lists edges; use `task get`, `note get`, `file get`
or `customer company get` to read the records. To remove a company link, use
`customer unlink <company-id> <edge-id>`; both records remain.

## Edges and graph queries

Use `slice assign` and `customer link` for their membership rules. Use `edge`
when you need to set a relation directly. Notes, files, slices and customer
records all use endpoint type `asset`; tasks use `task`.

For example, link rollout task `42` to decision note `81`:

```sh
nrc edge create --source-type task --source-id 42 \
  --target-type asset --target-id 81 --relation references
nrc edge list --source-type task --source-id 42
```

Relations include `references`, `related-to`, `depends-on`, `blocks`,
`derived-from`, `supersedes` and `member-of`. A `blocks` or `depends-on` edge is
a graph relation, not the task's blocker field. Use `task update <id> --blk
<task-id>` to set a task blocker, or `--blk clear` to remove it.
**`edge delete <edge-id>` removes the relation, not its endpoint records.**

Use graph queries to inspect the connections:

```sh
# Follow links up to two hops from the rollout task.
nrc graph walk --start-type task --start-id 42 --depth 2

# Find a shortest path from the task to the checklist File.
nrc graph path --from-type task --from-id 42 --to-type asset --to-id 91

# Find records connected to both rollout tasks.
nrc graph common --a-type task --a-id 42 --b-type task --b-id 43

# List the ten most connected nodes by degree.
nrc graph degree --top 10
```

Walk, path and common queries default to both edge directions. Use `--direction
outgoing` or `--direction incoming` to follow one direction. Use `--relation`
to limit relation types, for example `--relation references,member-of`.
Walk and path searches are bounded to at most four hops. Check a walk's
`truncated` field before treating its result as complete.
These commands use the NRC server directly; they need no Search or AI service.

## Search and retrieval

Start the [Search profile](../docs/OPERATIONS.md#optional-services) before using
`search query`. Start the AI profile, which includes Search, before using
`retrieve`. Configure its LLM provider as described in Operations.

```sh
nrc search query "rollout checklist"
nrc retrieve "What is connected to the rollout?" --depth 2 --paths best
```

Search finds matching records. Retrieve combines search results with linked
records, content and graph paths. It returns evidence, not a generated answer.
Use `--payload none` to omit record content or `--no-graph` to omit graph expansion.

## Reminders and workspace memo

Use reminders for deadlines and optional work windows. Replace the dates and
note ID below with your own. Use an explicit time-zone offset to avoid ambiguity:

```sh
nrc reminder create "Submit rollout documents" --deadline 2026-10-09T17:00:00+02:00 \
  --window-start 2026-10-05T09:00:00+02:00 --urgency-days 2 --note-id 81
nrc reminder list
```

`nrc agenda show` and `nrc agenda set <content>` read and replace the shared
workspace memo. This is not the Calendar's Agenda view. Attention and Calendar
are browser views; the CLI reads their underlying tasks, reminders and appointments.

## Appointments

Use appointments for events with a start time and an optional end time.
Replace the example dates, assignee and IDs with your own. All appointment date
flags accept RFC3339 with `Z` or an explicit offset, or positive Unix nanoseconds.
For lists, `--from` is inclusive and `--to` is exclusive. The range must not
exceed 62 days:

```sh
nrc appointment create "Design review" --start 2026-09-27T10:00:00+02:00 --end 2026-09-27T11:00:00+02:00 --project NRC --assignee anke --description "API review" --url https://example.test/meet
nrc appointment list --from 2026-09-01T00:00:00Z --to 2026-11-01T00:00:00Z --project NRC --assignee anke
nrc appointment show 42
nrc appointment update 42 --start 2026-09-27T10:30:00+02:00 --description "Updated agenda"
nrc appointment update 42 --end "" # clear the end, making it a point appointment
nrc appointment delete 42
```

JSON timestamps are decimal nanosecond strings. Appointment lists follow all
pages automatically. The CLI does not schedule notifications.
See [Browser notifications](../docs/CONCEPTS.md#browser-notifications) for browser
alerts and their limits.

## Scripts and protocol scope

Commands return JSON by default. Use `--pretty` to indent it, or `--human` for
display. Run `nrc capabilities` for a machine-readable command and flag list.

Durable data uses protocol scope `0`. Remove `room` fields from batch documents
and individual batch operations. Explicit room selectors are rejected.
Existing local note backups retain their original scope; new backups use scope 0.
They are not interchangeable with legacy room/DM backups.

`nrc room list` reads RoomMapping assets from scope 0. Their stored IDs identify
chat rooms. Legacy graph JSON fields named `room_id` report `0`.
Go clients should use `protocol.WorkspaceDataConvID` for durable requests and
subscribe with `protocol.EncodeSubscribeConvs(protocol.WorkspaceDataConvID)`.
The server rejects nonzero durable scopes; it does not rewrite them.
Chat and DM requests retain their conversation IDs.

## Release packaging

Use Python 3.9 or newer and Go 1.26 or newer. From the repository root:

```sh
python3 cli/release.py cli-v0.7.0
# Optional: build only selected targets.
python3 cli/release.py cli-v0.7.0 --target linux/amd64 --output /tmp/nrc-release
python3 -m unittest discover -s cli -p test_release.py
```

The default output is `cli/dist/`. Builds cover Linux, macOS and Windows on amd64
and arm64, with CGO disabled. Each archive includes the binary, NRC's `LICENSE`,
third-party notices and license files from the target's imported modules and Go
toolchain. The script also writes archive SHA256 checksums. It does not publish.
The notice collection includes whole-module notices, not just linked files.

To add licenses to an existing binary without rebuilding it:

```sh
python3 cli/release_licenses.py /path/to/nrc-linux-amd64 --output /tmp/nrc-licensed
```

This creates a licensed archive containing the unchanged binary, its build
metadata and checksums. It fetches the module and Go versions recorded in the
binary, verifies module checksums, and refuses unknown local replacements or
CGO builds that need a separate review. Keep the license files with redistributed
binaries. Neither script uploads assets or creates GitHub releases.
