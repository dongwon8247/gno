package rpspool

import (
	"strings"
	"testing"
)

func TestParseChoice(t *testing.T) {
	cases := []struct {
		in  string
		out uint8
		ok  bool
	}{
		{"rock", ChoiceRock, true},
		{"r", ChoiceRock, true},
		{"R", ChoiceRock, true},
		{"PAPER", ChoicePaper, true},
		{"p", ChoicePaper, true},
		{"scissors", ChoiceScissors, true},
		{"scissor", ChoiceScissors, true},
		{"s", ChoiceScissors, true},
		{"  paper  ", ChoicePaper, true},
		{"banana", 0, false},
		{"", 0, false},
	}
	for _, c := range cases {
		got, ok := parseChoice(c.in)
		if ok != c.ok {
			t.Errorf("parseChoice(%q): ok=%v, want %v", c.in, ok, c.ok)
			continue
		}
		if ok && got != c.out {
			t.Errorf("parseChoice(%q): got %d, want %d", c.in, got, c.out)
		}
	}
}

func TestChoiceLabel(t *testing.T) {
	if !strings.Contains(choiceLabel(ChoiceRock), "Rock") {
		t.Error("Rock label missing")
	}
	if !strings.Contains(choiceLabel(ChoicePaper), "Paper") {
		t.Error("Paper label missing")
	}
	if !strings.Contains(choiceLabel(ChoiceScissors), "Scissors") {
		t.Error("Scissors label missing")
	}
	if choiceLabel(99) != "?" {
		t.Error("unknown label fallback failed")
	}
}

func TestRender(t *testing.T) {
	out := Render("")
	for _, want := range []string{
		"RPS Pool",
		"Round #",
		"Rock",
		"Paper",
		"Scissors",
		"Carryover",
		"ugnot",
		"block #",
		"data:image/svg+xml",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("Render output missing %q", want)
		}
	}
}
