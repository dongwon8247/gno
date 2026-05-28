package snakeplan

import (
	"encoding/base64"
	"strings"

	"chain/runtime"

	"gno.land/p/moul/txlink"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/dna"
)

const stepMs = 400 // ms per step in the replay

func Render(path string) string {
	path = strings.TrimSpace(path)

	var last *GameResult
	if strings.HasPrefix(path, "g1") && len(path) >= 30 {
		if v, ok := games.Get(path); ok {
			last = v.(*GameResult)
		}
	}

	var b strings.Builder
	height := runtime.ChainHeight()

	b.WriteString("# 🎬 Snake Cinema — Plan & Execute Snake\n\n")

	// Cinematic replay on top.
	if last != nil {
		b.WriteString(renderReplay(last))
	} else {
		b.WriteString(renderEmptyBoard())
	}
	b.WriteString("\n\n")

	// Status strip.
	if last != nil {
		outcome := "🐍 alive"
		if last.Died {
			outcome = ufmt.Sprintf("💀 %s", last.DeathReason)
		}
		b.WriteString(ufmt.Sprintf(
			"%s **YOUR REPLAY** · `%s` · %s · length **%d** · %d steps · 💰 pot **%d ugnot** · [↻ refresh](/r/demo/games/snakeplan:%s) · [⬅ lobby](/r/demo/games/snakeplan)\n\n",
			renderLiveDot(), shortAddr(last.Player), outcome, last.Length, len(last.Path)-1, pot, path,
		))
	} else {
		b.WriteString(ufmt.Sprintf(
			"%s **LIVE** · ⛓ block #%d · 🎬 %d games · 💀 %d deaths · 💰 **%d ugnot pot** · [↻ refresh](/r/demo/games/snakeplan)\n\n",
			renderLiveDot(), height, totalGames, totalDeaths, pot,
		))
	}

	// Record.
	if best.Length > 0 {
		b.WriteString(ufmt.Sprintf(
			"🏆 **Longest run: %d** by `%s` (block #%d) — beat it for the **%d ugnot pot**!\n\n",
			best.Length, shortAddr(best.Player), best.Block, pot,
		))
	} else {
		b.WriteString(ufmt.Sprintf("🏆 **No record yet** — first survivor takes the **%d ugnot pot**!\n\n", pot))
	}

	b.WriteString("> [!NOTE] **One transaction = one full game.** Submit a U/D/L/R sequence; the contract simulates, encodes the run as SVG, and replays it above. No JavaScript, no client.\n\n")

	// Plan + play action area
	b.WriteString("## 🎮 Plan your run\n\n")
	b.WriteString("<gno-form>\n")
	b.WriteString(`<gno-input name="moves" placeholder="RRRUUULLLDDD" description="U/D/L/R sequence (max 200 moves). Case-insensitive. Other chars ignored." />` + "\n")
	b.WriteString("</gno-form>\n\n")
	b.WriteString(ufmt.Sprintf("[**▶ PLAY (100 ugnot) →**](%s)\n\n",
		txlink.NewLink("Play").AddArgs("moves", "").SetSend(ufmt.Sprintf("%dugnot", EntryFee)).URL(),
	))

	// Sample sequences (pre-filled) — instant gratification for first-time visitors.
	b.WriteString("### Quick samples\n\n")
	b.WriteString("<gno-columns>\n\n")
	b.WriteString(sampleCard("Right scan", "RRRRRRRRRDDDDDDDLLLLLLLLLUUUUUUUDDDDDDD",
		"Sweep the board left to right, top to bottom"))
	b.WriteString("\n\n|||\n\n")
	b.WriteString(sampleCard("Spiral", "RRRRRDDDDDLLLLLUUUUURRRDDDLLLDDD",
		"Spiral inward — risky but elegant"))
	b.WriteString("\n\n|||\n\n")
	b.WriteString(sampleCard("Zigzag", "RRDDLLUUURRDDLLLUUUURRDDD",
		"Zigzag through the field"))
	b.WriteString("\n\n</gno-columns>\n\n")

	// Leaderboard with clickable rows to view each player's replay.
	if len(leaderboard) > 0 {
		b.WriteString("## 🏆 Top 10 — click a row to watch their run\n\n")
		b.WriteString("| # | Player | Length | Block | Replay |\n|---|---|---|---|---|\n")
		for i, rec := range leaderboard {
			marker := ""
			if best.Length > 0 && rec.Player == best.Player && rec.Length == best.Length && rec.Block == best.Block {
				marker = " 👑"
			}
			b.WriteString(ufmt.Sprintf("| %d | `%s`%s | **%d** | %d | [▶ watch](/r/demo/games/snakeplan:%s) |\n",
				i+1, shortAddr(rec.Player), marker, rec.Length, rec.Block, rec.Player.String(),
			))
		}
		b.WriteString("\n")
	}

	b.WriteString("---\n\n")
	b.WriteString("**The wild trick:** the contract returns just the result path. The SVG above is a self-animating image — `<animate>` element's `values` attribute scrubs the snake head through every position, at 400ms per step. ")
	b.WriteString("**One tx → one full game → one replay. No backend, no game server, no JS.** Read the [contract](/r/demo/games/snakeplan/snakeplan.gno).\n")

	return b.String()
}

