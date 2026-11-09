package personalmemory_test

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	memory "nrc-ai/personal_memory"
)

func TestSearchPrioritizesLatestCorrection(t *testing.T) {
	store, err := memory.Open(filepath.Join(t.TempDir(), "private", "memory.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "owner", "workspace")
	for i := 0; i < 11; i++ {
		text := "unrelated"
		if i >= 4 {
			text = strings.Repeat("Lavendel old answer ", 20)
		}
		if _, err := s.Append(t.Context(), fmt.Sprint(i), "chat", "complete", []memory.Record{{Role: "assistant", Text: text}}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.Append(t.Context(), "correction", "chat", "complete", []memory.Record{{Role: "user", Text: "Correction: Lavendel Otto"}}); err != nil {
		t.Fatal(err)
	}
	for _, other := range []*memory.Scope{scope(t, store, "other", "workspace"), scope(t, store, "owner", "other")} {
		if _, err := other.Append(t.Context(), "private", "chat", "complete", []memory.Record{{Role: "user", Text: "Lavendel private"}}); err != nil {
			t.Fatal(err)
		}
	}
	ids, err := s.Search(t.Context(), "Lavendel", 3)
	if err != nil || !reflect.DeepEqual(ids, []int64{11, 10, 9}) {
		t.Fatal("latest correction lost, wrong limit/order or cross-scope evidence", ids, err)
	}
}

func TestVoiceFragmentCrashDurability(t *testing.T) {
	path := os.Getenv("NRC_TEST_VOICE_CAPTURE_DB")
	if path != "" {
		store, err := memory.Open(path)
		if err != nil {
			t.Fatal(err)
		}
		s := scope(t, store, "owner", "workspace")
		start, end := int64(10), int64(20)
		first := memory.Record{Role: "user", Text: " Lavendel", EventID: "one", ProviderSession: "live", StartMS: &start, EndMS: &end}
		seg, err := s.Append(t.Context(), "voice", "voice", "active", []memory.Record{first})
		if err != nil {
			t.Fatal(err)
		}
		second := memory.Record{Role: "user", Text: " Otto", EventID: "two", ProviderSession: "live"}
		seg, err = s.AppendFragment(t.Context(), seg.Sequence, seg.Revision, second)
		if err != nil {
			t.Fatal(err)
		}
		duplicate, err := s.AppendFragment(t.Context(), seg.Sequence, seg.Revision, second)
		if err != nil || !reflect.DeepEqual(duplicate, seg) {
			t.Fatal("duplicate", duplicate, err)
		}
		if _, err := s.AppendFragment(t.Context(), seg.Sequence, seg.Revision-1, second); !errors.Is(err, memory.ErrConflict) {
			t.Fatal("revision fence", err)
		}
		second.Text = "rewritten"
		if _, err := s.AppendFragment(t.Context(), seg.Sequence, seg.Revision, second); !errors.Is(err, memory.ErrConflict) {
			t.Fatal("original replacement", err)
		}
		large := memory.Record{Role: "user", Text: strings.Repeat("x", memory.MaxOriginalBytes), EventID: "large"}
		if _, err := s.AppendFragment(t.Context(), seg.Sequence, seg.Revision, large); !errors.Is(err, memory.ErrOriginalLimit) {
			t.Fatal("encoded bound", err)
		}
		if err := s.Finish(t.Context(), seg.Sequence, seg.Revision, "active", seg.Records); err == nil {
			t.Fatal("Finish accepted active")
		}
		os.Exit(0) // No Close/checkpoint: accepted events must survive abrupt exit.
	}
	path = filepath.Join(t.TempDir(), "private", "memory.db")
	cmd := exec.Command(os.Args[0], "-test.run=^TestVoiceFragmentCrashDurability$")
	cmd.Env = append(os.Environ(), "NRC_TEST_VOICE_CAPTURE_DB="+path)
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("child: %v %s", err, output)
	}
	store, err := memory.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	s := scope(t, store, "owner", "workspace")
	seg, err := s.Read(t.Context(), 0)
	if err != nil || seg.State != "incomplete" || seg.Revision != 3 || len(seg.Records) != 2 {
		t.Fatal(seg, err)
	}
	if seg.Records[0].Text != " Lavendel" || seg.Records[1].Text != " Otto" || *seg.Records[0].StartMS != 10 || *seg.Records[0].EndMS != 20 {
		t.Fatal("evidence changed", seg)
	}
	ids, err := s.Search(t.Context(), "Lavendel AND Otto", 10)
	if err != nil || len(ids) != 1 || ids[0] != 0 {
		t.Fatal(ids, err)
	}
	if _, err := s.AppendFragment(t.Context(), 0, seg.Revision, memory.Record{Role: "user", EventID: "late"}); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("reopened terminal", err)
	}
	lease, _, release, err := s.Execution(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	active, err := lease.Append(t.Context(), "new", "voice", "active", []memory.Record{{Role: "user", EventID: "new"}})
	if err != nil {
		t.Fatal(err)
	}
	policy, err := s.Retention(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if err := s.Configure(t.Context(), policy); err != nil {
		t.Fatal(err)
	}
	if _, err := lease.AppendFragment(t.Context(), active.Sequence, active.Revision, memory.Record{Role: "user", EventID: "stale"}); !errors.Is(err, memory.ErrConflict) {
		t.Fatal("epoch fence", err)
	}
}
