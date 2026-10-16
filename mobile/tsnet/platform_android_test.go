package tailnet

import (
	"errors"
	"os"
	"testing"

	"tailscale.com/net/netmon"
)

type snapshotFixture struct {
	err error
}

func (s *snapshotFixture) Snapshot() (string, error) {
	if s.err != nil {
		return "not JSON", s.err
	}
	return `[{"Name":"fixture","Index":7,"MTU":1500,"Up":true,"Addresses":["10.20.30.40/24","fe80::1%fixture/64"]}]`, nil
}

// Explicit source-file arguments allow this Android bridge contract to run on
// the host too: go test -race platform_android.go platform_android_test.go
func TestBridgeCallbackError(t *testing.T) {
	for _, name := range []string{"HOME", "TMPDIR", "TS_LOGS_DIR"} {
		t.Setenv(name, os.Getenv(name))
	}
	failure := errors.New("enumeration failed")
	source := &snapshotFixture{err: failure}
	if err := Initialize(t.TempDir(), source); err != nil {
		t.Fatal(err)
	}
	if got, err := netmon.GetInterfaceList(); !errors.Is(err, failure) || got != nil {
		t.Fatalf("callback error must propagate before parsing: %v %v", got, err)
	}
	source.err = nil
	got, err := netmon.GetInterfaceList()
	if err != nil || len(got) != 1 || got[0].Name != "fixture" || len(got[0].AltAddrs) != 2 || got[0].AltAddrs[1].String() != "fe80::1%fixture" {
		t.Fatalf("valid callback did not recover: %v %v", got, err)
	}
}
