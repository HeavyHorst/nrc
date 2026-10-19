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

## Staff tickets

Company ticket-sharing groups are managed separately from individual tickets:

```sh
nrc customer ticket-group list 41
nrc customer ticket-group create 41 --id support --name 'Support team' --contacts 42,43
nrc customer ticket-group create 41 --name 'Billing' # generates a stable random ID
nrc customer ticket-group update 41 support --name 'Customer support' --contacts 42,44
nrc customer ticket-group update 41 support --contacts '' # empty membership
nrc customer ticket-group delete 41 support
```

Groups share tickets only between direct fellow members within this company;
sharing is not transitive across overlapping groups. Names are trimmed, and
renaming never changes the group ID. Contact IDs must be unique canonical positive
decimal strings and must identify workspace contacts currently linked to the company
by `MemberOf` (either direction). Updates replace the entire supplied member list;
omitted flags preserve existing values. Removing stale/deleted members is allowed,
and deleting a group does not resolve its old contacts. These conditional preview-only
transactions preserve unknown company metadata, body and attachments. Ordinary
company updates also preserve groups. JSON list output has `company_id` and
`ticket_groups`; mutations report the company `id` and stable `group_id`.

Tickets use direct NRC workspace assets, entries and graph edges; except for
`ticket search`, no ticket portal or search service is required. All IDs below are stable positive numeric IDs,
never display names. Use the normal authenticated staff proxy configuration.

```sh
nrc ticket list --status open --assignee alice --company 41 --search invoice
nrc ticket search 'invoice conversation' --status open --assignee alice --company 41 --top 100
nrc ticket search 'invoice conversation' --payload --human
nrc ticket create --requester customer@example.com --title 'Invoice question' \
  --body 'Original customer request' --contact 42 --attach /tmp/invoice.pdf
nrc ticket get 100
nrc ticket update 100 --status in_progress --assignee alice --expect-updated-at 123456
nrc ticket reply 100 --body 'Staff-only investigation'  # internal by default
nrc ticket internal-note 100 --body-file /tmp/investigation.md --attach /tmp/log.txt
nrc ticket reply 100 --public --body 'Here is the answer'
nrc ticket attachments 100
nrc ticket attachments 100 --entry 101
nrc ticket download-attachment 100 0 /tmp/invoice.pdf
nrc ticket download-attachment 100 0 /tmp/log.txt --entry 101
nrc ticket links 100
nrc ticket link 100 --task 200
nrc ticket link 100 --slice 300
nrc ticket unlink 100 --task 200
nrc ticket create-task 100 --title 'Investigate billing' --description 'Follow up'
nrc ticket delete 100
```

`list` follows every live NRC page (not a snapshot). Exact filters are `--status`,
`--assignee`, `--company`, `--contact`, `--requester`, `--requester-name`, `--title`;
`--search` is a local case-insensitive substring search of title, requester and
original body. Status is `open`, `in_progress`, `waiting_customer`, `resolved` or
`closed`. Create requires explicit requester, title and nonempty body, with optional
company, contact, requester-name, assignee, status (default open), and attachments.
Use either `--body` or `--body-file`; bodies are limited to 32,000 bytes.

`ticket search <query>` instead calls the configured proxy's `POST /search`
(nrc-search required), without opening a WebSocket. It searches workspace scope 0
and returns ranked Ticket assets, not entry hits: the service aggregates the
original body and all replies/internal notes into one conversation before ranking
and limiting. `--status`, `--assignee` and `--company` are exact parent-ticket
filters. The trimmed query must be nonempty; `--top` defaults to 100 and accepts
1–100. `--payload` includes only the original ticket body, never concatenated
replies/internal notes. Normal JSON (default) and `--human` output are supported.
Unlike this indexed conversation search, `ticket list --search` remains a local
substring filter over title, requester and original body only.

Contact validation uses actual `MemberOf` edges in either direction, not legacy
metadata hints. Contact-only creation infers its company only when exactly one
company membership exists. Multiple memberships require `--company`; an explicitly
wrong company is rejected. Company/contact IDs must reference the correct asset type.

`get` includes the original read-only body, attachment metadata and all public and
internal entries ordered by creation time then ID. Entries retain their kind and
server owner identity; the CLI does not invent an author name. Staff entry writes
can only be internal notes or explicit public replies, never `customer_reply`.
Attachments can only be added while creating an original or entry (10 files maximum,
100 MB each). Downloads select a zero-based index or exact file ID and verify an
entry belongs to the ticket. Omitted output paths use the attachment basename.

