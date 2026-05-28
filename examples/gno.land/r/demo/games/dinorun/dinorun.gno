// Package dinorun is an on-chain Crash-style endless runner inspired by the
// Chrome offline dinosaur game.
//
// Rules:
//   - Pay EntryFee ugnot to StartRun.
//   - Each Jump advances Distance by the current Speed and then increments
//     Speed (the run gets "faster"). Each jump also rolls for death: the
//     death chance is Distance / DangerDenom percent.
//   - Cashout locks in your distance. If you beat the all-time record, you
//     take the entire pot. If you don't beat it (or you die), your entry fee
//     stays in the pot for the next record-breaker.
//
// This is the "Chrome dino game" reinterpreted for an SSR blockchain: no
// keyboard, no animation — just escalating risk per transaction.
package dinorun

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
	EntryFee       = int64(100) // 100 ugnot
	Denom          = "ugnot"
	StartSpeed     = int64(10)
	SpeedIncrement = int64(1)
	DangerDenom    = int64(5) // death% = distance / 5
	MaxLeaderboard = 10
)

type Run struct {
	Player     address
	Distance   int64
	Speed      int64
	Alive      bool
	StartBlock int64
	Jumps      int
}

type Record struct {
	Player   address
	Distance int64
	Block    int64
}

var (
	activeRuns  *avl.Tree // address.String() -> *Run
	leaderboard []Record
	best        Record
	pot         int64
	totalRuns   uint64
	totalJumps  uint64
)

func init() {
	activeRuns = avl.NewTree()
}

// StartRun begins a new run for the caller. Send exactly EntryFee ugnot.
// If the caller has a previous dead run that wasn't explicitly cashed out, it
// is auto-finalized to the leaderboard before the new run starts.
func StartRun(cur realm) {
	caller := unsafe.OriginCaller()
	key := caller.String()

	if v, has := activeRuns.Get(key); has {
		r := v.(*Run)
		if r.Alive {
			panic("you already have an active run — Cashout it first")
		}
		// Auto-finalize the dead run.
		finalize(cur, r)
		activeRuns.Remove(key)
	}

	sent := unsafe.OriginSend()
	if sent.AmountOf(Denom) != EntryFee {
		panic(ufmt.Sprintf("entry fee is exactly %d ugnot", EntryFee))
	}

	pot += EntryFee
	totalRuns++

	activeRuns.Set(key, &Run{
		Player:     caller,
		Distance:   0,
		Speed:      StartSpeed,
		Alive:      true,
		StartBlock: runtime.ChainHeight(),
	})

	chain.Emit("RunStarted", "player", key, "pot", ufmt.Sprintf("%d", pot))
}

// Jump advances the caller's run by Speed meters, then increments Speed.
// May kill the runner.
func Jump(cur realm) {
	caller := unsafe.OriginCaller()
	key := caller.String()

	v, has := activeRuns.Get(key)
	if !has {
		panic("no active run — StartRun first")
	}
	r := v.(*Run)
	if !r.Alive {
		panic("you're dead — Cashout to finalize")
	}

	r.Distance += r.Speed
	r.Speed += SpeedIncrement
	r.Jumps++
	totalJumps++

	chance := r.Distance / DangerDenom
	if chance >= 100 {
		r.Alive = false
	} else {
		seed1 := uint64(entropy.New().Seed())
		seed2 := uint64(entropy.New().Seed())
		rng := rand.New(rand.NewPCG(seed1, seed2))
		roll := int64(rng.IntN(100))
		if roll < chance {
			r.Alive = false
		}
	}

	chain.Emit("Jumped",
		"player", key,
		"distance", ufmt.Sprintf("%d", r.Distance),
		"alive", ufmt.Sprintf("%t", r.Alive),
	)
}

// Cashout finalizes the caller's run. If alive and the distance beats the
// record, the entire pot is paid out.
func Cashout(cur realm) {
	caller := unsafe.OriginCaller()
	key := caller.String()

	v, has := activeRuns.Get(key)
	if !has {
		panic("no active run")
	}
	r := v.(*Run)
	finalize(cur, r)
	activeRuns.Remove(key)
}

// finalize records a run on the leaderboard and pays out the pot if the run
// beats the all-time record while still alive.
func finalize(cur realm, r *Run) {
	score := r.Distance
	key := r.Player.String()

	rec := Record{Player: r.Player, Distance: score, Block: runtime.ChainHeight()}
	leaderboard = append(leaderboard, rec)
	sortLeaderboard()
	if len(leaderboard) > MaxLeaderboard {
		leaderboard = leaderboard[:MaxLeaderboard]
	}

	won := r.Alive && score > best.Distance
	if won {
		best = rec
		prize := pot
		pot = 0
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), r.Player, chain.NewCoins(chain.NewCoin(Denom, prize)))
		chain.Emit("NewRecord",
			"player", key,
			"distance", ufmt.Sprintf("%d", score),
			"prize", ufmt.Sprintf("%d", prize),
		)
		return
	}

	reason := "no record"
	if !r.Alive {
		reason = "died"
	}
	chain.Emit("Cashout", "player", key, "distance", ufmt.Sprintf("%d", score), "reason", reason)
}