func sampleCard(title, seq, desc string) string {
	url := txlink.NewLink("Play").AddArgs("moves", seq).SetSend(ufmt.Sprintf("%dugnot", EntryFee)).URL()
	return ufmt.Sprintf("**%s** (%d moves)\n\n`%s`\n\n_%s_\n\n[▶ Play this sample →](%s)\n",
		title, len(seq), seq, desc, url)
}

// renderReplay builds the cinematic SVG replay of a single GameResult.
// Head position scrubs through Path via <animate values=...>.
func renderReplay(r *GameResult) string {
	steps := len(r.Path) - 1
	if steps < 0 {
		steps = 0
	}
	totalMs := (steps + 1) * stepMs
	if totalMs < 600 {
		totalMs = 600
	}
	color := dna.ColorOf(r.Player.String())
	headFill := lighten(color)

	var b strings.Builder
	b.WriteString(ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">`,
		SvgW, SvgH, SvgW, SvgH,
	))
	b.WriteString(`<defs>` +
		`<radialGradient id="bg" cx="50%" cy="50%" r="70%">` +
		`<stop offset="0%" stop-color="#1f1f3a"/>` +
		`<stop offset="100%" stop-color="#0a0a1a"/>` +
		`</radialGradient>` +
		`<filter id="glow" x="-50%" y="-50%" width="200%" height="200%">` +
		`<feGaussianBlur stdDeviation="2.5" result="blur"/>` +
		`<feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>` +
		`</filter>` +
		`</defs>`)
	b.WriteString(ufmt.Sprintf(`<rect width="%d" height="%d" fill="url(#bg)"/>`, SvgW, SvgH))

	// Grid.
	for x := 0; x <= BoardW; x++ {
		b.WriteString(ufmt.Sprintf(
			`<line x1="%d" y1="0" x2="%d" y2="%d" stroke="#2a2a45" stroke-width="1"/>`,
			x*CellPx, x*CellPx, SvgH,
		))
	}
	for y := 0; y <= BoardH; y++ {
		b.WriteString(ufmt.Sprintf(
			`<line x1="0" y1="%d" x2="%d" y2="%d" stroke="#2a2a45" stroke-width="1"/>`,
			y*CellPx, SvgW, y*CellPx,
		))
	}

	// Wall border.
	b.WriteString(ufmt.Sprintf(
		`<rect x="1" y="1" width="%d" height="%d" fill="none" stroke="#8B0000" stroke-width="2" stroke-dasharray="5,3"/>`,
		SvgW-2, SvgH-2,
	))

	// Apples — visible from t=0; eaten ones fade out at their eaten step.
	eatenStepAt := map[uint32]int{}
	for i, a := range r.EatenApples {
		eatenStepAt[packCell(a)] = r.EatenAtStep[i]
	}
	for _, a := range r.InitialApples {
		ax := int(a.X)*CellPx + CellPx/2
		ay := int(a.Y)*CellPx + CellPx/2
		b.WriteString(`<g>`)
		// Outer halo.
		b.WriteString(ufmt.Sprintf(
			`<circle cx="%d" cy="%d" r="%d" fill="none" stroke="#FF8080" stroke-width="1" opacity="0.5">`+
				`<animate attributeName="r" values="%d;%d;%d" dur="1.6s" repeatCount="indefinite"/>`+
				`<animate attributeName="opacity" values="0.5;0;0.5" dur="1.6s" repeatCount="indefinite"/>`+
				`</circle>`,
			ax, ay, CellPx/2,
			CellPx/2-2, CellPx/2+3, CellPx/2-2,
		))
		// Apple body.
		b.WriteString(ufmt.Sprintf(
			`<circle cx="%d" cy="%d" r="%d" fill="#FF3B3B" stroke="#7A0F0F" stroke-width="1" filter="url(#glow)">`+
				`<animate attributeName="r" values="%d;%d;%d" dur="1.4s" repeatCount="indefinite"/>`,
			ax, ay, CellPx/3,
			CellPx/3-1, CellPx/3+1, CellPx/3-1,
		))
		if step, eaten := eatenStepAt[packCell(a)]; eaten {
			beginMs := step * stepMs
			b.WriteString(ufmt.Sprintf(
				`<animate attributeName="opacity" from="1" to="0" begin="%dms" dur="180ms" fill="freeze"/>`,
				beginMs,
			))
		}
		b.WriteString(`</circle>`)
		// Highlight.
		b.WriteString(ufmt.Sprintf(`<circle cx="%d" cy="%d" r="1.6" fill="#FFFFFF" opacity="0.75"/>`, ax-3, ay-3))
		b.WriteString(`</g>`)
	}

	// Trail polyline — drawn progressively via stroke-dashoffset animation.
	if len(r.Path) > 1 {
		points := make([]string, len(r.Path))
		for i, c := range r.Path {
			points[i] = ufmt.Sprintf("%d,%d", int(c.X)*CellPx+CellPx/2, int(c.Y)*CellPx+CellPx/2)
		}
		polyStr := strings.Join(points, " ")
		// Approximate path length for dash animation. Each step is ~CellPx in length.
		approxLen := (len(r.Path) - 1) * CellPx
		b.WriteString(ufmt.Sprintf(
			`<polyline points="%s" stroke="%s" stroke-width="%d" stroke-linecap="round" stroke-linejoin="round" fill="none" opacity="0.55" stroke-dasharray="%d %d" stroke-dashoffset="%d">`+
				`<animate attributeName="stroke-dashoffset" from="%d" to="0" dur="%dms" fill="freeze"/>`+
				`</polyline>`,
			polyStr, color, CellPx/2,
			approxLen, approxLen, approxLen,
			approxLen, totalMs,
		))
	}

	// Head — scrubs through Path via animate values.
	if len(r.Path) > 0 {
		xs := make([]string, len(r.Path))
		ys := make([]string, len(r.Path))
		for i, c := range r.Path {
			xs[i] = ufmt.Sprintf("%d", int(c.X)*CellPx+CellPx/2)
			ys[i] = ufmt.Sprintf("%d", int(c.Y)*CellPx+CellPx/2)
		}
		head0 := r.Path[0]
		b.WriteString(ufmt.Sprintf(
			`<circle cx="%d" cy="%d" r="%d" fill="%s" stroke="#FFD700" stroke-width="2" filter="url(#glow)">`,
			int(head0.X)*CellPx+CellPx/2, int(head0.Y)*CellPx+CellPx/2, CellPx/2-3, headFill,
		))
		b.WriteString(ufmt.Sprintf(
			`<animate attributeName="cx" values="%s" dur="%dms" fill="freeze" calcMode="discrete"/>`+
				`<animate attributeName="cy" values="%s" dur="%dms" fill="freeze" calcMode="discrete"/>`,
			strings.Join(xs, ";"), totalMs,
			strings.Join(ys, ";"), totalMs,
		))
		b.WriteString(`</circle>`)
	}

	// Death X at the final cell (appears at end of replay).
	if r.Died && len(r.Path) > 0 {
		lc := r.Path[len(r.Path)-1]
		lx := int(lc.X) * CellPx
		ly := int(lc.Y) * CellPx
		beginMs := (len(r.Path) - 1) * stepMs
		b.WriteString(ufmt.Sprintf(
			`<g stroke="#FF3030" stroke-width="3" stroke-linecap="round" opacity="0">`+
				`<line x1="%d" y1="%d" x2="%d" y2="%d"/>`+
				`<line x1="%d" y1="%d" x2="%d" y2="%d"/>`+
				`<animate attributeName="opacity" from="0" to="1" begin="%dms" dur="220ms" fill="freeze"/>`+
				`</g>`,
			lx+5, ly+5, lx+CellPx-5, ly+CellPx-5,
			lx+CellPx-5, ly+5, lx+5, ly+CellPx-5,
			beginMs,
		))
	}

	b.WriteString(`</svg>`)
	encoded := base64.StdEncoding.EncodeToString([]byte(b.String()))
	return ufmt.Sprintf("![Snake replay](data:image/svg+xml;base64,%s)", encoded)
}

