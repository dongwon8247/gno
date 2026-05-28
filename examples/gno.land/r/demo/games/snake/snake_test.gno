package snake

import (
	"strings"
	"testing"
)

func TestParseDirection(t *testing.T) {
	cases := []struct {
		in  string
		out uint8
	}{
		{"up", DirUp},
		{"U", DirUp},
		{"north", DirUp},
		{"down", DirDown},
		{"left", DirLeft},
		{"right", DirRight},
		{"  Right  ", DirRight},
	}
	for _, c := range cases {
		if got := parseDirection(c.in); got != c.out {
			t.Errorf("parseDirection(%q): got %d, want %d", c.in, got, c.out)
		}
	}
}

func TestRenderLobby(t *testing.T) {
	out := Render("")
	for _, want := range []string{
		"Snake World",
		"LIVE",
		"100 ugnot",
		"Join the world",
		"data:image/svg+xml",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("Render lobby missing %q", want)
		}
	}
}

func TestNextXY(t *testing.T) {
	c := Cell{X: 5, Y: 5}
	cases := []struct {
		dir uint8
		wx  int
		wy  int
	}{
		{DirUp, 5, 4},
		{DirDown, 5, 6},
		{DirLeft, 4, 5},
		{DirRight, 6, 5},
	}
	for _, ca := range cases {
		x, y := nextXY(c, ca.dir)
		if x != ca.wx || y != ca.wy {
			t.Errorf("nextXY(%d): got (%d,%d), want (%d,%d)", ca.dir, x, y, ca.wx, ca.wy)
		}
	}
}

func TestSortLeaderboard(t *testing.T) {
	leaderboard = []Record{
		{Length: 5},
		{Length: 20},
		{Length: 1},
		{Length: 12},
	}
	sortLeaderboard()
	if leaderboard[0].Length != 20 || leaderboard[3].Length != 1 {
		t.Errorf("sort wrong: %+v", leaderboard)
	}
	leaderboard = nil
}

func TestLighten(t *testing.T) {
	if got := lighten("#000000"); got != "#3C3C3C" {
		t.Errorf("lighten black: got %s", got)
	}
	if got := lighten("#FFFFFF"); got != "#FFFFFF" {
		t.Errorf("lighten white should clamp: got %s", got)
	}
}
