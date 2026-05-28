package snake

import (
	"encoding/base64"
	"strings"

	"chain/runtime"

	"gno.land/p/moul/txlink"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/dna"
)

// Render(path): if path is a g1 address, the page becomes that player's
// personalized view. Otherwise it's the lobby.
func Render(path string) string {
	path = strings.TrimSpace(path)

	var me *Snake
	if strings.HasPrefix(path, "g1") {
		if v, ok := snakes.Get(path); ok {
			me = v.(*Snake)
		}
	}

	var b strings.Builder
	height := runtime.ChainHeight()

	b.WriteString("# 🐍 Snake World — Communal on-chain Snake\n\n")

	// Always show the live board.
	b.WriteString(renderBoard(me))
	b.WriteString("\n\n")

	// State strip.
	if me != nil {
		alive := "🐍 alive"
		if !me.Alive {
			alive = "💀 dead"
		}
		b.WriteString(ufmt.Sprintf(
			"%s **YOUR SNAKE** · %s · length **%d** · facing %s · 💰 pot **%d ugnot** · [↻ refresh](/r/demo/games/snake:%s) · [⬅ lobby](/r/demo/games/snake)\n\n",
			renderLiveDot(), alive, len(me.Body), dirName(me.Direction), pot, path,
		))
	} else {
		b.WriteString(ufmt.Sprintf(
			"%s **LIVE** · ⛓ block #%d · 🐍 %d snakes · 🍎 %d apples · 💀 %d deaths · 💰 **%d ugnot pot** · [↻ refresh](/r/demo/games/snake)\n\n",
			renderLiveDot(), height, snakes.Size(), len(apples), totalDeaths, pot,
		))
	}

	if best.Length > 0 {
		b.WriteString(ufmt.Sprintf(
			"🏆 **Longest: %d** by `%s` (block #%d) — beat it for the **%d ugnot pot**!\n\n",
			best.Length, shortAddr(best.Player), best.Block, pot,
		))
	} else {
		b.WriteString(ufmt.Sprintf(
			"🏆 **No record yet** — first to cashout alive takes **%d ugnot pot**!\n\n",
			pot,
		))
	}

	// State-aware action area.
	switch {
	case me == nil:
		b.WriteString("## 🎮 Join the world\n\n")
		b.WriteString("<gno-columns>\n\n")
		b.WriteString(renderJoinButton())
		b.WriteString("\n\n|||\n\n")
		b.WriteString("### Rules\n\n")
		b.WriteString("- Pay **100 ugnot** to spawn a 1-cell snake\n")
		b.WriteString("- Each transaction: pick a direction → move 1 cell\n")
		b.WriteString("- 🍎 apples grow you, walls/other snakes/yourself = 💀\n")
		b.WriteString("- Cashout alive + beat record = take the whole pot\n\n")
		b.WriteString("</gno-columns>\n\n")
	case !me.Alive:
		b.WriteString("## 💀 Your snake died\n\n")
		b.WriteString(ufmt.Sprintf("Final length: **%d**. Cashout to record.\n\n", len(me.Body)))
		b.WriteString("<gno-columns>\n\n")
		b.WriteString(renderCashoutButton())
		b.WriteString("\n\n|||\n\n")
		b.WriteString("Or just `Join` again — your dead snake auto-finalizes.\n\n")
		b.WriteString("</gno-columns>\n\n")
	default:
		b.WriteString("## 🎮 Move your snake\n\n")
		b.WriteString(renderDPad(me))
		b.WriteString("\n\n")
		b.WriteString("**Cashout** to lock in your length:\n\n")
		b.WriteString(renderCashoutButton())
		b.WriteString("\n\n")
	}

	// Active snakes list.
	if snakes.Size() > 0 {
		b.WriteString("## 🐍 Snakes in this world\n\n")
		b.WriteString(renderSnakeList(path))
	}

	if len(leaderboard) > 0 {
		b.WriteString("## 🏆 Top 10\n\n")
		b.WriteString("| # | Player | Length | Block |\n|---|---|---|---|\n")
		for i, rec := range leaderboard {
			marker := ""
			if best.Length > 0 && rec.Player == best.Player && rec.Length == best.Length && rec.Block == best.Block {
				marker = " 👑"
			}
			b.WriteString(ufmt.Sprintf("| %d | `%s`%s | **%d** | %d |\n",
				i+1, shortAddr(rec.Player), marker, rec.Length, rec.Block))
		}
		b.WriteString("\n")
	}

	b.WriteString("---\n\n")
	b.WriteString("**Why this is wild:** every snake, every apple, every move is on-chain in one [contract](/r/demo/games/snake/snake.gno). Players' colors come from [/r/demo/dna](/r/demo/dna) imported like a library. No backend, no game server — the contract *is* the game.\n")

	return b.String()
}

