// Package snakeplan is a Plan & Execute Snake. One transaction is one full
// game: the caller submits a move sequence (e.g. "RRUULDD"), the contract
// simulates it deterministically (apples placed from a chain-derived seed),
// records the result, and replays the run as an SVG SMIL animation on the
// next page load.
//
// The whole game lives in one tx — no per-step transactions, no live
// multiplayer. Beat the all-time longest length to take the entire pot.
package snakeplan

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
	BoardW   = 20
	BoardH   = 12
	CellPx   = 28
	SvgW     = BoardW * CellPx // 560
	SvgH     = BoardH * CellPx // 336
	EntryFee = int64(100)
	Denom    = "ugnot"

	MaxMoves    = 200
	NumApples   = 5
	HistoryKeep = 10
)

type Cell struct {
	X, Y uint8
}

// GameResult captures everything needed to replay a single run as an SVG.
type GameResult struct {
	Player        address
	Block         int64
	InitialApples []Cell // apples on the board at t=0
	Path          []Cell // head positions, index 0 = start, last = death/end
	EatenApples   []Cell // apples in order of eating (positions)
	EatenAtStep   []int  // path index when each apple was eaten
	Length        int
	Died          bool
	DeathReason   string // "wall" | "self" | ""
}

type Record struct {
	Player address
	Length int
	Block  int64
}

var (
	games       *avl.Tree // address.String() -> *GameResult (last game)
	best        Record
	leaderboard []Record
	pot         int64
	totalGames  uint64
	totalDeaths uint64
)

func init() {
	games = avl.NewTree()
}

// Play runs an entire game in one transaction. Send exactly EntryFee ugnot
// and pass a sequence string of U/D/L/R (case-insensitive). Other characters
// are ignored.
func Play(cur realm, moves string) {
	caller := unsafe.OriginCaller()

	sent := unsafe.OriginSend()
	if sent.AmountOf(Denom) != EntryFee {
		panic(ufmt.Sprintf("entry fee is exactly %d ugnot", EntryFee))
	}
	pot += EntryFee
	totalGames++

	moves = strings.ToUpper(strings.TrimSpace(moves))
	if len(moves) == 0 {
		panic("empty move sequence — submit at least one U/D/L/R move")
	}
	if len(moves) > MaxMoves {
		panic(ufmt.Sprintf("max %d moves", MaxMoves))
	}

	s1 := uint64(entropy.New().Seed())
	s2 := uint64(entropy.New().Seed()) ^ uint64(totalGames)
	rng := rand.New(rand.NewPCG(s1, s2))
	result := simulateWithRng(rng, caller, moves)
	games.Set(caller.String(), result)

	rec := Record{Player: caller, Length: result.Length, Block: result.Block}
	leaderboard = append(leaderboard, rec)
	sortLeaderboard()
	if len(leaderboard) > HistoryKeep {
		leaderboard = leaderboard[:HistoryKeep]
	}

	if result.Died {
		totalDeaths++
	}

	// Win check — must be alive at end and exceed all-time record.
	if !result.Died && result.Length > best.Length {
		best = rec
		prize := pot
		pot = 0
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), caller, chain.NewCoins(chain.NewCoin(Denom, prize)))
		chain.Emit("NewRecord",
			"player", caller.String(),
			"length", ufmt.Sprintf("%d", result.Length),
			"prize", ufmt.Sprintf("%d", prize),
		)
		return
	}

	reason := "no record"
	if result.Died {
		reason = "died: " + result.DeathReason
	}
	chain.Emit("GameEnded",
		"player", caller.String(),
		"length", ufmt.Sprintf("%d", result.Length),
		"reason", reason,
	)
}

