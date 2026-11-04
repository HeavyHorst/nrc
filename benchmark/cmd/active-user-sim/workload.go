package main

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"sync"
	"time"

	protocol "github.com/heavyhorst/nrc/protocol-go"
)

type taskState struct {
	Title, Description string
	Status, Priority   uint8
}

func stateOf(t *protocol.Task) taskState {
	return taskState{t.Title, t.Description, t.Status, t.Priority}
}

type event struct {
	start    time.Time
	measured bool
	// 0: excluded; 1: expected; 2: observed. One byte per workspace actor.
	observers      []byte
	remaining      int
	state          taskState
	asset          assetState
	edge           protocol.Edge
	id             uint64
	content        string
	room, seq, ack uint64
	author         string
	accepted       bool
}

type workspace struct {
	name            string
	index           int
	sim             *simulation
	actors          []*actor
	taskIDs         []uint64
	assetIDs        []uint64
	edgeIDs         []uint64
	mu              sync.Mutex
	tasks, messages map[string]*event
	assets, edges   map[string]*event
}

// Caller holds workspace.mu. Register before writing so a fast broadcast cannot outrun its expectation.
func (w *workspace) expect(sender *actor, room uint64, measured bool) *event {
	e := &event{start: time.Now(), measured: measured, room: room, observers: make([]byte, len(w.actors))}
	for i, a := range w.actors {
		if a.subscribed && (room == 0 || (a.room == room && a != sender)) {
			e.observers[i] = 1
			e.remaining++
		}
	}
	return e
}

func (a *actor) observe(e *event, kind string) error {
	if e == nil {
		return fmt.Errorf("unknown %s event (foreign workspace or untracked write)", kind)
	}
	switch e.observers[a.local] {
	case 0:
		return fmt.Errorf("%s delivered to excluded user %d", kind, a.id)
	case 2:
		return fmt.Errorf("duplicate %s delivery to user %d", kind, a.id)
	}
	e.observers[a.local] = 2
	e.remaining--
	e.accepted = true
	a.ws.sim.metrics.count("deliveries_"+kind, 1)
	if e.measured {
		a.ws.sim.metrics.record("delivery_"+kind, time.Since(e.start))
	}
	return nil
}

func (a *actor) observeTask(t *protocol.Task) error {
	w := a.ws
	w.mu.Lock()
	defer w.mu.Unlock()
	if t.ConvID != protocol.WorkspaceDataConvID {
		return fmt.Errorf("task outside workspace-data scope")
	}
	e := w.tasks[t.Title]
	if e == nil || stateOf(t) != e.state || t.ID == 0 || (e.id != 0 && e.id != t.ID) {
		return fmt.Errorf("unknown/corrupt task title %q", t.Title)
	}
	e.id = t.ID
	if err := a.observe(e, "task"); err != nil {
		return err
	}
	a.cache[t.ID] = stateOf(t)
	return nil
}

func messageKey(id protocol.ClientMessageID) string { return hex.EncodeToString(id[:]) }

func (a *actor) observeMessage(m protocol.RetainedMessage) error {
	w := a.ws
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.messages[messageKey(m.ClientMessageID)]
	if err := checkMessage(e, m); err != nil {
		return err
	}
	return a.observe(e, "chat")
}

func checkMessage(e *event, m protocol.RetainedMessage) error {
	if e == nil || m.Sequence == 0 || m.ConvID != e.room || m.Content != e.content || m.Username != e.author || m.ContentType != protocol.ContentTypePlainText {
		return fmt.Errorf("unknown, unauthorized or corrupt retained message %s", messageKey(m.ClientMessageID))
	}
	if (e.seq != 0 && e.seq != m.Sequence) || (e.ack != 0 && e.ack != m.Sequence) {
		return fmt.Errorf("retained message sequence mismatch")
	}
	e.seq = m.Sequence
	return nil
}

func (w *workspace) seed(ctx context.Context) error {
	a := w.actors[0]
	for i := 0; i < min(8, len(w.actors)); i++ {
		title := fmt.Sprintf("%s-seed-%d", w.name, i)
		state := taskState{Title: title, Description: "active user simulation", Priority: 1}
		w.mu.Lock()
		e := w.expect(a, 0, false)
		e.state = state
		w.tasks[title] = e
		w.mu.Unlock()
		r, err := a.request(ctx, "create_task", false, func(id uint32) (uint16, []byte, error) {
			return protocol.C_CreateTask, protocol.EncodeTaskCreateWithCorrelation(0, title, state.Description, 1, id), nil
		})
		if err != nil {
			return err
		}
		w.taskIDs = append(w.taskIDs, r.data.(*protocol.Task).ID)
	}
	// A retained write plus idempotent retry proves retention is enabled before measurement.
	if err := w.seedRecords(ctx); err != nil {
		return err
	}
	return a.chat(ctx, false, true)
}

