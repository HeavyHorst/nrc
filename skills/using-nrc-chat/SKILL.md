---
name: using-nrc-chat
description: Operates NRC room chat, retained room messages, real-time watching, presence, and direct messages through the nrc CLI. Use when asked to send or watch chat, inspect online users, or start, list, use, or leave NRC direct-message conversations.
---

# Using NRC Chat

Use NRC chat for real-time communication. Chat rooms are separate from workspace-wide durable data: `--room` selects chat only, while notes, tasks, edges, search, and retrieval do not accept it.

## Command Discipline

1. Use the `nrc` CLI and its exact command shapes.
2. Non-streaming commands emit compact JSON by default. Use `--human` only when a person explicitly needs prose or a table.
3. `nrc chat watch` is a long-running JSONL stream. Run it as a tracked background process when other work must continue, and stop that process explicitly when finished.
4. Sending a message changes shared external state. Send only when the user requested or otherwise explicitly authorized that message and destination.
5. Use `nrc room list` when a room name is unknown or ambiguous. Omitting `--room` uses the configured default room; do not rely on it when the intended destination is unclear.
6. If a command shape or flag is rejected, inspect `nrc <command> --help` or `nrc capabilities` instead of guessing.

## Send Room Messages

An ordinary send is ephemeral real-time chat:

```bash
nrc chat send "Ready for review" --room engineering
nrc chat send "See **decision** [note:456]." --room engineering --markdown
```

Ephemeral sends are not added to retained history, even when server retention is enabled. A successful machine-mode response is a structured `sent` mutation with `retained:false`.

Use `--retained` only when the user wants the message available in bounded asynchronous room history:

```bash
nrc chat send "Deployment starts at 18:00." --room operations --retained
```

Retained messages:

- require nonzero server-side `NRC_MESSAGE_RETENTION`;
- expire according to that operator-configured window;
- are not permanent workspace memory;
- are supported for rooms, not direct-message conversations;
- return `client_message_id`, `sequence`, and a Unix-nanosecond server timestamp on success.

For a decision, runbook, finding, or reference that must remain canonical beyond the retention window, use `maintaining-room-memory` and create or update a note instead.

## Retry Retained Sends Safely

If a retained send fails after transmission or acknowledgement validation, the CLI reports that the outcome is unknown and prints the generated client message ID. The server may already have appended the message.

Retry only with the exact same room, content, content type, and ID:

```bash
nrc chat send "Deployment starts at 18:00." \
  --room operations \
  --retained \
  --client-message-id <id-from-error>
```

Never retry an uncertain retained send with a fresh ID; that can append a duplicate. `--client-message-id` requires `--retained`. IDs contain 32 hexadecimal characters; hyphens are accepted.

## Link Tasks And Notes In Chat

Use typed references in chat text:

- `[task:42]` for a task
- `[note:456]` for a note

Preserve the exact decimal ID, including 64-bit IDs. Send the token as plain message text, not inside Markdown backticks or links, so NRC renders it as clickable. References resolve workspace-wide regardless of the destination chat room. Legacy `#42` task references still work, but prefer typed references for new messages.

```bash
nrc chat send "Decision recorded in [note:456]; implementation tracked in [task:42]." --room engineering
```

## Watch Chat And Inspect Presence

Watch one room in real time:

```bash
nrc chat watch --room engineering
```

Machine mode first emits `watch_started`, then zero or more `message` JSON lines, followed by `watch_stopped` or `connection_closed`. Message events include `room_id`, `sequence`, `username`, `timestamp`, `content_type`, and `content`. Watching does not retrieve historical messages.

List currently visible users in a room:

```bash
nrc users --room engineering
```

The machine result is an object with a `users` array. Treat presence as a current observation, not durable history.

## Direct Messages

Manage direct-message conversations with:

```bash
nrc dm list
nrc dm start <username>
nrc dm leave <conv-id>
```

`dm start` returns the conversation ID and the peer's current online status. Send an ephemeral direct message by using that numeric conversation ID as the chat destination:

```bash
nrc chat send "Can you review [task:42]?" --room <conv-id>
```

Retained direct messages are not supported. `dm leave` changes shared state; run it only when the user explicitly asks to leave that conversation.

## Completion

After a send, report the destination and whether it was ephemeral or retained. For retained sends, include the returned sequence when useful. Do not claim delivery beyond the structured acknowledgement, and do not describe ephemeral or retained chat as durable memory.
