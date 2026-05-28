// Package pixelwall is an on-chain collaborative pixel canvas — r/place
// reimagined as a 30-line smart contract. Every pixel is one transaction,
// stored forever on Gno.land.
package pixelwall

import (
	"strconv"
	"strings"

	"gno.land/p/demo/svg"
	"gno.land/p/moul/txlink"
	"gno.land/p/nt/ufmt/v0"
)

const (
	Size     = 32              // grid side in pixels
	Total    = Size * Size     // 1024 pixels
	PixelPx  = 12              // SVG units per pixel
	CanvasPx = Size * PixelPx  // 384
)

// 16-color palette inspired by r/place.
var palette = [16]string{
	"#FFFFFF", "#E4E4E4", "#888888", "#222222",
	"#FFA7D1", "#E50000", "#E59500", "#A06A42",
	"#E5D900", "#94E044", "#02BE01", "#00D3DD",
	"#0083C7", "#0000EA", "#CF6EE4", "#820080",
}

var paletteNames = [16]string{
	"white", "lt-gray", "gray", "black",
	"pink", "red", "orange", "brown",
	"yellow", "lime", "green", "cyan",
	"lt-blue", "blue", "magenta", "purple",
}

var (
	pixels      [Total]uint8
	painted     [Total]bool
	paintCount  uint64
	uniquePixel uint64
)

// SetPixel paints pixel (x, y) with the given color index (0..15).
// (0, 0) is the top-left corner of the 32×32 grid.
func SetPixel(_ realm, x, y, color int) {
	if x < 0 || x >= Size || y < 0 || y >= Size {
		panic("coordinate out of range (must be 0..31)")
	}
	if color < 0 || color >= 16 {
		panic("color must be 0..15")
	}
	i := y*Size + x
	if !painted[i] {
		uniquePixel++
		painted[i] = true
	}
	pixels[i] = uint8(color)
	paintCount++
}

func Render(_ string) string {
	var b strings.Builder

	b.WriteString("# 🎨 Pixelwall — On-chain r/place\n\n")
	b.WriteString("> [!NOTE] Every pixel is a transaction. Once placed, it lives on Gno.land forever — no server, no database, just a 100-line contract.\n\n")

	b.WriteString(ufmt.Sprintf(
		"**%d** strokes · **%d / %d** pixels painted\n\n",
		paintCount, uniquePixel, Total,
	))

	b.WriteString(renderCanvas())
	b.WriteString("\n\n")

	b.WriteString("## Paint a pixel\n\n")
	b.WriteString("Pick a color, then enter `x` (0..31) and `y` (0..31):\n\n")
	b.WriteString(renderPalette())

	b.WriteString("\n---\n")
	b.WriteString("**Why this is wild:** read the [full source](/r/demo/pixelwall/pixelwall.gno) — that's the entire app, frontend included. ")
	b.WriteString("No backend, no API, no host. Just a Gno smart contract rendering itself.\n")

	return b.String()
}

func renderCanvas() string {
	c := svg.NewCanvas(CanvasPx, CanvasPx)
	c.WithViewBox(0, 0, CanvasPx, CanvasPx)
	c.Append(svg.NewRectangle(0, 0, CanvasPx, CanvasPx, "#FFFFFF"))
	for i := 0; i < Total; i++ {
		if !painted[i] {
			continue
		}
		x := (i % Size) * PixelPx
		y := (i / Size) * PixelPx
		c.Append(svg.NewRectangle(x, y, PixelPx, PixelPx, palette[pixels[i]]))
	}
	return c.Render("pixelwall canvas")
}

func renderPalette() string {
	var b strings.Builder
	b.WriteString("| swatch | color | quick-paint |\n|---|---|---|\n")
	for i := 0; i < 16; i++ {
		chip := paletteChip(i)
		link := txlink.NewLink("SetPixel").
			AddArgs("color", strconv.Itoa(i), "x", "", "y", "").
			URL()
		b.WriteString(ufmt.Sprintf("| %s | `%2d` %s | [paint with %s →](%s) |\n",
			chip, i, paletteNames[i], paletteNames[i], link))
	}
	return b.String()
}

func paletteChip(idx int) string {
	c := svg.NewCanvas(24, 24)
	c.WithViewBox(0, 0, 24, 24)
	c.Append(svg.NewRectangle(0, 0, 24, 24, palette[idx]))
	return c.Render(paletteNames[idx])
}
