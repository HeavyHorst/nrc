# Standalone review forms

The NRC register **Abnahmen** creates a form independently of a ticket or task.
Drafts contain a title, build, environment and ordered points with stable local
IDs. Reordering does not renumber points. Release requires a build and at least
one question and freezes the complete form. Staff can withdraw an active release
only before its first run exists; that returns the same form to an editable
draft. Copying creates an editable draft; a new build uses that copy, not an edit
of a form already used in a run.

Staff can archive a released form and restore it from the **Archived** register
filter. Archiving hides the form from the default register and prevents new runs.
Existing runs, reports, access and references are unchanged.

Each point may have an author-defined `section` label (at most 256 UTF-8 bytes).
It is part of the form JSON and freezes together with the question at release.
Copying and reordering retain the label. Empty or omitted labels are valid, so
existing forms need no rewrite or additional database migration.

The portal shows one editable point at a time, with point navigation and
**Speichern und weiter** until the last point. Longer forms group the navigation
by author-defined section, or use display-only groups of eight for unlabeled
points. Personal progress counts the current participant's saved answers, not
the team's contributions. Team contributions and the separate closure form can
be expanded without JavaScript.

The internal comparison opens a wide point-by-team table with question/section
search and result filtering across teams. Selecting a cell shows each person's
contribution separately. Creating a task there links the concrete answer asset;
short findings remain complete in the task description. If the generated
description exceeds the existing 4096-byte task limit, the title prompt warns
that it will contain a UTF-8-safe, explicitly marked excerpt. The complete
original answer is unchanged and reachable through the task's answer link.
Ticket links open the review form; answer links open its run and focus the exact
contribution by answer ID, including when participants share a display name.

Closed portal reports lead with the decision and closing comment. Their result
counts partition the form's points: any `no` means deviation, otherwise any
`unable` means not testable, otherwise any `yes` means passed; points without
answers are unanswered. Conflicts remain explicit. Clarification points precede
the initially collapsed complete list. The report has no answer controls.

Each QA or customer team has its own run. Staff assign people by their stable
NRC subject or canonical ticket-portal `requester`, not by display name or company.
An empty staff identity assigns the current NRC subject. Participants can read
their team's contributions and edit only their own answers. Close permission is
separate. QA closes with `completed`; customers choose `accepted`, `conditional`
or `rejected`. Open points do not prevent a decision. The preview shows open
points and contradictory yes/no contributions before closure.

Answers and closure use the workspace writer transaction. Closure requires the
revision seen in the preview. A new answer or changed assignment invalidates
that revision and requires another review. Once closed, answers, assignments,
decision and report content cannot be changed. Revoking access still works.
Use **Aktualisieren** to fetch other people's contributions; the MVP does not
broadcast run changes.

## Existing portal accounts and guests

The existing `services/bots/nrc-tickets` service serves **Meine Abnahmen** using
the same account and browser session as the ticket portal. Only explicit run assignments appear. A customer
does not gain access through a company membership or a ticket reference.
The portal receives form fields and the assigned team's contributions, never
internal graph links, invitation hashes or participant account identities.
Internal staff can select active portal accounts from the current workspace
when assigning participants to an open run. This does not grant access to
portal account administration.

Guests use `/abnahmen/einladung#TOKEN`. The fragment is exchanged in a same-origin
POST and immediately removed; it is not sent as a URL query, redirect or Referer.
The portal stores the invitation and a random guest identity in an authenticated,
encrypted `Secure`, `HttpOnly`, `SameSite=Strict`, host-only cookie. Every write
checks Origin and a session-bound CSRF value. Every backend access checks the
invitation's run, expiry and revocation again. Two browsers using the same link
and name remain separate participants.

Set `TICKETS_GUEST_SESSION_KEY` on the portal to a private, random 32-byte key
encoded as 64 hex characters. Keep it stable across restarts; rotating it ends
existing guest sessions. Without this setting account access works, but guest
routes return 503. TLS termination and the existing `TICKETS_ORIGIN` remain
required. Do not log request bodies, fragment-exchange payloads or cookies.
Set the same `TICKETS_ORIGIN` in the Tailscale proxy's environment (Compose `.env`)
so the Inspector generates public invitation URLs without asking users for a host.