func simulateWithRng(rng *rand.Rand, caller address, moves string) *GameResult {
	// Start at the center.
	start := Cell{X: BoardW / 2, Y: BoardH / 2}
	body := []Cell{start}
	occ := map[uint32]bool{packCell(start): true}

	// Place initial apples in empty cells.
	apples := []Cell{}
	for attempts := 0; len(apples) < NumApples && attempts < 500; attempts++ {
		x := uint8(rng.IntN(BoardW))
		y := uint8(rng.IntN(BoardH))
		c := Cell{X: x, Y: y}
		k := packCell(c)
		if occ[k] {
			continue
		}
		if containsCell(apples, c) {
			continue
		}
		apples = append(apples, c)
	}
	initialApples := make([]Cell, len(apples))
	copy(initialApples, apples)

	path := []Cell{start}
	eatenApples := []Cell{}
	eatenAt := []int{}

	direction := byte('R')
	died := false
	deathReason := ""

	for i := 0; i < len(moves); i++ {
		m := moves[i]
		switch m {
		case 'U', 'D', 'L', 'R':
			direction = m
		default:
			continue
		}

		head := body[0]
		nx := int(head.X)
		ny := int(head.Y)
		switch direction {
		case 'U':
			ny--
		case 'D':
			ny++
		case 'L':
			nx--
		case 'R':
			nx++
		}

		if nx < 0 || nx >= BoardW || ny < 0 || ny >= BoardH {
			died = true
			deathReason = "wall"
			break
		}
		newHead := Cell{X: uint8(nx), Y: uint8(ny)}
		newKey := packCell(newHead)

		// Apple check.
		ateAt := -1
		for ai, a := range apples {
			if a.X == newHead.X && a.Y == newHead.Y {
				ateAt = ai
				break
			}
		}

		// Self-collision: tail moves unless we ate an apple this step.
		tailKey := uint32(0)
		hasTail := false
		if ateAt < 0 && len(body) > 0 {
			t := body[len(body)-1]
			tailKey = packCell(t)
			hasTail = true
		}
		if occ[newKey] && !(hasTail && newKey == tailKey) {
			died = true
			deathReason = "self"
			break
		}

		// Apply move.
		if ateAt >= 0 {
			eatenApples = append(eatenApples, newHead)
			eatenAt = append(eatenAt, len(path))
			apples = append(apples[:ateAt], apples[ateAt+1:]...)
			// Spawn replacement — track in apples slice but skip if board too full.
			for attempts := 0; attempts < 200; attempts++ {
				ax := uint8(rng.IntN(BoardW))
				ay := uint8(rng.IntN(BoardH))
				c := Cell{X: ax, Y: ay}
				if occ[packCell(c)] {
					continue
				}
				if c.X == newHead.X && c.Y == newHead.Y {
					continue
				}
				if containsCell(apples, c) {
					continue
				}
				apples = append(apples, c)
				break
			}
		}

		// Shift body.
		newBody := make([]Cell, 0, len(body)+1)
		newBody = append(newBody, newHead)
		end := len(body)
		if ateAt < 0 {
			end = len(body) - 1
		}
		for j := 0; j < end; j++ {
			newBody = append(newBody, body[j])
		}
		// Rebuild occ from newBody (tails may have moved out).
		occ = map[uint32]bool{}
		for _, c := range newBody {
			occ[packCell(c)] = true
		}
		body = newBody

		path = append(path, newHead)
	}

	return &GameResult{
		Player:        caller,
		Block:         runtime.ChainHeight(),
		InitialApples: initialApples,
		Path:          path,
		EatenApples:   eatenApples,
		EatenAtStep:   eatenAt,
		Length:        len(body),
		Died:          died,
		DeathReason:   deathReason,
	}
}

func packCell(c Cell) uint32 {
	return uint32(c.X)*256 + uint32(c.Y)
}

func containsCell(cs []Cell, c Cell) bool {
	for _, x := range cs {
		if x.X == c.X && x.Y == c.Y {
			return true
		}
	}
	return false
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

func shortAddr(a address) string {
	s := a.String()
	if len(s) > 14 {
		return s[:8] + "…" + s[len(s)-4:]
	}
	return s
}