func sortLeaderboard() {
	for i := 0; i < len(leaderboard); i++ {
		for j := i + 1; j < len(leaderboard); j++ {
			if leaderboard[j].Distance > leaderboard[i].Distance {
				leaderboard[i], leaderboard[j] = leaderboard[j], leaderboard[i]
			}
		}
	}
}

// Render uses the path argument as the viewer's address. If the path is a
// g1-address whose owner has an active run, the page becomes their personal
// game board (banner shows their dino, buttons show only the allowed actions).
// Otherwise it renders the lobby with the demo banner.
func Render(path string) string {
	path = strings.TrimSpace(path)

	var playerRun *Run
	if strings.HasPrefix(path, "g1") {
		if v, ok := activeRuns.Get(path); ok {
			playerRun = v.(*Run)
		}
	}

	var b strings.Builder
	height := runtime.ChainHeight()

	b.WriteString("# 🦖 DinoRun — On-chain endless runner\n\n")

	// State-aware top banner
	switch {
	case playerRun == nil:
		b.WriteString(renderDinoBanner())
	case !playerRun.Alive:
		b.WriteString(renderDeathBanner(playerRun))
	default:
		b.WriteString(renderGameBanner(playerRun))
	}
	b.WriteString("\n\n")

	// State-aware status strip
	if playerRun != nil {
		alive := "🏃 alive"
		if !playerRun.Alive {
			alive = "💀 dead"
		}
		b.WriteString(ufmt.Sprintf(
			"%s **YOUR RUN** · `%s` · %s · **%dm** · next jump `+%dm` · 💀 **%d%%** · 💰 pot `%d` ugnot · [↻ refresh](/r/demo/games/dinorun:%s) · [⬅ exit to lobby](/r/demo/games/dinorun)\n\n",
			renderLiveDot(), shortAddr(playerRun.Player), alive,
			playerRun.Distance, playerRun.Speed, dieChance(playerRun.Distance),
			pot, path,
		))
	} else {
		b.WriteString(ufmt.Sprintf(
			"%s **LIVE** · ⛓ block #%d · 🎲 %d runs · 🦘 %d jumps · 💰 **%d ugnot pot** · [↻ refresh](/r/demo/games/dinorun)\n\n",
			renderLiveDot(), height, totalRuns, totalJumps, pot,
		))
	}

	// Record line
	if best.Distance > 0 {
		b.WriteString(ufmt.Sprintf(
			"🏆 **All-time record: %dm** by `%s` (block #%d) — beat it to take the **%d ugnot pot**!\n\n",
			best.Distance, shortAddr(best.Player), best.Block, pot,
		))
	} else {
		b.WriteString(ufmt.Sprintf(
			"🏆 **No record yet** — first runner to cashout alive takes the **%d ugnot pot**!\n\n",
			pot,
		))
	}

	// State-aware action area
	switch {
	case playerRun == nil:
		b.WriteString("## 🎮 Click to play\n\n")
		b.WriteString("<gno-columns>\n\n")
		b.WriteString(renderStartButton())
		b.WriteString("\n\n|||\n\n")
		b.WriteString("### 💡 How it works\n\n")
		b.WriteString("Pay **100 ugnot** to start.\n\n")
		b.WriteString("Each `Jump` → `+10m` start, `+1m` faster each jump.\n\n")
		b.WriteString("**Death% = distance / 5**.\n\n")
		b.WriteString("**Cashout alive** + beat record → take entire pot. ")
		b.WriteString("Die or under-perform → entry fee feeds the pot.\n\n")
		b.WriteString("</gno-columns>\n\n")
	case !playerRun.Alive:
		b.WriteString("## 💀 Game over — finalize your run\n\n")
		b.WriteString("<gno-columns>\n\n")
		b.WriteString(renderCashoutButton())
		b.WriteString("\n\n|||\n\n")
		b.WriteString(ufmt.Sprintf("### Final distance: **%dm**\n\n", playerRun.Distance))
		b.WriteString("You took the leap. The dino didn't make it.\n\n")
		b.WriteString("Click **Cashout** to record your score on the leaderboard. Or just `Start Run` — your dead run will auto-finalize.\n\n")
		b.WriteString("</gno-columns>\n\n")
	default:
		nextDistance := playerRun.Distance + playerRun.Speed
		nextDie := dieChance(nextDistance)
		b.WriteString("## 🎮 Your move\n\n")
		b.WriteString(ufmt.Sprintf(
			"At **%dm**, your next `Jump` will land you at **%dm** with a **%d%% death chance**. Cashout while alive to take the pot if you've beaten the record.\n\n",
			playerRun.Distance, nextDistance, nextDie,
		))
		b.WriteString("<gno-columns>\n\n")
		b.WriteString(renderJumpButton())
		b.WriteString("\n\n|||\n\n")
		b.WriteString(renderCashoutButton())
		b.WriteString("\n\n</gno-columns>\n\n")
	}

	// Active runners — always shown so spectators see who's playing.
	if activeRuns.Size() > 0 {
		b.WriteString("## 🏃 Currently running\n\n")
		b.WriteString(renderActiveRuns(height, path))
	}

	if playerRun == nil {
		// Show full how-it-works in lobby.
		b.WriteString("## ⚙️ Detailed mechanics\n\n")
		b.WriteString("```\n")
		b.WriteString("Jump #1 → +10m   (speed 10, death% = 2%)\n")
		b.WriteString("Jump #2 → +11m   (speed 11, death% = 4%)\n")
		b.WriteString("Jump #3 → +12m   (speed 12, death% = 6%)\n")
		b.WriteString("...\n")
		b.WriteString("Jump #10 → +19m  (speed 19, death% = 30%)\n")
		b.WriteString("Jump #20 → +29m  (speed 29, death% ≈ 70%)  🔥\n")
		b.WriteString("```\n\n")
	}

	// Leaderboard
	if len(leaderboard) > 0 {
		b.WriteString("## 🏆 Top 10\n\n")
		b.WriteString("| # | Runner | Distance | Block |\n|---|---|---|---|\n")
		for i, rec := range leaderboard {
			marker := ""
			if best.Distance > 0 && rec.Player == best.Player && rec.Distance == best.Distance && rec.Block == best.Block {
				marker = " 👑"
			}
			b.WriteString(ufmt.Sprintf("| %d | `%s`%s | **%dm** | %d |\n",
				i+1, shortAddr(rec.Player), marker, rec.Distance, rec.Block))
		}
		b.WriteString("\n")
	}

	b.WriteString("---\n\n")
	b.WriteString("**Why this is wild:** game state, randomness, pot mechanics, payouts — one ")
	b.WriteString("[contract](/r/demo/games/dinorun/dinorun.gno). ")
	b.WriteString("Player avatars composed from [/r/demo/dna](/r/demo/dna). ")
	b.WriteString("No off-chain server, no game backend — every meter, every death, every payout is on-chain and auditable.\n")

	return b.String()
}

