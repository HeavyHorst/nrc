# Kundenportal / NRC Tickets

`services/bots/nrc-tickets` is an independent Go HTTP service. It serves a German
homepage/list, new-request form, ticket conversation and reply form. NRC assets
are the **only authoritative ticket store**; restarting the portal does not lose
tickets. Deploy a ticket-capable NRC server first (Ticket=13, TicketEntry=14).
The staff client remains separate.

In NRC, open **TICKETS** for the workspace register or **CUSTOMERS → TICKETS**
for a company-scoped entry point. The full-width table shares task selection,
focus, sort indicators and persisted column resizing. Its initial order is newest
activity first; ↑/↓ navigates the current filtered/sorted rows, Enter opens the
shared Inspector and Escape closes it. Input fields and pickers keep their own
arrow keys. Reply and new-ticket drafts survive record switches until reload;
pending writes block switching. Linked tickets open in the Inspector without
changing the surrounding view. Save/errors are visible inside the Inspector,
including on narrow screens; M focuses the reply composer.

The internal search field uses the shared `/search` service (250 ms debounce,
up to 100 ticket hits). It searches the original request, requester/title/ID,
customer replies, public replies and **internal notes**. Each ticket appears once;
conversation text and vector chunks contribute to that ticket before ranking.
Status, assignee and company filters apply before ranking/top-N. Table sorting
still uses the selected column. Loading, stale-index and local-fallback states
are explicit; an unavailable service falls back to substring matching across
loaded tickets and conversations. Empty queries use the normal NRC register.
The index is asynchronous; search is ranked evidence, not a complete inventory.
The register still loads tickets/entries for activity and Inspector state.
Deploy the updated Search service before the client/CLI/AI consumers, and include
asset types `13,14` in custom `EMBED_ASSET_TYPES` overrides (now enabled by default).
CLI `nrc ticket search <query>` and Sullivan `search_tickets` use the same service.
This is **staff-only** search, not a customer-portal endpoint; its results and
internal-note evidence must not be exposed to public customers.

Ticket metadata uses the same directly visible
inline editors as tasks and notes, without a separate **EDIT TICKET** disclosure.
The original request appears once, read-only in the conversation;
staff metadata saves do not replace the request body or its attachments.
Company and contact open a shared assignment dialog with searchable custom
selects and stable asset IDs, saving the pair together.
Choosing a company scopes contacts to its `MemberOf` memberships. Choosing a
contact first sets its company; multi-company contacts have one explicit option
per company. Company stays locked until CONTACT is cleared. Existing missing
or archived selections are retained rather than silently removed.
Their saves use conditional versioned patches, preserving attachments and
rejecting competing edits rather than overwriting them. After a conflict,
refresh and reopen the field to use the saved version; the reply draft is retained.
If another staff member changes the requester, public sending remains blocked
until **USE CURRENT RECIPIENT** confirms the new address without losing reply
text or queued uploads. Disconnected saves remain unconfirmed in the editor.
The composer defaults to **INTERNAL NOTE** and resets to it after sending.
**CUSTOMER REPLY** explicitly names its public visibility. **LINK TASK** uses
`RelatedTo`; **ASSIGN SLICE** uses Ticket → Slice `MemberOf`. Tickets appear in
the slice's TICKETS section with title, status and assignee, count towards MEM,
and can be assigned/unassigned from either view. TicketEntry records are not
members; task-status shares and WIP remain task-only. One ticket may belong to
several slices. Legacy `RelatedTo` links stay readable as general work links and
are not silently migrated into membership. **CREATE TASK** creates and links an internal task.
Below ticket metadata, the shared collapsible resource strip separates **TASKS**
(status and assignee), **SLICES** (only `MemberOf` memberships), and **REFERENCES**
(notes, files and other relations, including legacy slice links). Only one group
opens at a time; refreshing its contents preserves disclosure and reply drafts.
Rows use the same direction, kind, relation and remove-link controls as task/note
links. Removing a link never deletes its target; removing a slice membership
unassigns only that slice. Task status and assignee appear beneath the task title.
**LINK REFERENCE** uses the shared note/file picker and relation selector.
The slice counter extends protocol version 9: update server, web client, CLI and
native mobile client together; old slice decoders are incompatible with these
rows, and the mobile app rejects a mismatching handshake. Distribute the updated
mobile app before rolling out the server; previously installed v8 apps cannot connect.
New tickets and reply/internal-note composers accept up to 10 attachments using
the shared NRC uploader (100 MiB/file). Uploads remain in the record's in-memory
draft until acknowledged; failed uploads must be removed before sending. Original
request attachments and each entry's attachments use the existing file ledger.
Task completion never changes ticket status. Drafts are kept during navigation,
but are not persisted across page reloads.

## Priority, follow-up and history

