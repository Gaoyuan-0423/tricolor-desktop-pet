//go:build windows

package main

import (
	"bytes"
	"compress/zlib"
	"embed"
	"encoding/binary"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"io"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

//go:embed packed/blue/atlas.png packed/blue/frames.z packed/amber/atlas.png packed/amber/frames.z packed/frost/atlas.png packed/frost/frames.z gaze/blue.gaze gaze/amber.gaze gaze/frost.gaze assets/0.wav assets/1.wav assets/2.wav
var fs embed.FS
var u = syscall.NewLazyDLL("user32.dll")
var g = syscall.NewLazyDLL("gdi32.dll")
var k = syscall.NewLazyDLL("kernel32.dll")
var winmm = syscall.NewLazyDLL("winmm.dll")

// All window procedures run on the locked UI thread.
var procedures = map[*syscall.LazyDLL]map[string]*syscall.LazyProc{}

//go:uintptrescapes
func call(d *syscall.LazyDLL, n string, args ...uintptr) uintptr {
	byName := procedures[d]
	if byName == nil {
		byName = make(map[string]*syscall.LazyProc)
		procedures[d] = byName
	}
	proc := byName[n]
	if proc == nil {
		proc = d.NewProc(n)
		byName[n] = proc
	}
	r, _, _ := proc.Call(args...)
	return r
}
func str(s string) *uint16 { p, _ := syscall.UTF16PtrFromString(s); return p }

type point struct{ X, Y int32 }
type msg struct {
	H       uintptr
	M       uint32
	W, L    uintptr
	T       uint32
	P       point
	Private uint32
}
type wc struct {
	Size, Style              uint32
	Proc                     uintptr
	CE, WE                   int32
	Inst, Icon, Cursor, Back uintptr
	Menu, Name               *uint16
	Small                    uintptr
}
type bih struct {
	Size            uint32
	W, H            int32
	Planes, Bits    uint16
	Compress, Bytes uint32
	X, Y            int32
	Cols, Important uint32
}
type device struct {
	Page, Usage uint16
	Flags       uint32
	Wnd         uintptr
}

const (
	logicalWidth          = 300
	logicalHeight         = 270
	masterWidth           = 600
	masterHeight          = 540
	keyPatchY             = 290
	firstCharacterCommand = 10
	firstSizeCommand      = 20
	cacheBudget           = 24 << 20
)

var percentages = [...]int{50, 75, 100, 125, 150, 200}
var characters = [...]struct{ id, title string }{
	{"blue", "DeepSeek"},
	{"amber", "Claude"},
	{"frost", "Codex"},
}
var character int
var percent = 100
var dc, dib, stockBitmap, hwnd uintptr
var bits unsafe.Pointer
var xy = point{25, 80}
var size, cur point
var gaze gazeState
var activeRig *gazeRig
var gazeCanvas gazeWork
var lastPose gazePose
var currentMaster []byte
var currentMasterName string
var layoutBusy, buttonDown, dragging, menuOpen bool
var pressedOnHead bool
var pressAt, dragThreshold point
var started = time.Now()
var mouseAt, mouseStart, keyAt, smileAt time.Time
var last string
var symbol, quadrant int
var muted bool
var activeAtlas *frameAtlas
var baseFrame []byte
var frameCache map[string][]byte
var cacheOrder []string
var xFilter, yFilter []samples
var sounds [3][]byte

func settingPath(name string) string {
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "ThreeColorPet", name)
}

func readSetting(name string) string {
	data, _ := os.ReadFile(settingPath(name))
	return string(data)
}

func loadCharacter() int {
	id := readSetting("character")
	for i, c := range characters {
		if c.id == id {
			return i
		}
	}
	return 0
}

func saveSetting(name, value string) {
	target := settingPath(name)
	if target == "" {
		return
	}
	dir := filepath.Dir(target)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return
	}
	temp, err := os.CreateTemp(dir, name+"-*")
	if err != nil {
		return
	}
	defer os.Remove(temp.Name())
	_, writeErr := temp.WriteString(value)
	if closeErr := temp.Close(); writeErr == nil && closeErr == nil {
		_ = os.Rename(temp.Name(), target)
	}
}

func toggleMute() {
	muted = !muted
	if muted {
		call(winmm, "PlaySoundW", 0, 0, 0)
	}
	saveSetting("muted", strconv.FormatBool(muted))
}

type rect struct{ left, top, right, bottom int32 }
type monitorInfo struct {
	cb           uint32
	screen, work rect
	flags        uint32
}

func loadPercent() int {
	value, err := strconv.Atoi(readSetting("size"))
	if err == nil {
		for _, n := range percentages {
			if value == n {
				return n
			}
		}
	}
	return 100
}

