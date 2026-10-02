package protocol

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// readRepositoryFile reads a path relative to the repository root, resolved from
// this test's own location so the test works from any working directory.
func readRepositoryFile(t *testing.T, path string) string {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not locate protocol-go source directory")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(currentFile), "..", path))
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}

// odinOpcodes parses the Opcode enum from protocol/types.odin. It reads the enum
// body only, so the reserved-opcode comments around it cannot contribute, and it
// honours Odin's implicit values: an entry with no `= N` continues from the
// previous one.
func odinOpcodes(t *testing.T) map[string]int {
	t.Helper()
	source := readRepositoryFile(t, "protocol/types.odin")
	start := strings.Index(source, "Opcode :: enum u16 {")
	if start < 0 {
		t.Fatal("Opcode enum not found in protocol/types.odin")
	}
	body := source[start:]
	if end := strings.Index(body, "\n}"); end >= 0 {
		body = body[:end]
	}

	explicit := regexp.MustCompile(`^\s*(C_[A-Za-z0-9_]+|S_[A-Za-z0-9_]+)\s*=\s*(\d+)\s*,?`)
	implicit := regexp.MustCompile(`^\s*(C_[A-Za-z0-9_]+|S_[A-Za-z0-9_]+)\s*,`)
	opcodes := map[string]int{}
	next := 0
	for _, line := range strings.Split(body, "\n") {
		if match := explicit.FindStringSubmatch(line); match != nil {
			value, err := strconv.Atoi(match[2])
			if err != nil {
				t.Fatalf("parse opcode %s: %v", match[1], err)
			}
			opcodes[match[1]] = value
			next = value + 1
			continue
		}
		if match := implicit.FindStringSubmatch(line); match != nil {
			opcodes[match[1]] = next
			next++
		}
	}
	if len(opcodes) == 0 {
		t.Fatal("no opcodes parsed from protocol/types.odin")
	}
	return opcodes
}

// readmeOpcodes parses the two opcode tables in protocol/README.md.
func readmeOpcodes(t *testing.T) map[string]int {
	t.Helper()
	readme := readRepositoryFile(t, "protocol/README.md")
	// A table row is `| 56 | `C_ListTaskSlices` | ... |`. Range rows such as
	// `| 4, 5 | *reserved* |` do not name an opcode and are skipped.
	row := regexp.MustCompile("(?m)^\\|\\s*(\\d+)\\s*\\|\\s*`(C_[A-Za-z0-9_]+|S_[A-Za-z0-9_]+)`")
	opcodes := map[string]int{}
	for _, match := range row.FindAllStringSubmatch(readme, -1) {
		value, err := strconv.Atoi(match[1])
		if err != nil {
			t.Fatalf("parse opcode %s: %v", match[2], err)
		}
		if previous, duplicate := opcodes[match[2]]; duplicate {
			t.Fatalf("protocol/README.md documents %s twice (%d, %d)", match[2], previous, value)
		}
		opcodes[match[2]] = value
	}
	if len(opcodes) == 0 {
		t.Fatal("no opcodes parsed from protocol/README.md")
	}
	return opcodes
}

// TestReadmeOpcodeTablesMatchProtocol keeps protocol/README.md honest. The
// document is the map for anyone adding an opcode, so a stale table sends them
// to the wrong number or hides an opcode that already exists.
func TestReadmeOpcodeTablesMatchProtocol(t *testing.T) {
	odin := odinOpcodes(t)
	readme := readmeOpcodes(t)

	for name, value := range odin {
		documented, present := readme[name]
		if !present {
			t.Errorf("protocol/types.odin defines %s = %d but protocol/README.md does not document it", name, value)
			continue
		}
		if documented != value {
			t.Errorf("%s = %d in protocol/types.odin but %d in protocol/README.md", name, value, documented)
		}
	}
	for name, value := range readme {
		if _, present := odin[name]; !present {
			t.Errorf("protocol/README.md documents %s = %d but protocol/types.odin does not define it", name, value)
		}
	}
}