func dieChance(distance int64) int64 {
	c := distance / DangerDenom
	if c > 100 {
		c = 100
	}
	return c
}

func renderActiveRuns(height int64, currentPath string) string {
	var b strings.Builder
	b.WriteString("<gno-columns>\n\n")
	i := 0
	activeRuns.Iterate("", "", func(key string, value any) bool {
		if i > 0 && i%3 == 0 {
			b.WriteString("|||\n\n")
		}
		r := value.(*Run)
		chance := dieChance(r.Distance)
		isYou := key == currentPath
		marker := ""
		if isYou {
			marker = " 🎯 **YOU**"
		}

		status := "🏃 alive"
		if !r.Alive {
			status = "💀 dead — Cashout!"
		}
		b.WriteString(dna.GenerateMini(key))
		b.WriteString("\n\n")
		b.WriteString(ufmt.Sprintf("`%s`%s<br>\n", shortAddr(r.Player), marker))
		b.WriteString(ufmt.Sprintf("**%dm** · %s<br>\n", r.Distance, status))
		if r.Alive {
			b.WriteString(ufmt.Sprintf("next `+%dm` · 💀 **%d%%**<br>\n", r.Speed, chance))
		}
		if !isYou {
			b.WriteString(ufmt.Sprintf("[Open this view →](/r/demo/games/dinorun:%s)\n", key))
		}
		b.WriteString("\n")
		i++
		return false
	})
	b.WriteString("</gno-columns>\n\n")
	return b.String()
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) > 14 {
		return s[:8] + "…" + s[len(s)-4:]
	}
	return s
}