Tickets have LOW, NORMAL, HIGH and URGENT priority. Missing `priority` on older
records means NORMAL; no migration is needed. Staff can set priority when creating
a ticket or through the Inspector, filter it, and sort by its semantic order.
CLI and Sullivan use the same values (`low`, `normal`, `high`, `urgent`), including
the ticket search filter. These are independent of linked task priorities.

FOLLOW-UP is an optional staff scheduling timestamp. The browser edits and displays
it in local time; clear the date to remove it. The DUE filter selects positive
timestamps at or before server time, regardless of ticket status, assignee or
reply debt; other selected filters still apply. Refresh the list to reevaluate
time alone passing. It does not send notifications, create a reminder asset, change
status or clear automatically on a reply. Unscheduled records sort as zero (first
ascending, last descending). With both DUE and search selected, the register uses
server substring search before pagination rather than filtering ranked top-100
results afterward.

Due follow-ups also appear automatically in ATTENTION for tickets assigned to the
operator or unassigned, even when read, answered or closed. FOLLOW-UP DUE is the
primary reason; reply debt and unread counts remain visible on that same row.
Reading and replies do not clear it: reschedule or clear the date. The connected
client refreshes the server's Attention snapshot every 30 seconds and immediately
when the tab becomes visible. Background browser throttling can delay polling;
reconnect rebuilds the snapshot. No desktop notification or reminder asset is created.
The Tickets navigation badge remains an unread count; the Attention count includes
due follow-ups.

Attention polling opts into `omit_total_count: true` on descending-ID ticket
queries. The response marks `total_count_omitted: true`; its zero `total_count`
is unavailable, not an exact count. The client walks `has_more` pages and counts
the complete result. Queries without this opt-in retain exact totals. Other sort
orders and text searches retain the existing scan path.

The fast path merges the operator and unassigned ranges of a worker-owned
assignee/ID B-tree. Per-ticket decoded metadata and conversation summaries are
maintained by the central asset store, including replay and transaction patches.
Customer-reply IDs provide unread counts by binary search against the personal
read watermark. Due state is evaluated against server time, never cached.
The existing `asset_parents` index supplies children for reconstruction and
repairs after deleting/reclassifying an activity maximum; no duplicate parent
index, persistent projection or WAL format is introduced. Such repairs still
cost a scan of the affected ticket's entries. Empty/sparse Attention results
can still visit all own/unassigned ticket summaries, but not all entry histories.
Pages are live rather than a point-in-time snapshot; concurrent edits or a newly
due ticket above the cursor are reconciled on the next refresh.

Preview metadata adds optional `priority` and `follow_up_at`. The latter is an
empty string (or absent) for none, otherwise canonical positive signed-i64 Unix
milliseconds encoded as a string. Both fields remain private in the customer portal.
Deploy the updated server and search service before their clients.

```sh
nrc ticket update 123 --priority urgent --follow-up '2026-10-23T09:00:00+02:00'
nrc ticket list --priority urgent --follow-up-due
nrc ticket update 123 --follow-up ''
nrc ticket search 'login' --priority high
```

HISTORY in the Ticket Inspector opens the existing durable asset-scoped change
register, including related links. Ticket links in History reopen the Ticket
Inspector. This reuses the general history: metadata changes still say Details,
without old/new field values. The ticket conversation remains separate.

## Attention and read state

The Tickets navigation badge counts unread tickets assigned to the signed-in
operator or unassigned. Attention separates **CUSTOMER WAITING / ASSIGNED TO ME**
from **SUPPORT INBOX / UNASSIGNED**. Reading clears unread, not reply debt;
an internal note cannot answer a customer. A public reply clears reply debt.
New customer follow-ups bring the ticket back into Attention even when its saved
workflow status is waiting/resolved/closed. Workflow status is not automatically
rewritten: staff can explicitly reopen it. Metadata edits do not count as
conversation activity; the ticket register orders by original request/entry time.

The five workflow states are OPEN, IN PROGRESS, WAITING ON CUSTOMER, RESOLVED,
and CLOSED (`open`, `in_progress`, `waiting_customer`, `resolved`, `closed` in
CLI/API). WAITING ON CUSTOMER describes the opposite direction from REPLY NEEDED.

Task comments use the same unread model for tasks assigned to the operator,
including completed tasks: own comments are excluded, Attention opens the first
unread comment, and TASKS shows the number of affected tasks. Comments must be
visible in a focused tab to be read; hidden/collapsed inspectors do not clear them.
On reconnect, both sources are rebuilt from complete server snapshots without
historical desktop notifications. Read marks are browser-local, keyed by workspace
and verified nickname, survive reloads, and propagate between tabs through storage
events. They are not server assets, device-synchronized, or exposed by CLI/Sullivan.
If browser storage is unavailable they last only for the current page session.

## CLI and Sullivan

### Shared customer ticket visibility