// expandRanges turns "1-3, 8, 16-56" into the set of opcodes it names.
func expandRanges(t *testing.T, spec string) map[int]bool {
	t.Helper()
	set := map[int]bool{}
	for _, part := range strings.Split(spec, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		bounds := strings.SplitN(part, "-", 2)
		low, err := strconv.Atoi(strings.TrimSpace(bounds[0]))
		if err != nil {
			t.Fatalf("parse range %q: %v", part, err)
		}
		high := low
		if len(bounds) == 2 {
			high, err = strconv.Atoi(strings.TrimSpace(bounds[1]))
			if err != nil {
				t.Fatalf("parse range %q: %v", part, err)
			}
		}
		if high < low {
			t.Fatalf("range %q is inverted", part)
		}
		for value := low; value <= high; value++ {
			set[value] = true
		}
	}
	return set
}

func sameSet(a, b map[int]bool) (missing, extra []int) {
	for value := range a {
		if !b[value] {
			missing = append(missing, value)
		}
	}
	for value := range b {
		if !a[value] {
			extra = append(extra, value)
		}
	}
	sort.Ints(missing)
	sort.Ints(extra)
	return
}

// TestReadmeOpcodeRangesMatchGetOpcode keeps the accepted ranges in the document
// equal to the ranges the server enforces, per side. Comparing the whole set
// rather than a boundary value is what catches a range that was widened to
// swallow an opcode it does not own: the client and server ranges are adjacent,
// so a boundary probe alone can be satisfied by the other side.
func TestReadmeOpcodeRangesMatchGetOpcode(t *testing.T) {
	source := readRepositoryFile(t, "protocol/protocol.odin")
	condition := regexp.MustCompile(`status_code >= (\d+) && status_code <= (\d+)`)
	exact := regexp.MustCompile(`status_code == (\d+)`)

	enforced := map[int]bool{}
	for _, match := range condition.FindAllStringSubmatch(source, -1) {
		low, _ := strconv.Atoi(match[1])
		high, _ := strconv.Atoi(match[2])
		for value := low; value <= high; value++ {
			enforced[value] = true
		}
	}
	for _, match := range exact.FindAllStringSubmatch(source, -1) {
		value, _ := strconv.Atoi(match[1])
		enforced[value] = true
	}
	if len(enforced) == 0 {
		t.Fatal("no opcode ranges found in protocol/protocol.odin get_opcode")
	}

	// The comment above the checks declares which side owns which range.
	declared := regexp.MustCompile(`(?m)^\s*//\s*(Client|Server) opcodes:\s*([0-9,\-\s]+)\s*$`)
	declaredClient, declaredServer := map[int]bool{}, map[int]bool{}
	for _, match := range declared.FindAllStringSubmatch(source, -1) {
		set := expandRanges(t, match[2])
		if match[1] == "Client" {
			declaredClient = set
		} else {
			declaredServer = set
		}
	}
	if len(declaredClient) == 0 || len(declaredServer) == 0 {
		t.Fatal("get_opcode must declare one client and one server opcode range comment")
	}
	combined := map[int]bool{}
	for value := range declaredClient {
		combined[value] = true
	}
	for value := range declaredServer {
		combined[value] = true
	}
	if missing, extra := sameSet(enforced, combined); len(missing) > 0 || len(extra) > 0 {
		t.Errorf("get_opcode conditions and its range comment disagree: enforced-only %v, comment-only %v", missing, extra)
	}

	// The document states the ranges as bullets. Backticks are stripped before
	// expansion so the regex does not need to embed one.
	readme := readRepositoryFile(t, "protocol/README.md")
	documented := regexp.MustCompile(`(?m)^- (Client|Server) to (?:server|client):\s*(.+)$`)
	found := documented.FindAllStringSubmatch(readme, -1)
	if len(found) != 2 {
		t.Fatalf("expected two documented opcode range bullets, found %d", len(found))
	}
	for _, match := range found {
		spec := strings.ReplaceAll(match[2], "`", "")
		documented := expandRanges(t, spec)
		declared := declaredClient
		label := "client"
		if match[1] == "Server" {
			declared = declaredServer
			label = "server"
		}
		if missing, extra := sameSet(declared, documented); len(missing) > 0 || len(extra) > 0 {
			t.Errorf("%s opcode range differs: get_opcode accepts %v, protocol/README.md documents %v", label, missing, extra)
		}
	}

	for name, value := range odinOpcodes(t) {
		if !enforced[value] {
			t.Errorf("%s = %d is outside every accepted range in get_opcode; the server would reject it", name, value)
		}
	}
}

