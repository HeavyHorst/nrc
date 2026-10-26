package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

// The worker runs the authoritative image/audio preprocessing and encoders.
// The Go text backbone turns their projected features into searchable vectors.
type mediaWorker struct {
	mu  sync.Mutex
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Scanner
}

type mediaResponse struct {
	Features  []float32 `json:"features"`
	Tokens    int       `json:"tokens"`
	Data      string    `json:"data"`
	LocalOnly bool      `json:"local_only"`
	Error     string    `json:"error"`
}

func (w *mediaWorker) features(kind, path string, offset int) ([]float32, int, error) {
	response, err := w.request(kind, path, offset, false)
	if err != nil {
		return nil, 0, err
	}
	if response.Tokens < 0 || response.Tokens > 750 || len(response.Features) != response.Tokens*512 {
		return nil, 0, fmt.Errorf("invalid media feature shape")
	}
	return response.Features, response.Tokens, nil
}

func (w *mediaWorker) request(kind, path string, offset int, prepare bool) (mediaResponse, error) {
	var response mediaResponse
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.cmd == nil {
		cmd := exec.Command("node", envOrDefault("MEDIA_WORKER_PATH", "./media_worker.mjs"))
		cmd.Stderr = os.Stderr
		in, err := cmd.StdinPipe()
		if err != nil {
			return response, err
		}
		out, err := cmd.StdoutPipe()
		if err != nil {
			in.Close()
			return response, err
		}
		if err := cmd.Start(); err != nil {
			in.Close()
			return response, err
		}
		w.cmd, w.in = cmd, in
		w.out = bufio.NewScanner(out)
		w.out.Buffer(make([]byte, 4096), 16*1024*1024)
	}
	cmd := w.cmd
	timer := time.AfterFunc(2*time.Minute, func() { _ = cmd.Process.Kill() })
	defer timer.Stop()
	request := struct {
		Kind    string `json:"kind"`
		Path    string `json:"path"`
		Offset  int    `json:"offset"`
		Prepare bool   `json:"prepare,omitempty"`
	}{kind, path, offset, prepare}
	if err := json.NewEncoder(w.in).Encode(request); err != nil {
		w.stop()
		return response, fmt.Errorf("media worker write: %w", err)
	}
	if !w.out.Scan() {
		w.stop()
		return response, fmt.Errorf("media worker stopped or timed out")
	}
	if err := json.Unmarshal(w.out.Bytes(), &response); err != nil {
		w.stop()
		return response, err
	}
	if response.Error != "" {
		return response, fmt.Errorf("media worker: %s", response.Error)
	}
	return response, nil
}

func (w *mediaWorker) stop() {
	if w.cmd != nil {
		w.in.Close()
		_ = w.cmd.Process.Kill()
		_ = w.cmd.Wait()
		w.cmd = nil
	}
}

func (w *mediaWorker) Close() { w.mu.Lock(); defer w.mu.Unlock(); w.stop() }