func (a *actor) mutate(ctx context.Context, measured bool) error {
	w := a.ws
	a.action++
	title := fmt.Sprintf("%s-u%d-v%d", w.name, a.id, a.action)
	state := taskState{title, "edited by a subscribed user", uint8(a.action % 4), uint8(a.action % 3)}
	w.mu.Lock()
	e := w.expect(a, 0, measured)
	e.state = state
	e.id = w.taskIDs[a.local%len(w.taskIDs)]
	w.tasks[title] = e
	w.mu.Unlock()
	taskID := w.taskIDs[a.local%len(w.taskIDs)]
	_, err := a.request(ctx, "update_task", measured, func(id uint32) (uint16, []byte, error) {
		return protocol.C_UpdateTask, protocol.EncodeTaskUpdateWithCorrelation(0, int64(taskID), title, state.Description, int32(state.Status), int32(state.Priority), 0, id), nil
	})
	return err
}

func (a *actor) getTask(ctx context.Context, id uint64, measured bool) (taskState, error) {
	r, err := a.request(ctx, "read_task", measured, func(corr uint32) (uint16, []byte, error) {
		return protocol.C_GetTask, protocol.EncodeGetTask(0, id, corr), nil
	})
	if err != nil {
		return taskState{}, err
	}
	v := r.data.(*protocol.TaskFull)
	if !v.Success || v.Task == nil || v.ConvID != 0 || v.Task.ID != id {
		return taskState{}, fmt.Errorf("task read failed or returned wrong identity")
	}
	state := stateOf(v.Task)
	a.ws.mu.Lock()
	e := a.ws.tasks[state.Title]
	valid := e != nil && e.state == state
	a.ws.mu.Unlock()
	if !valid {
		return state, fmt.Errorf("task read contains unrecognized state")
	}
	// A read can be interleaved with broadcasts; only quiescent reconciliation compares current values.
	return state, nil
}

func (a *actor) chat(ctx context.Context, measured, retry bool) error {
	w := a.ws
	a.action++
	var id protocol.ClientMessageID
	binary.BigEndian.PutUint64(id[:8], uint64(a.id+1))
	binary.BigEndian.PutUint64(id[8:], a.action)
	content := fmt.Sprintf("%s user=%d action=%d retained message", w.name, a.id, a.action)
	w.mu.Lock()
	e := w.expect(a, a.room, measured)
	e.content = content
	e.author = fmt.Sprintf("sim-%d", a.id)
	w.messages[messageKey(id)] = e
	w.mu.Unlock()
	send := func(kind string) error {
		r, err := a.request(ctx, kind, measured, func(corr uint32) (uint16, []byte, error) {
			b, e := protocol.EncodeSendMessageV2(a.room, id, corr, protocol.ContentTypePlainText, content)
			return protocol.C_SendMessageV2, b, e
		})
		if err != nil {
			return err
		}
		ack := r.data.(*protocol.AckSendMessage)
		w.mu.Lock()
		defer w.mu.Unlock()
		if ack.AssignedSeq == 0 || (e.ack != 0 && e.ack != ack.AssignedSeq) || (e.seq != 0 && e.seq != ack.AssignedSeq) {
			w.sim.metrics.fail("correctness", "retained ACK/retry sequence mismatch")
			return fmt.Errorf("retained ACK/retry sequence mismatch")
		}
		e.ack = ack.AssignedSeq
		e.accepted = true
		return nil
	}
	if err := send("retained_send"); err != nil {
		return err
	}
	if retry {
		return send("retained_retry")
	}
	return nil
}

func (w *workspace) reconcile(ctx context.Context, refresh *actor) error {
	// A response on one socket is not a delivery barrier on another socket.
	if err := parallel(ctx, len(w.actors), 16, func(i int) error {
		_, err := w.actors[i].request(ctx, "reconcile_barrier", false, pingRequest)
		return err
	}); err != nil {
		return err
	}
	for _, id := range w.taskIDs {
		state, err := w.actors[len(w.actors)-1].getTask(ctx, id, false)
		if err != nil {
			return err
		}
		w.mu.Lock()
		for _, a := range w.actors {
			if a == refresh {
				a.cache[id] = state
				continue
			}
			if a.subscribed && a.cache[id] != state {
				w.sim.metrics.fail("correctness", fmt.Sprintf("workspace %s user %d cache diverged for task %d", w.name, a.id, id))
			}
		}
		w.mu.Unlock()
	}
	return w.reconcileRecords(ctx, refresh)
}

