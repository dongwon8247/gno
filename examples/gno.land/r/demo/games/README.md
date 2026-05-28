# Gno.land Game Demos

A growing catalog of bite-sized, fully on-chain games — every rule, every payout, every pixel of UI lives inside a single Gno smart-contract realm. No backend, no game server, no off-chain image storage.

## What's here

| Game | Description | Stake / payout |
|------|-------------|----------------|
| **[rpspool](./rpspool)** ✂️🪨📄 | Multi-player Rock/Paper/Scissors betting pool. Bet ugnot on a side; when the block window closes the contract picks the winning shape on-chain and winners split the pot pro-rata. | 1+ ugnot, winners split pot |
| **[dinorun](./dinorun)** 🦖 | Crash-style Chrome dino. Each `Jump` advances faster (+1 speed/jump) and increases death chance (`distance / 5`%). Cashout alive + beat the record to take the pot. | 100 ugnot entry, winner-take-all |
| **[snake](./snake)** 🐍 | Communal multiplayer Snake — every player shares one 50×30 board. Walls / other snakes / yourself = death. | 100 ugnot entry, winner-take-all on longest length |
| **[snakeplan](./snakeplan)** 🎬 | **Plan & Execute Snake**. Submit a U/D/L/R sequence in one transaction; the contract simulates the run and the SVG above replays it automatically. | 100 ugnot entry, winner-take-all on longest length |

## Conventions across all games

- Player avatars and colors are sourced from [`/r/demo/dna`](../dna) — proving realm composability (one library realm, many consumers).
- Entry fee `100 ugnot` collected via `unsafe.OriginSend()`; payouts via `banker.NewBanker`.
- `Render(path)` is **state-aware**: empty path → lobby, `g1<address>` → personalized view (highlight your snake, show only legal actions).
- Heavy use of SVG SMIL animation (no JavaScript) — pulsing live indicator, progress bars, scrolling cacti, animated replays.
- Top-10 leaderboard, all-time record gating, pot rolls over on failures.

## Try it locally

```bash
# build tools
cd gnovm && go build -o /tmp/gno ./cmd/gno
cd ../contribs/gnodev && go build -o /tmp/gnodev .

# start node + gnoweb
cd /path/to/gno
/tmp/gnodev local -web-listener 127.0.0.1:8888 -empty-blocks -empty-blocks-interval 1
```

Then visit `http://127.0.0.1:8888/r/demo/games/snake` etc.

## Adding a new game

Read [NOTES.md](./NOTES.md) first — it covers gnoweb's capabilities and limits, reusable SVG patterns, common pitfalls (e.g. `ufmt` doesn't support `%X` verb), and the working priority list of which classic games are next.
