package protocol

import (
	"context"
	"encoding/binary"
	"errors"
	"testing"
	"time"
)

func overloadReply(code string, opcode uint16, id uint32) *Message {
	b := make([]byte, 8+len(code))
	binary.BigEndian.PutUint16(b, opcode)
	binary.BigEndian.PutUint16(b[2:], uint16(len(code)))
	copy(b[4:], code)
	binary.BigEndian.PutUint32(b[4+len(code):], id)
	return &Message{Opcode: S_ErrorResponse, Data: b}
}

func TestDatabaseOverloadRetries(t *testing.T) {
	for _, code := range []string{DBConnectionOverloaded, DBWorkerOverloaded} {
		t.Run(code, func(t *testing.T) {
			refusal := overloadReply(code, C_UpdateTask, 73)
			calls := 0
			r, err := RetryDatabaseRequest(context.Background(), C_UpdateTask, 73, func(context.Context) (*Message, error) { calls++; return refusal, nil })
			if err != nil || r != refusal || calls != 4 {
				t.Fatalf("calls=%d, result=%v, err=%v", calls, r, err)
			}
			if DatabaseOverload(refusal, C_DeleteTask, 73) != "" || DatabaseOverload(refusal, C_UpdateTask, 74) != "" {
				t.Fatal("mismatched response retried")
			}
		})
	}
	for _, code := range []string{"Server too busy", "db_worker_overloaded extra", "permission denied"} {
		if _, ok := DatabaseRetryDelay(code, 0); ok {
			t.Fatal(code)
		}
	}
	for _, attempt := range []int{-1, 3, 100} {
		if _, ok := DatabaseRetryDelay(DBWorkerOverloaded, attempt); ok {
			t.Fatal(attempt)
		}
	}
	if d, _ := DatabaseRetryDelay(DBWorkerOverloaded, 2); d != 600*time.Millisecond {
		t.Fatal(d)
	}
}

func TestDatabaseRetryCancellationAndUnknownOutcome(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	_, err := RetryDatabaseRequest(ctx, C_UpdateTask, 73, func(context.Context) (*Message, error) {
		calls++
		cancel()
		return overloadReply(DBWorkerOverloaded, C_UpdateTask, 73), nil
	})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("%d %v", calls, err)
	}
	calls = 0
	_, err = RetryDatabaseRequest(context.Background(), C_UpdateTask, 73, func(context.Context) (*Message, error) { calls++; return nil, context.DeadlineExceeded })
	if !errors.Is(err, context.DeadlineExceeded) || calls != 1 {
		t.Fatalf("%d %v", calls, err)
	}
}

func TestDatabaseOverloadLegacyTaskMutation(t *testing.T) {
	code := DBConnectionOverloaded
	b := make([]byte, 17+len(code))
	binary.BigEndian.PutUint16(b[11:], uint16(len(code)))
	copy(b[13:], code)
	binary.BigEndian.PutUint32(b[13+len(code):], 73)
	r := &Message{Opcode: S_TaskListResponse, Data: b}
	if got := DatabaseOverload(r, C_CreateTask, 73); got != code {
		t.Fatal(got)
	}
	b[8] = 1
	if got := DatabaseOverload(r, C_CreateTask, 73); got != "" {
		t.Fatal("successful read triggered replay")
	}
}
