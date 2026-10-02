package scenario

import (
	"testing"

	"github.com/cespare/xxhash/v2"
)

func TestConfiguredServerURLs(t *testing.T) {
	tests := []struct {
		name    string
		config  Config
		wantLen int
		wantErr bool
	}{
		{
			name:    "legacy single URL",
			config:  Config{ServerURL: "ws://127.0.0.1:8080", NumWorkspaces: 4},
			wantLen: 1,
		},
		{
			name: "one URL per workspace",
			config: Config{
				ServerURLs:    []string{"ws://127.0.0.1:8082", "ws://127.0.0.1:8083"},
				NumWorkspaces: 2,
			},
			wantLen: 2,
		},
		{
			name: "one explicit URL for all workspaces",
			config: Config{
				ServerURLs:    []string{"ws://127.0.0.1:8080"},
				NumWorkspaces: 4,
			},
			wantLen: 1,
		},
		{
			name: "URL count mismatch",
			config: Config{
				ServerURLs:    []string{"ws://127.0.0.1:8082", "ws://127.0.0.1:8083"},
				NumWorkspaces: 4,
			},
			wantErr: true,
		},
		{
			name:    "empty URL",
			config:  Config{ServerURLs: []string{""}, NumWorkspaces: 1},
			wantErr: true,
		},
		{
			name:    "no workspaces",
			config:  Config{ServerURL: "ws://127.0.0.1:8080"},
			wantErr: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			urls, err := configuredServerURLs(test.config)
			if test.wantErr {
				if err == nil {
					t.Fatalf("configuredServerURLs() error = nil, want error")
				}
				return
			}
			if err != nil {
				t.Fatalf("configuredServerURLs() error = %v", err)
			}
			if len(urls) != test.wantLen {
				t.Fatalf("configuredServerURLs() returned %d URLs, want %d", len(urls), test.wantLen)
			}
		})
	}
}

func TestServerURLForWorkspace(t *testing.T) {
	if got := serverURLForWorkspace([]string{"ws://single"}, 3); got != "ws://single" {
		t.Fatalf("single endpoint = %q, want ws://single", got)
	}

	servers := []string{"ws://worker-0", "ws://worker-1", "ws://worker-2", "ws://worker-3"}
	for i, want := range servers {
		if got := serverURLForWorkspace(servers, i); got != want {
			t.Fatalf("workspace %d endpoint = %q, want %q", i, got, want)
		}
	}
}

func TestGeneratedWorkspacesCoverScalingWorkers(t *testing.T) {
	for _, workers := range []int{1, 2, 4} {
		workspaceIDs := generateDistributedWorkspaceIDs(workers)
		for wantWorker, workspaceID := range workspaceIDs {
			shard := xxhash.Sum64String(workspaceID) % 256
			gotWorker := int(shard % uint64(workers))
			if gotWorker != wantWorker {
				t.Fatalf(
					"%d workers: workspace %q maps to worker %d, want %d",
					workers,
					workspaceID,
					gotWorker,
					wantWorker,
				)
			}
		}
	}
}

func TestConversationOccupancyIsIndependentOfWorkspaceCount(t *testing.T) {
	const (
		usersPerWorkspace = 800
		conversations     = 10
		convsPerUser      = 3
		wantOccupancy     = 240
	)

	for _, workspaceCount := range []int{1, 2, 4} {
		occupancy := make([][]int, workspaceCount)
		for i := range occupancy {
			occupancy[i] = make([]int, conversations)
		}

		for userID := 0; userID < usersPerWorkspace*workspaceCount; userID++ {
			workspaceIndex, workspaceUserID := workspaceAssignment(userID, workspaceCount)
			for j := 0; j < convsPerUser; j++ {
				conversationIndex := (workspaceUserID + j) % conversations
				occupancy[workspaceIndex][conversationIndex]++
			}
		}

		for workspaceIndex, conversations := range occupancy {
			for conversationIndex, got := range conversations {
				if got != wantOccupancy {
					t.Fatalf(
						"%d workspaces: workspace %d conversation %d occupancy = %d, want %d",
						workspaceCount,
						workspaceIndex,
						conversationIndex,
						got,
						wantOccupancy,
					)
				}
			}
		}
	}
}