`update` changes only supplied metadata flags, preserving unknown metadata fields,
original payload and attachments. Empty optional flags clear values. Every update
is a conditional server transaction against the version just read;
`--expect-updated-at` additionally rejects stale caller versions. Work links use
`RelatedTo` edges, read in either direction; duplicate links are refused.
`create-task` creates and links atomically. Delete follows the server asset lifecycle
(including server-owned child/edge cleanup); linked tasks and slices are not deleted.
All mutations report explicit results and are never automatically retried. If an
acknowledgement is lost, inspect records before manually retrying. Uploaded blobs
can remain unreferenced if a subsequent create fails.

JSON is default; `--human`, `--pretty`, `--fields` on reads, and `nrc capabilities`
follow the shared CLI contract. Ticket lists use the `entries` envelope. Generic
`nrc asset` also recognizes `ticket` and `ticket_entry` for raw administrative use.

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
nrc publish category-order "Marketplace" "Erste Schritte" "API & Integrationen"
nrc publish category-order # Reset main categories to alphabetical order
```

`category-order` takes exact published category names in the desired order.
Omitted and new categories follow alphabetically. Changes are immediately public,
persist across restarts and do not change article positions, contents or approvals.
Unknown or duplicate category names reject the entire change.

Output defaults to JSON. `draft` copies the current note and attachments into a
private snapshot, and returns the service-configured human `review_url` (a relative
path if no reviewer URL is configured). `inspect` compares stored draft
content with the published version and reports an advisory `stale` flag. Only a
reviewer using the browser can publish. Source workspace is fixed by the service
instance, not the CLI's default workspace. After an ambiguous create failure, list
drafts before retrying; creation is not idempotent and is never automatically retried.

## Newsletter and service information

`nrc newsletter` operates the same optional newsletter service as the browser,
through `/newsletter/api/...` on the configured Tailscale proxy. It uses the
configured workspace and Tailscale identity; workspace access and the explicit
`NRC_NEWSLETTER_USERS` sending permission are required. There are no additional
CLI credentials and no direct Zoho connection. `nrc capabilities` includes all
commands and flags. Responses default to JSON; `--human` prints indented JSON.

```sh
nrc newsletter state
nrc newsletter templates
nrc newsletter customers
nrc newsletter subscriber list
nrc newsletter subscriber search --query example.com --limit 25 --offset 0
nrc newsletter campaign list
nrc newsletter campaign list --include-archived --fields id,title,status,archived,revision

# Delete only drafts; archive/restore only completed campaigns. No mail is sent.
# Use the current revision from campaign list; stale revisions are rejected.
nrc newsletter campaign delete <id> --revision 1
nrc newsletter campaign archive <id> --revision 3
nrc newsletter campaign restore <id> --revision 4

# Preview first; only the second command imports existing consent. Neither sends mail.
nrc newsletter consent import --input consents.json
nrc newsletter consent import --input consents.json --confirm
```

Consent input is a JSON array or `{"records":[...]}`; stdin (also `--input -`)
is supported. Each row requires `email`, `source`, past RFC3339 `confirmed_at`,
`evidence`, and `scope`; `external_id` is optional. For example:

```json
[{"email":"anna@example.test","source":"Zoho export","confirmed_at":"2025-02-03T10:20:00Z","evidence":"DOI record 123","scope":"Product newsletter","external_id":"123"}]
```

Import customers/contacts first: consent matches existing live contact addresses.
Unknown addresses, duplicates, existing subscriptions, optouts and delivery blocks
are reported/skipped. Invalid records or conflicting duplicates reject the batch.
Import preserves the original proof and sends no invitation. Use at most 200 rows
per batch and keep the complete request within 64 KiB. A `confirm` property in the
file is rejected: only the explicit CLI flag authorizes writing.

Campaign create/update take a complete draft JSON object, not a partial patch:

```json
{"kind":"service","audience":"selected_customers","customer_ids":["7"],"service_reason":"Necessary API migration","title":"API migration","template_id":"12","subject":"API migration on December 1","variables":{"introduction":"Migration details"}}
```

Use an approved template ID from `templates` and its actual Mailjet variable
names. For all nonarchived customers set `audience:"all_customers"` and
`customer_ids:[]`. A newsletter draft uses `kind:"newsletter"` with no audience,
customer IDs or service reason. Service information must be necessary and
non-promotional; this is not an override for marketing consent.

```sh
nrc newsletter campaign create --input campaign.json
nrc newsletter campaign update <id> --revision 1 --input campaign.json
nrc newsletter campaign audience <id> --revision 2
nrc newsletter campaign preview <id> --revision 2

# These commands send real mail when the service is configured.
nrc newsletter campaign test <id> --revision 2 --email tester@example.test
nrc newsletter campaign send <id> --revision 2 \
  --confirm-subject 'API migration on December 1' --audience-token '<review token>'

