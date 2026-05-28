// Package snake is a communal on-chain Snake game. All players share one
// 50×30 board. Each Move is a transaction. Eating an apple grows your snake.
// Hitting a wall, another snake, or your own body kills you. Beat the longest
// length record (alive) to take the entire pot.
package snake

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"math/rand"
	"strings"

	"gno.land/p/demo/entropy"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	BoardW   = 50
	BoardH   = 30
	CellPx   = 12
	SvgW     = BoardW * CellPx // 600
	SvgH     = BoardH * CellPx // 360
	EntryFee = int64(100)
	Denom    = "ugnot"

	DirUp    = uint8(0)
	DirRight = uint8(1)
	DirDown  = uint8(2)
	DirLeft  = uint8(3)

	TargetApples = 5
	HistoryKeep  = 10
)

type Cell struct {
	X, Y uint8
}

type Snake struct {
	Player    address
	Body      []Cell // [0]=head, [last]=tail
	Direction uint8
	Alive     bool
	JoinBlock int64
}

type Record struct {
	Player address
	Length int
	Block  int64
}

var (
	snakes      *avl.Tree // address.String() -> *Snake
	apples      []Cell
	pot         int64
	best        Record
	leaderboard []Record
	totalDeaths uint64
	totalJoins  uint64
)

func init() {
	snakes = avl.NewTree()
	seedRng().IntN(1) // warm the entropy package
	spawnApples()
}

func seedRng() *rand.Rand {
	s1 := uint64(entropy.New().Seed())
	s2 := uint64(entropy.New().Seed())
	return rand.New(rand.NewPCG(s1, s2))
}

func spawnApples() {
	rng := seedRng()
	for len(apples) < TargetApples {
		placed := false
		for attempts := 0; attempts < 200; attempts++ {
			x := uint8(rng.IntN(BoardW))
			y := uint8(rng.IntN(BoardH))
			if !occupied(x, y) {
				apples = append(apples, Cell{x, y})
				placed = true
				break
			}
		}
		if !placed {
			return // board too full
		}
	}
}

func occupied(x, y uint8) bool {
	for _, a := range apples {
		if a.X == x && a.Y == y {
			return true
		}
	}
	found := false
	snakes.Iterate("", "", func(key string, v any) bool {
		s := v.(*Snake)
		for _, c := range s.Body {
			if c.X == x && c.Y == y {
				found = true
				return true
			}
		}
		return false
	})
	return found
}

// Join spawns a new 1-cell snake for the caller. Send exactly EntryFee ugnot.
// If the caller has a previous dead snake, it auto-finalizes first.
func Join(cur realm) {
	caller := unsafe.OriginCaller()
	key := caller.String()

	if v, has := snakes.Get(key); has {
		s := v.(*Snake)
		if s.Alive {
			panic("you already have an alive snake — Cashout or Move it first")
		}
		finalize(cur, s)
		snakes.Remove(key)
	}

	sent := unsafe.OriginSend()
	if sent.AmountOf(Denom) != EntryFee {
		panic(ufmt.Sprintf("entry fee is exactly %d ugnot", EntryFee))
	}
	pot += EntryFee
	totalJoins++

	rng := seedRng()
	var x, y uint8
	placed := false
	for attempts := 0; attempts < 500; attempts++ {
		x = uint8(rng.IntN(BoardW))
		y = uint8(rng.IntN(BoardH))
		if !occupied(x, y) {
			placed = true
			break
		}
	}
	if !placed {
		panic("board is full — try again later")
	}

	snakes.Set(key, &Snake{
		Player:    caller,
		Body:      []Cell{{x, y}},
		Direction: DirRight,
		Alive:     true,
		JoinBlock: runtime.ChainHeight(),
	})
	chain.Emit("SnakeJoined", "player", key, "pot", ufmt.Sprintf("%d", pot))
}