// TestReadmeProtocolVersionMatchesServer keeps the advertised version and the
// document in step, because a client uses the document to decide compatibility.
func TestReadmeProtocolVersionMatchesServer(t *testing.T) {
	server := readRepositoryFile(t, "server.odin")
	declared := regexp.MustCompile(`PROTOCOL_VERSION :: (\d+)`).FindStringSubmatch(server)
	if declared == nil {
		t.Fatal("PROTOCOL_VERSION not found in server.odin")
	}
	readme := readRepositoryFile(t, "protocol/README.md")
	documented := regexp.MustCompile(`Current protocol version: ` + "`" + `(\d+)` + "`").FindStringSubmatch(readme)
	if documented == nil {
		t.Fatal("current protocol version not found in protocol/README.md")
	}
	if declared[1] != documented[1] {
		t.Errorf("server.odin declares PROTOCOL_VERSION %s but protocol/README.md documents %s", declared[1], documented[1])
	}
}

// TestReadmeLimitsMatchProtocol keeps the documented limits equal to the Odin
// constants, so a limit change cannot leave the document promising more than the
// server accepts.
func TestReadmeLimitsMatchProtocol(t *testing.T) {
	odin := readConstants(t, "protocol/types.odin", `(?m)^\s*(MAX_[A-Z0-9_]+)\s*::\s*([0-9]+(?:\s*\*\s*[0-9]+)?)`)
	for name, value := range readConstants(t, "protocol/assets.odin", `(?m)^\s*(MAX_[A-Z0-9_]+)\s*::\s*([0-9]+(?:\s*\*\s*[0-9]+)?)`) {
		odin[name] = value
	}
	for name, value := range readConstants(t, "protocol/edges.odin", `(?m)^\s*(MAX_[A-Z0-9_]+)\s*::\s*([0-9]+(?:\s*\*\s*[0-9]+)?)`) {
		odin[name] = value
	}
	for _, path := range []string{"protocol/transactions.odin", "protocol/customer_reads.odin", "protocol/graph_rank.odin"} {
		for name, value := range readConstants(t, path, `(?m)^\s*(MAX_[A-Z0-9_]+)\s*::\s*([0-9]+(?:\s*\*\s*[0-9]+)?)`) {
			odin[name] = value
		}
	}

	// Each documented limit names its constant, so the check is exact: the
	// number stated next to a constant must be the number that constant holds.
	// Matching bare numbers would let one constant pass on another's value.
	readme := readRepositoryFile(t, "protocol/README.md")
	number := regexp.MustCompile(`\d+`)
	documented := map[string]int{}
	for _, line := range strings.Split(readme, "\n") {
		if !strings.HasPrefix(line, "- **") {
			continue
		}
		stated, err := strconv.Atoi(number.FindString(line))
		if err != nil {
			continue
		}
		for _, match := range regexp.MustCompile("`(MAX_[A-Z0-9_]+)`").FindAllStringSubmatch(line, -1) {
			documented[match[1]] = stated
		}
	}
	if len(documented) == 0 {
		t.Fatal("no limits parsed from protocol/README.md")
	}
	for name, value := range odin {
		stated, present := documented[name]
		if !present {
			t.Errorf("protocol defines %s = %d but protocol/README.md does not document it", name, value)
			continue
		}
		if stated != value {
			t.Errorf("%s = %d in protocol/ but protocol/README.md states %d", name, value, stated)
		}
	}
}