func (a *actor) history(ctx context.Context) error {
	w := a.ws
	seen := make(map[string]uint64)
	var cursor uint64
	high := a.readyHigh
	w.mu.Lock()
	var last uint64
	for _, e := range w.messages {
		if e.room == a.room {
			last = max(last, e.ack)
		}
	}
	w.mu.Unlock()
	pages := 0
	for {
		r, err := a.request(ctx, "history", false, func(id uint32) (uint16, []byte, error) {
			b, e := protocol.EncodeReplayMessagesAfter(a.room, cursor, 100, id)
			return protocol.C_ReplayMessagesAfter, b, e
		})
		if err != nil {
			return err
		}
		page := r.data.(*protocol.MessagePage)
		if page.ConvID != a.room || !page.Ascending || page.Truncated {
			return fmt.Errorf("history scope/order/retention invalid for unexpired fixture")
		}
		// The disposable shard starts at sequence 1 and nothing expires in this run.
		if page.HighWaterSeq < high || page.HighWaterSeq < last || page.RetentionCutoffSeq != 1 {
			return fmt.Errorf("invalid history high-water/retention boundary")
		}
		high = page.HighWaterSeq
		pages++
		for _, m := range page.Messages {
			if m.Sequence <= cursor || m.Sequence > high {
				return fmt.Errorf("history duplicate/out-of-order sequence")
			}
			cursor = m.Sequence
			key := messageKey(m.ClientMessageID)
			if _, ok := seen[key]; ok {
				return fmt.Errorf("deduplication failed: duplicate stored message")
			}
			seen[key] = m.Sequence
			w.mu.Lock()
			e := w.messages[key]
			err := checkMessage(e, m)
			w.mu.Unlock()
			if err != nil {
				return err
			}
		}
		var continuation uint64
		if len(page.Messages) > 0 {
			continuation = cursor
		}
		if page.ContinuationCursor != continuation || page.HasMore != (cursor < last) || (page.HasMore && len(page.Messages) == 0) {
			return fmt.Errorf("history pagination made no progress")
		}
		if !page.HasMore {
			break
		}
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for key, e := range w.messages {
		if e.room != a.room {
			continue
		}
		if e.ack != 0 && seen[key] != e.ack {
			return fmt.Errorf("acknowledged retained message missing from history: %s", key)
		}
		if e.ack == 0 && seen[key] != 0 {
			w.sim.metrics.count("unknown_writes_found_in_history", 1)
		}
	}
	w.sim.metrics.count("history_messages_verified", int64(len(seen)))
	if pages > 1 {
		w.sim.metrics.count("paginated_histories_verified", 1)
	}
	return nil
}

func (w *workspace) verify(ctx context.Context) error {
	if err := w.reconcile(ctx, nil); err != nil {
		return err
	}
	// Check one user per room. Everyone else remains subscribed and continuously drains events.
	visited := make(map[uint64]bool)
	for _, a := range w.actors {
		if visited[a.room] {
			continue
		}
		visited[a.room] = true
		var peer *actor
		for _, b := range w.actors {
			if b != a && b.room == a.room {
				peer = b
				break
			}
		}
		if peer == nil {
			return fmt.Errorf("room lacks a peer for lifecycle checks")
		}
		_, err := a.request(ctx, "unsubscribe", false, func(id uint32) (uint16, []byte, error) {
			return protocol.C_UnsubscribeConvs, protocol.EncodeUnsubscribeConvsWithCorrelation(id, 0, int64(a.room)), nil
		})
		if err != nil {
			return err
		}
		w.mu.Lock()
		a.subscribed = false
		w.mu.Unlock()
		if err = peer.mutate(ctx, false); err != nil {
			return err
		}
		if err = peer.chat(ctx, false, true); err != nil {
			return err
		}
		if _, err = a.request(ctx, "unsubscribed_barrier", false, pingRequest); err != nil {
			return err
		}
		w.sim.metrics.count("unsubscribe_checks", 1)
		a.close()
		// Write while this user is offline; history must recover the missed message.
		if err = peer.chat(ctx, false, false); err != nil {
			return err
		}
		start := time.Now()
		if err = a.connect(ctx); err != nil {
			return err
		}
		if err = a.history(ctx); err != nil {
			w.sim.metrics.fail("correctness", err.Error())
			return err
		}
		if err = w.reconcile(ctx, a); err != nil {
			return err
		}
		w.sim.metrics.record("recovery", time.Since(start))
		w.sim.metrics.count("reconnect_checks", 1)
	}
	return w.deleteRecords(ctx)
}