// renderDinoBanner returns a big self-animating SVG: a running dinosaur (legs
// shuffling), scrolling cacti, drifting clouds, and a horizon line. Pure
// SMIL — keeps animating with no refresh.
func renderDinoBanner() string {
	const raw = `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="200" viewBox="0 0 800 200">` +
		// Sky + ground
		`<rect width="800" height="160" fill="#F7F7F7"/>` +
		`<rect y="160" width="800" height="40" fill="#EDEDED"/>` +
		`<line x1="0" y1="160" x2="800" y2="160" stroke="#535353" stroke-width="2"/>` +
		// Ground texture dashes scrolling
		`<g stroke="#535353" stroke-width="1">` +
		`<line x1="0" y1="170" x2="40" y2="170"><animate attributeName="x1" from="0" to="-800" dur="4s" repeatCount="indefinite"/><animate attributeName="x2" from="40" to="-760" dur="4s" repeatCount="indefinite"/></line>` +
		`<line x1="120" y1="175" x2="200" y2="175"><animate attributeName="x1" from="120" to="-680" dur="4s" repeatCount="indefinite"/><animate attributeName="x2" from="200" to="-600" dur="4s" repeatCount="indefinite"/></line>` +
		`<line x1="320" y1="172" x2="380" y2="172"><animate attributeName="x1" from="320" to="-480" dur="4s" repeatCount="indefinite"/><animate attributeName="x2" from="380" to="-420" dur="4s" repeatCount="indefinite"/></line>` +
		`<line x1="500" y1="178" x2="600" y2="178"><animate attributeName="x1" from="500" to="-300" dur="4s" repeatCount="indefinite"/><animate attributeName="x2" from="600" to="-200" dur="4s" repeatCount="indefinite"/></line>` +
		`<line x1="700" y1="173" x2="780" y2="173"><animate attributeName="x1" from="700" to="-100" dur="4s" repeatCount="indefinite"/><animate attributeName="x2" from="780" to="-20" dur="4s" repeatCount="indefinite"/></line>` +
		`</g>` +
		// Clouds (drift slow)
		`<g fill="#BBBBBB">` +
		`<ellipse cx="100" cy="40" rx="30" ry="10"><animate attributeName="cx" from="900" to="-100" dur="22s" repeatCount="indefinite"/></ellipse>` +
		`<ellipse cx="400" cy="30" rx="25" ry="8"><animate attributeName="cx" from="900" to="-100" dur="28s" repeatCount="indefinite"/></ellipse>` +
		`<ellipse cx="650" cy="50" rx="32" ry="11"><animate attributeName="cx" from="900" to="-100" dur="20s" repeatCount="indefinite"/></ellipse>` +
		`</g>` +
		// Cacti (fast scroll)
		`<g fill="#2E7D32">` +
		`<g><rect x="0" y="120" width="14" height="40"/><rect x="-6" y="130" width="6" height="14"/><rect x="14" y="125" width="6" height="14"/>` +
		`<animateTransform attributeName="transform" type="translate" from="850 0" to="-50 0" dur="3.2s" repeatCount="indefinite"/></g>` +
		`<g><rect x="0" y="128" width="10" height="32"/><rect x="-4" y="138" width="4" height="10"/>` +
		`<animateTransform attributeName="transform" type="translate" from="850 0" to="-50 0" begin="1.0s" dur="3.2s" repeatCount="indefinite"/></g>` +
		`<g><rect x="0" y="115" width="16" height="45"/><rect x="-6" y="125" width="6" height="16"/><rect x="16" y="120" width="6" height="16"/>` +
		`<animateTransform attributeName="transform" type="translate" from="850 0" to="-50 0" begin="2.1s" dur="3.2s" repeatCount="indefinite"/></g>` +
		`</g>` +
		// Pterodactyl drifting high
		`<g fill="#535353"><g>` +
		`<rect x="0" y="60" width="14" height="3"/>` +
		`<polygon points="0,60 -10,55 -8,62"><animate attributeName="points" values="0,60 -10,55 -8,62;0,60 -8,63 -8,62;0,60 -10,55 -8,62" dur="0.4s" repeatCount="indefinite"/></polygon>` +
		`<polygon points="14,60 24,55 22,62"><animate attributeName="points" values="14,60 24,55 22,62;14,60 22,63 22,62;14,60 24,55 22,62" dur="0.4s" repeatCount="indefinite"/></polygon>` +
		`<animateTransform attributeName="transform" type="translate" from="850 0" to="-50 0" dur="9s" repeatCount="indefinite"/></g></g>` +
		// Dinosaur (fixed on left), legs alternating
		`<g transform="translate(70 100)" fill="#535353">` +
		`<rect x="0" y="20" width="40" height="32"/>` + // body
		`<rect x="30" y="0" width="30" height="28"/>` + // head
		`<rect x="55" y="8" width="4" height="4" fill="#F7F7F7"/>` + // eye
		`<rect x="44" y="22" width="2" height="2" fill="#F7F7F7"/>` + // mouth
		`<rect x="-8" y="35" width="10" height="5"/>` + // tail
		// left leg
		`<rect x="6" y="52" width="9" height="12">` +
		`<animate attributeName="height" values="12;6;12" dur="0.28s" repeatCount="indefinite"/>` +
		`<animate attributeName="y" values="52;58;52" dur="0.28s" repeatCount="indefinite"/>` +
		`</rect>` +
		// right leg
		`<rect x="24" y="52" width="9" height="12">` +
		`<animate attributeName="height" values="6;12;6" dur="0.28s" repeatCount="indefinite"/>` +
		`<animate attributeName="y" values="58;52;58" dur="0.28s" repeatCount="indefinite"/>` +
		`</rect>` +
		`</g>` +
		// Speed-line accents next to dino
		`<g stroke="#999" stroke-width="2" fill="none">` +
		`<line x1="50" y1="115" x2="35" y2="115"><animate attributeName="opacity" values="0;1;0" dur="0.6s" repeatCount="indefinite"/></line>` +
		`<line x1="50" y1="130" x2="30" y2="130"><animate attributeName="opacity" values="0;1;0" dur="0.6s" begin="0.2s" repeatCount="indefinite"/></line>` +
		`<line x1="50" y1="145" x2="40" y2="145"><animate attributeName="opacity" values="0;1;0" dur="0.6s" begin="0.4s" repeatCount="indefinite"/></line>` +
		`</g>` +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("![DinoRun](data:image/svg+xml;base64,%s)", encoded)
}