# Only for an individual, documented signup request; never invite the whole CRM.
nrc newsletter subscriber invite 81 --source 'Signup request ticket #123'
nrc newsletter subscriber unsubscribe 81
```

Inspect `campaign list` for IDs, revisions, status and delivery outcomes. Updating
invalidates the test. `preview` returns raw template HTML/text as JSON, never
executes it, and is not a personalized Mailjet render. Sending requires a test of
the exact revision and its exact subject. Service campaigns additionally require
the token returned by `audience`; changed recipients reject sending. The CLI never
automatically reviews, tests, confirms or retries sending. After an ambiguous
failure inspect state before retrying; sending is queued, not completed by the
command returning successfully.

Service roles belong to contacts, separately for each linked company:

```sh
nrc contact create --company 7 --title 'Service mailbox' --email service@example.test --service-for 7
nrc contact update 81 --service-for 7,9
nrc contact update 81 --service-for '' # Clear all service roles
```

`--service-for` replaces the complete list. IDs must be unique, nonarchived
companies linked by `member-of` (either orientation); create can designate its
`--company`. Omit the flag to preserve existing roles. A role without a live
membership never authorizes service delivery. Newsletter optouts do not block
necessary service information, but hard-bounce/spam blocks always do.

## Workspace data commands

```sh
nrc task list
nrc note list
nrc slice list
nrc customer list
nrc contact list
nrc activity list
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
Create a slice with a display name, then use its returned numeric asset ID.
Duplicate names are allowed. Replace `11` below with the created ID:

```sh
nrc slice create "Customer rollout" --outcome "Customer can use the new release"
nrc slice list --fields slice_id,name
nrc slice assign 11 --task 42,43 --note 81 --file 91
nrc slice members 11
nrc slice get 11
nrc slice update 11 --name "Customer rollout phase 2"
```

`get`, `members`, `assign`, `unassign`, `update`, `close`, `reopen` and `delete`
take a stable numeric slice ID, never a name. List name queries remain
case-insensitive substring searches; use the returned `slice_id` to address a
match. Renaming preserves memberships and links. Names must remain nonempty and
within the protocol's 128-byte limit; previews and versions must remain valid.

These commands add membership links, not copies. The tasks keep their project
labels and can belong to other slices. Use `slice unassign` to remove a member
without deleting it. Use `slice close` when the outcome is reached; task completion
does not close the slice automatically. Use `slice reopen` to reopen it.

To connect the work to a customer, first find the company ID with
`nrc customer list`. Replace `7` below with that ID:

For relevance-ranked discovery use `nrc customer search "Acme" --limit 20`
or `nrc customer list --search "Acme" --page-size 20`.
Both use nrc-search's hybrid text/vector company register: matching linked
contacts contribute to company matches, companies are deduplicated, and archived
companies are excluded unless `--archived` is set. Returned records are loaded
fresh from NRC. Search requires the typed search service; unavailable search
returns an error, not a silently different search.

Blank/whitespace `--search` still lists the complete NRC register with normal
cursor pagination. Nonblank `--search` cannot be combined with `--all` or
`--cursor`: ranked search returns `entries`, `query`, `limit`, `limit_reached`,
`complete:false`, and `stale`, not an inventory count or pagination cursor.
`limit_reached` signals possible additional matches, not an exact total.

Companies use `nrc customer`, contacts use `nrc contact`, and durable activities
use `nrc activity`, with `list`, `get`, `create`, `update`, and `delete` directly
under each. Only customers support `archive`, `restore`, and company-register
`search`. Contact/activity creation requires `--company <id>`; their lists are
workspace-wide. The previous nested command paths are removed without aliases.

```sh
nrc customer create --title "Example GmbH" --city "Berlin"
nrc contact create --company 7 --title "Anna Beispiel" --email "anna@example.test"
nrc contact update 81 --phone "+49 30 123456"
nrc activity create --company 7 --title "Angebot besprochen" --kind Call --body "Angebot bis Freitag senden."
```

```sh
nrc customer link 7 task 42
nrc customer link 7 asset 81
nrc customer link 7 asset 91
nrc customer links 7
```

Customer work links default to `related-to`. Contacts and activities default to
`member-of`. `customer links` lists edges; use `task get`, `note get`, `file get`
or `customer get` to read the records. To remove a company link, use
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
nrc reminder create "Update my Xcode" --deadline 2026-10-16T17:00:00+02:00
nrc reminder create "Submit rollout documents" --deadline 2026-10-09T17:00:00+02:00 \
  --window-start 2026-10-05T09:00:00+02:00 --urgency-days 2 --note-id 81 --visibility team
nrc reminder list
```

New reminders default to `--visibility personal`: only their creator can see,
edit or delete them. `--visibility team` shares a reminder with the workspace.
Older reminders remain Team. Visibility is fixed at creation and shown in list
and get output; updates preserve it. Personal reminders may reference a shared
note, but cannot have shared graph relations, parent/child records or attachments.

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