func renderBoard(me *Snake) string {
	var b strings.Builder
	b.WriteString(ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d">`,
		SvgW, SvgH, SvgW, SvgH,
	))
	// Background with subtle gradient.
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

	// Subtle grid every 5 cells.
	for x := 0; x <= BoardW; x += 5 {
		b.WriteString(ufmt.Sprintf(
			`<line x1="%d" y1="0" x2="%d" y2="%d" stroke="#2a2a45" stroke-width="1"/>`,
			x*CellPx, x*CellPx, SvgH,
		))
	}
	for y := 0; y <= BoardH; y += 5 {
		b.WriteString(ufmt.Sprintf(
			`<line x1="0" y1="%d" x2="%d" y2="%d" stroke="#2a2a45" stroke-width="1"/>`,
			y*CellPx, SvgW, y*CellPx,
		))
	}

	// Outer wall border — clearly mark the dangerous edges.
	b.WriteString(ufmt.Sprintf(
		`<rect x="1" y="1" width="%d" height="%d" fill="none" stroke="#8B0000" stroke-width="2" stroke-dasharray="4,3" rx="2"/>`,
		SvgW-2, SvgH-2,
	))

	// All snakes (use DNA color). Tail fades, head has eyes.
	snakes.Iterate("", "", func(key string, v any) bool {
		s := v.(*Snake)
		color := dna.ColorOf(key)
		bodyLen := len(s.Body)
		for i, c := range s.Body {
			cx := int(c.X) * CellPx
			cy := int(c.Y) * CellPx
			fill := color
			isHead := i == 0
			if isHead && s.Alive {
				fill = lighten(color)
			}
			// Tail fade — segments toward the tail get more transparent.
			opacity := segmentOpacity(i, bodyLen, s.Alive)
			b.WriteString(ufmt.Sprintf(
				`<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="%s" stroke="#0a0a18" stroke-width="1" opacity="%s"/>`,
				cx, cy, CellPx, CellPx, fill, opacity,
			))
			// Eyes on the head (alive snakes only).
			if isHead && s.Alive {
				b.WriteString(renderEyes(cx, cy, s.Direction))
			}
			// Dead snake: red X over head.
			if isHead && !s.Alive {
				b.WriteString(ufmt.Sprintf(
					`<g stroke="#FF3030" stroke-width="2" stroke-linecap="round">`+
						`<line x1="%d" y1="%d" x2="%d" y2="%d"/>`+
						`<line x1="%d" y1="%d" x2="%d" y2="%d"/>`+
						`</g>`,
					cx+2, cy+2, cx+CellPx-2, cy+CellPx-2,
					cx+CellPx-2, cy+2, cx+2, cy+CellPx-2,
				))
			}
		}
		return false
	})

	// Highlight player's snake (gold glowing outline + pulsing next-move preview).
	if me != nil && len(me.Body) > 0 {
		head := me.Body[0]
		hx := int(head.X) * CellPx
		hy := int(head.Y) * CellPx
		// Outer glow ring.
		b.WriteString(ufmt.Sprintf(
			`<rect x="%d" y="%d" width="%d" height="%d" rx="3" fill="none" stroke="#FFD700" stroke-width="2.5" filter="url(#glow)">`,
			hx-2, hy-2, CellPx+4, CellPx+4,
		))
		b.WriteString(`<animate attributeName="opacity" values="0.5;1;0.5" dur="1.1s" repeatCount="indefinite"/></rect>`)
		// Inner gold outline.
		b.WriteString(ufmt.Sprintf(
			`<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="none" stroke="#FFD700" stroke-width="1.5" opacity="0.9"/>`,
			hx-1, hy-1, CellPx+2, CellPx+2,
		))

		if me.Alive {
			// Next-move preview cell with arrow inside.
			nx, ny := nextXY(head, me.Direction)
			if nx >= 0 && nx < BoardW && ny >= 0 && ny < BoardH {
				color := dna.ColorOf(me.Player.String())
				px := nx * CellPx
				py := ny * CellPx
				b.WriteString(ufmt.Sprintf(
					`<rect x="%d" y="%d" width="%d" height="%d" rx="2" fill="%s" opacity="0.3" stroke="#FFD700" stroke-width="1" stroke-dasharray="2,2">`+
						`<animate attributeName="opacity" values="0.15;0.55;0.15" dur="1.2s" repeatCount="indefinite"/>`+
						`</rect>`,
					px, py, CellPx, CellPx, color,
				))
				// Direction arrow inside the preview cell.
				b.WriteString(renderArrowGlyph(px, py, me.Direction))
			}
		}
	}

	// Apples — sparkling ring + pulsing core.
	for _, a := range apples {
		cx := int(a.X)*CellPx + CellPx/2
		cy := int(a.Y)*CellPx + CellPx/2
		// Outer glow ring.
		b.WriteString(ufmt.Sprintf(
			`<circle cx="%d" cy="%d" r="9" fill="none" stroke="#FF8080" stroke-width="1" opacity="0.5">`+
				`<animate attributeName="r" values="8;13;8" dur="1.6s" repeatCount="indefinite"/>`+
				`<animate attributeName="opacity" values="0.5;0;0.5" dur="1.6s" repeatCount="indefinite"/>`+
				`</circle>`,
			cx, cy,
		))
		// Apple body.
		b.WriteString(ufmt.Sprintf(
			`<circle cx="%d" cy="%d" r="5" fill="#FF3B3B" stroke="#7A0F0F" stroke-width="1" filter="url(#glow)">`+
				`<animate attributeName="r" values="4;6;4" dur="1.4s" repeatCount="indefinite"/>`+
				`</circle>`,
			cx, cy,
		))
		// Apple shine highlight.
		b.WriteString(ufmt.Sprintf(
			`<circle cx="%d" cy="%d" r="1.5" fill="#FFFFFF" opacity="0.7"/>`,
			cx-2, cy-2,
		))
	}

	b.WriteString(`</svg>`)
	encoded := base64.StdEncoding.EncodeToString([]byte(b.String()))
	return ufmt.Sprintf("![Snake board](data:image/svg+xml;base64,%s)", encoded)
}

