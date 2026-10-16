# NRC mobile chat — Android-first alpha

A real NRC chat client, not a WebView. The interface follows the selected warm,
text-first design: ivory/forest-green, monospace identity and state labels, flat
message transcripts with local initial avatars, no bubble chat. Dark mode follows Android's theme.
The folded mark uses the exact paths in `logo/logo.svg`, monochrome in the UI and
white on a dark padded tile for Android adaptive/themed launcher icons.

## What works

- Connect to an existing HTTPS NRC/Tailscale proxy with its verified identity.
  No JWT signing secret or bot credential belongs in the app.
- Built-in engineering/operations rooms and discovery of named room mappings.
- List/start DMs by exact NRC username; room presence and saved unread counts.
- Send UTF-8 text with server-acknowledged delivery state.
- Negotiate room and DM retention, load the latest 100 messages, page older history
  and recover retained messages on reconnect. Latest NRC `main` supports both.
- Save drafts in Android-private storage, separately for each server/workspace.
  DM draft keys use the partner username, not the server's ephemeral DM ID.
- Keep the latest 1,000 loaded messages per conversation in app-private SQLite,
  available offline after a process restart. Conversation names, unread counts,
  delivery states and safe replay checkpoints are saved with them.
- Foreground reconnection, protocol-version checks, application heartbeat, and
  explicit offline/unknown-delivery states. Offline send is disabled.
- Menu → **System log**: recent connection, protocol and local-storage events,
  with technical causes and copy/clear actions.
- Native Markdown/GFM chat rendering: headings, emphasis, strikethrough, quotes,
  nested lists, read-only task lists, links, tables and selectable code blocks.
- Compact consecutive messages from the same author within five minutes, without
  repeating their name/avatar; every message keeps its timestamp and actions.
- Copy original Markdown and reply beside the timestamp, with native 48-dp touch
  targets. Reply inserts a Markdown quote before the existing draft, focuses the
  composer and never sends automatically. Cancel reply removes the unchanged quote
  prefix, preserving draft edits; attachment replies quote the filename, not JSON.
  If the quote itself is edited, it becomes ordinary draft text. Formatted HTML
  clipboard and Sullivan/record panels remain web-only.

**This is not yet a production mobile messenger.** There is no durable outbox,
FCM integration, notification permission flow, reactions, or read
receipts. Current web-client image attachments display directly in the transcript;
all file types have native Open/Save actions, subject to a compatible viewer app.
Legacy chunked-image JSON is not assembled. Markdown-linked external HTTPS images
can be loaded explicitly in the transcript.
The default ARM64 APK embeds Tailscale, without requiring the external VPN app;
see [the tsnet transport and isolated Headscale test](tsnet/README.md). It keeps
the existing NRC app ID/signature, settings and history: there is no second APK
variant. Android runtime behavior still needs real-device validation.
The UI does not claim that `sent` means the recipient read or received a message.
Unacknowledged sends become `delivery unknown`; they are never automatically
resent, because ephemeral sends cannot safely deduplicate and retained deduplication
has a bounded retry window.

## Markdown in chat

The renderer is native Compose, not HTML or a WebView. Original UTF-8 message
text is kept unchanged in the protocol and local history; formatting is a view.
Long table cells wrap inside consistent columns, delimiter colons determine
left/center/right alignment, and wide tables scroll horizontally independently
of the conversation. Fenced code has language-aware highlighting, horizontal
scrolling and **Copy code**; intentional indentation inside the fence is preserved.
Task checkboxes are read-only, including uppercase `[X]`.

Links open via the platform handler, limited to HTTP, HTTPS and mailto; embedded
credentials and file/content/intent/JavaScript destinations are refused. Raw HTML
is displayed literally, never executed. NRC task/note references, math/KaTeX,
footnotes and arbitrary embedded HTML are not part of this feature set; this is
not a claim of complete equivalence to the web renderer or formal GFM conformance.

Overcomplex messages fall back to selectable, unmodified plain text with an
explicit notice. Before parsing, a conservative line-prefix check refuses more
than 16 quote markers, even in code examples; this avoids the parser's quadratic
allocation failure on a valid 50-KiB repeated-quote message. Native rendering
also has a 64-level/4,096-node AST budget. These are rendering limits, not changes
to the stored message or NRC's protocol limit, and not a general all-input/device
performance guarantee.