func renderEmptyBoard() string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">`,
		SvgW, SvgH, SvgW, SvgH,
	))
	b.WriteString(`<defs><radialGradient id="bg" cx="50%" cy="50%" r="70%"><stop offset="0%" stop-color="#1f1f3a"/><stop offset="100%" stop-color="#0a0a1a"/></radialGradient></defs>`)
	b.WriteString(ufmt.Sprintf(`<rect width="%d" height="%d" fill="url(#bg)"/>`, SvgW, SvgH))
	for x := 0; x <= BoardW; x++ {
		b.WriteString(ufmt.Sprintf(
			`<line x1="%d" y1="0" x2="%d" y2="%d" stroke="#2a2a45" stroke-width="1"/>`,
			x*CellPx, x*CellPx, SvgH,
		))
	}
	for y := 0; y <= BoardH; y++ {
		b.WriteString(ufmt.Sprintf(
			`<line x1="0" y1="%d" x2="%d" y2="%d" stroke="#2a2a45" stroke-width="1"/>`,
			y*CellPx, SvgW, y*CellPx,
		))
	}
	b.WriteString(ufmt.Sprintf(
		`<rect x="1" y="1" width="%d" height="%d" fill="none" stroke="#8B0000" stroke-width="2" stroke-dasharray="5,3"/>`,
		SvgW-2, SvgH-2,
	))
	// Demo snake at center, idle pulse.
	cx := (BoardW / 2) * CellPx
	cy := (BoardH / 2) * CellPx
	b.WriteString(ufmt.Sprintf(
		`<circle cx="%d" cy="%d" r="%d" fill="#5DADE2" stroke="#FFD700" stroke-width="2">`+
			`<animate attributeName="r" values="%d;%d;%d" dur="1.4s" repeatCount="indefinite"/>`+
			`</circle>`,
		cx+CellPx/2, cy+CellPx/2, CellPx/2-3,
		CellPx/2-5, CellPx/2-1, CellPx/2-5,
	))
	// Text: "Submit a run".
	b.WriteString(ufmt.Sprintf(
		`<text x="%d" y="%d" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="18" font-weight="700" fill="#888">Submit a run to see your replay</text>`,
		SvgW/2, SvgH-30,
	))
	b.WriteString(`</svg>`)
	encoded := base64.StdEncoding.EncodeToString([]byte(b.String()))
	return ufmt.Sprintf("![empty board](data:image/svg+xml;base64,%s)", encoded)
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

func lighten(hex string) string {
	if len(hex) != 7 || hex[0] != '#' {
		return hex
	}
	r := hexB(hex[1], hex[2])
	g := hexB(hex[3], hex[4])
	bl := hexB(hex[5], hex[6])
	return "#" + hex2(min255(r+60)) + hex2(min255(g+60)) + hex2(min255(bl+60))
}

func hexB(hi, lo byte) int { return hexD(hi)*16 + hexD(lo) }

func hexD(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	}
	return 0
}

func min255(v int) int {
	if v > 255 {
		return 255
	}
	return v
}

const hexChars = "0123456789ABCDEF"

func hex2(v int) string {
	v = v & 0xFF
	return string([]byte{hexChars[v>>4], hexChars[v&0xF]})
}