// segmentOpacity makes a snake body fade from head to tail.
func segmentOpacity(idx, total int, alive bool) string {
	if total <= 1 {
		if alive {
			return "1"
		}
		return "0.35"
	}
	// Head full opacity, tail down to 0.45.
	fade := 100 - (idx*55)/(total-1)
	if !alive {
		fade = fade / 3 // Dead snakes are very faded.
	}
	switch {
	case fade > 100:
		return "1"
	case fade < 15:
		return "0.15"
	case fade >= 95:
		return "1"
	case fade >= 85:
		return "0.9"
	case fade >= 75:
		return "0.8"
	case fade >= 65:
		return "0.7"
	case fade >= 55:
		return "0.6"
	case fade >= 45:
		return "0.5"
	case fade >= 35:
		return "0.4"
	case fade >= 25:
		return "0.3"
	}
	return "0.2"
}

// renderEyes draws two white pixels on the snake head, positioned according to
// the facing direction.
func renderEyes(hx, hy int, dir uint8) string {
	const eye = 2
	var e1x, e1y, e2x, e2y int
	switch dir {
	case DirUp:
		e1x, e1y = hx+3, hy+2
		e2x, e2y = hx+CellPx-3-eye, hy+2
	case DirDown:
		e1x, e1y = hx+3, hy+CellPx-3-eye
		e2x, e2y = hx+CellPx-3-eye, hy+CellPx-3-eye
	case DirLeft:
		e1x, e1y = hx+2, hy+3
		e2x, e2y = hx+2, hy+CellPx-3-eye
	case DirRight:
		e1x, e1y = hx+CellPx-3-eye, hy+3
		e2x, e2y = hx+CellPx-3-eye, hy+CellPx-3-eye
	}
	return ufmt.Sprintf(
		`<rect x="%d" y="%d" width="%d" height="%d" fill="#FFFFFF"/>`+
			`<rect x="%d" y="%d" width="%d" height="%d" fill="#FFFFFF"/>`,
		e1x, e1y, eye, eye,
		e2x, e2y, eye, eye,
	)
}

// renderArrowGlyph draws a small white arrow at the center of (px,py)-sized
// cell pointing in `dir`.
func renderArrowGlyph(px, py int, dir uint8) string {
	cx := px + CellPx/2
	cy := py + CellPx/2
	var pts string
	switch dir {
	case DirUp:
		pts = ufmt.Sprintf("%d,%d %d,%d %d,%d", cx, cy-3, cx-3, cy+2, cx+3, cy+2)
	case DirDown:
		pts = ufmt.Sprintf("%d,%d %d,%d %d,%d", cx, cy+3, cx-3, cy-2, cx+3, cy-2)
	case DirLeft:
		pts = ufmt.Sprintf("%d,%d %d,%d %d,%d", cx-3, cy, cx+2, cy-3, cx+2, cy+3)
	case DirRight:
		pts = ufmt.Sprintf("%d,%d %d,%d %d,%d", cx+3, cy, cx-2, cy-3, cx-2, cy+3)
	}
	return ufmt.Sprintf(`<polygon points="%s" fill="#FFFFFF" opacity="0.85"/>`, pts)
}