func monitorWork(monitor uintptr) rect {
	info := monitorInfo{}
	info.cb = uint32(unsafe.Sizeof(info))
	if monitor != 0 && call(u, "GetMonitorInfoW", monitor, uintptr(unsafe.Pointer(&info))) != 0 {
		return info.work
	}
	return rect{0, 0, int32(call(u, "GetSystemMetrics", 0)), int32(call(u, "GetSystemMetrics", 1))}
}

func windowSize(pct int, dpi uintptr, work rect) point {
	if dpi == 0 {
		dpi = 96
	}
	scale := float64(pct) * float64(dpi) / (100 * 96)
	if work.right > work.left && work.bottom > work.top {
		scale = min(scale, float64(work.right-work.left)/logicalWidth, float64(work.bottom-work.top)/logicalHeight)
	}
	return point{max(1, int32(math.Round(logicalWidth*scale))), max(1, int32(math.Round(logicalHeight*scale)))}
}

func fitOrigin(pos, sz point, work rect) point {
	return point{max(work.left, min(pos.X, work.right-sz.X)), max(work.top, min(pos.Y, work.bottom-sz.Y))}
}

func clearFrameCache() {
	frameCache = make(map[string][]byte)
	cacheOrder = nil
	currentMasterName, gazeCanvas.frame, last = "", "", ""
	currentMaster = nil
}

func resizeBitmap(target point) bool {
	if target == size && dib != 0 {
		return true
	}
	var pixels unsafe.Pointer
	header := bih{Size: 40, W: target.X, H: -target.Y, Planes: 1, Bits: 32}
	next := call(g, "CreateDIBSection", dc, uintptr(unsafe.Pointer(&header)), 0, uintptr(unsafe.Pointer(&pixels)), 0, 0)
	if next == 0 {
		return false
	}
	if pixels == nil {
		call(g, "DeleteObject", next)
		return false
	}
	previous := call(g, "SelectObject", dc, next)
	if previous == 0 || previous == ^uintptr(0) {
		call(g, "DeleteObject", next)
		return false
	}
	if dib == 0 {
		stockBitmap = previous
	} else {
		call(g, "DeleteObject", dib)
	}
	dib, bits, size = next, pixels, target
	xFilter = samplingAxis(masterWidth, int(size.X))
	yFilter = samplingAxis(masterHeight, int(size.Y))
	clearFrameCache()
	return true
}

func releaseSurface() {
	if dc == 0 {
		return
	}
	if dib != 0 {
		call(g, "SelectObject", dc, stockBitmap)
		call(g, "DeleteObject", dib)
	}
	call(g, "DeleteDC", dc)
	dc, dib, bits = 0, 0, nil
}

func setLayout(pct int, dpi uintptr, work rect, origin point, keepFeet bool) bool {
	if dc == 0 || layoutBusy {
		return false
	}
	layoutBusy = true
	defer func() { layoutBusy = false }()
	target := windowSize(pct, dpi, work)
	if keepFeet && size.X != 0 {
		origin.X += (size.X - target.X) / 2
		origin.Y += size.Y - target.Y
	}
	if !resizeBitmap(target) {
		return false
	}
	percent, xy = pct, fitOrigin(origin, target, work)
	last = ""
	if baseFrame != nil {
		paint(animationFrame(time.Now()))
	}
	return true
}

func setWindowLayout(pct int, origin point, keepFeet bool) bool {
	monitor := call(u, "MonitorFromWindow", hwnd, 2)
	return setLayout(pct, call(u, "GetDpiForWindow", hwnd), monitorWork(monitor), origin, keepFeet)
}

// The frame table is zlib-compressed little-endian TPK1. Each tile offset
// points to the top-left premultiplied BGRA pixel in this character's atlas.
type tileFrame struct {
	height  int
	offsets []uint32
}

type frameAtlas struct {
	tile, width, height int
	frames              map[string]tileFrame
	pixels              []byte
}

const (
	maxFrameTable  = 64 << 20
	maxAtlasPixels = (256 << 20) / 4
)