// renderGameBanner builds the personalized track for an alive run. The dino
// sits at the left, the *next* obstacle is drawn at the right showing the
// preview of where the next jump will land, and a top bar shows distance /
// speed / death-chance numbers. The danger bar grows red as you approach death.
func renderGameBanner(r *Run) string {
	chance := dieChance(r.Distance)
	dangerW := int(chance * 7) // 700 max width
	dangerColor := "#4CAF50"
	switch {
	case chance >= 70:
		dangerColor = "#D32F2F"
	case chance >= 40:
		dangerColor = "#E59500"
	}

	raw := `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="200" viewBox="0 0 800 200">` +
		// Sky + ground
		`<rect width="800" height="160" fill="#F7F7F7"/>` +
		`<rect y="160" width="800" height="40" fill="#EDEDED"/>` +
		`<line x1="0" y1="160" x2="800" y2="160" stroke="#535353" stroke-width="2"/>` +
		// Scrolling ground texture
		`<g stroke="#535353" stroke-width="1">` +
		`<line x1="0" y1="170" x2="40" y2="170"><animate attributeName="x1" from="0" to="-800" dur="2.4s" repeatCount="indefinite"/><animate attributeName="x2" from="40" to="-760" dur="2.4s" repeatCount="indefinite"/></line>` +
		`<line x1="200" y1="175" x2="300" y2="175"><animate attributeName="x1" from="200" to="-600" dur="2.4s" repeatCount="indefinite"/><animate attributeName="x2" from="300" to="-500" dur="2.4s" repeatCount="indefinite"/></line>` +
		`<line x1="500" y1="172" x2="580" y2="172"><animate attributeName="x1" from="500" to="-300" dur="2.4s" repeatCount="indefinite"/><animate attributeName="x2" from="580" to="-220" dur="2.4s" repeatCount="indefinite"/></line>` +
		`</g>` +
		// Big distance number top-right
		ufmt.Sprintf(`<text x="780" y="42" text-anchor="end" font-family="-apple-system,sans-serif" font-size="36" font-weight="800" fill="#222">%dm</text>`, r.Distance) +
		`<text x="780" y="60" text-anchor="end" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#666">DISTANCE</text>` +
		// Speed + jump#
		ufmt.Sprintf(`<text x="780" y="92" text-anchor="end" font-family="-apple-system,sans-serif" font-size="14" font-weight="700" fill="#444">next +%dm · jump #%d</text>`, r.Speed, r.Jumps+1) +
		// Death % gauge label
		ufmt.Sprintf(`<text x="40" y="42" text-anchor="start" font-family="-apple-system,sans-serif" font-size="36" font-weight="800" fill="%s">%d%%</text>`, dangerColor, chance) +
		`<text x="40" y="60" text-anchor="start" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#666">DEATH CHANCE</text>` +
		// Danger gauge bar (background)
		`<rect x="40" y="74" width="700" height="10" rx="5" ry="5" fill="#E0E0E0"/>` +
		// Danger gauge fill, with pulse if >= 70%
		ufmt.Sprintf(`<rect x="40" y="74" width="%d" height="10" rx="5" ry="5" fill="%s">`, dangerW, dangerColor)
	if chance >= 70 {
		raw += `<animate attributeName="opacity" values="1;0.4;1" dur="0.8s" repeatCount="indefinite"/>`
	}
	raw += `</rect>` +
		// Running dino (left, fixed) — legs alternate
		`<g transform="translate(70 100)" fill="#535353">` +
		`<rect x="0" y="20" width="40" height="32"/>` +
		`<rect x="30" y="0" width="30" height="28"/>` +
		`<rect x="55" y="8" width="4" height="4" fill="#F7F7F7"/>` +
		`<rect x="44" y="22" width="2" height="2" fill="#F7F7F7"/>` +
		`<rect x="-8" y="35" width="10" height="5"/>` +
		`<rect x="6" y="52" width="9" height="12">` +
		`<animate attributeName="height" values="12;6;12" dur="0.22s" repeatCount="indefinite"/>` +
		`<animate attributeName="y" values="52;58;52" dur="0.22s" repeatCount="indefinite"/>` +
		`</rect>` +
		`<rect x="24" y="52" width="9" height="12">` +
		`<animate attributeName="height" values="6;12;6" dur="0.22s" repeatCount="indefinite"/>` +
		`<animate attributeName="y" values="58;52;58" dur="0.22s" repeatCount="indefinite"/>` +
		`</rect>` +
		`</g>` +
		// Speed lines behind dino — denser/brighter
		`<g stroke="#999" stroke-width="2" fill="none">` +
		`<line x1="55" y1="115" x2="20" y2="115"><animate attributeName="opacity" values="0;1;0" dur="0.4s" repeatCount="indefinite"/></line>` +
		`<line x1="55" y1="128" x2="15" y2="128"><animate attributeName="opacity" values="0;1;0" dur="0.4s" begin="0.13s" repeatCount="indefinite"/></line>` +
		`<line x1="55" y1="142" x2="25" y2="142"><animate attributeName="opacity" values="0;1;0" dur="0.4s" begin="0.26s" repeatCount="indefinite"/></line>` +
		`</g>` +
		// Incoming obstacle (cactus) coming from right; speed scales with distance
		ufmt.Sprintf(`<g fill="%s">`, dangerColor) +
		`<g><rect x="0" y="120" width="14" height="40"/><rect x="-6" y="130" width="6" height="14"/><rect x="14" y="125" width="6" height="14"/>` +
		ufmt.Sprintf(`<animateTransform attributeName="transform" type="translate" from="850 0" to="-50 0" dur="%.1fs" repeatCount="indefinite"/>`, obstacleDuration(r.Distance)) +
		`</g></g>` +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("![Your run](data:image/svg+xml;base64,%s)", encoded)
}

