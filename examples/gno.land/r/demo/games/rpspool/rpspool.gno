// Package rpspool is an on-chain multi-player rock-paper-scissors betting pool.
//
// Each round, anyone can bet `ugnot` on Rock, Paper, or Scissors. When the
// round's block window closes, the contract picks the winning shape using
// deterministic randomness derived from chain state. Everyone who bet on the
// winning shape splits the entire pot pro-rata. If no one bet on the winning
// shape, the whole pot rolls over to the next round.
//
// Winnings are credited to a per-address ledger (pull pattern) — call
// Withdraw() to send your accumulated payouts to your wallet.
package rpspool

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"encoding/base64"
	"math/rand"
	"strings"

	"gno.land/p/demo/entropy"
	"gno.land/p/moul/txlink"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/dna"
)

const (
	ChoiceRock     = uint8(0)
	ChoicePaper    = uint8(1)
	ChoiceScissors = uint8(2)

	RoundBlocks = int64(60) // ~1 minute on a 1s-block chain
	Denom       = "ugnot"
	MinBet      = int64(1)
	HistoryKeep = 10
)

type Wager struct {
	Bettor address
	Choice uint8
	Amount int64
	Block  int64
}

type Round struct {
	ID           uint64
	StartBlock   int64
	EndBlock     int64
	Bets         []Wager
	Totals       [3]int64 // R, P, S
	Resolved     bool
	Winner       uint8
	PotAtResolve int64
	PaidOut      int64
}

var (
	current     Round
	history     []Round
	winnings    *avl.Tree // address.String() -> int64
	carryover   int64
	nextRoundID uint64 = 1
)

func init() {
	winnings = avl.NewTree()
	startNewRound()
}

func startNewRound() {
	h := runtime.ChainHeight()
	current = Round{
		ID:         nextRoundID,
		StartBlock: h,
		EndBlock:   h + RoundBlocks,
	}
	nextRoundID++
}

// Bet places a bet on Rock, Paper, or Scissors. The bet size is the amount of
// ugnot sent with the transaction (use `-send Nugnot` or the form's Send field).
// Accepts: "rock"/"r", "paper"/"p", "scissors"/"s".
func Bet(cur realm, choice string) {
	// Auto-resolve a stale round so this bet lands in a fresh one.
	if !current.Resolved && runtime.ChainHeight() >= current.EndBlock {
		resolveCurrent(cur)
		startNewRound()
	}

	c, ok := parseChoice(choice)
	if !ok {
		panic("choice must be one of: rock, paper, scissors (or r/p/s)")
	}

	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		panic("must send ugnot with bet")
	}
	amount := sent.AmountOf(Denom)
	if amount < MinBet {
		panic("minimum bet is 1 ugnot")
	}

	current.Bets = append(current.Bets, Wager{
		Bettor: unsafe.OriginCaller(),
		Choice: c,
		Amount: amount,
		Block:  runtime.ChainHeight(),
	})
	current.Totals[c] += amount
}

// Resolve closes the current round (if its window has passed), distributes the
// pot, and opens a fresh round. Anyone can call it.
func Resolve(cur realm) {
	if current.Resolved {
		panic("round already resolved — place a bet to start the next one")
	}
	if runtime.ChainHeight() < current.EndBlock {
		panic("round window not over yet")
	}
	resolveCurrent(cur)
	startNewRound()
}

func resolveCurrent(_ realm) {
	// Deterministic on-chain randomness — entropy package mixes chain height,
	// time, and call context so the seed is not predictable at bet time.
	seed1 := uint64(entropy.New().Seed())
	seed2 := uint64(entropy.New().Seed()) ^ (current.ID * 0x9E3779B97F4A7C15)
	rng := rand.New(rand.NewPCG(seed1, seed2))
	winner := uint8(rng.IntN(3))

	totalPot := carryover
	for i := 0; i < 3; i++ {
		totalPot += current.Totals[i]
	}

	current.Resolved = true
	current.Winner = winner
	current.PotAtResolve = totalPot

	winnerTotal := current.Totals[winner]
	if winnerTotal == 0 {
		carryover = totalPot
		current.PaidOut = 0
	} else {
		paid := int64(0)
		for _, b := range current.Bets {
			if b.Choice != winner {
				continue
			}
			share := totalPot * b.Amount / winnerTotal
			addWinnings(b.Bettor, share)
			paid += share
		}
		carryover = totalPot - paid // dust rolls over
		current.PaidOut = paid
	}

	history = append(history, current)
	if len(history) > HistoryKeep {
		history = history[len(history)-HistoryKeep:]
	}

	chain.Emit("RoundResolved",
		"round", ufmt.Sprintf("%d", current.ID),
		"winner", choiceLabel(winner),
		"pot", ufmt.Sprintf("%d", totalPot),
		"paidOut", ufmt.Sprintf("%d", current.PaidOut),
	)
}