func parseFrameTable(data []byte) *frameAtlas {
	if len(data) < 14 || string(data[:4]) != "TPK1" {
		return nil
	}
	le := binary.LittleEndian
	tile := int(le.Uint16(data[4:6]))
	columns := int(le.Uint16(data[6:8]))
	count := int(le.Uint32(data[8:12]))
	frameCount := int(le.Uint16(data[12:14]))
	if tile == 0 || columns == 0 || count == 0 || frameCount == 0 {
		return nil
	}
	// The Windows build targets x64. Divide before multiplying to bound both
	// image allocation and the byte offsets stored below.
	width := tile * columns
	height := tile * ((count + columns - 1) / columns)
	if width > maxAtlasPixels || height > maxAtlasPixels/width {
		return nil
	}
	data = data[14:]
	if frameCount > len(data)/8 {
		return nil
	}
	atlas := &frameAtlas{tile: tile, width: width, height: height, frames: make(map[string]tileFrame, frameCount)}
	frameColumns := (masterWidth + tile - 1) / tile
	for i := 0; i < frameCount; i++ {
		if len(data) == 0 {
			return nil
		}
		n := int(data[0])
		if n == 0 || len(data) < 1+n+2 {
			return nil
		}
		for _, c := range data[1 : 1+n] {
			if c < 0x21 || c > 0x7e {
				return nil
			}
		}
		name := string(data[1 : 1+n])
		if _, exists := atlas.frames[name]; exists {
			return nil
		}
		h := int(le.Uint16(data[1+n:]))
		expected := masterHeight
		if strings.HasPrefix(name, "key") {
			expected = masterHeight - keyPatchY
		}
		if h != expected {
			return nil
		}
		data = data[n+3:]
		slots := frameColumns * ((h + tile - 1) / tile)
		if slots > len(data)/4 {
			return nil
		}
		offsets := make([]uint32, slots)
		for j := range offsets {
			id := int(le.Uint32(data[j*4:]))
			if id >= count {
				return nil
			}
			offsets[j] = uint32(4 * (id/columns*tile*width + id%columns*tile))
		}
		atlas.frames[name] = tileFrame{height: h, offsets: offsets}
		data = data[slots*4:]
	}
	if _, ok := atlas.frames["idle0"]; !ok || len(data) != 0 {
		return nil
	}
	return atlas
}

func loadAtlas(index int) *frameAtlas {
	if index < 0 || index >= len(characters) {
		return nil
	}
	dir := "packed/" + characters[index].id + "/"
	table, err := fs.Open(dir + "frames.z")
	if err != nil {
		return nil
	}
	defer table.Close()
	z, err := zlib.NewReader(table)
	if err != nil {
		return nil
	}
	defer z.Close()
	data, err := io.ReadAll(io.LimitReader(z, maxFrameTable+1))
	if err != nil || len(data) > maxFrameTable {
		return nil
	}
	atlas := parseFrameTable(data)
	if atlas == nil {
		return nil
	}
	raw, err := fs.ReadFile(dir + "atlas.png")
	if err != nil {
		return nil
	}
	config, err := png.DecodeConfig(bytes.NewReader(raw))
	if err != nil || config.Width != atlas.width || config.Height != atlas.height {
		return nil
	}
	im, err := png.Decode(bytes.NewReader(raw))
	if err != nil {
		return nil
	}
	rgba := image.NewRGBA(im.Bounds())
	draw.Draw(rgba, rgba.Bounds(), im, image.Point{}, draw.Src)
	p := rgba.Pix
	for i := 0; i < len(p); i += 4 {
		p[i], p[i+2] = p[i+2], p[i]
	}
	atlas.pixels = p
	return atlas
}

func (atlas *frameAtlas) copyFrame(name string, dst []byte) bool {
	frame, ok := atlas.frames[name]
	if !ok || len(dst) != 4*masterWidth*frame.height {
		return false
	}
	i := 0
	for y := 0; y < frame.height; y += atlas.tile {
		h := min(atlas.tile, frame.height-y)
		for x := 0; x < masterWidth; x += atlas.tile {
			w := 4 * min(atlas.tile, masterWidth-x)
			src := int(frame.offsets[i])
			dest := 4 * (y*masterWidth + x)
			i++
			for row := 0; row < h; row++ {
				copy(dst[dest:dest+w], atlas.pixels[src:src+w])
				dest += masterWidth * 4
				src += atlas.width * 4
			}
		}
	}
	return true
}

// Each dest pixel's taps integrate the covered source pixels when shrinking.
// When enlarging they interpolate between the two nearest pixel centers.
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

func scaledFrame(src []byte) []byte {
	width, height := int(size.X), int(size.Y)
	horizontal := src
	if width != masterWidth {
		horizontal = make([]byte, width*masterHeight*4)
		for y := 0; y < masterHeight; y++ {
			for x, taps := range xFilter {
				filterPixel(src, (y*masterWidth+taps.first)*4, 4, taps.weights, horizontal[(y*width+x)*4:])
			}
		}
	}
	if height == masterHeight {
		return horizontal
	}
	pixels := make([]byte, width*height*4)
	for y, taps := range yFilter {
		for x := 0; x < width; x++ {
			filterPixel(horizontal, (taps.first*width+x)*4, width*4, taps.weights, pixels[(y*width+x)*4:])
		}
	}
	return pixels
}

