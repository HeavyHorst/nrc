# Customer workspace

The CUSTOMERS view stores companies, contacts and activity records in the NRC
workspace. Chat room selection does not affect them. Tasks and notes remain their
original objects and are linked with edges.
This first version has no sales pipeline, standalone ticket lifecycle or automatic
audit trail. Calls, meetings, emails and decisions are recorded explicitly; chat is
not copied into customer history.

## Enable the view

Set this in the environment of `tailscale-proxy` (the existing Compose deployment
reads the repository `.env`):

```dotenv
NRC_CUSTOMERS_USERS=alice@example.com,bob@example.com
```

Use full Tailscale `UserProfile.LoginName` values, **not NRC display nicknames**.
Matching is exact and case-sensitive; spaces around comma-separated entries are
ignored. Empty/unset means disabled for everyone. No wildcard or tagged-node access.
Recreate/restart the proxy with the updated environment and reload the client.
Deploy the updated server and client together: this view requires asset types 8–10
and the customer on-demand read opcodes below.

`GET /api/features` resolves identity via Tailscale WhoIs and returns only
`{"customers":true}` or `{"customers":false}` with `Cache-Control: no-store`.
The client defaults to disabled on failed requests and refreshes on reconnect.

**This is a view rollout flag, not a new data permission.** A user with access to
the same workspace can still read or change its customer assets through generic
NRC APIs, even if the CUSTOMERS navigation entry is hidden. Use workspace access
boundaries for sensitive data; neither tags nor this allowlist are customer-data ACLs.

## Storage contract

| Asset type | Preview JSON (`version: 1`) | Payload |
| --- | --- | --- |
| CustomerCompany / 8 | `title`, `number`, `sector`, `city`, `address`, `website`, `assignee`, optional `archived` | Empty |
| CustomerContact / 9 | `title`, `role`, `email`, `phone` | Empty |
| CustomerActivity / 10 | `title`, `kind` (Call/Meeting/Email/Decision), `excerpt` | Plain text record, optionally wire-compressed |

Contact and activity membership uses `MemberOf` (7) asset-to-asset edges, the same
container-membership relation as work slices. Creation writes
contact/activity → company, atomically with the asset through
`C_ApplyTransaction`; the member is the edge source and the company is the target,
matching the slice direction. Reading accepts either direction. Asset types
distinguish contacts from activities, so no additional relation enum is needed. A
contact or activity can belong to multiple companies; an activity can also link to
a contact through the generic edge API. Generic work links (notes, tasks, files and
other assets) stay `RelatedTo` (2). The company history shows its direct activity
links, not transitive contact links. The customer editor creates new records;
linking existing contacts/activities uses the generic edge API in this version.
Search and membership read edges only, never `companyId` metadata. The earlier,
undeployed prototype's `companyId` records are not migrated automatically: they
remain stored but must be linked explicitly to appear under a company.

Existing installations that created contact/activity associations as `RelatedTo`
must be migrated once: for each `RelatedTo` edge whose endpoints are a company and
a contact or activity, delete it and create the equivalent `MemberOf` edge in the
member → company direction. Use one atomic transaction per edge
(`nrc batch apply --atomic`) so no link is lost between the delete and the create.
Edges that connect a company to a note, task or other asset are not membership and
must be left as `RelatedTo`.

Parent type stays `None`: these links must not introduce ownership deletion
cascades. Removing a link preserves the asset. Company archive preserves
contacts, activities and graph links; the view does not offer hard deletion.
Activity author and time come from server asset metadata. The UI creates activities
but does not edit them; generic asset APIs retain their existing semantics.