In **CUSTOMERS → CONTACTS → SHARED TICKET VISIBILITY**, create named groups
such as Technik or Projektteam and select contacts of that company. Direct
fellow-members can mutually **read and reply** to all existing and future tickets,
including original-request and public-reply attachments and image previews.
There is no per-ticket grant, automatic company-wide access, or transitive
expansion across overlapping groups. Internal notes and their files stay private.
The portal labels team requests separately and identifies the original submitter;
replies use the actual signed-in person's name without changing that submitter.

Groups are version-1 company metadata, `ticket_groups: [{id, name, contact_ids}]`.
IDs are stable across renames; contact IDs are decimal strings. Members must be
current `CustomerContact` assets linked to the company by `MemberOf`. Every
portal request rechecks these records and edges, including direct URLs, replies
and downloads. Removing membership/contact/company revokes the corresponding
grant on subsequent requests; already downloaded data cannot be recalled.
Own tickets and direct grants from other groups remain accessible. Malformed or
unavailable sharing metadata fails closed, without taking away own-ticket access.
Company/group edits use conditional preview patches, preserve body/attachments
and other metadata, and reject stale versions instead of overwriting them.

Portal accounts must explicitly bind `contact_id` to their NRC contact alongside
`company_id`; no email/domain inference is used. Existing accounts without this
optional mapping remain own-only. New tickets carry the contact ID. Older tickets
without it resolve through an explicitly mapped requester account of the same
company, so existing tickets participate without rewriting the original request.
Configure accounts on the deployment and restart the portal after changing them;
selecting a contact in NRC does not provision credentials.

```sh
nrc customer ticket-group list 123
nrc customer ticket-group create 123 --name Technik --contacts 42,43
nrc customer ticket-group update 123 <group-id> --name Projektteam --contacts 42,44
nrc customer ticket-group update 123 <group-id> --contacts ''
nrc customer ticket-group delete 123 <group-id>
```

Sullivan provides `read_ticket_groups` and `propose_ticket_group` for the same
create/update/delete operations. Grants and revocations are explicitly disclosed
and staged for human approval only; applying rechecks the company version and
resulting members. Only one unapplied group mutation per company can be staged
in a plan: apply it and re-read the company before proposing the next, so an
approved batch cannot conflict with its own version checks. No generic customer
mutation permission is introduced.

### Ticket records

The staff CLI uses the same workspace records, attachments and company/contact
membership rules. Original request bodies remain read-only; updates are
conditional metadata-only patches. `reply` defaults to an internal note:

```sh
nrc ticket list --status open
nrc ticket get 123
nrc ticket create --title "Login issue" --requester customer@example.org --body-file request.txt --attach screenshot.png
nrc ticket update 123 --status in_progress --assignee rene
nrc ticket reply 123 --body "Investigating internally"
nrc ticket reply 123 --public --body-file response.txt --attach report.pdf
nrc ticket attachments 123
nrc ticket download-attachment 123 0 ./download.pdf
nrc ticket links 123
nrc ticket link 123 --task 456
nrc ticket link 123 --slice 789
nrc ticket create-task 123 --title "Investigate login"
```

`internal-note`, `unlink` and `delete` are also available; `--entry <id>` selects
an entry's attachments instead of those on the original request. File upload and
download use the existing authenticated staff file service. No mutation is
automatically retried after a lost acknowledgement.

Sullivan's `read_tickets` lists/filter-pages tickets or reads a ticket's complete
conversation, including internal notes and attachment metadata. In plan mode,
`propose_ticket` stages `create`, `update_metadata`, `entry` or `delete` for human
approval. Entry proposals default to `internal_note`; a `public_reply` requires
an explicit requester and the exact version returned by `read_tickets`. The
approval describes customer visibility, recipient and attachment filenames.
The server checks that parent version atomically when creating the reply and
its attachments; a concurrent ticket change rejects the write. Deploy the
updated server before the AI service; older servers reject guarded requests.

AI attachment sources must already belong to a workspace task/asset or File
asset; arbitrary URLs and free-floating blob IDs are not accepted. Generated
UTF-8 text files (at most 1 MiB each, ten attachments total) upload through the
private file service only on approved apply. Existing task/edge proposal tools
create/link tasks with `RelatedTo`, and assign Ticket Asset → Slice Asset with
`MemberOf`, without synchronizing their statuses. Neither
reads nor proposals write ticket records or upload generated files.

If an approved write may have committed but its ACK was lost, that action becomes
`outcome_unknown` and cannot be reapplied. Inspect the current conversation before
making a new proposal; this is not an idempotency-key implementation. A definite
server rejection remains retryable. The approval UI currently reports this as an
apply error; the server enforces the replay block even if it is selected again.

## Private account provisioning