Markdown images keep an alt-text marker at their source position and show a
**Load image** control below the message. They are not fetched automatically:
loading external content shares the phone's IP with that host. Only credential-free
HTTPS URLs are accepted, with no redirects and a separate unauthenticated client.
Requests time out after 15 seconds, downloads are capped at 8 MiB even without
Content-Length, decode requests at 1024 × 1024, and the in-memory image cache at
16 MiB; no disk image cache is configured. Failed images have an explicit retry.
These external Markdown images are separate from the NRC file-upload flow below.

Version-1 NRC image attachment envelopes use a separate path: validated file IDs
are resolved against the configured chat origin and workspace, never against an
arbitrary URL supplied in a message. Visible attachments load automatically after
chat authentication, using the proxy's normal Tailscale authorization (no bot secrets).
Tap a loaded preview to enlarge it; Close or Android Back returns to chat.
The same 8 MiB download/1024 × 1024 decode/16 MiB memory limits and no-redirect
policy apply. Preview errors offer Retry; oversized attachments show the limit.
The image cache is isolated per profile and authenticated username and is memory-only.
Offline or storage-blocked sessions do not fetch image attachments. Their metadata
and original message payload persist locally; image bytes are not saved for offline use.
Old cached Markdown placeholders cannot restore their lost source without a fresh
server-history fetch. This update preserves original live and retained Markdown payloads.

## Files from the phone

The paperclip offers **Photo or image** and **File** through Android's document
picker, without broad storage permissions. The selected file is streamed into
app-private temporary storage (maximum 100 MiB), then shown for confirmation;
images have a local preview. Confirming streams multipart data to the same
`POST /upload?workspace=…` endpoint as the web client and sends its version-1
attachment envelope through NRC only after a successful, validated upload.
Draft text is not cleared by attachment sends. Multipart progress is transport
progress, not proof that a chat message has been acknowledged.
File authorization remains the proxy's workspace-grant policy, as on the web;
chat-target binding does not introduce DM-only file access controls.

Transfers are foreground-only, cancellable and never retried automatically.
Changing conversation/profile, disconnecting or backgrounding cancels an active
transfer. Returning from the system picker can require reconnecting before Send
becomes available; a different account/chat cannot receive the selected file.
Cancellation after an upload reached the server may leave an unreferenced blob;
it does not cause an automatic chat send or deletion of shared server data.

**Open** downloads a bounded, complete file to app-private cache, then grants a
temporary read-only content URI to Android's app chooser. **Save** downloads first,
then uses Android's Create Document picker to choose a destination. PDF, audio,
video, archives and other types are opened by compatible installed apps, not an
embedded WebView or an in-chat media player. Missing viewers and access/storage
errors are surfaced. Downloads are capped at 100 MiB, reject redirects/truncation
and check the expected attachment size. Only one transfer runs at a time.
Local staging and Save copies are cancellable too. A cancelled Save may leave a
partial file at the chosen destination; the app reports that rather than claiming
completion. A document provider that ignores thread interruption can delay cleanup;
new file actions remain blocked until its streams have closed.
Upload staging files are removed on completion/cancel; opened-file cache is
replaced by the next download or app recreation. Explicitly saved copies remain
at the user's chosen destination. Process death does not resume or resend transfers.

## Troubleshooting a connection

Open the three-dot menu → **System log** after a failure, then **Copy log** to
share the report. Events include UTC time, connection phase, exception class chain,
HTTP status or an allowlisted OS error code when available, and troubleshooting
hints for DNS, TLS, routing and proxy errors. Hints are possible checks, not proof
of a root cause. Raw exception text, stack traces, URLs, usernames, message contents,
headers, tokens and server error payloads are never stored in this log.

The latest 200 events are kept in Android-private preferences across ordinary
app restarts (best-effort persistence, not a crash-safe audit trail). **Clear log**
removes only diagnostics, never chat history or drafts; subsequent events start a
new log. Copying explicitly places the sanitized report on the system clipboard.
Desktop live preview stores its diagnostics in `~/.nrc-chat/system-log.json`.

## Device-local history

SQLite stores each message separately and commits messages and replay metadata in
one transaction, off the UI thread. Data is isolated by server address and workspace;
after authentication, a changed username discards the previous identity's cached
chat state and all room/DM drafts rather than mixing identities. If draft deletion
or identity-cache restoration fails, connection and draft editing are blocked rather than exposing
another identity's drafts. Existing history is not overwritten on read failure.
Local copies are not end-to-end encrypted;
they use Android's app-private storage, and Android backup is disabled.