Invitation links default to participation only. Granting guest closure explicitly
allows any link holder to decide under a self-declared name; the report labels
that provenance. For a named person's approval assign their existing portal
account with close permission instead. Guests gain no ticket access.

## Findings and retests

Forms and individual answers can carry optional internal `RelatedTo` edges to
tickets or tasks. Removing an edge does not remove the answer or change the
report. Creating a task from a finding preserves the original contribution.
A retest uses a released copy for the new build and references a closed predecessor
with the same team label and kind. It has fresh answers and assignments; the
old run remains unchanged. Starting from a ticket creates the same editable
form and an optional internal edge, not a required ticket dependency.

## Work slices

Use **Assign review** in the Slice Inspector or `nrc slice assign <slice-id>
--review <form-id>`. A form can belong to several slices and remains a member
after release or archival. Runs and individual answers are not slice members.
Unassigning removes only the membership; deleting a draft also removes its
membership edges. Membership does not grant access to portal reports.

The Slice register includes forms in its member count, not its task counts or
task coverage. Opted-in `C_ListTaskSlices` requests append byte `1` after the
length-prefixed project filter (which can be empty). `S_TaskSliceList` then
appends a big-endian u32 review count per row after the existing correlation ID.
Legacy requests get the original response. Counts use the existing indexed
membership projection and need no schema migration. New memberships and edits
to the form itself contribute to Slice movement, not changes to runs or answers.
Existing memberships gain that timestamp when the form is next edited; past
activity is not replayed.

Update the server before serving the new web client: older servers reject the
opt-in request. The CLI can retry slice listings in the legacy format, without
review counts.

## Wire contract and storage

`C_Review` (77) is opcode u16 big-endian + JSON + correlation u32 big-endian.
`S_Review` (182) is opcode u16 + correlation u32 + JSON. IDs and nanosecond
timestamps are canonical decimal strings, including in JavaScript. The exact
DTOs are in `protocol/reviews.odin` and `protocol-go/reviews.go`.

Operations: `create`, `get`, `update`, `release`, `unrelease`, `archive`, `restore`, `delete_draft`, `copy`, `run_create`, `run_get`,
`run_list`, `participant_add`, `participant_accounts`, `answer`, `close`, `invite`, `revoke`,
`invitation_info`, `guest_join`.
`participant_accounts` requires a `run_id` and returns paged account choices
with only requester identity, display name and login.
`update`, `release`, `unrelease`, `archive`, `restore`, `delete_draft` and `close`
require `if_revision`. A release with a run returns `has_runs` on withdrawal;
`run_create` sends the observed `released_at` as `if_released_at`. A stale token
returns `conflict`. Tokenless older clients get `conflict` for archived forms
or releases issued after a withdrawal; otherwise their request still works.
Token-aware callers get `archived` for archived forms. Archive state is stored
in the record preview, not the frozen form or run response.
`run_list` supports an optional `form_id` and an exclusive `cursor`, returning
`cursor` and `has_more`. Pages stop at 50 runs or a 64 KiB serialized row budget.
There are at most 100 questions and 64 participants per run. Requests/forms
are bounded by 48 KiB and complete responses by the existing command-output
budget; a write whose response cannot fit rolls back rather than becoming
unreadable. Keep forms and comments concise.