func selectCharacter(index int) bool {
	atlas := loadAtlas(index)
	if atlas == nil {
		return false
	}
	idle := make([]byte, 4*masterWidth*masterHeight)
	if !atlas.copyFrame("idle0", idle) {
		return false
	}
	rig := loadGazeRig(index)
	if rig == nil {
		return false
	}
	character, activeAtlas, activeRig, baseFrame = index, atlas, rig, idle
	smileAt = time.Time{}
	stroke = headStroke{}
	clearFrameCache()
	paint("idle0")
	return true
}

func masterFrame(name string) []byte {
	if name == currentMasterName && currentMaster != nil {
		return currentMaster
	}
	source := baseFrame
	if name != "idle0" {
		source = make([]byte, len(baseFrame))
		dst := source
		if strings.HasPrefix(name, "key") {
			top := keyPatchY * masterWidth * 4
			copy(source[:top], baseFrame[:top])
			dst = source[top:]
		}
		if !activeAtlas.copyFrame(name, dst) {
			return nil
		}
	}
	currentMasterName, currentMaster = name, source
	return source
}

func framePixels(name string) []byte {
	if pixels, ok := frameCache[name]; ok {
		return pixels
	}
	source := masterFrame(name)
	if source == nil {
		return nil
	}
	pixels := scaledFrame(source)
	if len(pixels) > cacheBudget {
		return pixels
	}
	limit := min(48, cacheBudget/len(pixels))
	if len(cacheOrder) >= limit {
		delete(frameCache, cacheOrder[0])
		cacheOrder = cacheOrder[1:]
	}
	frameCache[name] = pixels
	cacheOrder = append(cacheOrder, name)
	return pixels
}

// Directions are quantized to 1/64. GAZ1's signed coefficients are in eighths
// of a master pixel, giving exact 1/512-pixel coordinates before interpolation.
type gazePose struct{ headX, headY, eyeX, eyeY int }

func (s *gazeState) pose(name string) gazePose {
	q := func(v float64) int { return int(math.Round(v * 64)) }
	p := gazePose{headX: q(s.head.x), headY: q(s.head.y)}
	if name != "idle7" && !strings.HasPrefix(name, "smile") {
		p.eyeX, p.eyeY = q(s.eyes.x), q(s.eyes.y)
	}
	return p
}

type gazeRig struct {
	x, y, w, h int
	field      []byte
}

func loadGazeRig(index int) *gazeRig {
	f, err := fs.Open("gaze/" + characters[index].id + ".gaze")
	if err != nil {
		return nil
	}
	defer f.Close()
	z, err := zlib.NewReader(f)
	if err != nil {
		return nil
	}
	defer z.Close()
	data, err := io.ReadAll(io.LimitReader(z, 13+masterWidth*masterHeight*6))
	if err != nil || len(data) < 12 || string(data[:4]) != "GAZ1" {
		return nil
	}
	u := binary.LittleEndian
	r := &gazeRig{
		x: int(u.Uint16(data[4:])), y: int(u.Uint16(data[6:])),
		w: int(u.Uint16(data[8:])), h: int(u.Uint16(data[10:])),
		field: data[12:],
	}
	if r.w == 0 || r.h == 0 || r.x+r.w > masterWidth || r.y+r.h > masterHeight || len(r.field) != r.w*r.h*6 {
		return nil
	}
	return r
}

func (r *gazeRig) warp(src, dst []byte, pose gazePose) {
	for row := 0; row < r.h; row++ {
		y := r.y + row
		for col := 0; col < r.w; col++ {
			i := (row*r.w + col) * 6
			c := r.field[i : i+6]
			if c[0]|c[1]|c[2]|c[3]|c[4]|c[5] == 0 {
				continue
			}
			x := r.x + col
			hx := x*512 + pose.headX*int(int8(c[0])) + pose.headY*int(int8(c[2]))
			hy := y*512 + pose.headX*int(int8(c[1])) + pose.headY*int(int8(c[3]))
			sx, sy := hx, hy
			if pose.eyeX != 0 || pose.eyeY != 0 {
				// The iris field lives on the neutral face; it follows the head.
				ex := ((hx + 256) >> 9) - r.x
				ey := ((hy + 256) >> 9) - r.y
				if ex >= 0 && ex < r.w && ey >= 0 && ey < r.h {
					e := (ey*r.w + ex) * 6
					sx += pose.eyeX * int(int8(r.field[e+4]))
					sy += pose.eyeY * int(int8(r.field[e+5]))
				}
			}
			sx = max(0, min((masterWidth-1)*512, sx))
			sy = max(0, min((masterHeight-1)*512, sy))
			left, top := sx>>9, sy>>9
			right, bottom := min(left+1, masterWidth-1), min(top+1, masterHeight-1)
			fx, fy := sx&511, sy&511
			weights := [4]int{(512 - fx) * (512 - fy), fx * (512 - fy), (512 - fx) * fy, fx * fy}
			topLeft := src[4*(top*masterWidth+left):][:4]
			topRight := src[4*(top*masterWidth+right):][:4]
			bottomLeft := src[4*(bottom*masterWidth+left):][:4]
			bottomRight := src[4*(bottom*masterWidth+right):][:4]
			out := dst[4*(y*masterWidth+x):][:4]
			for j := range out {
				value := int(topLeft[j])*weights[0] + int(topRight[j])*weights[1] +
					int(bottomLeft[j])*weights[2] + int(bottomRight[j])*weights[3]
				out[j] = byte((value + (1 << 17)) >> 18)
			}
		}
	}
}