The register loads one server-search page at a time, including matches through
contacts that the client has never loaded. Selecting a company loads one incident
edge page and resolves its linked assets with exact reads. LOAD MORE controls advance
the register and relationship cursors independently. Relationship pages are ordered
by ascending edge ID; activity ordering and type filters apply to loaded records only.
The UI displays loaded/total counts explicitly. Reconnect refreshes the selected
company and its first relationship page, rather than the whole workspace. Reconciliation
preserves newer live mutations and unrelated shared caches. These are live cursor
traversals, not point-in-time snapshots. The shared task/note link picker still loads
its candidate collections, but only when opened.
Metadata uses the existing 4 KB preview limit; the editor
limits activity text to 8,000 characters. Unknown schema versions are not editable.
Writes are acknowledged by the existing persistence path. Concurrent edits retain
the existing asset last-writer-wins behavior; this is not a revisioned audit ledger.

## On-demand read protocol contract

All integers are big-endian. Pages are live (not snapshots), sorted by the stated ID,
use a strict `after_*` cursor, default a zero limit to 50, clamp limits to 250, and
never exceed 131072 bytes.

`C_ListEdgesPaged` (54) is exactly 34 bytes: opcode u16, conv_id u64, target_type
u16, target_id u64, limit u16, after_edge_id u64, correlation u32. Its
`S_EdgeListPage` (162) header is exactly 39 bytes: opcode u16, conv_id u64,
target_type u16, target_id u64, has_more u8, next_edge_id u64, total_count u32,
count u16, correlation u32, followed by `count` standard Edge entries. It returns
only incident edges from `edges_by_entity`; total_count is the current incident count.

`C_SearchCustomers` (55) is 27 + query bytes: opcode u16, conv_id u64, limit u16,
after_company_id u64, include_archived u8, query byte length u16, UTF-8 query (at
most 256 bytes), correlation u32. Its `S_CustomerSearchPage` (163) header is 29
bytes: opcode u16, conv_id u64, has_more u8, next_company_id u64, total_count u32,
count u16, correlation u32, followed by standard AssetHeader entries (no payload).
Results are deduplicated valid version-1 companies in ascending asset_id order.
Matching is a case-insensitive substring of the decoded company fields (including
title, number, address and assignee), decimal asset ID, or contact fields (including
name, email and phone) of a contact connected by a `MemberOf` asset/asset
edge in either direction. Empty query matches every valid company. Companies with
JSON boolean `archived: true` are excluded unless include_archived is set; malformed,
unknown-version, and non-string-title metadata is excluded. All data operations
require `conv_id = 0` (workspace scope); nonzero room and DM scopes are rejected.

## Verification and disposable preview

```sh
node --test client/*.test.mjs
go -C services/auth/tailscale-proxy test ./...
go -C protocol-go test ./...
./test/run_odin_tests.sh . -define:NRC_SIMULATION=true -define:ODIN_TEST_NAMES=test_customer_assets_create_list_persistence_roundtrip
odin build . -vet -out:/tmp/nrc-customers-server
```

For browser E2E, run `test/customer-workspace-dev.mjs` as a supervised local service
with `NRC_TEST_SERVER=/tmp/nrc-customers-server`, then:

```sh
NRC_CUSTOMERS_TEST_URL=http://127.0.0.1:8091 node client/customers.e2e.mjs
```

The fixture uses the real Odin server with temporary data, port 8080 for WebSockets
and port 8091 for HTTP. It intentionally bypasses Tailscale with a test identity and
enables the view; **never deploy this fixture as the production auth proxy**. Stop
it before tests that require port 8080. Its temporary data is removed on exit.

The fixture also stands in for the file service: `POST /upload` holds the uploaded
bytes in memory and `GET /files/<fileId>` serves them back, so the client's upload
button and attachment downloads work without the tailscale-proxy.

For a demo workspace with notes, tasks, files, attachments, links and messages, start
it with `NRC_FIXTURE_SEED=1` (default workspace `workspace1`, override with
`NRC_FIXTURE_SEED_WORKSPACE`). The fixture then runs `test/seed-demo-workspace.mjs`,
which writes through the Go CLI (`nrc`) — the same protocol paths the client uses.
Run the seed against an already running fixture with:

```sh
node test/seed-demo-workspace.mjs --url http://127.0.0.1:8091
```
