package session_test

import (
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestRelay_ZeroKnowledge_ByConstruction enforces the relay's core
// architectural rule: the blind pump must never depend on a cryptographic or
// key package, and must not link the concrete websocket transport either.
//
// It proves this by construction rather than by inspection: it shells out to
// the real `go list -deps` for this package and asserts that no dependency's
// import path contains "crypto" or the websocket library. If a future change
// makes the pump decrypt, key, or otherwise inspect payloads, the offending
// dependency shows up here and the test fails.
func TestRelay_ZeroKnowledge_ByConstruction(t *testing.T) {
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve test file location")
	}
	pkgDir := filepath.Dir(thisFile)

	goBin, err := exec.LookPath("go")
	if err != nil {
		t.Skipf("go tool not found on PATH, cannot run dependency check: %v", err)
	}

	cmd := exec.Command(goBin, "list", "-deps", ".")
	cmd.Dir = pkgDir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps failed: %v\n%s", err, out)
	}

	// A dependency path is forbidden if it contains any of these substrings.
	forbidden := []string{"crypto", "github.com/coder/websocket"}

	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		dep := strings.TrimSpace(line)
		if dep == "" {
			continue
		}
		for _, bad := range forbidden {
			if strings.Contains(dep, bad) {
				t.Errorf("zero-knowledge violation: blind pump must not depend on %q, "+
					"but its dependency graph includes %q", bad, dep)
			}
		}
	}
}