There is no registration or default account. Create a private JSON input file
with an editor/password manager (do not put passwords in shell commands, process
arguments, logs, Git, or environment variables). Use a protected directory and
`umask 077`. Input is an array with the following fields:

* `login`: the HTTP Basic login, without a colon
* `password`: a unique random password, 14–72 bytes
* `requester`: canonical lower-case account identity, normally email
* `name`: customer-facing display name
* `company_id`: canonical positive decimal NRC company asset ID, or empty string
* `contact_id` (optional): canonical positive decimal NRC contact ID; requires
  `company_id` and must be unique across accounts. Enables explicit sharing groups.

Provision the full account set in one operation, from the sidecar directory:

```sh
go build -o /tmp/nrc-tickets .
/tmp/nrc-tickets -provision /secure/ticket-accounts.json < /secure/accounts-input.json
```

The utility creates a **new** file exclusively, mode 0600, containing salted
bcrypt hashes (cost 12). Remove the plaintext input securely according to your
storage policy. Never publish the file. Provision to a new path and atomically
replace the old file to rotate accounts, then restart the service. The loader
rejects empty/invalid configs, duplicate logins/identities, invalid hashes and
group/world-readable files. Accounts are explicitly provisioned by operators;
requester, company and contact cannot be chosen by the browser. Accounts with the
same company still **cannot** access one another's tickets unless their contacts
are explicitly in a common ticket-sharing group.

## Deployment

Required settings (no credential defaults):

| Variable | Meaning |
| --- | --- |
| `NRC_SERVER` | Private NRC WebSocket base URL; `wss` across untrusted networks |
| `NRC_WORKSPACE` | Dedicated ticket workspace |
| `NRC_BOT_SECRET` | Same infrastructure bot secret accepted by NRC; secret environment/file injection, never CLI |
| `FILES_URL` | Private bot file-service origin, e.g. `http://tailscale-proxy:8094`; never the public customer hostname |
| `TICKETS_ACCOUNTS_FILE` | Private account hash file path |
| `TICKETS_ORIGIN` | Exact public HTTPS origin, e.g. `https://support.example.org`, no slash/path |
| `TICKETS_ADDR` | Listen address; default `:8096` |

Serve on a dedicated hostname through a TLS reverse proxy. **Never expose the
plain HTTP listener to the internet**: HTTP Basic sends credentials on every
request. Bind the listener to loopback/private network. Terminate TLS at the
proxy, set HSTS, enforce body/time/concurrency limits and authentication rate
limits there, and never log Authorization headers or request bodies. Do not enable
CORS, response caching or generic public file routes. Allow multipart requests up
to 100 MiB + 128 KiB and sufficient upload time at the reverse proxy. The origin setting is trusted
configuration, not derived from Host/Forwarded headers. POST requires an exact
Origin match and rejects cross-site fetch metadata; absent/null Origin fails.
Browsers without Origin on form POST are unsupported. GET never mutates records.
Basic authentication has browser-managed credentials rather than a logout
session; use a separate browser profile for shared devices.

Optional overlay, from repository root (existing NRC `.env` required):

```sh
docker compose --env-file .env -f docker/docker-compose.yml -f docker/compose.tickets.yml up -d --build tickets
```

Set `NRC_TICKETS_WORKSPACE`, `TICKETS_ORIGIN`, and an **absolute host path**
`TICKETS_ACCOUNTS_FILE` in the protected `.env`. The overlay reuses NRC's private
network and bot secret, publishes only loopback 8096 and mounts the private
account file plus operator branding. It does not mount attachments, a DB, or staff files. A host TLS
proxy can forward to loopback 8096. Container root is retained to read the 0600
bind-mounted file; capabilities are dropped and the filesystem is read-only.
The `/tmp` tmpfs holds bounded multipart staging (112 MiB); limit concurrent
uploads at the reverse proxy. Rebuild the proxy too when upgrading from the
download-only bot listener: `docker compose ... build tailscale-proxy`, then
recreate it using your normal deployment procedure. Private port 8094 must never
be published. The customer portal relays files using the infrastructure bot
secret; workspace grants do not replace its stricter per-ticket authorization.
For stricter installations use a matching nonroot UID and private file ownership.

## Corporate design / branding

Like Publish, the portal accepts deployment-owned CSS, a logo, brand text and
footer links. No staff-client changes or recompilation are needed. Set these
environment variables and restart the portal after changing files/configuration:

| Variable | Meaning |
| --- | --- |
| `TICKETS_BRAND` | Page title and header name; default `Ihr Kundenportal` |
| `TICKETS_LOGO_FILE` | Optional PNG/JPEG/WebP, at most 2 MiB; SVG/HTML rejected |
| `TICKETS_THEME_FILE` | Optional trusted CSS file, at most 256 KiB; appended after default stylesheet |
| `TICKETS_FOOTER_TEXT` | Escaped plain footer text, e.g. copyright/company name |
| `TICKETS_IMPRINT_URL` | Impressum link |
| `TICKETS_PRIVACY_URL` | Datenschutz link |
| `TICKETS_TERMS_URL` | Nutzungsbedingungen link |
| `TICKETS_CONTACT_URL` | Kontakt link |