// obstacleDuration returns how fast incoming cacti scroll: shorter as the
// player goes further. Visual signal that the game is "speeding up".
func obstacleDuration(distance int64) float64 {
	d := 3.0 - float64(distance)/100.0
	if d < 0.8 {
		d = 0.8
	}
	return d
}

// renderDeathBanner: a static-looking, dramatic banner showing a fallen dino,
// a "GAME OVER" stamp, and the final distance.
func renderDeathBanner(r *Run) string {
	raw := `<svg xmlns="http://www.w3.org/2000/svg" width="800" height="200" viewBox="0 0 800 200">` +
		`<rect width="800" height="160" fill="#FFEEEE"/>` +
		`<rect y="160" width="800" height="40" fill="#EDDDDD"/>` +
		`<line x1="0" y1="160" x2="800" y2="160" stroke="#8B0000" stroke-width="2"/>` +
		// Fallen dino (rotated 90deg)
		`<g transform="translate(120 158) rotate(-85)" fill="#8B0000">` +
		`<rect x="0" y="20" width="40" height="32"/>` +
		`<rect x="30" y="0" width="30" height="28"/>` +
		`<rect x="55" y="8" width="4" height="4" fill="#FFEEEE"/>` +
		`<rect x="44" y="22" width="2" height="2" fill="#FFEEEE"/>` +
		`<rect x="6" y="52" width="9" height="12"/>` +
		`<rect x="24" y="52" width="9" height="12"/>` +
		`</g>` +
		// X-eyes (faint floating)
		`<g stroke="#8B0000" stroke-width="3" fill="none">` +
		`<line x1="200" y1="60" x2="220" y2="80"><animate attributeName="opacity" values="1;0.5;1" dur="1.4s" repeatCount="indefinite"/></line>` +
		`<line x1="220" y1="60" x2="200" y2="80"><animate attributeName="opacity" values="1;0.5;1" dur="1.4s" repeatCount="indefinite"/></line>` +
		`</g>` +
		// Cactus that killed
		`<g fill="#2E7D32">` +
		`<rect x="260" y="120" width="14" height="40"/>` +
		`<rect x="254" y="130" width="6" height="14"/>` +
		`<rect x="274" y="125" width="6" height="14"/>` +
		`</g>` +
		// GAME OVER text
		`<text x="500" y="60" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="40" font-weight="900" fill="#8B0000">💀 GAME OVER</text>` +
		ufmt.Sprintf(`<text x="500" y="105" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="48" font-weight="900" fill="#222">%dm</text>`, r.Distance) +
		ufmt.Sprintf(`<text x="500" y="125" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="13" font-weight="700" fill="#666">final distance · %d jumps</text>`, r.Jumps) +
		// Faint pulsing record-comparison text
		ufmt.Sprintf(`<text x="500" y="150" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#888">cashout to record · record is %dm</text>`, best.Distance) +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("![Game over](data:image/svg+xml;base64,%s)", encoded)
}

