# NRC newsletter backend

Standalone Go service; build context is repository root. No second CRM database:
the bot reads workspace-wide (`conv_id=0`) customer-contact assets with correlated
50-record cursor pages, version-1 preview metadata (`title`, `email`, `archived`).
Archived contacts are excluded. Full contact records are never persisted; the
single bbolt file stores address-bound consent, suppression, tested template
snapshots and durable campaign recipient jobs. Back up `/data/newsletter.db`
while stopped (or with a bbolt-consistent backup); retain its signing key forever
so old unsubscribe links continue working. Run one replica per data directory.

## Configuration

Use the optional overlay from the repository root after filling `.env`:

```sh
docker compose --env-file .env -f docker/docker-compose.yml -f docker/compose.newsletter.yml up -d --build
```

Set `NRC_NEWSLETTER_WORKSPACE` and `NRC_NEWSLETTER_USERS` (explicit comma-separated
full Tailscale logins authorized to administer/send newsletters). The overlay
sets the private backend URL and fixed service workspace. The proxy enforces
both this sending allowlist and workspace membership, signs backend assertions,
and exposes `/newsletter/api/...`. The browser supplies `X-NRC-Workspace` and
only shows NEWSLETTER in the matching workspace. No nginx route is needed.
This does not broaden access to customer assets themselves.

