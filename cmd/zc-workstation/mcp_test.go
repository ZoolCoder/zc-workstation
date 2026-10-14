package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestMCPPlanThenApplyByID(t *testing.T) {
	cfg, dir := fixture(t)
	s := mcpServer(t.TempDir())
	text, err := s.Call("plan", map[string]any{"config": cfg})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID   string `json:"plan_id"`
		Plan struct{ Changes int }
	}
	if err := json.Unmarshal([]byte(text), &reply); err != nil || reply.Plan.Changes != 1 {
		t.Fatalf("plan %q: %v", text, err)
	}
	if text, err = s.Call("apply", map[string]any{"plan_id": reply.ID}); err != nil || !strings.Contains(text, "applied and verified") {
		t.Fatalf("apply %q: %v", text, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "a.txt")); err != nil {
		t.Fatal(err)
	}
	if text, err := s.Call("status", map[string]any{"config": cfg}); err != nil || !strings.Contains(text, `"target": "notes"`) {
		t.Fatalf("status %q: %v", text, err)
	}
}

func TestMCPDeletionGoesToAPerson(t *testing.T) {
	cfg, dir := fixture(t)
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "stray.txt"), []byte("x"), 0o600)
	s := mcpServer(t.TempDir())
	text, err := s.Call("plan", map[string]any{"config": cfg})
	if err != nil {
		t.Fatal(err)
	}
	var reply struct {
		ID string `json:"plan_id"`
	}
	_ = json.Unmarshal([]byte(text), &reply)
	_, err = s.Call("apply", map[string]any{"plan_id": reply.ID})
	if err == nil || !strings.Contains(err.Error(), "Ask the user to run: "+name+" apply") {
		t.Fatalf("apply with deletion: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "stray.txt")); err != nil {
		t.Fatal("agent deleted a file")
	}
}