Footer links accept HTTP(S) or root-relative URLs, not protocol-relative or
script URLs. Empty footer settings omit the footer entirely. Legal content is
hosted separately; the portal does not create legal pages. Theme CSS and logos
are loaded at startup and served at authenticated `/style.css` and
`/branding/logo`, not by exposing an operator directory. The themed file selector
uses an authenticated same-origin script to display selected filenames; form
uploads still work without JavaScript. CSP disallows inline/external scripts,
external fonts/images/styles, frames and inline styles. Theme files must be
trusted operator configuration, not customer uploads.

With Compose, put files in `ticket-branding/` at repository root (or set
`TICKETS_BRANDING_DIR` to a private deployment directory), then use
`TICKETS_THEME_FILE=/branding/theme.css` and
`TICKETS_LOGO_FILE=/branding/logo.png`. Do not commit customer branding or secrets.
Example `theme.css`:

```css
:root {
  --accent: #744b88;
  --accent-hover: #573766;
  --on-accent: #ffffff;
  --header-background: #30223c;
  --header-text: #ffffff;
  --background: #f6f3f8;
  --surface: #ffffff;
  --text: #282331;
  --muted: #62596c;
  --border: #ded5e5;
  --input-border: #a598b0;
  --radius: 8px;
  --font-family: system-ui, sans-serif;
}
```

Check contrast and narrow layouts when adapting these tokens; complete CSS
overrides are supported in the same stylesheet if needed.

## Storage and customer API

Ticket: workspace conv 0, no parent. Preview JSON has `version:1`, `title`,
`company_id`, `contact_id` (empty), `requester`, `requester_name`, `status:open`,
`assignee` (empty); plain payload holds the original request. Staff can change
status through NRC. Replies: TicketEntry, conv 0, parent_type Asset=2 and parent_id
ticket ID; preview `version:1,kind:customer_reply,author:<configured name>`;
plain payload is the reply. Public staff replies use `public_reply`; staff-only
entries use `internal_note`.

`GET /api/tickets` returns a `tickets` array when nonempty. `GET
/api/tickets/<id>` returns a `ticket` object with public `id,title,status,body`
and `entries` (`author,body`). Both may contain `attachments` with public
`filename,size,url`. Status is a German display label. `POST
/api/tickets` accepts URL-encoded `title,body`; `POST
/api/tickets/<id>/reply` accepts URL-encoded `body`. Successful API writes return
201 with only the ticket `id`; forms redirect after acknowledged creation. Both
API and pages require Basic auth. POST API calls also require the configured
Origin. Unknown metadata fields are rejected. Bodies are limited to 32000 bytes,
titles to 200 bytes. Unknown/cross-requester IDs return 404.

Both writes also accept `multipart/form-data`: the same text fields plus file
parts named `files` (multiple), maximum 10 files and 100 MiB total per message.
Raw bytes upload to NRC's private blob service first; only server-returned
attachment metadata is written to the Ticket/TicketEntry. Caller-supplied file
IDs, attachment URLs, requester metadata and extra fields are rejected. Successful
blob upload alone does not mean the ticket was saved; success requires NRC ACK.
Aborted/failed writes can leave unreferenced blobs, handled by normal attachment
GC, not by unsafe immediate deletes (content-addressed blobs may be shared).

All customer output is built from explicit public DTOs. Raw assets, requester
metadata, company/contact IDs, assignee and graph work links never enter API
JSON/templates. Unknown entry kinds and internal notes, including their attachment
names and download links, are excluded;
guessing their IDs does not grant access. Text uses Go template escaping, not
Markdown/raw HTML. Download URLs are scoped to both ticket and attached asset:
`/tickets/<ticket>/attachments/<ticket-or-entry>/<fileId>`. Every request rechecks
the ticket's requester, the entry's public kind/parent and the actual attachment
list before fetching bytes. A known blob ID or same-company identity never grants
access. Downloads always use `application/octet-stream` and attachment disposition,
including HTML/SVG; active uploads are not rendered as portal pages. PNG, JPEG,
GIF and WebP attachments show an image preview with a full-size link. The same
scoped URL with `?preview=1` rechecks all access rules and serves inline bytes
only after checking the file signature against these raster MIME types, never
trusting the filename, stored MIME or upstream Content-Type. No server-side image
decoding or thumbnail cache is involved; HTML/SVG remain download-only. There is no
generic NRC file proxy or shared attachment directory exposed to customers.