func addWinnings(addr address, amount int64) {
	key := addr.String()
	prev := int64(0)
	if v, ok := winnings.Get(key); ok {
		prev = v.(int64)
	}
	winnings.Set(key, prev+amount)
}

// Withdraw sends the caller's accumulated winnings to their wallet.
func Withdraw(cur realm) {
	caller := unsafe.OriginCaller()
	key := caller.String()
	v, ok := winnings.Get(key)
	if !ok {
		panic("no winnings to withdraw")
	}
	amount := v.(int64)
	if amount <= 0 {
		panic("no winnings to withdraw")
	}
	winnings.Set(key, int64(0))

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), caller, chain.NewCoins(chain.NewCoin(Denom, amount)))
}

// WinningsOf returns the unclaimed winnings credited to the given address.
func WinningsOf(addr address) int64 {
	v, ok := winnings.Get(addr.String())
	if !ok {
		return 0
	}
	return v.(int64)
}

func parseChoice(s string) (uint8, bool) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "rock", "r":
		return ChoiceRock, true
	case "paper", "p":
		return ChoicePaper, true
	case "scissors", "scissor", "s":
		return ChoiceScissors, true
	}
	return 0, false
}

func choiceLabel(c uint8) string {
	switch c {
	case ChoiceRock:
		return "🪨 Rock"
	case ChoicePaper:
		return "📄 Paper"
	case ChoiceScissors:
		return "✂️ Scissors"
	}
	return "?"
}

func Render(_ string) string {
	var b strings.Builder
	height := runtime.ChainHeight()
	pot := carryover
	for i := 0; i < 3; i++ {
		pot += current.Totals[i]
	}
	uniqueBettors := countUniqueBettors(current.Bets)
	roundOver := current.Resolved || height >= current.EndBlock

	b.WriteString("# ✂️🪨📄 RPS Pool\n\n")

	// LIVE status strip — pulsing dot animates with no refresh needed
	b.WriteString(ufmt.Sprintf(
		"%s **LIVE** · ⛓ block #%d · 🎲 Round #%d · 🎯 %d players · 💰 %d ugnot pot · [↻ refresh](/r/demo/games/rpspool)\n\n",
		renderLiveDot(), height, current.ID, uniqueBettors, pot,
	))

	// Progress bar
	b.WriteString(renderProgressBar(height))
	b.WriteString("\n\n")

	// Big banner when round window has closed
	if roundOver {
		b.WriteString(renderRoundOverBanner())
		b.WriteString("\n\n")
	}

	b.WriteString("> [!NOTE] Bet ugnot on Rock, Paper, or Scissors. When the round closes, the contract picks the winning shape using on-chain randomness — winners split the entire pot pro-rata. No house edge. If no one picks the winning shape, the pot rolls over.\n\n")

	// Action area — bet buttons or resolve
	b.WriteString("## Place your bet\n\n")
	if roundOver {
		b.WriteString(ufmt.Sprintf("⏳ Round window closed. [**Resolve & open next round →**](%s)\n\n",
			txlink.NewLink("Resolve").URL()))
	} else {
		b.WriteString("<gno-columns>\n\n")
		b.WriteString(ufmt.Sprintf("### 🪨 Rock\n\n`%d ugnot` from %d bets\n\n[**Bet on Rock →**](%s)\n\n",
			current.Totals[ChoiceRock], countBetsFor(ChoiceRock),
			txlink.NewLink("Bet").AddArgs("choice", "rock").URL()))
		b.WriteString("|||\n\n")
		b.WriteString(ufmt.Sprintf("### 📄 Paper\n\n`%d ugnot` from %d bets\n\n[**Bet on Paper →**](%s)\n\n",
			current.Totals[ChoicePaper], countBetsFor(ChoicePaper),
			txlink.NewLink("Bet").AddArgs("choice", "paper").URL()))
		b.WriteString("|||\n\n")
		b.WriteString(ufmt.Sprintf("### ✂️ Scissors\n\n`%d ugnot` from %d bets\n\n[**Bet on Scissors →**](%s)\n\n",
			current.Totals[ChoiceScissors], countBetsFor(ChoiceScissors),
			txlink.NewLink("Bet").AddArgs("choice", "scissors").URL()))
		b.WriteString("</gno-columns>\n\n")
		b.WriteString("> Set bet size with the **Send** field. Minimum: `1 ugnot`. Carryover from previous rounds: `")
		b.WriteString(ufmt.Sprintf("%d ugnot", carryover))
		b.WriteString("`.\n\n")
	}

	// Players in this round — DNA grid (composes /r/demo/dna)
	if len(current.Bets) > 0 {
		b.WriteString("## 🎭 Players this round\n\n")
		b.WriteString(renderPlayersGrid())
		b.WriteString("\n\n")
		b.WriteString("_Each face is an on-chain identicon generated by [`/r/demo/dna`](/r/demo/dna) — different realm, imported as a library._\n\n")
	}

	// Live activity feed
	if len(current.Bets) > 0 {
		b.WriteString("## 📡 Live activity\n\n")
		b.WriteString(renderActivityFeed(height))
		b.WriteString("\n")
	}

	// Withdraw
	b.WriteString("## 💸 Withdraw winnings\n\n")
	b.WriteString(ufmt.Sprintf("Won past rounds? [**Withdraw your winnings →**](%s)\n\n",
		txlink.NewLink("Withdraw").URL()))

	// History
	if len(history) > 0 {
		b.WriteString("## 📜 Recent rounds\n\n")
		b.WriteString("| Round | Winner | Pot | Paid out | Rolled over |\n|---|---|---|---|---|\n")
		for i := len(history) - 1; i >= 0; i-- {
			r := history[i]
			rolled := r.PotAtResolve - r.PaidOut
			b.WriteString(ufmt.Sprintf("| #%d | %s | %d | %d | %d |\n",
				r.ID, choiceLabel(r.Winner), r.PotAtResolve, r.PaidOut, rolled))
		}
		b.WriteString("\n")
	}

	b.WriteString("---\n\n")
	b.WriteString("**Why this is wild:** rules, randomness, payouts, and UI live in one [contract](/r/demo/games/rpspool/rpspool.gno) — and the player avatars come from another realm ([/r/demo/dna](/r/demo/dna)) imported like a Go library. Every bet, every payout, every pixel of UI is on-chain and auditable.\n")

	return b.String()
}