Rooms and DMs are retained **on the server** when `NRC_MESSAGE_RETENTION` is enabled;
otherwise they are ephemeral there. Messages already received by this phone persist
locally in either case. Server expiry does not delete a local
copy. Each conversation keeps up to 1,000 messages; clearing app storage or
uninstalling removes them. There is no automatic resend: a send interrupted by
process death restores as `delivery unknown`, and retained replay can confirm it.
Replay checkpoints advance only from correlated history pages, never a live frame
or an outgoing ACK. Cached DMs retain their history by partner username when the
server assigns a different conversation ID. A DM no longer in the server's active
list is read-only locally until the user explicitly chooses `Reopen DM`; simply
viewing local history never silently restores revoked server membership.

Older-history cursors survive restart. Catch-up marks genuinely new peer messages
unread in unselected conversations; initial history and older browsing do not.
Delivery bookkeeping survives cache eviction and is separate from replay checkpoints.
Live receipts trigger background replay after 256 peer sequences. At most 2,048
are admitted per conversation; if history recovery is unavailable, additional new
peer records wait for correlated replay rather than growing an unbounded ledger.
The UI identifies this pause and incomplete unread counts. Deferred records become
unread according to the selected conversation when recovery actually displays them.
Recovery cannot restore records that expired or became inaccessible on the server.
Receipts use small SQLite rows, including lossless migration of oversized old caches.
Old oversized ledgers are preserved without further growth until replay can compact
them; inaccessible old DMs may retain their legacy memory cost. The bound is per
conversation, not a constant-size whole-workspace cache.
History requests run one at a time, with four bounded retries for the server's
capacity/maintenance errors and an explicit `Retry message history` action afterward.
Access denial and sends are never automatically retried.

## Build and install

Requires JDK 17, Go 1.27.1+, Android SDK platform 35, an NDK (tested with
27.2.12479018), and accepted SDK licenses. Set
`ANDROID_HOME`, or put `sdk.dir=/path/to/sdk` in ignored `local.properties`.
Set `ANDROID_NDK_HOME` to the installed NDK directory for the gomobile build.
The checked-in Gradle wrapper downloads Gradle 8.11.1.

```sh
# Run from mobile/
./gradlew :shared:jvmTest
./sign-debug-apk.sh
adb install -r androidApp/build/outputs/apk/debug/androidApp-debug.apk
```

The debug APK is for private testing, not store submission. Its existing signing
identity must be preserved for in-place updates; see the signing procedure below.
Android 8.0/API 26 or newer and an ARM64 phone are required. Enter the NRC HTTPS
origin (without a path) and workspace name, then use **Continue Tailscale sign-in**
to enroll NRC's own node in your browser. The action remains available after a
cancelled browser visit and returns when reauthentication is required. The
separate Tailscale app is not needed. NRC attachments use the embedded transport;
external Markdown images and browser links do not. Normal TLS
certificate verification is enforced; HTTP and embedded credentials are rejected.
No Firebase project or Play Store account is needed for this foreground alpha.

### Signing-key custody

`signing/debug.sops.json` is the encrypted backup of the **existing** alpha
keystore, not a newly generated APK key. It contains `keystore_base64`,
`store_password`, `key_alias` and `key_password`, all encrypted by SOPS. Its two
public age recipients are in `.sops.yaml`; build access requires the project secret,
and recovery custody requires an owner-held private-key backup outside Amp.
Never commit an unencrypted keystore, credentials JSON or private age identity.

For a new enrollment, create two age identities **outside the repository, on the
owner's computer** (do not replace the existing APK key):

```sh
umask 077
age-keygen -o nrc-build.agekey
age-keygen -o nrc-recovery.agekey
age-keygen -y nrc-build.agekey
age-keygen -y nrc-recovery.agekey
```

Only the resulting public `age1…` recipients belong in the repository/chat.
Enter the build private identity through Amp's masked secret input as the
**project-scoped** secret `SOPS_AGE_KEY`: paste only the single `AGE-SECRET-KEY-…`
line, not the commented multi-line file (the masked input can flatten line breaks).
Do not paste it into chat, command arguments or ordinary Amp environment-variable
settings. Keep the separate recovery identity
in an owner-controlled password manager and an independent offline backup, outside
Amp. Verify recovery on the owner's machine before discarding the original
keystore. From the repository root, with an absolute recovery-key path:

```sh
env -i PATH="$PATH" HOME=/dev/null XDG_CONFIG_HOME=/dev/null \
  SOPS_AGE_KEY_FILE=/absolute/path/nrc-recovery.agekey \
  sops --decrypt mobile/signing/debug.sops.json >/dev/null && echo "Recovery OK"
```

The isolated environment and disabled default key directories prevent a build identity from silently
making the recovery check pass. Exit success and `Recovery OK` prove decryption
without displaying private signing material. An APK contains only the public
certificate; it cannot recover the private signing key.

In a fresh orb, `.agents/setup` installs checksum-pinned SOPS and age, but never
generates identities or decrypts signing material. After changing the project secret,
refresh the orb environment with `amp orb restart-processes` before building.
On a trusted local machine, use `SOPS_AGE_KEY_FILE=/secure/path/nrc-recovery.agekey`
instead of putting its private contents in an environment variable.

`sign-debug-apk.sh` decrypts into a mode-0700 temporary directory with mode-0600
files, verifies the original certificate SHA-256
`b8d67864abd5c79328bba51e8e656048d9a35c1a220c19c13b3ea504f13627ce`,
and supplies Gradle only that directory's path. Passwords are not command arguments.
It disables reusable Gradle daemons/configuration caching and removes temporary
material on normal exit, failure, SIGINT and SIGTERM. SIGKILL or an orb crash cannot
run cleanup; any surviving private `nrc-android-signing.*` directory must be removed
before reusing/discarding that environment. Do not run secret-bearing builds with
untrusted code/plugins or publish build scans. Project code can access project secrets.

Raw `assembleDebug` is deliberately refused without the signing wrapper; tests,
lint and desktop preview do not require decryption. This remains the original
Android **debug** identity, not a production release-signing setup or Play App Signing.
No release key or key-rotation strategy is configured here.

The app disconnects in the background to avoid pretending a WebSocket provides
reliable background messaging. Returning to the foreground reconnects. Enable
`NRC_MESSAGE_RETENTION` on the server if room history is wanted; the app does not
change the server's retention policy. With positive retention, current NRC servers
support history and replay for DMs too. With retention disabled, neither rooms nor
DMs can recover missed messages.

## Preview and tests

```sh
./gradlew :preview:run
./gradlew :shared:jvmTest :ui:jvmTest :androidApp:lintDebug
# Headless Linux with Xvfb installed:
xvfb-run -a ./gradlew :ui:jvmTest
```

`preview` is a desktop host for the **same Compose screens used by Android**, not
an Android emulator. Sample mode is visibly labelled and stays out of the APK.
It lets you inspect light/dark, navigation, composer, and offline states. Its
toolbar can switch to a real HTTPS NRC connection; that mode uses the shared
client, desktop-private draft preferences and SQLite at `~/.nrc-chat/history.db`.
Sample mode never writes sample messages into that database. Desktop rendering cannot verify
Android keyboards, system Back, lifecycle, TalkBack or real-device performance.
Those require a physical Android device or an Android-capable runner.

Tests exercise wire compatibility, signed DM IDs, UTF-8 bounds, malformed frames,
secure address validation, draft recovery/isolation, search, navigation and
offline send gating, plus actual SQLite reopen, offline message restoration,
history bounds and server/workspace isolation. Neither preview data nor unit tests establish server delivery.

## iOS later

- `shared`: Kotlin Multiplatform models, codec, connection/replay, draft logic and SQLDelight SQLite schema/store.
- `ui`: Compose Android screens plus JVM rendering for development.
- `androidApp`: Android activity, lifecycle, OkHttp engine and private draft storage.
- `preview`: desktop-only development host and sample data.

On macOS, `shared` exposes `NrcChat` framework targets for iPhone and Apple Silicon
simulator. The intended iOS app uses SwiftUI over this core, with its own platform
storage/HTTP engine/lifecycle adapters. No iOS app or validated Apple build exists
yet. Background notifications need device registration plus a trusted push sender
on NRC's backend; FCM can deliver Android pushes and relay iOS pushes through APNs.
That infrastructure and a Firebase project must be configured separately.