Every create waits for a validated correlated `S_AssetCreated` ACK. No automatic
mutation retries occur. Network loss after send can mean the write persisted but
the ACK was lost: the portal says to check the overview before submitting again.
Portal form submissions have no idempotency keys. Password reset, ticket edits,
customer status changes and offline mode are not available. NRC unavailability fails requests.
The optional email channel below has its own durable deduplication and delivery journal.
Current reads scan paged ticket/entry metadata on demand (up to 1000 pages/type),
not a customer DB; very large workspaces need a future server-side scoped query.
NRC staff/bots are trusted to label public replies correctly and not reassign
requester identities during a concurrent read. Do not reuse requester identities
for different people. Back up NRC and account config using their normal policies.

## Optional email channel

Set `TICKETS_MAIL_CONFIG_FILE` to a private (0600/0400) JSON file. When unset,
the existing portal remains unchanged and sends no mail. Configuration contains
`journal` (persistent bbolt file path), `address` (private listener, default
`127.0.0.1:8097`), `gateway_secret` (at least 32 random bytes),
optional `imap`, and `smtp` with
`address` (host:port), `username`, `password` or `oauth2`, `from` (canonical
lower-case mailbox) and `implicit_tls`.
SMTP always verifies TLS: STARTTLS is mandatory unless implicit TLS is selected.
Do not put credentials in Git, command arguments, logs or browser configuration.

### Direct IMAP reception

The tickets module can read an existing support mailbox directly; no additional
mail gateway service is required. Configure `imap.address`, `username`, and
either `password` or app-only `oauth2` credentials. Implicit verified TLS is the
default (normally port 993); `start_tls:true` requires STARTTLS instead. `mailbox`
defaults to `INBOX`. It polls immediately at startup, then 30 seconds after each
pass. Polls have a two-minute deadline and process at most 200 messages per pass.

The private journal binds the server, login and folder and durably checkpoints
UIDVALIDITY/UID only after reception or quarantine is saved. Unread flags are
not used: the reader uses EXAMINE and BODY.PEEK and neither marks mail read nor
deletes it. First connection skips existing mail by default. Set
`import_existing:true` explicitly to import the current folder history. A later
UIDVALIDITY change **pauses reception** by default; inspect the mailbox and enable
`import_existing` deliberately to rescan the new namespace. Known identical
messages deduplicate, but historical mail skipped at activation may now import.
Use a separate journal when changing mailbox identity; do not delete a production
journal to reset the cursor. Oversized messages are quarantined by UID without
downloading the body; the original stays in the mailbox. Other rejected messages
retain their raw bytes in the journal for inspection.

**IMAP login authenticates NRC, not the message sender.** Normal new mail is
accepted openly, subject to MIME/content limits and automatic-message filtering;
the sender/requester is always the top-level `From`. There is no verified-marker
policy or privileged staff forwarding. Keep spam, sender-authentication and
malware protection upstream at the mail provider/gateway; NRC has no scanner.

The provider must deliver `smtp.from` plus addresses (for example,
`helpdesk+<random-ticket-token>@firma.example`) to the same existing support
mailbox. The configured mailbox local part is limited to 31 bytes to leave room
for the plus separator and 32-character token. No additional mailboxes are needed.
Preserve the original `To`/`Cc`
headers unchanged through delivery and any gateway: NRC reads the reply token
from those headers, not the SMTP envelope. BCC-only ticket replies are not
supported. Validate plus delivery and header preservation before activation.

Microsoft 365 example (placeholders only; store the real file privately):

```json
{
  "journal": "/mail-data/mail.db",
  "address": "127.0.0.1:8097",
  "gateway_secret": "REPLACE_WITH_RANDOM_PRIVATE_ADMIN_TOKEN",
  "imap": {
    "address": "outlook.office365.com:993",
    "username": "helpdesk@firma.example",
    "mailbox": "INBOX",
    "import_existing": false,
    "oauth2": {
      "token_url": "https://login.microsoftonline.com/TENANT_ID/oauth2/v2.0/token",
      "client_id": "APPLICATION_ID",
      "client_secret": "APPLICATION_SECRET",
      "scopes": ["https://outlook.office365.com/.default"]
    }
  },
  "smtp": {
    "address": "smtp.office365.com:587",
    "username": "helpdesk@firma.example",
    "from": "helpdesk@firma.example",
    "oauth2": {
      "token_url": "https://login.microsoftonline.com/TENANT_ID/oauth2/v2.0/token",
      "client_id": "APPLICATION_ID",
      "client_secret": "APPLICATION_SECRET",
      "scopes": ["https://outlook.office365.com/.default"]
    }
  }
}
```

