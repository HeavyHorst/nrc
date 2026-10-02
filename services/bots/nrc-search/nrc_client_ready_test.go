package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestResetReadyClosesPreviousGeneration(t *testing.T) {
	client, err := NewNRCClient(Config{}, "workspace1", nil, nil, nil)
	if err != nil {
		t.Fatalf("NewNRCClient failed: %v", err)
	}

	previousReady, previousGeneration := client.ReadyState()
	client.resetReady()

	select {
	case <-previousReady:
	default:
		t.Fatal("expected previous ready generation to close on reset")
	}

	currentReady, currentGeneration := client.ReadyState()
	if currentGeneration == previousGeneration {
		t.Fatal("expected ready generation to advance on reset")
	}

	select {
	case <-currentReady:
		t.Fatal("expected current ready generation to remain open before server ready")
	default:
	}

	client.closeReady()
	select {
	case <-currentReady:
	default:
		t.Fatal("expected current ready generation to close when marked ready")
	}
}

func TestWaitForClientReadyIgnoresStaleGeneration(t *testing.T) {
	client, err := NewNRCClient(Config{}, "workspace1", nil, nil, nil)
	if err != nil {
		t.Fatalf("NewNRCClient failed: %v", err)
	}

	errCh := make(chan error, 1)
	go func() {
		errCh <- waitForClientReady(context.Background(), client, 200*time.Millisecond, "workspace1")
	}()

	time.Sleep(10 * time.Millisecond)
	client.resetReady()

	select {
	case err := <-errCh:
		t.Fatalf("wait returned before current generation became ready: %v", err)
	case <-time.After(20 * time.Millisecond):
	}

	client.closeReady()

	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("waitForClientReady returned error: %v", err)
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("waitForClientReady did not return after current generation became ready")
	}
}

func TestSubscribeAndReconcileWaiterReceivesLeaderError(t *testing.T) {
	client, err := NewNRCClient(Config{}, "workspace1", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := errors.New("leader reconciliation failed")
	state := &reconcileState{done: make(chan struct{})}
	client.reconcileDone[7] = state
	result := make(chan error, 1)
	go func() { result <- client.SubscribeAndReconcile(context.Background(), 7) }()

	state.err = want
	close(state.done)
	select {
	case got := <-result:
		if !errors.Is(got, want) {
			t.Fatalf("waiter error = %v, want %v", got, want)
		}
	case <-time.After(time.Second):
		t.Fatal("reconciliation waiter did not return")
	}
}