func countBetsFor(c uint8) int {
	n := 0
	for _, bet := range current.Bets {
		if bet.Choice == c {
			n++
		}
	}
	return n
}

func countUniqueBettors(bets []Wager) int {
	seen := map[string]bool{}
	for _, bet := range bets {
		seen[bet.Bettor.String()] = true
	}
	return len(seen)
}

func renderProgressBar(height int64) string {
	const (
		barW = 600
		barH = 32
	)

	total := current.EndBlock - current.StartBlock
	elapsed := height - current.StartBlock
	if elapsed < 0 {
		elapsed = 0
	}
	if elapsed > total {
		elapsed = total
	}
	pct := 0
	fillW := 0
	if total > 0 {
		pct = int(elapsed * 100 / total)
		fillW = int(elapsed * int64(barW) / total)
	}
	blocksLeft := total - elapsed
	if blocksLeft < 0 {
		blocksLeft = 0
	}

	fillColor := "#4A90E2"
	urgent := false
	finished := current.Resolved || height >= current.EndBlock
	switch {
	case finished:
		fillColor = "#999999"
		fillW = barW
	case pct >= 80:
		fillColor = "#E59500"
		urgent = true
	}

	var label string
	switch {
	case current.Resolved:
		label = ufmt.Sprintf("Round #%d resolved", current.ID)
	case finished:
		label = ufmt.Sprintf("Round #%d — ready to resolve", current.ID)
	default:
		label = ufmt.Sprintf("Round #%d  ·  %d%%  ·  ~%ds left", current.ID, pct, blocksLeft)
	}

	// <animate> on the fill-rect grows width over the remaining seconds — no
	// refresh required. In urgent mode we also pulse the color.
	animateWidth := ""
	animateFill := ""
	if !finished && blocksLeft > 0 {
		animateWidth = ufmt.Sprintf(
			`<animate attributeName="width" from="%d" to="%d" dur="%ds" fill="freeze"/>`,
			fillW, barW, blocksLeft,
		)
		if urgent {
			animateFill = `<animate attributeName="fill" values="#E59500;#FF5500;#E59500" dur="0.8s" repeatCount="indefinite"/>`
		}
	}

	raw := ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">`+
			`<rect width="%d" height="%d" fill="#EEEEEE" rx="6" ry="6"/>`+
			`<rect width="%d" height="%d" fill="%s" rx="6" ry="6">%s%s</rect>`+
			`<text x="%d" y="%d" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="14" font-weight="700" fill="#1a1a1a">%s</text>`+
			`</svg>`,
		barW, barH, barW, barH,
		barW, barH,
		fillW, barH, fillColor, animateWidth, animateFill,
		barW/2, barH/2+5, label,
	)
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("![%s](data:image/svg+xml;base64,%s)", label, encoded)
}

