package main

import (
	"bytes"
	"fmt"
	"testing"
)

// The full two-pass scaler is the old output path; patch results must be pixel
// identical to it, including premultiplied-alpha edges and rounding.
func fullScaleReference(src []byte, width, height int) []byte {
	x, y := samplingAxis(masterWidth, width), samplingAxis(masterHeight, height)
	return fullScaleWithAxes(src, width, height, x, y)
}

func fullScaleWithAxes(src []byte, width, height int, x, y []samples) []byte {
	h := src
	if width != masterWidth {
		h = make([]byte, width*masterHeight*4)
		for row := 0; row < masterHeight; row++ {
			for col, t := range x {
				filterPixel(src, 4*(row*masterWidth+t.first), 4, t.weights, h[4*(row*width+col):])
			}
		}
	}
	if height == masterHeight {
		return h
	}
	out := make([]byte, width*height*4)
	for row, t := range y {
		for col := 0; col < width; col++ {
			filterPixel(h, 4*(t.first*width+col), width*4, t.weights, out[4*(row*width+col):])
		}
	}
	return out
}

func testBackground() []byte {
	b := make([]byte, masterWidth*masterHeight*4)
	for y := 0; y < masterHeight; y++ {
		for x := 0; x < masterWidth; x++ {
			i := 4 * (y*masterWidth + x)
			a := byte((x*17 + y*11) % 256)
			b[i] = byte(int(a) * ((x * 3) % 256) / 255)
			b[i+1] = byte(int(a) * ((y * 5) % 256) / 255)
			b[i+2] = byte(int(a) * ((x + y) % 256) / 255)
			b[i+3] = a
		}
	}
	return b
}

func TestSleepPatchMatchesFullCompositing(t *testing.T) {
	background := testBackground()
	for _, sz := range [][2]int{{150, 135}, {300, 270}, {451, 406}, {600, 540}, {900, 810}} {
		t.Run(fmt.Sprintf("%dx%d", sz[0], sz[1]), func(t *testing.T) {
			x, y := samplingAxis(masterWidth, sz[0]), samplingAxis(masterHeight, sz[1])
			base := fullScaleReference(background, sz[0], sz[1])
			for phase := 1; phase <= 25; phase++ {
				full := bytes.Clone(background)
				drawSleepingLetters(full, phase)
				want := fullScaleReference(full, sz[0], sz[1])
				got := bytes.Clone(base)
				patch := makeSleepPatch(full, x, y)
				patch.copyTo(got, sz[0])
				if !bytes.Equal(got, want) {
					t.Fatalf("phase %d differs from full-frame scaling", phase)
				}
				master := bytes.Clone(background)
				patch.copyToMaster(master)
				if !bytes.Equal(master, full) {
					t.Fatalf("phase %d changed pixels outside the master patch", phase)
				}
			}
		})
	}
}

func TestSleepPatchCacheIsBoundedAndReusesPhases(t *testing.T) {
	var c sleepPatchCache
	calls := 0
	create := func() sleepPatch { calls++; return sleepPatch{pixels: make([]byte, 12), masterPixels: make([]byte, 8)} }
	for cycle := 0; cycle < 3; cycle++ {
		for phase := 1; phase <= 25; phase++ {
			c.get(phase, 25*20, create)
		}
	}
	if calls != 25 || c.bytes != 25*20 {
		t.Fatalf("cache calls=%d bytes=%d", calls, c.bytes)
	}
	var bounded sleepPatchCache
	for phase := 1; phase <= 25; phase++ {
		bounded.get(phase, 20, create)
	}
	if bounded.bytes != 20 {
		t.Fatalf("budget exceeded: %d", bounded.bytes)
	}
}

func TestSleepCadenceAndWake(t *testing.T) {
	for _, sleep := range []int64{15000, 30000, 60000, 120000, 300000, 600000} {
		if got := sleepTimerPeriod(sleep+599, sleep, false); got != 16 {
			t.Fatalf("closing: %d", got)
		}
		if got := sleepTimerPeriod(sleep+600, sleep, false); got != 40 {
			t.Fatalf("sleep: %d", got)
		}
		if got := sleepTimerPeriod(sleep+1000, sleep, true); got != 16 {
			t.Fatalf("interaction: %d", got)
		}
		if got := sleepTimerPeriod(0, sleep, false); got != 16 {
			t.Fatalf("wake: %d", got)
		}
	}
}

// These isolate cache costs only; they do not measure gaze, WindowManager or UI.
// Old cache capacity and FIFO eviction match the existing framePixels path.
func BenchmarkSleepFrameCache(b *testing.B) {
	for _, sz := range [][2]int{{300, 270}, {600, 540}} {
		w, h := sz[0], sz[1]
		for _, method := range []string{"full_frame_fifo", "bounded_patch"} {
			b.Run(fmt.Sprintf("%s/%dx%d", method, w, h), func(b *testing.B) {
				background := testBackground()
				x, y := samplingAxis(masterWidth, w), samplingAxis(masterHeight, h)
				base := fullScaleWithAxes(background, w, h, x, y)
				dst := make([]byte, len(base))
				full := make(map[int][]byte)
				order := []int{}
				limit := min(48, (24<<20)/len(base))
				var patches sleepPatchCache
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					phase := 1 + i%25
					if method == "full_frame_fifo" {
						pixels, ok := full[phase]
						if !ok {
							frame := bytes.Clone(background)
							drawSleepingLetters(frame, phase)
							pixels = fullScaleWithAxes(frame, w, h, x, y)
							if len(order) >= limit {
								delete(full, order[0])
								order = order[1:]
							}
							full[phase] = pixels
							order = append(order, phase)
						}
						copy(dst, pixels)
					} else {
						copy(dst, base)
						patches.get(phase, 8<<20, func() sleepPatch {
							frame := bytes.Clone(background)
							drawSleepingLetters(frame, phase)
							return makeSleepPatch(frame, x, y)
						}).copyTo(dst, w)
					}
				}
			})
		}
	}
}
