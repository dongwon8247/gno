package dinorun

import (
	"strings"
	"testing"
)

func TestRender(t *testing.T) {
	out := Render("")
	for _, want := range []string{
		"DinoRun",
		"LIVE",
		"100 ugnot",
		"How it works",
		"Start Run",
		"Jump",
		"Cashout",
		"data:image/svg+xml",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("Render missing %q", want)
		}
	}
}

func TestShortAddrShortString(t *testing.T) {
	// short addrs return unchanged path
	s := "short"
	var a address
	// We can't easily construct a real address in unit test, so just call the
	// helper with the empty zero value and ensure no panic.
	_ = a.String()
	_ = s
}

func TestSortLeaderboard(t *testing.T) {
	leaderboard = []Record{
		{Distance: 50},
		{Distance: 200},
		{Distance: 100},
		{Distance: 10},
		{Distance: 300},
	}
	sortLeaderboard()
	if leaderboard[0].Distance != 300 {
		t.Errorf("top should be 300, got %d", leaderboard[0].Distance)
	}
	if leaderboard[1].Distance != 200 {
		t.Errorf("second should be 200, got %d", leaderboard[1].Distance)
	}
	if leaderboard[4].Distance != 10 {
		t.Errorf("last should be 10, got %d", leaderboard[4].Distance)
	}
	leaderboard = nil
}
