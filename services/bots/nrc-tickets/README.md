# NRC Tickets

Separately deployable German customer portal, backed exclusively by NRC Ticket
and TicketEntry assets. Ticket-scoped attachments use NRC's private blob service;
there is no local ticket database, public registration, generic asset/file proxy,
or dependency on the staff web client. Branding uses operator CSS/logo/footer
configuration in the same style as Publish.

See [deployment, provisioning, security and test instructions](../../../docs/TICKETS.md).

```sh
go test -race ./...
go build -o /tmp/nrc-tickets .
```

## Abnahmen for accounts and guests

`/abnahmen` adds **Meine Abnahmen** to the existing authenticated portal.
The server lists only runs explicitly assigned to the account's canonical
`requester`; ticket-sharing groups do not grant review access. All list pages are
loaded. Questions show team contributions and their staff/portal/guest origin.
Saving an answer affects only the current participant. Closing is a separate
decision with its own comment, an explicit preview and an `if_revision` guard.
A changed revision requires a new preview. No write is automatically retried
after a lost acknowledgement.

Staff-generated invitations must use this exact URL form on `TICKETS_ORIGIN`:

```text
/abnahmen/einladung#<64-character-server-generated-hex-token>
```

The fragment is never sent as an HTTP URL. A same-origin external script removes
it from browser history, exchanges it by POST and navigates to `/abnahmen/gast`.
JavaScript is required only for this initial exchange. Query-string invitations
are rejected. Do not log request bodies or Cookie/Set-Cookie headers at the
reverse proxy. Do not redirect invitations through third-party link trackers.
The link grants access to whoever holds it, not to a verified person.

Guest access requires `TICKETS_GUEST_SESSION_KEY`: an operator-generated random
32-byte secret encoded as 64 hex characters, injected through the deployment's
private secret configuration. Never use a password or the bot secret as this
key. An absent key disables guest routes with HTTP 503 while existing ticket
and account routes continue working; an invalid configured key stops startup.
The existing Compose overlay needs this variable passed explicitly if guest
access is enabled there.

The portal uses an AES-256-GCM authenticated encrypted `__Host-nrc-review` cookie
with Secure, HttpOnly, SameSite=Strict and an eight-hour absolute expiry. It holds
the invitation, a random guest ID and the accepted display name. Tokens and guest
IDs never enter rendered pages, localStorage or sessionStorage. Keep the same key
across replicas and restarts to preserve sessions; rotating it invalidates all
guest sessions. There is no portal session database. A separate encrypted
`__Host-nrc-review-<token hash>` cookie remembers each invitation's own identity
with the same flags and original absolute expiry. The backend validates every
invitation exchange before any cookie is changed. Invalid, revoked or expired
links leave the active session untouched. Switching A → B → A restores A's
participant and answers without transferring B's permissions or extending A's
eight-hour session. Cookies are bound to their name and portal origin. Browser
cookie deletion or eviction still loses the remembered identity. Different
sessions with the same name remain different participants.

The name form and subsequent guest writes require the exact configured Origin
and a session-bound CSRF value. The backend checks invitation expiry, revocation,
run scope and live closing permissions on each operation. Ordinary guest links
cannot close. An explicitly close-enabled guest sees a warning that their close
attribution is self-supplied, not verified. An invitation never authenticates the
ticket routes or grants access to another run.

Only the narrow optional `reviewSource` interface calls `C_Review`/`S_Review`.
The bot remains `nrc-tickets`, with its existing bot credentials. The browser
cannot supply source, account identity, requester, guest ID or permissions.
No generic asset API, internal links/notes, extra record store or database is
exposed. Deploy the matching NRC review backend before enabling these pages.

Run the review browser fixture as well as the existing ticket/sharing regression:

```sh
go test -race ./...
go vet ./...
node browser.e2e.mjs
node reviews.browser.e2e.mjs
```

`TICKETS_SCREENSHOTS` optionally saves screenshots for either browser suite.
The review fixture uses disposable fake authoritative state and loopback browser
security semantics, not production credentials. Wire tests separately check real
WebSocket framing and correlation. These tests do not prove backend authorization;
the server's own review tests cover that boundary.

The invitation-switch browser regression uses the real Odin/TLS stack. From the
repository root, run:

```sh
NRC_REVIEW_GUEST_E2E=1 go -C test/e2e test -run '^TestReviewGuestInvitationBrowser$' -v -count=1 -timeout=5m
```

`NRC_REVIEW_SERVER_BIN` can reuse a built Odin binary. For a before/after run,
`NRC_REVIEW_GUEST_BEFORE_BIN` selects a saved pre-fix portal binary; it must use
the matching review backend. The test covers A → invalid → A, A → B → A,
editing the original answers, isolated closing rights/CSRF, live revocation and
expiry, and independent server-side participant/answer counts. It saves its
synthetic-data evidence under `.amp/in/artifacts/review-p2-latest/`.

### Long review forms and closed reports

Forms with **more than eight points** use section navigation and one expanded
point. Author-provided `section` labels take precedence; missing labels fall back
to numbered batches of eight in the rendered view, without changing stored form
JSON. `section` is optional and limited to 256 UTF-8 bytes. Sections retain their
first appearance order. Forms with eight or fewer points keep the direct layout.

Progress and section counters count only the current participant's saved answers,
not team activity. The initial view selects their first unanswered point. A
successful ordinary HTML POST redirects to the next point; validation failures
and unconfirmed writes retain the selected point and draft instead. Navigation
does not save drafts. Answer persistence and navigation need no JavaScript (the
fragment-based guest invitation exchange still does).

Closed reports show the decision, attribution and proviso before point totals and
clarification items. Totals are mutually exclusive: any `no` is a deviation,
otherwise any `unable` is not checkable, otherwise `yes` passes; no answers means
unanswered. Thus mixed yes/no is a deviation and mixed yes/unable is not checkable.
All team contributions remain readable inside the collapsed all-points list.
Reports contain no writable forms. Close previews lead with the plain-language
decision and the author's unchanged closing comment. Unanswered, uncheckable,
deviating and contradictory points link directly into a collapsed all-points
list; native fragment navigation opens the target without JavaScript.

If contributions change after preview, the portal returns HTTP 409 with the
decision/comment still editable, marks the changed points, and offers only a
renewed preview. Per-point contribution fingerprints are comparison hints, not
authorization tokens. Every re-preview compares its submitted revision again,
including repeated changes. Final confirmation requires the review checkbox and
still sends the exact seen revision to NRC's transactional close operation. A
race at that operation also reloads the current state and preserves the draft.

The guest name page reads the title via `invitation_info` only after checking a
valid, unexpired, unrevoked invitation. It creates no participant until the name
form is submitted. It explains team visibility, self-supplied names, continuing
in the same browser/device and the maximum eight-hour session. Link forwarding
is secondary disclosure. The active review separates saved personal answers
from team counts; unanswered and uncheckable are distinct, and contradictions
link to the affected point. An unacknowledged answer stays a draft, not a saved
personal answer.

The browser fixture includes a 48-point invoice review (`/abnahmen/73`), its
closed report (`/abnahmen/74`) and the original two-point legacy review. The long
workflow is also tested with JavaScript disabled. These routes exist only in the
opt-in Go test fixture, not the production binary.