func renderSnakeList(currentPath string) string {
	var b strings.Builder
	b.WriteString("<gno-columns>\n\n")
	i := 0
	snakes.Iterate("", "", func(key string, v any) bool {
		if i > 0 && i%3 == 0 {
			b.WriteString("|||\n\n")
		}
		s := v.(*Snake)
		color := dna.ColorOf(key)
		marker := ""
		if key == currentPath {
			marker = " 🎯 **YOU**"
		}
		status := "🐍 alive"
		if !s.Alive {
			status = "💀 dead"
		}
		// color swatch + meta
		b.WriteString(ufmt.Sprintf(
			`![swatch](data:image/svg+xml;base64,%s)`+"\n\n",
			swatchSVG(color),
		))
		b.WriteString(ufmt.Sprintf("`%s`%s<br>\n", shortAddr(s.Player), marker))
		b.WriteString(ufmt.Sprintf("**len %d** · %s · facing %s<br>\n", len(s.Body), status, dirName(s.Direction)))
		if key != currentPath {
			b.WriteString(ufmt.Sprintf("[Open this view →](/r/demo/games/snake:%s)\n", key))
		}
		b.WriteString("\n")
		i++
		return false
	})
	b.WriteString("</gno-columns>\n\n")
	return b.String()
}

func swatchSVG(color string) string {
	raw := ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20"><rect width="40" height="20" rx="3" ry="3" fill="%s"/></svg>`,
		color,
	)
	return base64.StdEncoding.EncodeToString([]byte(raw))
}

// renderJoinButton — green card with a pulsing snake head.
func renderJoinButton() string {
	raw := `<svg xmlns="http://www.w3.org/2000/svg" width="260" height="140" viewBox="0 0 260 140">` +
		`<rect width="260" height="140" rx="12" ry="12" fill="#2E7D32"/>` +
		`<rect width="260" height="140" rx="12" ry="12" fill="#FFFFFF" opacity="0"><animate attributeName="opacity" values="0;0.15;0" dur="1.8s" repeatCount="indefinite"/></rect>` +
		// snake head + body segments
		`<g fill="#FFFFFF">` +
		`<rect x="40" y="80" width="18" height="18" rx="3"/>` +
		`<rect x="58" y="80" width="18" height="18" rx="3" opacity="0.85"/>` +
		`<rect x="76" y="80" width="18" height="18" rx="3" opacity="0.7"/>` +
		`<rect x="94" y="80" width="18" height="18" rx="3" opacity="0.5"/>` +
		`<rect x="46" y="84" width="4" height="4" fill="#2E7D32"/>` +
		`</g>` +
		// apple
		`<circle cx="150" cy="89" r="7" fill="#FF3B3B" stroke="#FFFFFF" stroke-width="1"><animate attributeName="r" values="6;8;6" dur="1.2s" repeatCount="indefinite"/></circle>` +
		`<text x="130" y="40" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="22" font-weight="800" fill="#FFFFFF">JOIN WORLD</text>` +
		`<rect x="155" y="55" width="80" height="38" rx="6" fill="#FFFFFF"/>` +
		`<text x="195" y="72" text-anchor="middle" font-size="10" font-weight="700" fill="#2E7D32">ENTRY FEE</text>` +
		`<text x="195" y="86" text-anchor="middle" font-size="12" font-weight="800" fill="#2E7D32">100 ugnot</text>` +
		`<text x="130" y="125" text-anchor="middle" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.85">▶ CLICK TO SPAWN</text>` +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("[![Join](data:image/svg+xml;base64,%s)](%s)",
		encoded,
		txlink.NewLink("Join").SetSend(ufmt.Sprintf("%dugnot", EntryFee)).URL(),
	)
}