// Move advances the caller's snake one cell in the given direction.
// dir: "up"/"down"/"left"/"right" (or u/d/l/r).
func Move(cur realm, dir string) {
	caller := unsafe.OriginCaller()
	key := caller.String()

	v, has := snakes.Get(key)
	if !has {
		panic("no active snake — call Join first")
	}
	s := v.(*Snake)
	if !s.Alive {
		panic("your snake is dead — Cashout to finalize")
	}

	d := parseDirection(dir)

	// Reject 180° reversal for snakes of length > 1.
	if len(s.Body) > 1 {
		if (s.Direction == DirUp && d == DirDown) ||
			(s.Direction == DirDown && d == DirUp) ||
			(s.Direction == DirLeft && d == DirRight) ||
			(s.Direction == DirRight && d == DirLeft) {
			panic("can't reverse direction")
		}
	}

	head := s.Body[0]
	nx, ny := nextXY(head, d)
	if nx < 0 || nx >= BoardW || ny < 0 || ny >= BoardH {
		s.Alive = false
		s.Direction = d
		chain.Emit("SnakeDied", "player", key, "reason", "wall", "length", ufmt.Sprintf("%d", len(s.Body)))
		return
	}

	newHead := Cell{uint8(nx), uint8(ny)}

	// Apple check.
	ateApple := false
	for i, a := range apples {
		if a.X == newHead.X && a.Y == newHead.Y {
			apples = append(apples[:i], apples[i+1:]...)
			ateApple = true
			break
		}
	}

	// Snake-body collision (any snake, including self). Self-tail will move so
	// it's safe to step onto — unless we ate an apple (tail stays).
	deadByCollision := false
	snakes.Iterate("", "", func(otherKey string, ov any) bool {
		os := ov.(*Snake)
		bodyLimit := len(os.Body)
		if otherKey == key && !ateApple && bodyLimit > 0 {
			bodyLimit-- // self-tail leaves this turn
		}
		for i := 0; i < bodyLimit; i++ {
			c := os.Body[i]
			if c.X == newHead.X && c.Y == newHead.Y {
				deadByCollision = true
				return true
			}
		}
		return false
	})
	if deadByCollision {
		s.Alive = false
		s.Direction = d
		chain.Emit("SnakeDied", "player", key, "reason", "collision", "length", ufmt.Sprintf("%d", len(s.Body)))
		return
	}

	// Advance: new head + (body minus tail unless eating).
	end := len(s.Body)
	if !ateApple {
		end = len(s.Body) - 1
	}
	newBody := make([]Cell, 0, end+1)
	newBody = append(newBody, newHead)
	for i := 0; i < end; i++ {
		newBody = append(newBody, s.Body[i])
	}
	s.Body = newBody
	s.Direction = d

	if ateApple {
		spawnApples()
		chain.Emit("AppleEaten", "player", key, "len", ufmt.Sprintf("%d", len(s.Body)))
	}
}

// Cashout finalizes the caller's snake (alive or dead).
func Cashout(cur realm) {
	caller := unsafe.OriginCaller()
	key := caller.String()
	v, has := snakes.Get(key)
	if !has {
		panic("no active snake")
	}
	s := v.(*Snake)
	finalize(cur, s)
	snakes.Remove(key)
}

func finalize(cur realm, s *Snake) {
	length := len(s.Body)
	key := s.Player.String()

	rec := Record{Player: s.Player, Length: length, Block: runtime.ChainHeight()}
	leaderboard = append(leaderboard, rec)
	sortLeaderboard()
	if len(leaderboard) > HistoryKeep {
		leaderboard = leaderboard[:HistoryKeep]
	}

	won := s.Alive && length > best.Length
	if won {
		best = rec
		prize := pot
		pot = 0
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), s.Player, chain.NewCoins(chain.NewCoin(Denom, prize)))
		chain.Emit("NewRecord", "player", key, "length", ufmt.Sprintf("%d", length), "prize", ufmt.Sprintf("%d", prize))
		return
	}
	if !s.Alive {
		totalDeaths++
	}
}

func sortLeaderboard() {
	for i := 0; i < len(leaderboard); i++ {
		for j := i + 1; j < len(leaderboard); j++ {
			if leaderboard[j].Length > leaderboard[i].Length {
				leaderboard[i], leaderboard[j] = leaderboard[j], leaderboard[i]
			}
		}
	}
}

func parseDirection(dir string) uint8 {
	switch strings.ToLower(strings.TrimSpace(dir)) {
	case "up", "u", "north", "n":
		return DirUp
	case "down", "d", "south", "s":
		return DirDown
	case "left", "l", "west", "w":
		return DirLeft
	case "right", "r", "east", "e":
		return DirRight
	}
	panic("direction must be up/down/left/right")
}

func dirName(d uint8) string {
	switch d {
	case DirUp:
		return "↑ up"
	case DirRight:
		return "→ right"
	case DirDown:
		return "↓ down"
	case DirLeft:
		return "← left"
	}
	return "?"
}

func nextXY(c Cell, d uint8) (int, int) {
	x, y := int(c.X), int(c.Y)
	switch d {
	case DirUp:
		y--
	case DirDown:
		y++
	case DirLeft:
		x--
	case DirRight:
		x++
	}
	return x, y
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) > 14 {
		return s[:8] + "…" + s[len(s)-4:]
	}
	return s
}