Follow Microsoft's [app-only IMAP/SMTP OAuth setup](https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth):
grant the Office 365 Exchange Online **application** permissions
`IMAP.AccessAsApp` and `SMTP.SendAsApp` with administrator consent; register the
service principal in Exchange using the Enterprise Application object ID (not
the App Registration object ID), and grant access/SendAs for the support mailbox.
Enable mailbox IMAP and authenticated SMTP where tenant policy permits them.
OAuth tokens are cached and renewed before expiry; token errors fail closed,
without password fallback. Authentication and plus-delivery policies need validation in
your tenant; the local TLS fixtures do not establish a working tenant setup.

For another provider, replace each `oauth2` object with `"password":"..."` and
use its IMAP/SMTP hosts. Never configure both authentication methods together.
SMTP relays that authorize by network rather than credentials can omit both
username and password; transport encryption remains mandatory.

### Optional gateway and private administration

The listener is **not the public customer API**. Bind privately; use TLS between
untrusted networks. `gateway_secret` remains required for private CLI
administration even when IMAP is used. Alternatively, an operator-owned mail
gateway posts the original RFC822
bytes to `POST /inbound`, with `Authorization: Bearer <gateway_secret>`.
No verified-sender header is required or used; the token authenticates the
gateway, not the top-level From identity. Sender checks and spam/malware filtering
belong upstream; Authentication-Results does not grant ticket access in NRC.
No direct SMTP receiver or provider-specific webhook signature adapter is
included; use direct IMAP or connect your own gateway to the support mailbox.
HTTP 202 means durably queued/quarantined/ignored, not that NRC or SMTP succeeded;
the gateway must treat 4xx as rejection and retry transport/5xx failures safely.
Raw message limit is 32 MiB including MIME overhead; request text is at most
32,000 UTF-8 bytes and subject 200 bytes. Oversized input is rejected, not truncated.

Normal new mail creates a Ticket and reuses a unique matching contact.
Unknown senders create a CustomerContact with `source:email` and
`review_status:pending`, without a company edge or login. **CUSTOMERS → NEW
CONTACTS** discovers these even without a company. Use the existing company
picker to assign membership, and explicitly mark the contact reviewed. The queue
is paged independently; CHECK MORE CONTACTS searches subsequent contact pages.
No domain or CC creates company membership or ticket-sharing rights. Existing
explicit portal account/company/contact bindings may be reused, but new contact
assignment does not retrospectively change ticket company fields. Staff can
assign those through the normal ticket editor.

Forwarding never impersonates the original customer: attached `message/rfc822`
messages remain opaque files, and inline forwarded headers/content remain text.
Covering text is the top-level sender's request, not an automatic internal note.
There are no internal-domain privileges or manual approval/requester overrides.
No customer access rights, portal account, invitation or password are automatically
created; a pending contact is not a login or a sharing grant.

Activation records a durable server-time cutoff and a baseline of observed
entries: historical public replies are **not** emailed, even when concurrent
edits move them past a pagination cursor. Entries created during the initial
baseline scan can also be conservatively excluded. Thereafter the worker discovers new public
TicketEntry records, including browser, CLI and approved Sullivan writes, every
five seconds. New clients snapshot the confirmed requester in `recipient` and
guard the parent version. A missing/changed recipient fails closed; upgrade all
writers before activation. Internal/customer notes are never outbound mail.
An initial email ticket receives an acknowledgement. Replies include attachments
and stable Message-ID/References, with a durable random ticket-specific plus
address as `Reply-To`. An incoming message joins an existing ticket only when
`To`/`Cc` contains that address **and** its top-level From currently has requester
or explicit portal sharing access. Access is rechecked after attachment upload,
and the reply write guards the current ticket version. Invalid, unknown or
conflicting reply tokens and unauthorized senders are quarantined. Without a
reply token, normal mail is a new request: References, In-Reply-To and subject
numbers alone never associate or authorize a reply. Automatic replies, delivery
reports and mail from the support mailbox itself are ignored instead of
generating new conversations.
After attachment preparation, an atomic conditional transaction checks both
ticket and public-entry versions and claims the prepared mail for SMTP. The
ticket's unchanged preview is patched as a version guard, advancing its updated
timestamp. This claim is the authorization cutoff: subsequent edits cannot
retract mail already authorized for transport. Pre-mutation transient inbound
read/upload failures stay queued; partially applied or uncertain writes do not
automatically restart.

`mail_delivery` on the original acknowledgement/public reply is queued, sent,
failed or unknown. **sent means accepted by the SMTP relay, not delivered**.
Definite failures need an explicit retry; lost SMTP/NRC acknowledgements are
unknown and never replayed automatically. Restarted inflight work is likewise
unknown. Inspect journal/NRC/relay evidence before resolving such cases manually;
there is deliberately no force-retry command for uncertain operations. After a
lost metadata patch the journal remains authoritative and repairs the status
without resending. Confirmed repairs are not repeatedly read from NRC; outstanding
repairs rotate after queued work, at most one per pass. Keep the private journal
on a persistent volume and back it up: it also holds the private reply tokens;
losing it breaks existing reply addresses. Treat those addresses like private links,
not portal credentials. Keep their tokens out of public logs. Back up the journal
and apply a retention policy appropriate for personal data: it retains original
emails including quarantined messages. This version has no automatic journal
purge, virus scanner, CC subscriptions or delivery-provider bounce reconciliation.

