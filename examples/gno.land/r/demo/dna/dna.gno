// Package dna turns any Gno.land address into a unique, deterministic identicon —
// a 5×5 horizontally symmetric SVG "genetic signature". No registration, no
// storage, no off-chain image host: the contract generates the image from the
// address alone, every time it's viewed.
package dna

import (
	"strings"

	"gno.land/p/demo/svg"
	"gno.land/p/nt/ufmt/v0"
)

const (
	GridSize = 5
	CellPx   = 28
	Padding  = 10
	CanvasPx = GridSize*CellPx + 2*Padding
)

// Render(path): treat `path` as an address. Empty path shows the gallery.
func Render(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return renderHome()
	}
	return renderDNAPage(path)
}

func renderHome() string {
	examples := []string{
		"g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5",
		"g17ernafy6ctpcz6uepfsq2js8x2vz0wladh5yc3",
		"g1u7y667z64x2h7vc6fmpcprgey4ck233jaww9zq",
		"g1manfred47kzduec920z88wfr64ylksmdcedlf5",
		"g1us8428u2a5satrlxzagqqa5m6vmuze025anjlj",
		"g16d3wff0p2cn3v8ekhxpgsr6tq62lps3vu4dqgs",
	}

	var b strings.Builder
	b.WriteString("# 🧬 DNA — your address *is* your PFP\n\n")
	b.WriteString("> [!NOTE] Every Gno.land address has a unique, deterministic identicon. ")
	b.WriteString("No mint, no registration, no IPFS — the contract generates the image from your address alone, on-the-fly.\n\n")

	b.WriteString("## Gallery\n\n")
	b.WriteString("<gno-columns>\n")
	for i, addr := range examples {
		if i > 0 {
			b.WriteString("|||\n")
		}
		b.WriteString(Generate(addr))
		b.WriteString("\n\n")
		b.WriteString(ufmt.Sprintf("`%s…%s`\n\n", addr[:6], addr[len(addr)-4:]))
		b.WriteString(ufmt.Sprintf("[full →](/r/demo/dna:%s)\n", addr))
	}
	b.WriteString("</gno-columns>\n\n")

	b.WriteString("## Try yours\n\n")
	b.WriteString("Append your address as a `path` argument:\n\n")
	b.WriteString("```\n/r/demo/dna:g1YOUR_ADDRESS_HERE\n```\n\n")
	b.WriteString("Or click an example below:\n\n")
	for _, addr := range examples[:3] {
		b.WriteString(ufmt.Sprintf("- [`%s`](/r/demo/dna:%s)\n", addr, addr))
	}

	b.WriteString("\n---\n\n")
	b.WriteString("**Why this is wild:** this entire app — image and all — is one [60-line contract](/r/demo/dna/dna.gno). ")
	b.WriteString("No backend, no CDN, no PFP marketplace. Try doing that on another chain.\n")
	return b.String()
}

func renderDNAPage(addr string) string {
	short := addr
	if len(addr) > 12 {
		short = addr[:8] + "…" + addr[len(addr)-4:]
	}

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# 🧬 DNA of `%s`\n\n", short))
	b.WriteString(Generate(addr))
	b.WriteString(ufmt.Sprintf("\n\n```\n%s\n```\n\n", addr))
	b.WriteString("---\n\n")
	b.WriteString("This image is generated **on-chain** from your address alone. ")
	b.WriteString("No off-chain server, no image storage, no API key. ")
	b.WriteString("Read the [contract source](/r/demo/dna/dna.gno) — that's the whole app.\n\n")
	b.WriteString("[← back to gallery](/r/demo/dna)\n")
	return b.String()
}

// ColorOf returns the deterministic hex color (e.g. "#A1B2C3") derived from
// the address. Other realms compose this for per-user theming.
func ColorOf(addr string) string {
	rd := byteAt(addr, 3) ^ byteAt(addr, 7)
	gn := byteAt(addr, 5) ^ byteAt(addr, 11)
	bl := byteAt(addr, 9) ^ byteAt(addr, 13)
	return "#" + hex2(rd) + hex2(gn) + hex2(bl)
}

// Generate returns the deterministic identicon for the given address as a
// base64-encoded SVG markdown image. Use this from other realms to render the
// address's DNA inline.
func Generate(addr string) string {
	return generateDNA(addr, CellPx, Padding)
}

// GenerateMini returns a small (~60px) version of the identicon, suitable for
// rendering many addresses side-by-side in a grid.
func GenerateMini(addr string) string {
	return generateDNA(addr, 10, 4)
}

func generateDNA(addr string, cellPx, padding int) string {
	half := (GridSize + 1) / 2
	canvas := GridSize*cellPx + 2*padding

	rd := byteAt(addr, 3) ^ byteAt(addr, 7)
	gn := byteAt(addr, 5) ^ byteAt(addr, 11)
	bl := byteAt(addr, 9) ^ byteAt(addr, 13)
	fg := "#" + hex2(rd) + hex2(gn) + hex2(bl)
	bg := "#F5F5F2"

	c := svg.NewCanvas(canvas, canvas)
	c.WithViewBox(0, 0, canvas, canvas)
	c.Append(svg.NewRectangle(0, 0, canvas, canvas, bg))

	for row := 0; row < GridSize; row++ {
		for col := 0; col < half; col++ {
			b := byteAt(addr, row*half+col+15)
			if b&1 == 0 {
				continue
			}
			x := padding + col*cellPx
			y := padding + row*cellPx
			c.Append(svg.NewRectangle(x, y, cellPx, cellPx, fg))
			mirrorCol := GridSize - 1 - col
			if mirrorCol != col {
				xm := padding + mirrorCol*cellPx
				c.Append(svg.NewRectangle(xm, y, cellPx, cellPx, fg))
			}
		}
	}
	return c.Render("DNA of " + addr)
}

func byteAt(s string, i int) int {
	if len(s) == 0 {
		return 0
	}
	return int(s[i%len(s)])
}

const hexChars = "0123456789ABCDEF"

func hex2(v int) string {
	v = v & 0xFF
	return string([]byte{hexChars[v>>4], hexChars[v&0xF]})
}
