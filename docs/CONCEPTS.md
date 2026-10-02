# Concepts

NRC separates conversations from work you need to keep. Tasks, notes, files and
other records belong to a workspace. Views such as Attention and Calendar help
you find those records; they do not create separate copies.

## Workspaces and chat

A workspace is the shared data and access boundary. Rooms and two-person DMs
inside it carry chat and presence, not separate task or note databases.
Switching rooms does not change the workspace's durable data.

Room messages are ephemeral by default: the server does not store them.
`NRC_MESSAGE_RETENTION` can enable bounded history and reconnect replay for rooms.
DMs remain ephemeral because their membership is not durable. Retention is not an
archive or a backup; expired history is removed by retention maintenance.

Use chat for discussion. Put decisions in notes and work to do in tasks if you
need them after the conversation ends.

## Tasks

A task describes work to complete, such as "Test the Safari login". Its status
tracks progress through Backlog, Todo, In Progress and Done. An assignee identifies
the person responsible. Priority and an optional due date help order the work.

A task can wait on another task through its blocker field. Completing the blocker
clears that dependency on its direct dependents. Reopening it does not restore
the dependencies.

## Notes

A note keeps information rather than tracking completion. Use it for decisions,
instructions, meeting notes or background that would otherwise be lost in chat.
Notes support Markdown or HTML content, a project label and tags.

For example, keep the rollout decision in a note and create tasks for the work
it requires. Link the tasks to the note so the reasoning stays with the work.

## Files

A File record makes an uploaded document reusable. It holds a title, description,
category and tags, with the uploaded file as an attachment. Link an existing File
to tasks or notes instead of uploading another copy for each record.
For example, use one File record for the rollout checklist.

## Projects and tags

A project label groups records by project and lets you filter lists. A task has
one optional project label. Tags add other labels, for example to notes and files.
Neither a project nor a tag creates an access boundary.

## Slices

A slice brings tasks, notes and files together for a specific piece of work.
Use one when you need to track an outcome across projects, rather than change
the project labels of the records involved.

For a customer rollout, a slice can contain a Backend task, a Webclient task,
the decision note and the checklist File. The tasks keep their project labels.
The same task, note or file can belong to several slices without being copied.
The slice shows its members and task-status counts so you can see progress.

A slice has an owner, but that does not assign its tasks to the owner.
Closing a slice is an explicit action; finishing its tasks does not close it.
Deleting a slice removes its memberships, not the tasks, notes or files.

## Reminders

A reminder tracks a deadline, with an optional start for the work window and a
configurable urgency period. Use one for "Submit the rollout documents by Friday"
or "Renew the certificate during this window". It can link to a note with details.
Unlike a task, it has no assignee or completion status: it is a workspace reminder.

The Reminders view shows its state from the current time:

- **Locked:** the work window has not started.
- **Open:** the window is open and the deadline is not yet urgent.
- **Urgent:** the deadline is within the configured urgency period.
- **Late:** the deadline has passed. This takes precedence over the window start.

Use a task when you need to assign and track completion of the work itself.
Use a reminder when the deadline or work window is the main thing to track.

## Appointments

An appointment records something scheduled to start at a specific time, such as
a rollout review. It has a start time, an optional end time, an optional assignee
and project, a description and an optional meeting URL.
Use an appointment for a scheduled event, a task for work to complete and a
reminder for a deadline or work window.

## Calendar

The Calendar view puts open tasks with due dates, reminder deadlines and
appointments on one timeline. Use Agenda for a dated list or Month for a calendar
grid. Select a day to see its records, then open a record to inspect or edit it.
Dates and times are shown in the browser's local time zone.

Person and project filters narrow tasks and appointments. Either filter excludes
reminders, which do not have those fields. Calendar shows when work is dated;
it does not contain tasks without a due date.

## Attention

Attention answers "What needs my attention?" across projects in the workspace:

- Open tasks assigned to your nickname, with overdue work and tasks that unblock
  other work called out. Blocked tasks appear only when overdue, as waiting work.
- Urgent and late workspace reminders, not only reminders you created.
- Unread room messages, mentions and DMs tracked in the current browser session.

Use the Task, Reminder and Message filters to focus on one source. Attention is
not a separate inbox with a dismiss action. Its rows follow the underlying state:
finish or reassign a task, change a reminder, or read a conversation there.
It is not a durable history of chat notifications.

## Browser notifications

With browser permission, reminder notifications report urgent and late states.
They default to all workspace reminders. Appointment notifications default to
appointments assigned to your nickname and alert within 15 minutes before start.
The two notification settings are independent.

Keep an NRC tab open for notifications. There is no push service for a closed
browser. A suspended tab can delay alerts; appointments that have already started
do not produce catch-up alerts. Do not rely on these as a guaranteed alarm.

## Customers

Customer records group a company, its contacts and its activity history.
Use activities to keep calls, meetings, emails and decisions after chat ends.
Link tasks, notes and files to the company or its records to keep customer work
with that context. A customer record does not create a private data area.

## Example: a customer rollout

Keep the decision and rationale in a **Note**. Create **Tasks** for the Backend
and Webclient changes. Upload the checklist as a **File** and add those records
to a **Slice** named "Customer rollout". Add a **Reminder** for the submission
deadline and an **Appointment** for the review meeting. Link the work to the
**Customer**. Use **Calendar** to see dates and **Attention** to find your current
work and due reminders. Each record still belongs to the same workspace.

## Relationships and storage

Assignee, creator and owner fields describe responsibility, not permissions.
Workspace members share durable data; neither a project nor a DM makes a task private.

Edges link tasks and assets with relations such as `References`, `RelatedTo`,
`DependsOn`, `Blocks` and `MemberOf`. Graph APIs traverse these relationships.
The web client exposes links but has no node-link graph visualization.
Slice membership uses `MemberOf`. Customer contacts and activities also use
`MemberOf` for company membership; customer work links use `RelatedTo`.

Internally, notes, reminders, files, customers, slices and appointments are typed
assets with a preview, payload and optional attachments. In the binary protocol,
durable entities use reserved scope `conv_id = 0`. This is not a chat room.
Nonzero durable request scopes are rejected.

Asset parentage is different from a generic edge: deleting a parent task or
asset cascades to its owned child assets. File blobs live separately from these
records; removing a reference does not immediately erase the physical file.

## Publishing notes

Optional Publish turns a Markdown note into a public article. For example, keep
an internal rollout note in NRC and prepare a customer-facing copy with a public
title, summary and category. A draft copies the note body and every listed
attachment. Review them for confidential information before approving the draft.

Approval publishes that stored copy, not the live NRC note. Later source changes
need another draft and approval. The CLI can prepare and inspect drafts, but only
a human reviewer can publish or withdraw an article. Withdrawal stops serving the
article and its files; it cannot erase copies readers already downloaded.

See [Publish](../services/bots/nrc-publish/README.md) for setup and access rules.

## Durability and optional processors

Task, asset and edge writes share an atomic sharded write-ahead log. Success is
acknowledged after fsync. If a connection dies before its acknowledgement, the
write may still have committed; do not blindly retry mutations.

Search maintains a local index of workspace data. AI retrieves context and calls
the configured LLM. Both services can read workspace data; AI can also write
confirmed changes.

See [Operations](OPERATIONS.md) for access controls and LLM data handling,
[the AI reference](../services/bots/nrc-ai/README.md) for confirmation flows and
[persistence](SHARDED_PERSISTENCE.md) for storage details.