// --- Interactive SVG button cards ---

// renderStartButton: green card, dino with a "GO!" flag and a 100ugnot tag.
// Click anywhere on the card → StartRun tx with 100ugnot pre-filled.
func renderStartButton() string {
	raw := `<svg xmlns="http://www.w3.org/2000/svg" width="260" height="140" viewBox="0 0 260 140">` +
		// Card background with pulse
		`<rect width="260" height="140" rx="12" ry="12" fill="#2E7D32"/>` +
		`<rect width="260" height="140" rx="12" ry="12" fill="#FFFFFF" opacity="0">` +
		`<animate attributeName="opacity" values="0;0.15;0" dur="1.8s" repeatCount="indefinite"/>` +
		`</rect>` +
		// Mini dino at start line
		`<g transform="translate(20 70)" fill="#FFFFFF">` +
		`<rect x="0" y="0" width="22" height="18"/>` +
		`<rect x="17" y="-13" width="16" height="16"/>` +
		`<rect x="29" y="-9" width="3" height="3" fill="#2E7D32"/>` +
		`<rect x="2" y="18" width="6" height="8">` +
		`<animate attributeName="height" values="8;4;8" dur="0.35s" repeatCount="indefinite"/>` +
		`</rect>` +
		`<rect x="14" y="18" width="6" height="8">` +
		`<animate attributeName="height" values="4;8;4" dur="0.35s" repeatCount="indefinite"/>` +
		`</rect>` +
		`</g>` +
		// Start flag (waving)
		`<g transform="translate(58 30)" fill="#FFFFFF">` +
		`<rect x="0" y="0" width="2" height="50"/>` +
		`<polygon points="2,0 2,18 22,9">` +
		`<animate attributeName="points" values="2,0 2,18 22,9;2,0 2,18 19,12;2,0 2,18 22,9" dur="0.7s" repeatCount="indefinite"/>` +
		`</polygon>` +
		`</g>` +
		// Title text
		`<text x="130" y="38" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="22" font-weight="800" fill="#FFFFFF">START RUN</text>` +
		// Cost tag
		`<rect x="160" y="60" width="80" height="40" rx="6" ry="6" fill="#FFFFFF"/>` +
		`<text x="200" y="78" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="11" font-weight="700" fill="#2E7D32">ENTRY FEE</text>` +
		`<text x="200" y="93" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="13" font-weight="800" fill="#2E7D32">100 ugnot</text>` +
		// Click hint
		`<text x="130" y="125" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.85">▶  CLICK TO BEGIN</text>` +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("[![Start Run](data:image/svg+xml;base64,%s)](%s)",
		encoded,
		txlink.NewLink("StartRun").SetSend(ufmt.Sprintf("%dugnot", EntryFee)).URL(),
	)
}