Private administration through the CLI uses `NRC_TICKET_MAIL_URL` (HTTPS, or
loopback HTTP) and `NRC_TICKET_MAIL_SECRET_FILE` (private file containing only
the gateway token). Never give this credential to customers or Sullivan.

```sh
nrc ticket mail list
nrc ticket mail raw <job-id> > /secure/review.eml
nrc ticket mail retry <failed-outbound-job-id>
nrc customer contact list --review-status pending --all
nrc customer contact update <contact-id> --review-status reviewed
```

Optional Docker overlay `docker/compose.ticket-mail.yml` mounts the private
configuration and durable journal on the existing tickets service. It requires
the tickets overlay too; keep the optional gateway/private administration port private.

## Verification and rendering workflow

From `services/bots/nrc-tickets`:

```sh
go test -race ./...
go vet ./...
node browser.e2e.mjs
```

The browser test launches and cleans up a disposable Go test fixture, exercises
multipart creates/replies with and without files, compares downloaded bytes and
checks default/custom branding at desktop and narrow widths. Set
`TICKETS_SCREENSHOTS` to an absolute output directory for screenshots. It uses
fake authoritative assets plus an HTTP blob fixture; the opt-in integration test
below separately checks the real NRC wire/attachment persistence contract.

Tests cover auth, empty configuration, same-company cross-requester guesses,
internal-note/assignee/file confidentiality, multipart upload/download roundtrips,
ticket-scoped attachment authorization, metadata forgery, CSRF, escaped
templates, persisted writes through a fake authoritative source, uncertain write
handling, branding configuration and real WebSocket protocol ACK validation. An optional real-server test
creates persistent records in an **isolated test workspace** (set credentials via
your private environment, never inline secret command arguments):

```sh
# TICKETS_INTEGRATION_SERVER, TICKETS_INTEGRATION_WORKSPACE and NRC_BOT_SECRET configured privately
go test -run TestNRCIntegration -v
```

The staff browser regression uses the existing disposable real-server fixture:

```sh
odin build . -out:/tmp/nrc-ticket-server
# Run as a supervised service in an orb; this fixture uses only temporary data.
NRC_TEST_SERVER=/tmp/nrc-ticket-server node test/customer-workspace-dev.mjs
# In another shell, using that fixture's configured HTTP port:
NRC_TICKETS_TEST_URL=http://127.0.0.1:8091 node client/tickets.e2e.mjs
NRC_TICKETS_TEST_URL=http://127.0.0.1:8091 node client/record-activity.e2e.mjs
# From services/bots/nrc-tickets, against this disposable fixture only:
NRC_MAIL_TEST_URL=http://127.0.0.1:8091 go test -run TestMailNRCIntegration -v -count=1
```

It exercises acknowledged ticket/entry writes, private/public composition,
competing-edit rejection, task linkage without status synchronization, page
reload and company-context navigation. The fixture bypasses staff identity;
never deploy it as an actual NRC endpoint.

The mail integration checks direct sender identity, binary attachment persistence,
outgoing public replies and token-addressed followups without message references.
Local TLS IMAP/SMTP and OAuth fixtures separately cover wire
authentication, reordered FETCH attributes, interrupted/oversized downloads,
UID checkpoint/replay behavior and token renewal; no real tenant is contacted.

The activity regression selects two fake, server-verified users through the
fixture-only `x-nrc-test-user` header. It covers ticket/task badges, own-comment
exclusion, long first-unread navigation, read acknowledgement after reconnect,
internal/public reply debt, reload persistence and fresh follow-up notifications.

For browser checks without NRC, the opt-in test-only fixture has own/other-customer
tickets plus public replies and a hidden internal note. Production has no fixture
flag. In an orb launch it as a supervised service from the repository root:

```sh
amp orb service start tickets-fixture --command 'cd services/bots/nrc-tickets && TICKETS_TEST_ADDR=0.0.0.0:18096 go test -run TestBrowserFixture -v -timeout 0' --portal
```

Set `TICKETS_TEST_ORIGIN` to the exact returned HTTPS portal origin and restart
the fixture service with that variable so POST works through the portal. Use the
**test-only** login `anna` / `fixture-password-only` in browser HTTP credentials.
Visit `/`, `/new`, `/tickets/1`; create a request, send a reply and verify the
conversation updates. `/tickets/2` and `/tickets/11` must be 404. The fixture is
in-memory and resets on restart; never deploy it as the real portal. Stop it with
`amp orb service stop tickets-fixture` when finished.
