# Task and Note References in Chat

## Overview

Type `#` followed by a title or ID in chat to select a task or note from the current room. The picker shows the title prominently, with the ID beneath it and TASK or NOTE alongside. It inserts the consistent formats `[task:123]` and `[note:456]`. Use arrow keys and Enter/Tab, or click a result. Escape dismisses the picker.

Cached tasks and notes appear immediately. After a 250 ms typing pause, non-empty queries lazily search both entity kinds through the configured typed search service, scoped to the current workspace and room. Results include server-provided titles even for entries never loaded by list pagination, including Done tasks. This does not load all list pages or change their pagination state. If that service is unavailable or lacks typed search support, loaded items remain selectable with an explicit notice. A bare `#` lists loaded items only. Dismissal, query changes, and room/workspace changes discard obsolete search responses.

Both typed references open the relevant entity and offer the existing hover preview. IDs remain exact, including 64-bit IDs. References inside Markdown links and code are not converted. Legacy task references such as `#123` remain supported; the sections below describe that legacy syntax.

## Shared Loading Contracts

- `query-controller.js` owns HTTP search, debounce, cancellation, response validation, and suppression of obsolete room/workspace responses. Chat, Task Search, and Notes each create an independent controller; they retain their own filters, result projections, rendering, and local fallback. Search results never populate the full-entity cache.
- `NRCTasks.requestTask(roomId, taskId, callbacks)` and `NRCAssets.requestAsset(roomId, assetId, callbacks)` own cache-aware exact reads and combine concurrent requests for the same room and ID. Success/error callbacks fan out to all callers; settled requests are removed so failures can be retried. Asset previews do not satisfy a full-payload request.
- Inspector, linked-entity titles, note details, and AI reference previews reuse these exact-read helpers. Selection/generation checks stay at the rendering consumer, since cancelling one view must not discard a shared request needed by another.
- Raw `sendGetTask` / `sendGetAsset` remain available for intentional fresh reads, such as recovery after a failed edit or refreshing a shared note. Do not replace such refreshes with cache hits. Pagination remains owned by the entity lists.

## Features

### 1. Task Reference Parsing
- Automatically detects task references in the format `#123`
- Works in regular chat messages and sent messages
- Multiple references in a single message are all highlighted

**Example:**
```
I completed #123 and started work on #456. These depend on #789.
```

### 2. Visual Highlighting
- Task references appear in **cyan** with an underline, matching the UI accent color
- Hover effect: cyan background with white text (inverted)
- Styled as `.task-reference` class

### 3. Hover Preview
- Hovering over a task reference shows a floating preview card
- Preview displays:
  - Task ID and status code (BL/TD/WP/DN)
  - Title
  - Status (Backlog/Todo/In Progress/Done)
  - Assignee
  - Category/Color
  - Due date (with overdue warning if applicable)
  - First 100 characters of description
- Card appears above/below the reference depending on viewport space
- Card is fixed-position and high z-index (10000)

### 4. Click to Jump
- Clicking a task reference:
  1. Switches to the task's room if different
  2. Opens the kanban board if not visible
  3. Scrolls to the task card
  4. Highlights it with a 2-second cyan flash animation
  5. Logs a system message about the jump

### 5. Error Handling
- If a task doesn't exist, shows a "Task not found" preview
- Gracefully handles invalid references

## Implementation Files

### New Files
- **`task-references.js`** - Core module for parsing, rendering, and preview
- **`TASK_REFERENCES.md`** - This documentation

### Modified Files
- **`index.html`** - Added script tag for `task-references.js`
- **`app.js`** - Integrated task reference processing in `displayMessage()`
- **`css/main.css`** - Added styling for task references and preview cards

## Code Structure

### Main Functions

**`parseTaskReferences(text)`**
- Regex-based parser for `#\d+` pattern
- Returns array of reference objects with position data

**`renderMessageWithTaskReferences(text, roomId)`**
- Creates DOM with interspersed text and task reference elements
- Handles multiple references in a single text node

**`createTaskReferenceElement(taskId, roomId)`**
- Creates the interactive `<span class="task-reference">` element
- Attaches event listeners for hover and click

**`showTaskPreview(element, taskId, roomId)`**
- Shows floating preview card
- Handles positioning (avoids viewport edges)
- Manages card lifecycle

**`createTaskPreviewCard(task)`**
- Renders preview card HTML
- Formats task data for display
- Color-codes status

**`jumpToTask(taskId, roomId)`**
- Switches room, opens kanban, scrolls to task
- Applies highlight animation

**`processMessageTaskReferences(messageElement, roomId)`**
- Post-processing hook called after message is inserted into DOM
- Handles both text nodes and paragraph elements
- Called from `displayMessage()` in `app.js`

## Usage

Users don't need to do anything special. Task references work automatically:

1. **Type references in chat**: `Let me check #123`
2. **Hover** to see task details
3. **Click** to jump to the task in kanban

## CSS Classes & Styling

| Class | Purpose |
|-------|---------|
| `.task-reference` | Inline task reference link |
| `.task-preview-card` | Floating preview container |
| `.task-preview-header` | Preview header with ID and status |
| `.task-preview-status` | Status badge (color-coded) |
| `.task-preview-*` | Various preview sub-components |
| `.task-highlighted` | Animation applied when jumped to |

## Dependencies

- **Requires**: `tasks.js` - For accessing `window.NRCTasks` module
- **Requires**: `app.js` - For accessing `currentRoomId`, `switchToRoom()`, `kanbanVisible`, etc.
- **Optional**: Markdown parser (already in app) for rendering markdown in messages

## Performance Considerations

- **Lazy preview**: Preview card only created on hover (not on page load)
- **Event delegation**: Uses direct element listeners, not bubbling
- **DOM insertion**: Preview card is `position: fixed` (off-flow)
- **Regex caching**: Parser runs only when message is displayed
- **Task lookup**: O(1) lookup in `roomTasks` Map

## Browser Compatibility

- Works in all modern browsers (ES6+ support required)
- Uses `BigInt` for task IDs (requires Node.js 10.4+ or modern browsers)
- CSS animations use standard `@keyframes`

## Future Enhancements

Potential improvements for approach #2 (Activity Feed):

1. **Task Activity Log** - Show task events (created, moved, completed) in chat
2. **Smart Mentions** - `@alice` references person, `#123` references task
3. **Two-way Links** - Task details view shows which chat messages mention it
4. **Rich Embeds** - Option to expand reference inline with full task card
5. **Task Templates** - `/task` command to create tasks with references
6. **Auto-linking** - Automatically detect issue tracker IDs (JIRA, GitHub, etc.)

## Testing

To test the feature:

1. Create a task (Ctrl+K to open kanban, create a task, note its ID)
2. Type a message mentioning the task: `Working on #<id>`
3. Verify reference is highlighted in cyan
4. Hover over reference - preview card should appear
5. Click reference - should jump to task in kanban
6. Check highlight animation on the task

## Known Limitations

- Task references are one-way (chat → task)
- No automatic refresh if task is deleted after reference is displayed
- Preview shows room-scoped data only (can't reference tasks from other rooms... yet)
- No task creation shortcut from chat (separate `/task` command would be next phase)