// renderRoundOverBanner returns a strongly-styled banner shown when the round
// window has elapsed. Uses an IMPORTANT alert + a pulsing SVG to make it impossible to miss.
func renderRoundOverBanner() string {
	var b strings.Builder
	b.WriteString(renderPulseBanner())
	b.WriteString("\n\n")
	if current.Resolved {
		b.WriteString(ufmt.Sprintf(
			"> [!IMPORTANT] 🎲 **Round #%d resolved.** Winning shape: %s · Paid out: **%d ugnot** · Place a bet to open round #%d.\n",
			current.ID, choiceLabel(current.Winner), current.PaidOut, current.ID+1,
		))
	} else {
		b.WriteString(ufmt.Sprintf(
			"> [!IMPORTANT] 🏁 **Round #%d window closed.** Press **Resolve** below to roll the on-chain dice and open round #%d.\n",
			current.ID, current.ID+1,
		))
	}
	return b.String()
}

// renderPulseBanner is a big eye-catching pulsing SVG that screams "ROUND OVER".
func renderPulseBanner() string {
	const (
		w = 600
		h = 60
	)
	color := "#E59500"
	label := "🏁  ROUND OVER  —  RESOLVE TO CONTINUE"
	if current.Resolved {
		color = "#2E7D32"
		label = "🎲  ROUND RESOLVED  —  BET TO START NEXT"
	}
	raw := ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">`+
			`<rect width="%d" height="%d" fill="%s" rx="8" ry="8">`+
			`<animate attributeName="opacity" values="1;0.55;1" dur="1.4s" repeatCount="indefinite"/>`+
			`</rect>`+
			`<text x="%d" y="%d" text-anchor="middle" font-family="-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif" font-size="18" font-weight="800" fill="#FFFFFF">%s</text>`+
			`</svg>`,
		w, h, w, h,
		w, h, color,
		w/2, h/2+6, label,
	)
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("![%s](data:image/svg+xml;base64,%s)", label, encoded)
}

// renderLiveDot returns a small pulsing red "LIVE" dot — a self-animating SVG
// that needs no page refresh.
func renderLiveDot() string {
	const raw = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">` +
		`<circle cx="7" cy="7" r="5" fill="#E50000">` +
		`<animate attributeName="opacity" values="1;0.25;1" dur="1.1s" repeatCount="indefinite"/>` +
		`<animate attributeName="r" values="5;6;5" dur="1.1s" repeatCount="indefinite"/>` +
		`</circle></svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("![live](data:image/svg+xml;base64,%s)", encoded)
}

func renderPlayersGrid() string {
	seen := map[string]int64{}
	order := []address{}
	for _, bet := range current.Bets {
		key := bet.Bettor.String()
		if _, ok := seen[key]; !ok {
			order = append(order, bet.Bettor)
		}
		seen[key] += bet.Amount
	}

	var b strings.Builder
	b.WriteString("<gno-columns>\n\n")
	const perCol = 6
	for i, addr := range order {
		if i > 0 && i%perCol == 0 {
			b.WriteString("|||\n\n")
		}
		b.WriteString(dna.GenerateMini(addr.String()))
		short := addr.String()
		if len(short) > 10 {
			short = short[:6] + "…"
		}
		b.WriteString(ufmt.Sprintf(" `%s` `%d`<br>", short, seen[addr.String()]))
	}
	b.WriteString("\n\n</gno-columns>")
	return b.String()
}

func renderActivityFeed(height int64) string {
	var b strings.Builder
	b.WriteString("| | when | who | side | amount |\n|---|---|---|---|---|\n")
	n := len(current.Bets)
	limit := 8
	for i := n - 1; i >= 0 && n-i <= limit; i-- {
		bet := current.Bets[i]
		ago := height - bet.Block
		when := ufmt.Sprintf("%d blocks ago", ago)
		marker := ""
		if ago == 0 {
			when = "just now"
			marker = "✨"
		} else if ago <= 3 {
			marker = "🔥"
		}
		short := bet.Bettor.String()
		if len(short) > 14 {
			short = short[:8] + "…" + short[len(short)-4:]
		}
		b.WriteString(ufmt.Sprintf("| %s | %s | `%s` | %s | `%d ugnot` |\n",
			marker, when, short, choiceLabel(bet.Choice), bet.Amount))
	}
	return b.String()
}
