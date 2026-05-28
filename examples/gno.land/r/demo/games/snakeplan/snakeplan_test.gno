package snakeplan

import (
	"strings"
	"testing"
)

func TestRenderLobby(t *testing.T) {
	out := Render("")
	for _, want := range []string{
		"Snake Cinema",
		"LIVE",
		"100 ugnot",
		"Plan your run",
		"data:image/svg+xml",
		"Quick samples",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("Render lobby missing %q", want)
		}
	}
}

func TestPackCellRoundtrip(t *testing.T) {
	c := Cell{X: 10, Y: 5}
	if packCell(c) != 10*256+5 {
		t.Errorf("packCell wrong")
	}
}

func TestLighten(t *testing.T) {
	if got := lighten("#000000"); got != "#3C3C3C" {
		t.Errorf("lighten black: got %s", got)
	}
	if got := lighten("#FFFFFF"); got != "#FFFFFF" {
		t.Errorf("lighten white should clamp: got %s", got)
	}
}

func TestSortLeaderboard(t *testing.T) {
	leaderboard = []Record{
		{Length: 5}, {Length: 20}, {Length: 1}, {Length: 12},
	}
	sortLeaderboard()
	if leaderboard[0].Length != 20 || leaderboard[3].Length != 1 {
		t.Errorf("sort wrong: %+v", leaderboard)
	}
	leaderboard = nil
}