// The gaze is independent of the action. Only the current master canvas and
// one scratch canvas are retained; pose combinations never enter the frame cache.
type gazeWork struct {
	frame              string
	master, horizontal []byte
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

func (work *gazeWork) render(dst []byte, name string, pose gazePose) {
	r := activeRig
	if r == nil || pose == (gazePose{}) {
		return
	}
	source := masterFrame(name)
	if source == nil {
		return
	}
	if work.frame != name {
		if len(work.master) != len(source) {
			work.master = make([]byte, len(source))
		}
		copy(work.master, source)
		work.frame = name
	}
	r.warp(source, work.master, pose)
	if size.X == masterWidth && size.Y == masterHeight {
		for row := r.y; row < r.y+r.h; row++ {
			start := 4 * (row*masterWidth + r.x)
			copy(dst[start:start+r.w*4], work.master[start:start+r.w*4])
		}
		return
	}
	// Use exactly the normal two-pass filter, restricted to the output pixels
	// whose sampling footprint intersects the warped master rectangle.
	x0, x1 := affectedRange(xFilter, r.x, r.x+r.w)
	y0, y1 := affectedRange(yFilter, r.y, r.y+r.h)
	if x0 == x1 || y0 == y1 {
		return
	}
	sy0 := yFilter[y0].first
	end := yFilter[y1-1]
	sy1 := end.first + len(end.weights)
	stride := (x1 - x0) * 4
	length := (sy1 - sy0) * stride
	if cap(work.horizontal) < length {
		work.horizontal = make([]byte, length)
	}
	temp := work.horizontal[:length]
	for y := sy0; y < sy1; y++ {
		for x := x0; x < x1; x++ {
			t := xFilter[x]
			filterPixel(work.master, 4*(y*masterWidth+t.first), 4, t.weights, temp[(y-sy0)*stride+(x-x0)*4:])
		}
	}
	for y := y0; y < y1; y++ {
		t := yFilter[y]
		for x := x0; x < x1; x++ {
			filterPixel(temp, (t.first-sy0)*stride+(x-x0)*4, stride, t.weights, dst[4*(y*int(size.X)+x):])
		}
	}
}

func paint(name string) {
	pose := gaze.pose(name)
	if bits == nil || baseFrame == nil || (name == last && pose == lastPose) {
		return
	}
	pixels := framePixels(name)
	if pixels == nil {
		name = "idle0"
		pose = gaze.pose(name)
		if name == last && pose == lastPose {
			return
		}
		pixels = framePixels(name)
	}
	dst := unsafe.Slice((*byte)(bits), len(pixels))
	copy(dst, pixels)
	gazeCanvas.render(dst, name, pose)
	zero := point{}
	blend := uint32(0x01ff0000)
	if call(u, "UpdateLayeredWindow", hwnd, 0, uintptr(unsafe.Pointer(&xy)), uintptr(unsafe.Pointer(&size)), dc, uintptr(unsafe.Pointer(&zero)), 0, uintptr(unsafe.Pointer(&blend)), 2) != 0 {
		last, lastPose = name, pose
	}
}

func keyStage(age int64) int {
	switch {
	case age < 35:
		return 1
	case age < 70:
		return 2
	case age < 110:
		return 3
	case age < 155:
		return 4
	case age < 220:
		return 5
	default:
		return 0
	}
}

func mouseStage(reach, sinceMove int64) int {
	switch {
	case sinceMove >= 850:
		return 0
	case sinceMove >= 770:
		return 1
	case sinceMove >= 690:
		return 2
	case reach < 40:
		return 1
	case reach < 95:
		return 2
	default:
		return 3
	}
}

func animationFrame(now time.Time) string {
	if elapsed := now.Sub(smileAt); elapsed >= 0 && elapsed < time.Second {
		stage := 0
		for _, end := range [...]time.Duration{100, 250, 430, 630, 830} {
			if elapsed < end*time.Millisecond {
				break
			}
			stage++
		}
		return fmt.Sprintf("smile%d", stage)
	}
	if n := keyStage(now.Sub(keyAt).Milliseconds()); n != 0 {
		return fmt.Sprintf("key%d-%d", symbol, n)
	}
	if mouseAt.After(keyAt) {
		if n := mouseStage(now.Sub(mouseStart).Milliseconds(), now.Sub(mouseAt).Milliseconds()); n != 0 {
			return fmt.Sprintf("mouse%d%d", n, quadrant)
		}
	}
	t := now.Sub(started).Milliseconds()
	if t%4700 < 95 {
		return "idle7"
	}
	return fmt.Sprintf("idle%d", t/240%7)
}

func mouseQuadrant(p point) int {
	q := 0
	if p.X > xy.X+size.X/2 {
		q++
	}
	if p.Y < xy.Y+size.Y/2 {
		q += 2
	}
	return q
}

func logicalPoint(p point) (float64, float64) {
	return float64(p.X-xy.X) * logicalWidth / float64(size.X), float64(p.Y-xy.Y) * logicalHeight / float64(size.Y)
}

// Cursor tracking uses physical screen coordinates, normalized against the
// current pet window so a DPI change or a window move updates a stationary gaze.
type direction struct{ x, y float64 }
type gazeState struct {
	head, eyes direction
	updated    time.Time
}

func gazeTarget(cursor, origin, extent point) direction {
	if extent.X <= 0 || extent.Y <= 0 {
		return direction{}
	}
	x := float64(cursor.X-origin.X) * logicalWidth / float64(extent.X)
	y := float64(cursor.Y-origin.Y) * logicalHeight / float64(extent.Y)
	return direction{math.Tanh((x - 150) / 170), math.Tanh((y - 77) / 125)}
}

func easeDirection(current, target direction, dt, tau float64) direction {
	fraction := -math.Expm1(-dt / tau)
	return direction{current.x + (target.x-current.x)*fraction, current.y + (target.y-current.y)*fraction}
}

func (state *gazeState) advance(now time.Time, target direction) {
	dt := now.Sub(state.updated).Seconds()
	if state.updated.IsZero() {
		dt = .016
	}
	if dt <= 0 {
		return
	}
	state.head = easeDirection(state.head, target, dt, .135)
	state.eyes = easeDirection(state.eyes, target, dt, .065)
	state.updated = now
}

func onHead(p point) bool {
	if size.X == 0 || size.Y == 0 {
		return false
	}
	x, y := logicalPoint(p)
	dx, dy := (x-150)/43, (y-77)/52
	return dx*dx+dy*dy <= 1
}

type headStroke struct {
	since, lastMove time.Time
	startX, extreme float64
	direction       float64
	consumed        bool
}

var stroke headStroke

func startSmile(now time.Time) {
	if now.Sub(smileAt) >= 1300*time.Millisecond {
		smileAt = now
		stroke.consumed = true
	}
}

func strokeHead(p point, now time.Time) {
	if !onHead(p) {
		stroke = headStroke{}
		return
	}
	if stroke.consumed || now.Sub(smileAt) < 1300*time.Millisecond {
		return
	}
	x, _ := logicalPoint(p)
	if stroke.since.IsZero() || now.Sub(stroke.lastMove) > 350*time.Millisecond || now.Sub(stroke.since) > 900*time.Millisecond {
		stroke = headStroke{since: now, lastMove: now, startX: x, extreme: x}
		return
	}
	stroke.lastMove = now
	if stroke.direction == 0 {
		if math.Abs(x-stroke.startX) >= 7 {
			stroke.direction = math.Copysign(1, x-stroke.startX)
			stroke.extreme = x
		}
		return
	}
	progress := (x - stroke.extreme) * stroke.direction
	if progress > 0 {
		stroke.extreme = x
	} else if progress <= -7 {
		startSmile(now)
	}
}

func crossedDragThreshold(p point) bool {
	dx, dy := p.X-pressAt.X, p.Y-pressAt.Y
	return dx >= dragThreshold.X || dx <= -dragThreshold.X || dy >= dragThreshold.Y || dy <= -dragThreshold.Y
}

func cursorPosition() point {
	var p point
	call(u, "GetCursorPos", uintptr(unsafe.Pointer(&p)))
	return p
}

func sampleCursor(now time.Time) {
	p := cursorPosition()
	gaze.advance(now, gazeTarget(p, xy, size))
	if p != cur {
		if !dragging && !buttonDown && !menuOpen {
			strokeHead(p, now)
		}
		if !mouseAt.After(keyAt) || now.Sub(mouseAt) >= 850*time.Millisecond {
			mouseStart = now
		}
		mouseAt = now
		cur = p
	}
	quadrant = mouseQuadrant(p)
}

func tick() {
	now := time.Now()
	sampleCursor(now)
	paint(animationFrame(now))
}

func input(l uintptr) {
	var data [64]byte
	sz := uint32(len(data))
	n := call(u, "GetRawInputData", l, 0x10000003, uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(&sz)), 24)
	if n < 40 || n > 64 || data[0] != 1 || data[26]&1 != 0 {
		return
	}
	v := int(data[30])
	switch v {
	case 186:
		v = 59
	case 187:
		v = 61
	case 188:
		v = 44
	case 189:
		v = 45
	case 190:
		v = 46 + 1000
	case 191:
		v = 47
	case 219:
		v = 91
	case 221:
		v = 93
	case 222:
		v = 39
	case 46:
		v = 127
	default:
		if !(v >= 65 && v <= 90 || v >= 48 && v <= 57 || v == 32 || v == 8) {
			return
		}
	}
	keyAt = time.Now()
	sampleCursor(keyAt)
	symbol = v
	if !muted {
		kind := 0
		if v == 32 {
			kind = 1
		}
		if v == 8 || v == 127 {
			kind = 2
		}
		b := sounds[kind]
		if len(b) > 0 {
			call(winmm, "PlaySoundW", uintptr(unsafe.Pointer(&b[0])), 0, 7)
		}
	}
	paint(animationFrame(keyAt))
}
func proc(h, m, w, l uintptr) uintptr {
	switch m {
	case 0xff:
		input(l)
	case 0x113:
		tick()
		return 0
	case 0x201: // WM_LBUTTONDOWN
		buttonDown = true
		pressAt = cursorPosition()
		pressedOnHead = onHead(pressAt)
		stroke = headStroke{}
		dpi := call(u, "GetDpiForWindow", h)
		dragThreshold = point{max(1, int32(call(u, "GetSystemMetricsForDpi", 68, dpi))), max(1, int32(call(u, "GetSystemMetricsForDpi", 69, dpi)))}
		call(u, "SetCapture", h)
		return 0
	case 0x200: // WM_MOUSEMOVE, while captured
		if buttonDown {
			p := cursorPosition()
			if crossedDragThreshold(p) {
				buttonDown = false
				dragging = true
				call(u, "ReleaseCapture")
				packed := uintptr(uint16(p.X)) | uintptr(uint16(p.Y))<<16
				call(u, "SendMessageW", h, 0xa1, 2, packed)
				dragging = false
				setWindowLayout(percent, xy, false)
			}
		}
		return 0
	case 0x202: // WM_LBUTTONUP
		if buttonDown {
			buttonDown = false
			call(u, "ReleaseCapture")
			p := cursorPosition()
			if pressedOnHead && !crossedDragThreshold(p) && onHead(p) {
				now := time.Now()
				startSmile(now)
				paint(animationFrame(now))
			}
		}
		return 0
	case 0x215: // WM_CAPTURECHANGED
		buttonDown = false
		return 0
	case 3: // WM_MOVE
		var pos rect
		if call(u, "GetWindowRect", h, uintptr(unsafe.Pointer(&pos))) != 0 {
			xy = point{pos.left, pos.top}
		}
		return 0
	case 0x2e0: // WM_DPICHANGED
		if dc != 0 && l != 0 && !layoutBusy {
			pos := (*rect)(unsafe.Pointer(l))
			monitor := call(u, "MonitorFromRect", l, 2)
			setLayout(percent, w&0xffff, monitorWork(monitor), point{pos.left, pos.top}, false)
		}
		return 0
	case 0x7e, 0x1a: // WM_DISPLAYCHANGE, WM_SETTINGCHANGE (includes the work area)
		if hwnd != 0 && dc != 0 {
			setWindowLayout(percent, xy, false)
		}
		return 0
	case 0x205:
		menu := call(u, "CreatePopupMenu")
		for i, c := range characters {
			var checked uintptr
			if i == character {
				checked = 8
			}
			call(u, "AppendMenuW", menu, checked, uintptr(firstCharacterCommand+i), uintptr(unsafe.Pointer(str(c.title))))
		}
		sizes := call(u, "CreatePopupMenu")
		for i, n := range percentages {
			var checked uintptr
			if n == percent {
				checked = 8
			}
			label := str(strconv.Itoa(n) + "%")
			call(u, "AppendMenuW", sizes, checked, uintptr(firstSizeCommand+i), uintptr(unsafe.Pointer(label)))
		}
		call(u, "AppendMenuW", menu, 0x10, sizes, uintptr(unsafe.Pointer(str("大小"))))
		call(u, "AppendMenuW", menu, 0x800, 0, 0)
		flag := uintptr(0)
		if muted {
			flag = 8
		}
		call(u, "AppendMenuW", menu, flag, 1, uintptr(unsafe.Pointer(str("静音"))))
		call(u, "AppendMenuW", menu, 0, 2, uintptr(unsafe.Pointer(str("退出三色桌宠"))))
		p := point{}
		call(u, "GetCursorPos", uintptr(unsafe.Pointer(&p)))
		call(u, "SetForegroundWindow", h)
		menuOpen = true
		cmd := call(u, "TrackPopupMenu", menu, 0x102, uintptr(p.X), uintptr(p.Y), 0, h, 0)
		menuOpen = false
		call(u, "DestroyMenu", menu)
		switch {
		case cmd >= firstCharacterCommand && cmd < firstCharacterCommand+uintptr(len(characters)):
			index := int(cmd - firstCharacterCommand)
			if index != character && selectCharacter(index) {
				saveSetting("character", characters[character].id)
			}
		case cmd >= firstSizeCommand && cmd < firstSizeCommand+uintptr(len(percentages)):
			n := percentages[cmd-firstSizeCommand]
			if n != percent && setWindowLayout(n, xy, true) {
				saveSetting("size", strconv.Itoa(percent))
			}
		case cmd == 1:
			toggleMute()
		case cmd == 2:
			call(u, "DestroyWindow", h)
		}
		return 0
	case 2:
		call(u, "PostQuitMessage", 0)
		return 0
	}
	return call(u, "DefWindowProcW", h, m, w, l)
}
func main() {
	runtime.LockOSThread()
	muted = readSetting("muted") == "true"
	percent = loadPercent()
	// PER_MONITOR_AWARE_V2, available on the supported Windows 11 platform.
	if call(u, "SetProcessDpiAwarenessContext", ^uintptr(3)) == 0 {
		call(u, "SetProcessDPIAware")
	}
	for i := range sounds {
		sounds[i], _ = fs.ReadFile(fmt.Sprintf("assets/%d.wav", i))
	}
	inst := call(k, "GetModuleHandleW", 0)
	name := str("ThreeColorDesktopPet")
	c := wc{Proc: syscall.NewCallback(proc), Inst: inst, Name: name, Cursor: call(u, "LoadCursorW", 0, 32512)}
	c.Size = uint32(unsafe.Sizeof(c))
	if call(u, "RegisterClassExW", uintptr(unsafe.Pointer(&c))) == 0 {
		return
	}
	hwnd = call(u, "CreateWindowExW", 0x08080088, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(str("三色桌宠"))), 0x80000000, uintptr(xy.X), uintptr(xy.Y), logicalWidth, logicalHeight, 0, 0, inst, 0)
	if hwnd == 0 {
		return
	}
	dc = call(g, "CreateCompatibleDC", 0)
	if dc == 0 {
		return
	}
	defer releaseSurface()
	monitor := call(u, "MonitorFromWindow", hwnd, 2)
	work := monitorWork(monitor)
	dpi := call(u, "GetDpiForWindow", hwnd)
	initial := windowSize(percent, dpi, work)
	origin := point{work.left + 25, work.bottom - initial.Y - 68}
	if !setLayout(percent, dpi, work, origin, false) {
		return
	}
	dev := device{1, 6, 0x100, hwnd}
	if call(u, "RegisterRawInputDevices", uintptr(unsafe.Pointer(&dev)), 1, unsafe.Sizeof(dev)) == 0 {
		call(u, "MessageBoxW", hwnd, uintptr(unsafe.Pointer(str("系统未允许键盘响应，角色仍可跟随鼠标。"))), uintptr(unsafe.Pointer(name)), 0)
	}
	call(u, "GetCursorPos", uintptr(unsafe.Pointer(&cur)))
	if !selectCharacter(loadCharacter()) && !selectCharacter(0) {
		call(u, "MessageBoxW", hwnd, uintptr(unsafe.Pointer(str("无法读取角色的初始图像。"))), uintptr(unsafe.Pointer(str("三色桌宠"))), 0x10)
		return
	}
	call(u, "ShowWindow", hwnd, 4)
	call(u, "SetTimer", hwnd, 1, 16, 0)
	var m msg
	for int32(call(u, "GetMessageW", uintptr(unsafe.Pointer(&m)), 0, 0, 0)) > 0 {
		call(u, "TranslateMessage", uintptr(unsafe.Pointer(&m)))
		call(u, "DispatchMessageW", uintptr(unsafe.Pointer(&m)))
	}
}
