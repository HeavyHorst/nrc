package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	p "github.com/heavyhorst/nrc/protocol-go"
)

// Rules and revisions are always loaded from NRC.
type runtimeSource interface {
	monitor(context.Context, uint64) (p.Asset, p.MonitorState, error)
	apply(context.Context, p.ApplyMonitorRun) (string, error)
}

func cycle(ctx context.Context, source runtimeSource, history *historyWriter, workspace, nickname string, id uint64) (time.Duration, error) {
	a, state, err := source.monitor(ctx, id)
	if err != nil {
		return 30 * time.Second, monitorError(id, "configuration unavailable")
	}
	c, definition, err := parseMonitor(a)
	if err != nil {
		return 30 * time.Second, monitorError(id, "invalid or unsupported configuration")
	}
	interval := time.Duration(c.Interval)
	if c.Evaluator != nickname {
		return 30 * time.Second, monitorError(id, "different evaluator")
	}
	if !c.Enabled {
		history.requestAvailability(state)
		return min(interval, 30*time.Second), nil
	}
	if state.Sequence == math.MaxUint64 {
		return interval, monitorError(id, "run sequence exhausted")
	}
	var uuid [16]byte
	if _, err := rand.Read(uuid[:]); err != nil {
		return interval, err
	}
	observedAt := time.Now().UnixNano()
	start := time.Now()
	checkCtx, cancel := context.WithTimeout(ctx, time.Duration(c.Timeout))
	var observations []p.MonitorObservation
	var diagnostics *checkDiagnostics
	var queryErr error
	if definition.Kind == "victoriametrics" || definition.Kind == "victorialogs" {
		reader, ok := source.(interface {
			asset(context.Context, uint64) (p.Asset, error)
		})
		queryErr = errors.New("monitoring source unavailable or changed")
		if ok {
			id, _ := strconv.ParseUint(definition.SourceID, 10, 64)
			revision, _ := strconv.ParseInt(definition.SourceRevision, 10, 64)
			asset, err := reader.asset(checkCtx, id)
			if err == nil && asset.UpdatedAt == revision {
				config, err := p.DecodeMonitorSource(asset)
				if err == nil && config.Kind == definition.Kind {
					observations, queryErr = runQuery(checkCtx, definition, config)
				}
			}
		}
	} else {
		result := runCheck(checkCtx, definition)
		observations = []p.MonitorObservation{result.Observation}
		diagnostics = result.Diagnostics
	}
	duration := int64(time.Since(start))
	cancel()
	if ctx.Err() != nil {
		return interval, ctx.Err()
	} // Shutdown is not a target failure.
	run := p.ApplyMonitorRun{CorrelationID: 1, MonitorID: id, Revision: a.UpdatedAt, Sequence: state.Sequence + 1, Failed: queryErr != nil, Observations: observations}
	acceptance, submitErr := source.apply(ctx, run)
	history.offer(historyRun{ID: hex.EncodeToString(uuid[:]), Workspace: workspace, Acceptance: acceptance, Run: run, ObservedAt: observedAt, Duration: duration, Diagnostics: diagnostics})
	if acceptance == "confirmed" {
		history.requestAvailability(p.MonitorState{MonitorID: id, Revision: a.UpdatedAt, Sequence: run.Sequence})
	}
	slog.Info("monitor evaluated", "monitor_id", id, "sequence", run.Sequence, "instances", len(observations), "failed", run.Failed, "acceptance", acceptance)
	return interval, errors.Join(submitErr, queryErr)
}

func schedule(ctx context.Context, ids *monitorSet, workers int, source runtimeSource, history *historyWriter, workspace, nickname string) {
	runMonitorLoops(ctx, ids, workers, func(ctx context.Context, id uint64) time.Duration {
		start := time.Now()
		interval, err := cycle(ctx, source, history, workspace, nickname, id)
		if err != nil && ctx.Err() == nil {
			slog.Warn("monitor cycle failed", "monitor_id", id)
		}
		return interval - time.Since(start)
	})
}

