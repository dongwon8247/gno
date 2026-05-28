package pixelwall

import (
	"strings"
	"testing"
)

func resetState() {
	pixels = [Total]uint8{}
	painted = [Total]bool{}
	paintCount = 0
	uniquePixel = 0
}

func TestSetPixel(cur realm, t *testing.T) {
	resetState()
	SetPixel(cross(cur), 0, 0, 5)
	SetPixel(cross(cur), 31, 31, 10)
	SetPixel(cross(cur), 0, 0, 7) // overwrite — should not bump uniquePixel

	if paintCount != 3 {
		t.Errorf("paintCount: got %d, want 3", paintCount)
	}
	if uniquePixel != 2 {
		t.Errorf("uniquePixel: got %d, want 2", uniquePixel)
	}
	if pixels[0] != 7 {
		t.Errorf("pixel(0,0): got %d, want 7", pixels[0])
	}
	if pixels[31*Size+31] != 10 {
		t.Errorf("pixel(31,31): got %d, want 10", pixels[31*Size+31])
	}
}

func TestRender(t *testing.T) {
	resetState()
	out := Render("")
	if !strings.Contains(out, "Pixelwall") {
		t.Error("render missing title")
	}
	if !strings.Contains(out, "data:image/svg+xml") {
		t.Error("render missing canvas SVG")
	}
	if !strings.Contains(out, "Paint a pixel") {
		t.Error("render missing palette section")
	}
}