The Go CLI exposes the same admin workflow as `nrc newsletter`, including consent
import preview/confirmation, campaigns, audience review, test/send and individual
subscriber actions. Service roles are editable with `nrc contact ... --service-for`.
See the [CLI examples and input formats](../../../cli/README.md#newsletter-and-service-information).
CLI requests use the configured proxy/workspace and the same sending permission;
never give a CLI client the private backend assertion key.

Terminate public HTTPS at a dedicated origin forwarding to **127.0.0.1:8097**;
never expose private 8096. Configure `NEWSLETTER_PUBLIC_URL` to that HTTPS
origin and test confirmation, optout and provider callbacks before real use.
The overlay is additive and can be combined with the publishing overlay;
apply `compose.newsletter.yml` last so the publishing overlay's environment
replacement does not remove the newsletter gateway configuration.
No deployment or provider account provisioning happens automatically.

Required infrastructure: `NRC_SERVER` (WebSocket base URL, no workspace suffix),
`NRC_BOT_SECRET`, `NRC_WORKSPACE` (fixed workspace), `NRC_JWT_SECRET` (not the
development default). `NRC_JWT_ISSUER` defaults to `nrc-tailscale-proxy`.

Mail configuration: `MAILJET_API_KEY`, `MAILJET_SECRET_KEY`,
`NEWSLETTER_FROM_EMAIL`, `NEWSLETTER_FROM_NAME`, `NEWSLETTER_REPLY_TO`,
`NEWSLETTER_TEMPLATE_IDS` (comma-separated positive numeric explicit allowlist),
`NEWSLETTER_PUBLIC_URL` (external HTTPS base URL, no query/fragment).
Missing mail configuration reports `configured:false` and disables sending.
Provision/verify the sender, domain SPF/DKIM, transactional templates and account
permissions in Mailjet before production; this implementation has NOT verified
a real account and development/tests send NO external mail.

`NEWSLETTER_DATA_DIR` defaults `/data`; preserve this private volume with mode
0700. `NEWSLETTER_ADMIN_ADDR` defaults `:8096`; never publish this listener to
the Internet. The trusted proxy must strip incoming `X-NRC-Newsletter-Auth`
and generate a short-lived HS256 JWT with `typ:JWT`, `sub`, fixed `workspace`,
configured `iss`, string `aud:nrc-newsletter`, future `exp`, optional `nbf`.
All private routes require that assertion, not ordinary NRC client JWTs.

`NEWSLETTER_PUBLIC_ADDR` defaults `:8097`. Expose only this listener through
HTTPS at the public base URL; it has only `/confirm`, `/unsubscribe`, `/events`.
Do not log token query strings at the reverse proxy. Use rate limits at the
edge, especially for public token POSTs and private test mail.

Set independent random `NEWSLETTER_EVENT_SECRET`; register Mailjet event
callbacks for `bounce`, `spam`, `unsub` at `PUBLIC_URL/events`, using HTTPS Basic
auth (any username, secret as password), or a relay injecting
`Authorization: Bearer <secret>`. Do not reuse JWT/API credentials. The handler
accepts a single event or array, at most 256 KiB/1000 events. Only known
attempted recipients are affected; hard bounces/spam permanently block an
address, unsub events opt out. Unknown addresses and soft bounces are ignored.
Secret unset disables webhooks. Provisioning is an operator step, not an API call
made by this service. Do not put callback credentials in application logs.

## API and workflow

All JSON responses are `Cache-Control: no-store`; failures are `{error:string}`.
Routes follow the agreed frontend contract:

* `GET /api/state`: live subscribers, deduplicated eligible count, approved
  template metadata, campaigns and sender configuration. `pending` is counted
  under audience `not_subscribed`; subscribers retain their explicit status.
  Each subscriber's `companies` lists nonarchived linked companies as
  `{customer_id,name}`, from live `MemberOf` edges in either orientation. This
  includes ordinary contacts, not just service nominees; it does not grant
  service sending eligibility. The browser searches these names and opens the
  contact in the shared inspector when its name is clicked.
  Provider/register failures return 502/503 rather than a false empty register.
* `POST /api/campaigns` creates revision 1; `PUT /api/campaigns/{id}` requires
  current `revision`. Both take `title,template_id,subject,variables` (object).
  Unknown keys, invalid subjects, nonallowlisted templates and missing variables
  objects are rejected. Updates invalidate testing.
* `POST .../preview {revision,contact_id?}` returns `{html,text,exact:false,notice}`:
  the raw approved template content, or its tested snapshot. The browser shows
  it in a no-script/no-network sandbox. Placeholders remain visible, not locally
  interpreted. No verified exact-render read-only Mailjet endpoint is assumed;
  the required test mail is the final rendering check. Preview never sends mail.
* `POST .../test {revision,email}` sends an explicitly requested test; only
  confirmed Mailjet success marks `tested_revision`. Provider acceptance is not
  an inbox-delivery guarantee. Test addresses need not subscribe, but permanent
  suppression and unsubscribe also block tests (422); use another test address.
  Every mail, including tests and DOI, has the
  unconditional local unsubscribe/preferences link in HTML and text.
* `POST .../send {revision,confirmation:subject}` requires a tested revision,
  exact subject confirmation, and persists deduplicated eligible recipients
  and queued job before returning 202. No implicit invitation of the register.
* `POST /api/subscribers/{contactID}/invite {source}` is ONLY for an individual
  who requested subscription: source must record request evidence/origin.
  Confirmation token is random, stored only as SHA-256, expires in 48h;
  one-hour per-address cooldown and 20 invitations/hour aggregate limit.
  Provider uncertainty keeps pending consent and cooldown, never auto-resends.
* `POST /api/subscribers/{contactID}/unsubscribe {}` opts out the current address.
  There is intentionally no manual subscribe endpoint.
* Public token GETs show an explicit form and never change consent. POSTs apply
  preferences. Unsubscribe tokens are HMAC-SHA256 purpose-specific, bound to
  address and nonexpiring. Old confirmation tokens can only consent their old
  address even after CRM changes; no consent transfers to the replacement email.

### Template sending detail / deliberate deviation

Approved template names/content are fetched via `/v3/REST/template/{id}` and
`.../detailcontent`. `variables` lists discovered `var:` root identifiers, not a
complete Mailjet language schema (nested variables/control flow remain provider
validated). On successful test, the actual stored template HTML/text are pinned
to the tested revision. Subsequent provider edits cannot silently alter a send.
Send API v3.1 receives that content as `HTMLPart`/`TextPart`, `Variables`,
`TemplateLanguage:true`, `TemplateErrorDeliver:false`, sender and reply-to.
It does **not** receive `TemplateID`: Mailjet documents template content and
inline parts as alternative modes, preventing a reliable appended safety footer
when using TemplateID directly.
This preserves existing Mailjet templates and provider rendering without letting
campaign variables or a forgotten template variable remove the local safety link.
Only approve trusted templates, and visually verify the appended footer during
the required test. Templates should not depend on Mailjet contact-list `data:`
properties: NRC remains the contact authority. Campaign JSON mutation responses
can additionally include `template_html`/`template_text` after successful test;
`GET /api/state` omits this internal pinned content.

### Delivery and recovery semantics

One durable worker attempts at most one recipient per second, rereading the live
register and current address consent immediately before each send. Email change,
archive, deleted contact or optout skips that snapshot recipient. Register read
failure pauses pending work. Consent updates and a provider attempt are serialized;
an already-inflight mail cannot be recalled. Queued/sending/finished campaigns
cannot be edited or resent. Recipients: pending, inflight, sent, skipped, failed,
unknown. Campaigns: draft, queued, sending, sent, completed_with_errors.

Transport errors, malformed success responses, and 5xx are **unknown**, never
automatically retried. Crash recovery converts inflight to unknown and resumes
only never-attempted pending recipients. A provider rejection is failed, also not
automatically retried. There is no exactly-once claim: Mailjet offers no guaranteed
idempotency here. Inspect provider activity manually before considering a new
campaign after uncertainty. Local disk write failure terminates the service.

## Build / checks

```
go -C services/bots/nrc-newsletter test -race ./...
go -C services/bots/nrc-newsletter vet ./...
docker build -f services/bots/nrc-newsletter/Dockerfile -t nrc-newsletter .
```

Tests use only local fake HTTP/WebSocket providers and temporary bbolt files.
No external mail/API credentials are required. To inspect the client with fake
Mailjet and volatile demo contacts, run `node client/newsletter-fixture.mjs` from
the repository root (HTTP port 8097; do not deploy this fixture). In an orb use
`amp orb service start newsletter-fixture --command 'node client/newsletter-fixture.mjs' --port 8097 --portal`.

Newsletter campaigns send to confirmed workspace subscribers. Service campaigns
are a separate kind for necessary **non-promotional** customer information, not
an ignore-consent switch. Select specific company IDs or explicitly choose all
nonarchived companies. The contact editor's SERVICE INFORMATION section stores
company IDs as `service_for: ["123"]` in contact preview metadata. Delivery also
requires a live `MemberOf` association to each nominated company. Archived
companies/contacts, unassigned contacts and delivery-blocked addresses are excluded;
newsletter optouts alone do not suppress service information. Spam complaints and
hard bounces remain blocking for both kinds. There is no fallback to other contacts.
Use dedicated non-promotional Mailjet templates without marketing/unsubscribe
blocks for service messages; NRC does not append newsletter unsubscribe headers or
footers to that kind. It cannot classify template contents as legally non-promotional.

Save and test the current revision, then review the service audience before final
subject confirmation. The review reports missing reachable service contacts,
excluded records and duplicates. A changed audience invalidates the review token.
The queue snapshots recipients; role removal, membership removal, email changes
or delivery blocks are rechecked before dispatch. New contacts are never added to
an existing queue. Service reason and customer selection persist with the campaign.

Existing consents are imported only through the API or `nrc newsletter consent
import --input consents.json`, not through the browser. The CLI accepts a JSON
array or `{ "records": [...] }`, at most 200 rows / 64 KiB per request. Preview
first, then explicitly import with `--confirm`. The subscriber register still
shows existing consent provenance and original import proof.
Required row fields are `email`, `source`, `confirmed_at` (past RFC3339 timestamp),
`evidence` (e.g. original DOI record), and `scope` (original consent wording/scope).
`external_id` may preserve the Zoho ID. Example:

```json
[{"email":"newsletter@example.com","source":"Zoho export","confirmed_at":"2025-02-03T10:20:00Z","evidence":"DOI record 123","scope":"NRC product newsletter","external_id":"123"}]
```

The authenticated `POST /api/consents/import` accepts `{records, confirm:false}`
for preview and `confirm:true` for import. Only live contact addresses can match.
Unknown contacts, duplicates, existing subscriptions, optouts and blocks are
reported/skipped. Conflicting duplicates or invalid rows reject the entire batch.
An optout remains protected from import after a new invitation, even if delivery
fails or the service restarts. Only fresh DOI confirmation reactivates it.
Source, evidence, original scope/date, external ID and import time are durable.
The immutable original proof survives optout, failed reinvitation and subsequent
DOI confirmation, independently of the current subscription source/date. Pending
records with prior import proof cannot be reactivated by reimporting that proof.
No invitation or email is sent and no Zoho API is called. Import only actual
consents covering the intended newsletter, not a different legal basis such as
the existing-customer exception. Import is not a legal validation of that evidence.

There are no scheduled campaigns or tracking analytics.
Template variables are campaign-wide string values; nested Mailjet objects,
per-contact `data:` properties and automatic name extraction are not supported
by the form. A source entry documents the individual signup request, not a
legal determination that consent exists. Never invite the whole CRM register.

Authoritative API references used during implementation:

* https://dev.mailjet.com/docs/email-api/send-api-v31/use-template.md
* https://dev.mailjet.com/docs/email-api/send-api-v31/send-basic-email
* https://dev.mailjet.com/openapi/openapi-mailjet/templates/get_v3_template
* https://documentation.mailjet.com/hc/en-us/articles/16886347025947-Mailjet-Templating-Language
* https://www.mailjet.com/blog/email-best-practices/what-is-webhook/