func run() error {
	// DuckDB creates its database, WAL and spill files with process permissions.
	syscall.Umask(0077)
	server := flag.String("server", "", "NRC WebSocket base URL (wss://host)")
	workspace := flag.String("workspace", "", "NRC workspace")
	nickname := flag.String("nickname", "nrc-incidents", "configured evaluator identity")
	monitors := flag.String("monitors", "", "optional fixed monitor IDs (max 1024); empty discovers evaluator-assigned monitors every 30s")
	historyPath := flag.String("history", "", "sidecar-owned DuckDB file")
	historyListen := flag.String("history-listen", "", "optional private HTTP history address (requires NRC_HISTORY_SECRET)")
	workers := flag.Int("workers", 8, "maximum concurrent checks (1..64)")
	flag.Parse()
	u, err := url.Parse(*server)
	if err != nil || (u.Scheme != "wss" && u.Scheme != "ws") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return errors.New("invalid NRC URL")
	}
	if *workspace == "" || *nickname == "" || len(*nickname) > 32 || *workers < 1 || *workers > 64 || *historyPath == "" || strings.Contains(*historyPath, "?") || *historyPath == ":memory:" {
		return errors.New("workspace, nickname, history file and bounded workers are required")
	}
	secret := os.Getenv("NRC_BOT_SECRET")
	if secret == "" {
		return errors.New("NRC_BOT_SECRET is required")
	}
	ids := []uint64{}
	seen := map[uint64]bool{}
	for _, text := range strings.Split(*monitors, ",") {
		if *monitors == "" {
			break
		}
		id, err := strconv.ParseUint(strings.TrimSpace(text), 10, 64)
		if err != nil || id == 0 || seen[id] || len(ids) == 1024 {
			return errors.New("invalid or duplicate monitor IDs")
		}
		seen[id] = true
		ids = append(ids, id)
	}
	if err := os.MkdirAll(filepath.Dir(*historyPath), 0700); err != nil {
		return err
	}
	// Linux deployment, one scheduler per history directory. This lock is not HA.
	lock, err := os.OpenFile(*historyPath+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return errors.New("sidecar data path already in use")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	monitorIDs := newMonitorSet(ids)
	history := newHistoryWriter()
	var historyServer *http.Server
	var historyDone chan error
	if *historyListen != "" {
		historySecret := os.Getenv("NRC_HISTORY_SECRET")
		if len(historySecret) < 32 || strings.TrimSpace(historySecret) != historySecret {
			return errors.New("history listener requires NRC_HISTORY_SECRET of at least 32 characters without surrounding whitespace")
		}
		listener, err := net.Listen("tcp", *historyListen)
		if err != nil {
			return errors.New("history listener unavailable")
		}
		historyServer = &http.Server{
			Handler:           newHistoryAPI(history, *workspace, historySecret, monitorIDs),
			ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 5 * time.Second,
			WriteTimeout: 10 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10,
			BaseContext: func(net.Listener) context.Context { return ctx },
		}
		historyDone = make(chan error, 1)
		go func() {
			err := historyServer.Serve(listener)
			if errors.Is(err, http.ErrServerClosed) {
				err = nil
			}
			historyDone <- err
			cancel()
		}()
	}
	var writer sync.WaitGroup
	writer.Add(3)
	go func() { defer writer.Done(); history.serve(ctx, *historyPath) }()
	source := nrcSource{*server, *workspace, *nickname, secret}
	if *monitors == "" {
		writer.Add(1)
		go func() { defer writer.Done(); refreshMonitors(ctx, monitorIDs, source.discover, 30*time.Second) }()
	}
	go func() { defer writer.Done(); dispatchWebhooks(ctx, monitorIDs, *workers, source, *workspace) }()
	go func() { defer writer.Done(); collectAvailability(ctx, history, source, *workspace, *workers) }()
	schedule(ctx, monitorIDs, *workers, source, history, *workspace, *nickname)
	if historyServer != nil {
		shutdownCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		if err := historyServer.Shutdown(shutdownCtx); err != nil {
			historyServer.Close()
		}
		stop()
	}
	writer.Wait()
	slog.Info("sidecar stopped", "history_dropped", history.dropped.Load(), "history_pending", len(history.queue)+len(history.snapshots)+len(history.availability))
	if historyDone != nil {
		return <-historyDone
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