`ReviewForm` (18) and `ReviewAnswer` (19) are linkable assets, but generic create,
update, delete and transaction patch commands cannot bypass domain protection.
`delete_draft` requires the current form revision and removes only an unpublished
form and its links. The Inspector asks for confirmation. Released forms and
their reports cannot be deleted this way.
Private SQLite tables hold runs, memberships, invitation hashes and the unique
person/run/point answer mapping. Only the verified `nrc-tickets` bot can submit
portal or guest identities; ordinary NRC clients cannot impersonate them.
Upgrade existing installations explicitly using the
[schema-11 procedure](DEVELOPMENT.md#sqlite-schema-11). Nothing migrates production
data automatically.

### Guest invitation preview

Before asking for a guest's name, the verified `nrc-tickets` gateway may send:

```json
{"op":"invitation_info","source":"guest","token":"<64-character invitation token>"}
```

`guest_id` is optional and ignored by this operation; the portal may send its
existing guest session ID. Neither a name nor an existing participant is needed.
An optional `run_id` must match the invitation's run. Normal request text and
decimal validation still apply. Staff connections and `source:"portal"` are
forbidden, even when they supply a valid token.

The operation shares the existing workspace-scoped invitation hash lookup:
`revoked_at=0` and `expires_at > request.timestamp`. Unknown, malformed, revoked,
expired, wrong-workspace or wrong-run tokens return `status:"forbidden"` without
review data. Expiry includes the exact expiration timestamp. A valid invitation
can be previewed even after its run has closed; preview does not reopen it.

On success, `ReviewResponse.Status` is `"ok"` and `ReviewResponse.Form.Title` is
the canonical released form's title, never its run/customer label or request
title. All other response fields retain their empty/zero defaults (including
empty form/run IDs and revisions, no points, participants or answers). The
current DTO serializer includes these default fields, so the semantic response
is `{"status":"ok","form":{"title":"Actual form title"}}` plus those defaults.
No participant, history, ID floor, invitation or run revision is changed.
`guest_join`, `answer`, `close` and their role/revision checks are unchanged.

Dispatch: `protocol/reviews.odin` accepts the operation; `sqlite_reviews.odin`
routes it to `sqlite_review_run_command` in `sqlite_review_runs.odin`, which
returns the title projection immediately after token validation and before
participant lookup or mutation handling. `protocol-go/reviews.go` encodes the
request and accepts the title-only response. No new opcode or schema is needed.
The existing `C_Review` dispatch in `websocket_handler.odin` and verified-bot
classification in `worker_db.odin` remain unchanged. The gateway's own operation
allowlist/route must forward `invitation_info`; it is separate from this backend
dispatch and does not grant broader guest access.

## Client regression checks

Run `node --test client/*.test.mjs` for the client suite. With Chromium and
Playwright installed, run the real-stack browser regression separately:

```sh
NRC_REVIEW_CLIENT_E2E=1 go -C test/e2e test -run '^TestReviewClientPublicUI$' -count=1 -timeout=5m
```

It starts a disposable Odin server and authenticated client proxy, creates
ASCII and multibyte 4096-byte findings through the UI, checks their task links
and unchanged originals, and follows ticket/form, task/answer and note links.
`NRC_REVIEW_BEFORE` optionally selects an unchanged client directory for the
same scenario's negative control before testing the current client.

The portal's real-stack guest/owner walkthrough is separately opt-in:

```sh
NRC_REVIEW_WALKTHROUGH_E2E=1 go -C test/e2e test -run '^TestReviewRealStackWalkthrough$' -v -count=1 -timeout=8m
```

It builds the real portal, seeds a 48-point review and a short legacy form,
and drives separate guest/account browser sessions through public forms.
After invitation fragment exchange, the workflow runs without JavaScript,
including two successive revision conflicts with an unchanged closing draft.
The completed report and both participants' contributions are independently
read back from Odin. Numbered screenshots are published only after the entire
browser run passes, under `.amp/in/artifacts/review-ux/`.

Two focused real-stack browser regressions cover invitation switching and
canonical Inspector history:

```sh
NRC_REVIEW_GUEST_E2E=1 go -C test/e2e test -run '^TestReviewGuestInvitationBrowser$' -v -count=1 -timeout=5m
NRC_REVIEW_IDENTITY=1 NRC_REVIEW_CLIENT_E2E=1 go -C test/e2e test -run '^TestReviewClientPublicUI$' -v -count=1 -timeout=5m
```

The guest test checks A → invalid → A and A → B → A in one browser, editing
the original contributions without duplication, isolated close rights and CSRF,
and live invitation revocation/expiry. The Inspector test creates, copies and
retests forms through the UI, opens a task and goes Back, then saves the same
canonical form with an update instead of another create. It also verifies the
retest predecessor and typed answer navigation. Both save synthetic evidence
under `.amp/in/artifacts/review-p2-latest/`. `NRC_REVIEW_SERVER_BIN` reuses an
existing Odin binary. Optional pre-fix portal/client baselines can be selected
with `NRC_REVIEW_GUEST_BEFORE_BIN` and `NRC_REVIEW_BEFORE`, respectively.
