# Gno.land Game Demos — Working Context

> **For agents and collaborators**: this is the live working context for a series of game-demo realms exploring what is and isn't possible inside **gnoweb** (the SSR markdown frontend served at `https://gno.land`). Read this top-to-bottom before adding or modifying anything in `examples/gno.land/r/demo/games/`.

## 1. Purpose

We are building a catalog of **bite-sized, visually striking on-chain games** to evangelize Gno.land's differentiators:

1. **Code transparency** — the contract IS the game (UI, rules, randomness, payouts in one file).
2. **Composability** — realms can `import` each other (e.g. `/r/demo/dna` is reused by every game for player colors).
3. **Permanence** — once deployed, the game lives forever on-chain.
4. **Multi-user runtime** — a single contract, many concurrent players (vs. typical "one user per contract instance" L1s).
5. **Demos things other chains can't do** without a server.

Demo audience expects:
- Quick wow effect when opening the page
- Live-feeling visuals despite SSR (animation tricks below)
- Simple rules, easy to grasp in 30 seconds
- "Hold on — this is all just a smart contract?" moment

---

## 2. What's built (status as of last session)

All paths live under `examples/gno.land/r/demo/`.

| Realm | Status | Mechanic | Pot logic |
|-------|--------|----------|-----------|
| `pixelwall` | ✅ done | r/place-style 32×32 SVG pixel canvas | None (free pixels) |
| `dna` | ✅ done | Address → deterministic 5×5 identicon. Exports `Generate(addr)`, `GenerateMini(addr)`, `ColorOf(addr)` as a **composable library** used by every game | n/a |
| `games/rpspool` | ✅ done | Round-based Rock/Paper/Scissors betting. Block-window rounds; on-chain randomness picks winning shape; winners split pot pro-rata; carryover if nobody picks the winner | Pro-rata to winning side |
| `games/dinorun` | ✅ done | Crash-style endless runner. Each `Jump` advances by `Speed` (grows +1/jump). Death% = `distance / 5`. Cashout alive + beat record → take pot | Winner-take-all on record beat |
| `games/snake` | ✅ done | Communal multiplayer Snake. All players on one 50×30 board. `Move` per tx. Walls/other snakes/self = death | Winner-take-all on longest length |
| `games/snakeplan` | ✅ done | **Plan & Execute Snake**. One transaction = one full game. Submit U/D/L/R sequence → contract simulates → SVG animates the replay | Winner-take-all on longest length |

### Patterns shared by all
- Entry fee `100 ugnot`, taken via `unsafe.OriginSend()`
- Banker payout via `banker.NewBanker(BankerTypeRealmSend, cur)`
- `chain.Emit(...)` for off-chain indexing
- Top-10 leaderboard, sorted by length/distance
- State-aware `Render(path)`: lobby vs. personalized view (path = g1 address)
- Player colors from `dna.ColorOf(addr)` — composability flex
- DNA identicons in active-player lists via `dna.GenerateMini(addr)`
- Live red pulsing dot SVG in header (`renderLiveDot()` — copied between realms)

---

## 3. Next priorities (user-aligned)