// renderJumpButton: blue card, dino mid-jump with speed lines.
// Click → Jump tx.
func renderJumpButton() string {
	raw := `<svg xmlns="http://www.w3.org/2000/svg" width="260" height="140" viewBox="0 0 260 140">` +
		`<rect width="260" height="140" rx="12" ry="12" fill="#1565C0"/>` +
		// pulsing flash
		`<rect width="260" height="140" rx="12" ry="12" fill="#FFFFFF" opacity="0">` +
		`<animate attributeName="opacity" values="0;0.2;0" dur="0.9s" repeatCount="indefinite"/>` +
		`</rect>` +
		// Mid-jump dino arching up and down
		`<g fill="#FFFFFF">` +
		`<g>` +
		`<rect x="0" y="0" width="26" height="20"/>` +
		`<rect x="20" y="-14" width="18" height="18"/>` +
		`<rect x="34" y="-10" width="3" height="3" fill="#1565C0"/>` +
		`<rect x="2" y="20" width="6" height="8"/>` +
		`<rect x="16" y="20" width="6" height="8"/>` +
		`<animateTransform attributeName="transform" type="translate" values="40 80;40 35;40 80" dur="1.4s" repeatCount="indefinite"/>` +
		`</g>` +
		`</g>` +
		// ground line
		`<line x1="20" y1="115" x2="240" y2="115" stroke="#FFFFFF" stroke-width="2" opacity="0.6"/>` +
		// speed lines behind dino
		`<g stroke="#FFFFFF" stroke-width="2" opacity="0.7">` +
		`<line x1="25" y1="60" x2="5" y2="60"><animate attributeName="opacity" values="0;0.9;0" dur="0.5s" repeatCount="indefinite"/></line>` +
		`<line x1="20" y1="75" x2="0" y2="75"><animate attributeName="opacity" values="0;0.9;0" dur="0.5s" begin="0.15s" repeatCount="indefinite"/></line>` +
		`<line x1="25" y1="90" x2="0" y2="90"><animate attributeName="opacity" values="0;0.9;0" dur="0.5s" begin="0.3s" repeatCount="indefinite"/></line>` +
		`</g>` +
		// title
		`<text x="180" y="40" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="26" font-weight="800" fill="#FFFFFF">▶ JUMP</text>` +
		`<text x="180" y="60" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.9">risk one more step</text>` +
		`<text x="180" y="125" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.85">▶  CLICK TO JUMP</text>` +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("[![Jump](data:image/svg+xml;base64,%s)](%s)",
		encoded, txlink.NewLink("Jump").URL(),
	)
}

// renderCashoutButton: orange card, coin spinning.
// Click → Cashout tx.
func renderCashoutButton() string {
	raw := `<svg xmlns="http://www.w3.org/2000/svg" width="260" height="140" viewBox="0 0 260 140">` +
		`<rect width="260" height="140" rx="12" ry="12" fill="#E59500"/>` +
		`<rect width="260" height="140" rx="12" ry="12" fill="#FFFFFF" opacity="0">` +
		`<animate attributeName="opacity" values="0;0.18;0" dur="2.2s" repeatCount="indefinite"/>` +
		`</rect>` +
		// Spinning coin (rx animation simulates rotation)
		`<g transform="translate(48 70)">` +
		`<ellipse cx="0" cy="0" rx="28" ry="28" fill="#FFD700" stroke="#8B6914" stroke-width="2">` +
		`<animate attributeName="rx" values="28;6;28" dur="1.6s" repeatCount="indefinite"/>` +
		`</ellipse>` +
		`<text x="0" y="6" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="20" font-weight="800" fill="#8B6914">$</text>` +
		`</g>` +
		// falling coins
		`<g fill="#FFD700" stroke="#8B6914" stroke-width="1">` +
		`<circle cx="100" cy="30" r="5"><animate attributeName="cy" from="20" to="135" dur="1.8s" repeatCount="indefinite"/><animate attributeName="opacity" values="1;1;0" dur="1.8s" repeatCount="indefinite"/></circle>` +
		`<circle cx="120" cy="20" r="4"><animate attributeName="cy" from="10" to="135" dur="2.1s" begin="0.4s" repeatCount="indefinite"/><animate attributeName="opacity" values="1;1;0" dur="2.1s" begin="0.4s" repeatCount="indefinite"/></circle>` +
		`<circle cx="140" cy="40" r="5"><animate attributeName="cy" from="20" to="135" dur="1.7s" begin="0.8s" repeatCount="indefinite"/><animate attributeName="opacity" values="1;1;0" dur="1.7s" begin="0.8s" repeatCount="indefinite"/></circle>` +
		`</g>` +
		// title
		`<text x="170" y="40" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="24" font-weight="800" fill="#FFFFFF">💰 CASHOUT</text>` +
		`<text x="170" y="60" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.9">lock in your distance</text>` +
		`<text x="170" y="125" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.85">▶  CLICK TO CASHOUT</text>` +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("[![Cashout](data:image/svg+xml;base64,%s)](%s)",
		encoded, txlink.NewLink("Cashout").URL(),
	)
}

func renderLiveDot() string {
	const raw = `<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">` +
		`<circle cx="7" cy="7" r="5" fill="#E50000">` +
		`<animate attributeName="opacity" values="1;0.25;1" dur="1.1s" repeatCount="indefinite"/>` +
		`<animate attributeName="r" values="5;6;5" dur="1.1s" repeatCount="indefinite"/>` +
		`</circle></svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("![live](data:image/svg+xml;base64,%s)", encoded)
}
