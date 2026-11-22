package main

import (
	"image"
	"math"
)

const masterWidth, masterHeight = 600, 540

// Each output pixel keeps the exact fixed-point taps used by the full image scaler.
type samples struct {
	first   int
	weights []int
}

func samplingAxis(source, dest int) []samples {
	const one = 4096
	out := make([]samples, dest)
	ratio := float64(source) / float64(dest)
	for i := range out {
		if dest >= source {
			p := max(0, min(float64(source-1), (float64(i)+0.5)*ratio-0.5))
			left := int(p)
			rightWeight := int(math.Round((p - float64(left)) * one))
			out[i] = samples{left, []int{one - rightWeight}}
			if rightWeight > 0 {
				out[i].weights = append(out[i].weights, rightWeight)
			}
			continue
		}
		left, right := float64(i)*ratio, float64(i+1)*ratio
		first, end := int(left), min(source, int(math.Ceil(right)))
		taps := make([]int, end-first)
		prev := 0
		for j := first; j < end; j++ {
			cumulative := int(math.Round((min(right, float64(j+1)) - left) / ratio * one))
			taps[j-first] = cumulative - prev
			prev = cumulative
		}
		out[i] = samples{first, taps}
	}
	return out
}

func filterPixel(src []byte, start, stride int, weights []int, dst []byte) {
	var b, g, r, a int
	for _, w := range weights {
		p := src[start : start+4]
		b += w * int(p[0])
		g += w * int(p[1])
		r += w * int(p[2])
		a += w * int(p[3])
		start += stride
	}
	dst[0], dst[1], dst[2], dst[3] = byte((b+2048)>>12), byte((g+2048)>>12), byte((r+2048)>>12), byte((a+2048)>>12)
}

func affectedRange(axis []samples, low, high int) (int, int) {
	left := 0
	for left < len(axis) && axis[left].first+len(axis[left].weights) <= low {
		left++
	}
	right := left
	for right < len(axis) && axis[right].first < high {
		right++
	}
	return left, right
}

// The entire area that drawSleepingLetters may touch, including antialiasing.
var sleepingLettersBounds = image.Rect(428, 88, 508, 180)

func sleepLetterClamp(n float64) float64 { return max(0, min(1, n)) }

func drawSleepingLetters(full []byte, phase int) {
	t := int64(phase-1) * 80
	for i, glyph := range [...]struct{ x, y, w float64 }{{216, 82, 5}, {229, 67, 7}, {242, 52, 9}} {
		age := t - int64(i)*360
		if age < 0 || age >= 1100 {
			continue
		}
		opacity := (190. / 255) * min(1., float64(age)/180, float64(1100-age)/280)
		x := glyph.x * 2
		y := 2 * (glyph.y - 6*float64(age)/1100)
		w := 2 * glyph.w
		for py := max(0, int(y)-4); py < min(masterHeight, int(y+w)+5); py++ {
			for px := max(0, int(x)-4); px < min(masterWidth, int(x+w)+5); px++ {
				dx, dy := float64(px)+.5-x, float64(py)+.5-y
				n := max(0., min(w, dx))
				diag := max(0., min(w, (w-dx+dy)*.5))
				dist := min(math.Hypot(dx-n, dy), math.Hypot(dx-n, dy-w), math.Hypot(dx-(w-diag), dy-diag))
				edge := sleepLetterClamp(2.7 - dist)
				if edge == 0 {
					continue
				}
				ink := sleepLetterClamp(1.65 - dist)
				a := int(math.Round(opacity * edge * 255))
				out := full[4*(py*masterWidth+px):][:4]
				for k, col := range [3]int{149, 117, 98} {
					c := int(math.Round(249*(1-ink) + float64(col)*ink))
					out[k] = byte((c*a + int(out[k])*(255-a) + 127) / 255)
				}
				out[3] = byte(a + (int(out[3])*(255-a)+127)/255)
			}
		}
	}
}

// sleepPatch uses the same horizontal/vertical filtering and rounding as scaling
// the entire composed frame, but calculates only output pixels touched by a Z.
type sleepPatch struct {
	bounds       image.Rectangle
	pixels       []byte
	masterPixels []byte
}

func makeSleepPatch(src []byte, xAxis, yAxis []samples) sleepPatch {
	x0, x1 := affectedRange(xAxis, sleepingLettersBounds.Min.X, sleepingLettersBounds.Max.X)
	y0, y1 := affectedRange(yAxis, sleepingLettersBounds.Min.Y, sleepingLettersBounds.Max.Y)
	bounds := image.Rect(x0, y0, x1, y1)
	if bounds.Empty() {
		return sleepPatch{bounds: bounds}
	}
	sy0 := yAxis[y0].first
	last := yAxis[y1-1]
	sy1 := last.first + len(last.weights)
	stride := bounds.Dx() * 4
	horiz := make([]byte, (sy1-sy0)*stride)
	for y := sy0; y < sy1; y++ {
		for x := x0; x < x1; x++ {
			t := xAxis[x]
			filterPixel(src, 4*(y*masterWidth+t.first), 4, t.weights, horiz[(y-sy0)*stride+(x-x0)*4:])
		}
	}
	pixels := make([]byte, bounds.Dx()*bounds.Dy()*4)
	for y := y0; y < y1; y++ {
		for x := x0; x < x1; x++ {
			t := yAxis[y]
			filterPixel(horiz, (t.first-sy0)*stride+(x-x0)*4, stride, t.weights, pixels[(y-y0)*stride+(x-x0)*4:])
		}
	}
	masterPixels := make([]byte, sleepingLettersBounds.Dx()*sleepingLettersBounds.Dy()*4)
	masterStride := sleepingLettersBounds.Dx() * 4
	for y := sleepingLettersBounds.Min.Y; y < sleepingLettersBounds.Max.Y; y++ {
		start := 4 * (y*masterWidth + sleepingLettersBounds.Min.X)
		copy(masterPixels[(y-sleepingLettersBounds.Min.Y)*masterStride:], src[start:start+masterStride])
	}
	return sleepPatch{bounds: bounds, pixels: pixels, masterPixels: masterPixels}
}

func (p sleepPatch) copyTo(dst []byte, width int) {
	stride := p.bounds.Dx() * 4
	for y := p.bounds.Min.Y; y < p.bounds.Max.Y; y++ {
		copy(dst[4*(y*width+p.bounds.Min.X):][:stride], p.pixels[(y-p.bounds.Min.Y)*stride:][:stride])
	}
}

func (p sleepPatch) copyToMaster(dst []byte) {
	stride := sleepingLettersBounds.Dx() * 4
	for y := sleepingLettersBounds.Min.Y; y < sleepingLettersBounds.Max.Y; y++ {
		start := 4 * (y*masterWidth + sleepingLettersBounds.Min.X)
		copy(dst[start:start+stride], p.masterPixels[(y-sleepingLettersBounds.Min.Y)*stride:][:stride])
	}
}

// Store only the small altered rectangle for each phase, under an explicit cap.
// The owning view invalidates this cache when its base scene or dimensions change.
type sleepPatchCache struct {
	patches [26]sleepPatch
	valid   [26]bool
	bytes   int
}

func (c *sleepPatchCache) get(phase int, budget int, create func() sleepPatch) sleepPatch {
	if phase < 1 || phase >= len(c.patches) {
		return create()
	}
	if c.valid[phase] {
		return c.patches[phase]
	}
	p := create()
	needed := len(p.pixels) + len(p.masterPixels)
	if needed <= budget-c.bytes {
		c.patches[phase], c.valid[phase] = p, true
		c.bytes += needed
	}
	return p
}