Ranked by gnoweb-fit × demo impact (the user's classic-game shortlist):

| # | Game | Fit | Why this order |
|---|------|-----|----------------|
| 1 | **Tetris** | ⭐⭐⭐⭐ | Most famous game on the list. Maps naturally to Plan & Execute: submit a sequence of `(piece, rotation, column)` triples, contract simulates board, returns score. SVG replay drops pieces step by step. |
| 2 | **Sokoban** | ⭐⭐⭐⭐⭐ | Perfect gnoweb fit (pure turn-based puzzle). Daily seeded level — same puzzle for everyone, lowest-move-count wins the pot. Easy to ship. |
| 3 | **Space Invaders** | ⭐⭐⭐⭐ | Aliens auto-descend per block; player submits (x, fire?) per tx. Cooperative mode possible (everyone shoots same wave). |
| 4 | **Pac-Man** | ⭐⭐⭐ | Turn-based maze + ghost AI. Real-time feel lost, but a "you move then ghosts move" rhythm works. |
| 5 | **Galaga** | merge with #3 | Same essence as Space Invaders; skip or treat as a variant |
| ❌ | Super Mario, Donkey Kong | ⭐ | Real-time platformers — precise jump timing impossible without JS. Skip. |
| ❌ | Pong, Breakout | ⭐ | Real-time physics. Skip. |

### Other interesting candidates we discussed
- **Last-Stand Pool** (The Button) — last bettor takes everything if no new bet within X blocks. Naturally suspenseful.
- **Pixel Canvas live** (turn the existing pixelwall into a competition: who paints the most cells this hour).
- **Connect-4 PvP** — clean 2-player turn-based, no betting layer needed for v1.

---

## 4. gnoweb — how it works (must understand)

`gno.land/pkg/gnoweb` is the SSR frontend. Flow:

```
GET /r/demo/games/snake:g1abc       → ABCI query
  ↓                                   path = "g1abc"
GnoVM runs Render("g1abc") → returns markdown string
  ↓
Goldmark parses with custom extensions
  ↓
HTML wrapped in layout (head/header/body/footer/theme)
  ↓
Browser
```

**Critical facts**:
- `Render(path string) string` is the **entire UI** — anything you can't return as markdown can't be shown.
- The `path` argument is whatever comes after `:` in the URL: `/r/foo:bar` → `Render("bar")`.
- Output is sanitized markdown → no raw `<script>`, no `<meta>`, no inline event handlers.

### What you CAN do in gnoweb output
- GFM markdown: tables, strikethrough, checkboxes
- `<gno-columns>` ... `|||` ... `</gno-columns>` — column layout
- `<gno-form>` + `<gno-input>` — input fields that POST → 303 redirect → GET with query params (the form data becomes args to `Render`)
- Alert blocks: `> [!NOTE]` `> [!WARNING]` `> [!IMPORTANT]`
- `@username` and `g1...` are auto-linked to `/u/`
- SVG inline as base64 `data:image/svg+xml;base64,...` (we use this heavily for graphics)
- **SVG SMIL animation works inside base64 `<img>` tags** — `<animate>`, `<animateTransform>` — this is our entire "liveness" tactic
- Markdown image inside markdown link → clickable image: `[![alt](data-uri)](url)`
- Chroma syntax highlighting for fenced code blocks

### What you CANNOT do
- ❌ **JavaScript** — no client-side interactivity beyond what Stimulus controllers in gnoweb already provide
- ❌ **`<meta http-equiv="refresh">`** — sanitized out (confirmed empirically; we tried)
- ❌ Real-time keyboard / mouse / drag input
- ❌ WebSocket / SSE
- ❌ External images (`<img src="https://...">`) — blocked by image validator (only `data:image/svg+xml`)
- ❌ External CSS / fonts (only `/public/` self-hosted)
- ❌ HTTP `<form action="...">` with arbitrary endpoints

### Key files
- `gno.land/pkg/gnoweb/app.go` — router
- `gno.land/pkg/gnoweb/handler_http.go` — route handlers, especially POST → 303 redirect logic
- `gno.land/pkg/gnoweb/markdown/ext_*.go` — custom markdown extensions
- `gno.land/pkg/gnoweb/render_config.go` — image validator (`allowSvgDataImage`)
- `gno.land/pkg/gnoweb/components/` — Go components that wrap the rendered markdown

---

## 5. The flow problem (the real UX wall)

Every on-chain game has the same friction:

| Step | Where it breaks | Who can fix it |
|------|-----------------|----------------|
| Click button | Navigates to `?help&func=...` page | gnoweb (add return-URL) |
| Sign | Adena wallet popup every single tx | **Wallet (Session signing)** |
| Confirm | ~1s block confirmation | Inherent |
| See result | User must manually refresh | gnoweb (auto-refresh) or game design |

**The wallet-level "Session Signing" fix is the real answer.** Until that lands, three game-design workarounds:

### A. Plan & Execute (recommended for solo games)
- One tx = one whole game. Submit a sequence; contract simulates; SVG SMIL replays the result automatically.
- ✅ Single break point per game session
- ✅ Replay-as-content (shareable URLs)
- ❌ Loses live multiplayer
- Used by: `snakeplan`

### B. Auto-Tick
- Snake/Pacman move automatically every N blocks (in someone's transaction); user only sends Turn(dir).
- ✅ Closest to original game feel
- ❌ Requires someone to call `Tick()` for progress (needs a bot or first-active-user catch-up logic)
- Not yet built

### C. Batch Moves
- `Move(seq)` advances 5 cells in one tx.
- ✅ Easy to implement; reduces tx count
- ❌ Multiplayer collision detection becomes stale

### Bonus: Wallet-free Preview mode
We experimented with this in `snakeplan`: a separate URL path with sequence-as-seed lets users replay any sequence **without a wallet**. Removed for production but kept in commit history (see commit `feat: snakeplan preview`). **Re-add when going to mainnet for live demo without wallet setup.**

---

## 6. Reusable patterns (cookbook)

### State-aware `Render(path)`
```go
func Render(path string) string {
    path = strings.TrimSpace(path)
    var me *PlayerState
    if strings.HasPrefix(path, "g1") && len(path) >= 30 {
        if v, ok := state.Get(path); ok {
            me = v.(*PlayerState)
        }
    }
    // Branch on: me == nil (lobby) | me.Alive (active) | !me.Alive (game over)
}
```

### Clickable SVG button card
```go
url := txlink.NewLink("Jump").URL()
// or .SetSend("100ugnot").URL() for tx with coin
imgB64 := base64.StdEncoding.EncodeToString([]byte(svgRaw))
return ufmt.Sprintf("[![Jump](data:image/svg+xml;base64,%s)](%s)", imgB64, url)
```

### Live pulsing dot (no refresh)
```svg
<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 14 14">
  <circle cx="7" cy="7" r="5" fill="#E50000">
    <animate attributeName="opacity" values="1;0.25;1" dur="1.1s" repeatCount="indefinite"/>
    <animate attributeName="r" values="5;6;5" dur="1.1s" repeatCount="indefinite"/>
  </circle>
</svg>
```
Base64 → embed in markdown via `![live](data:image/svg+xml;base64,...)`.

### Self-advancing progress bar
```svg
<rect width="0" height="32" fill="#4A90E2">
  <animate attributeName="width" from="120" to="600" dur="48s" fill="freeze"/>
</rect>
```
Set `from` = current filled width, `to` = full, `dur` = remaining seconds.

### SVG cinematic replay (the snakeplan trick)
```svg
<circle cx="..." cy="..." r="...">
  <animate attributeName="cx" values="x1;x2;x3;..." dur="3000ms" calcMode="discrete" fill="freeze"/>
  <animate attributeName="cy" values="y1;y2;y3;..." dur="3000ms" calcMode="discrete" fill="freeze"/>
</circle>
```
`calcMode="discrete"` snaps cell-to-cell. Contract returns path; SMIL plays it.

### Trail draw-on with stroke-dashoffset
```svg
<polyline points="x1,y1 x2,y2 ..." stroke-dasharray="LEN LEN" stroke-dashoffset="LEN">
  <animate attributeName="stroke-dashoffset" from="LEN" to="0" dur="3000ms" fill="freeze"/>
</polyline>
```

### Pull-pattern payout (gas-safe)
Track winnings in `avl.Tree<string, int64>` keyed by `addr.String()`. Withdraw function pays caller from the tree balance via banker. Avoids gas explosion when many winners.

### DNA composability (player color from another realm)
```go
import "gno.land/r/demo/dna"

color := dna.ColorOf(addr.String())     // "#A1B2C3"
identicon := dna.GenerateMini(addr.String())  // base64 SVG image
```
This is the **single most important demo point** — show the audience: "Player colors come from a completely separate realm, imported like a Go library."

### Path-based player view
- Lobby: `/r/demo/games/X`
- Personalized: `/r/demo/games/X:g1MY_ADDR`
- In active-runner list, link to each player's view: `[Open this view →](/r/demo/games/X:g1OTHER)`

---

## 7. Gotchas (learned the hard way)

### `ufmt` does NOT support `%X` / `%x` verbs
Hex color generation must be manual:
```go
const hexChars = "0123456789ABCDEF"
func hex2(v int) string {
    v = v & 0xFF
    return string([]byte{hexChars[v>>4], hexChars[v&0xF]})
}
// usage: "#" + hex2(r) + hex2(g) + hex2(b)
```
Discovered when DNA was rendering all gray — `ufmt.Sprintf("#%02X...")` was outputting `#(unhandled verb: %X)(unhandled verb: %X)...`.

### `ufmt` supports `%f` (gnomaze uses it) — but prefer integers
For animation timings, use milliseconds: `dur="3000ms"` instead of float seconds.

### Alert block + inline code conflict
This BROKE rendering — `Bet` got vertically split and `ugnot` shown sideways:
```markdown
> [!NOTE] Bet `ugnot` on Rock, Paper, or Scissors.   ❌
```
Use plain text inside alert blocks:
```markdown
> [!NOTE] Bet ugnot on Rock, Paper, or Scissors.    ✅
```

### `panic` + `defer recover()` doesn't work across cross-calls
In tests:
```go
func TestSomething(cur realm, t *testing.T) {
    defer func() {
        if r := recover(); r == nil { t.Error("expected panic") }
    }()
    Mutating(cross(cur), badArg)  // panic here is NOT caught by the test's recover
}
```
Don't write panic-expectation tests for crossing functions. Test the precondition checks separately.

### Type/function name collision
`type Bet struct { ... }` + `func Bet(...)` = compile error. Use distinct names:
```go
type Wager struct { ... }   // not Bet
func Bet(cur realm, ...)    // function name
```

### gnodev doesn't auto-detect new packages
When you add a new `examples/gno.land/r/demo/games/X/` directory, `gnodev` needs to be **restarted** (not just `curl /reload`) for the new pkgpath to be queryable. Existing packages reload fine via `curl http://127.0.0.1:8888/reload`.

### gnodev needs `-empty-blocks` for live feel
By default gnodev only mines blocks when there's a tx. For SVG animation demos (progress bars, live dots) to look alive without anyone playing, restart with:
```bash
gnodev local -empty-blocks -empty-blocks-interval 1
```

### `runtime.AssertOriginCall()` blocks cross-realm calls
Use it on user-facing functions (`Heads`, `Tails`, `Bet`) to prevent other realms from calling on a user's behalf — but it means you can't compose by calling the function from another realm. Reserve for entry points only.

### Composing realms safely (the interrealm rules)
Read `docs/resources/gno-interrealm.md` before any caller-auth code. Key trap: `PreviousRealm()` only shifts on `fn(cross, ...)` calls into `func fn(cur realm, ...)` functions. `PreviousRealm().PkgPath() == "..."` checks in non-crossing functions are security bugs (see CLAUDE.md in repo root).

### `runtime.PreviousRealm().IsUserCall()` vs `IsUser()`
If your function accepts payment via `banker.OriginSend()`, the caller guard must be `IsUserCall()` not `IsUser()`. Reason in repo CLAUDE.md.

---

## 8. Dev workflow

### Setup
```bash
# build tools once
cd gnovm && go build -o /tmp/gno ./cmd/gno
cd ../contribs/gnodev && go build -o /tmp/gnodev .

# start local node + gnoweb
cd /Users/dongwon/workspace/gno
/tmp/gnodev local -web-listener 127.0.0.1:8888 -empty-blocks -empty-blocks-interval 1 -log-format json
```
Browser: `http://127.0.0.1:8888/r/demo/games/snake`.

### Iterate
```bash
# After code change:
cd examples && /tmp/gno lint ./gno.land/r/demo/games/X/    # static check
/tmp/gno test ./gno.land/r/demo/games/X/                   # run tests

# Reload gnoweb (existing package):
curl http://127.0.0.1:8888/reload

# Reload (new package): kill + restart gnodev
```

### Quick visual checks
```bash
# Confirm page rendered:
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8888/r/demo/games/X

# How many SVGs are on the page?
curl -s http://127.0.0.1:8888/r/demo/games/X | grep -oc 'data:image/svg'

# Decode the first base64 SVG to check the markup:
curl -s http://127.0.0.1:8888/r/demo/games/X | grep -oE 'data:image/svg\+xml;base64,[A-Za-z0-9+/=]+' | head -1 | sed 's/.*base64,//' | base64 -d | head -c 800
```

### Test patterns
- Lint must pass before commit
- `gno test` reports compile errors immediately
- For Render tests, search for visible string fragments (NOT text inside base64 SVGs):
  ```go
  if !strings.Contains(out, "Snake Cinema") { t.Error(...) }      // ✅
  if !strings.Contains(out, "JOIN WORLD") { t.Error(...) }        // ❌ inside SVG
  ```

---

## 9. The mental model

Always frame each new game around these questions:

1. **Can a single Render() call show the entire game state?**
2. **Can the player's action be captured in one transaction?** (Plan & Execute) Or many small ones with auto-progression in between?
3. **What does the SVG show that makes someone go "wait — this is one contract"?**
4. **Is the betting/pot logic clear in 10 seconds?** Always: pay-to-play → fail = pot grows → succeed = take pot.
5. **What other realm could this import** (or be imported by)? Showcase composability.

The demo value is **not** building a deep game. It's building a 5-minute "holy shit" that makes the audience read the contract source.

---

## 10. Open questions / decisions to revisit

- **Adena local connection**: User reports Adena can't connect to local gnodev. Workaround: gnoweb's built-in dev-key Send (unsafe-api). Need to verify Adena chain-id `dev` + RPC `http://127.0.0.1:26657` setup, or document the dev-key approach.
- **Daily-seed mode** for snakeplan: same board for everyone today, fewest moves wins. Mentioned but not built — could ship as `snakeplan` variant or new realm.
- **Tetris piece encoding**: ASCII per piece? `I3R0C5` (Piece, Rotation, Column)? Decide before starting.
- **Animation timing**: 400ms/step felt right for snake. Tune per game.
- **Move sequence URL length**: snakeplan caps at 200 moves; URLs get long. Acceptable for now.

---

## 11. Quick continuation prompt for a new agent

```
You're continuing the Gno.land game-demo series. Read examples/gno.land/r/demo/games/NOTES.md
top-to-bottom first. Current next priority is **Tetris** (#1 in section 3). Follow the
"Plan & Execute" pattern from snakeplan: one transaction per game, contract simulates,
SVG SMIL replays. Use dna.ColorOf for player colors. Read root CLAUDE.md for interrealm
gotchas. Lint + test before declaring done. Use the dev workflow in section 8.
```

---

*Last updated: continuation of game-demo series. Built over multiple sessions in 2026.*