// renderCashoutButton — orange card with falling coins.
func renderCashoutButton() string {
	raw := `<svg xmlns="http://www.w3.org/2000/svg" width="260" height="120" viewBox="0 0 260 120">` +
		`<rect width="260" height="120" rx="12" ry="12" fill="#E59500"/>` +
		`<rect width="260" height="120" rx="12" ry="12" fill="#FFFFFF" opacity="0"><animate attributeName="opacity" values="0;0.18;0" dur="2s" repeatCount="indefinite"/></rect>` +
		`<g transform="translate(48 60)">` +
		`<ellipse cx="0" cy="0" rx="24" ry="24" fill="#FFD700" stroke="#8B6914" stroke-width="2"><animate attributeName="rx" values="24;6;24" dur="1.6s" repeatCount="indefinite"/></ellipse>` +
		`<text x="0" y="6" text-anchor="middle" font-size="18" font-weight="800" fill="#8B6914">$</text>` +
		`</g>` +
		`<text x="170" y="50" text-anchor="middle" font-size="22" font-weight="800" fill="#FFFFFF">💰 CASHOUT</text>` +
		`<text x="170" y="70" text-anchor="middle" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.9">lock in your length</text>` +
		`<text x="170" y="105" text-anchor="middle" font-size="11" font-weight="600" fill="#FFFFFF" opacity="0.85">▶ CLICK TO CASHOUT</text>` +
		`</svg>`
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	return ufmt.Sprintf("[![Cashout](data:image/svg+xml;base64,%s)](%s)",
		encoded, txlink.NewLink("Cashout").URL(),
	)
}

// renderDPad — 4 big direction button cards (Up / Left / Right / Down).
func renderDPad(me *Snake) string {
	var b strings.Builder
	// Top row: Up
	b.WriteString("<gno-columns>\n\n")
	b.WriteString("\n\n|||\n\n")
	b.WriteString(arrowButton("up", me.Direction))
	b.WriteString("\n\n|||\n\n")
	b.WriteString("\n\n</gno-columns>\n\n")
	// Middle row: Left + Right
	b.WriteString("<gno-columns>\n\n")
	b.WriteString(arrowButton("left", me.Direction))
	b.WriteString("\n\n|||\n\n")
	b.WriteString(arrowButton("right", me.Direction))
	b.WriteString("\n\n</gno-columns>\n\n")
	// Bottom row: Down
	b.WriteString("<gno-columns>\n\n")
	b.WriteString("\n\n|||\n\n")
	b.WriteString(arrowButton("down", me.Direction))
	b.WriteString("\n\n|||\n\n")
	b.WriteString("\n\n</gno-columns>\n\n")
	return b.String()
}

func arrowButton(dir string, currentDir uint8) string {
	var (
		arrow      string
		bg         = "#1565C0"
		dirIdx     uint8
		blocked    bool
	)
	switch dir {
	case "up":
		arrow = "▲"
		dirIdx = DirUp
	case "down":
		arrow = "▼"
		dirIdx = DirDown
	case "left":
		arrow = "◀"
		dirIdx = DirLeft
	case "right":
		arrow = "▶"
		dirIdx = DirRight
	}
	// 180° reversal → grey out
	if (currentDir == DirUp && dirIdx == DirDown) ||
		(currentDir == DirDown && dirIdx == DirUp) ||
		(currentDir == DirLeft && dirIdx == DirRight) ||
		(currentDir == DirRight && dirIdx == DirLeft) {
		bg = "#999999"
		blocked = true
	}
	// Currently-facing direction → green tint
	if currentDir == dirIdx {
		bg = "#2E7D32"
	}

	raw := ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" width="200" height="80" viewBox="0 0 200 80">`+
			`<rect width="200" height="80" rx="10" ry="10" fill="%s"/>`+
			`<text x="100" y="48" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="40" font-weight="900" fill="#FFFFFF">%s</text>`+
			`<text x="100" y="68" text-anchor="middle" font-size="11" font-weight="700" fill="#FFFFFF" opacity="0.85">%s</text>`+
			`</svg>`,
		bg, arrow, strings.ToUpper(dir),
	)
	encoded := base64.StdEncoding.EncodeToString([]byte(raw))
	url := txlink.NewLink("Move").AddArgs("dir", dir).URL()
	if blocked {
		// Still clickable but will panic; mark visually as disabled.
		return ufmt.Sprintf("![%s blocked](data:image/svg+xml;base64,%s)", dir, encoded)
	}
	return ufmt.Sprintf("[![%s](data:image/svg+xml;base64,%s)](%s)", dir, encoded, url)
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

// lighten returns a slightly brighter shade of a "#RRGGBB" hex color.
func lighten(hex string) string {
	if len(hex) != 7 || hex[0] != '#' {
		return hex
	}
	r := hexByte(hex[1], hex[2])
	g := hexByte(hex[3], hex[4])
	b := hexByte(hex[5], hex[6])
	r = min255(r + 60)
	g = min255(g + 60)
	b = min255(b + 60)
	return "#" + hex2(r) + hex2(g) + hex2(b)
}

func hexByte(hi, lo byte) int {
	return hexDigit(hi)*16 + hexDigit(lo)
}

func hexDigit(c byte) int {
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
