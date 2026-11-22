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
	"math/rand"
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
var registry = syscall.NewLazyDLL("advapi32.dll")
var shell = syscall.NewLazyDLL("shell32.dll")

// The timer callback posts to the UI thread and never touches its procedure cache.
var postWindowMessage = u.NewProc("PostMessageW")

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

// NOTIFYICONDATAW uses the same window and resource icon as the pet.
type notifyIconData struct {
	Size                uint32
	Window              uintptr
	ID, Flags, Callback uint32
	Icon                uintptr
	Tip                 [128]uint16
	State, StateMask    uint32
	Info                [256]uint16
	Version             uint32
	InfoTitle           [64]uint16
	InfoFlags           uint32
	GUID                [16]byte
	BalloonIcon         uintptr
}

var tray notifyIconData
var taskbarCreated uintptr

type notifyIconIdentifier struct {
	Size   uint32
	Window uintptr
	ID     uint32
	GUID   [16]byte
}

func addTrayIcon() {
	ptr := uintptr(unsafe.Pointer(&tray))
	if call(shell, "Shell_NotifyIconW", 0, ptr) != 0 { // NIM_ADD
		tray.Version = 4
		call(shell, "Shell_NotifyIconW", 4, ptr) // NIM_SETVERSION
	}
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
	contactMessage        = 0x8000 + 13 // private WM_APP message
	trayMessage           = 0x8000 + 14
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
var currentMasterName scene
var layoutBusy, buttonDown, dragging, menuOpen bool
var pressedOnHead bool
var pressAt, dragThreshold point
var started = time.Now()
var mouseAt, mouseStart, keyAt, smileAt time.Time
var last scene
var symbol, quadrant int
var muted bool
var activeAtlas *frameAtlas
var baseFrame []byte
var frameCache map[scene][]byte
var cacheOrder []scene
var layers *expressionLayers
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

// This per-user entry is read when opening the menu and changed only on request.
const startupKey = `Software\Microsoft\Windows\CurrentVersion\Run`
const startupName = "ThreeColorPet"

func startupCommand() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	return `"` + path + `"`, nil
}

func registeredStartup() (string, error) {
	var data [512]uint16
	n := uint32(len(data) * 2)
	rc := call(registry, "RegGetValueW", syscall.HKEY_CURRENT_USER, uintptr(unsafe.Pointer(str(startupKey))), uintptr(unsafe.Pointer(str(startupName))), 2, 0, uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(&n)))
	switch rc {
	case 0:
		return syscall.UTF16ToString(data[:]), nil
	case 2, 3: // ERROR_FILE_NOT_FOUND / ERROR_PATH_NOT_FOUND
		return "", nil
	default:
		return "", fmt.Errorf("无法读取登录启动设置（Windows 错误 %d）", rc)
	}
}

func configureStartup(enabled bool) error {
	key, name := str(startupKey), str(startupName)
	if !enabled {
		rc := call(registry, "RegDeleteKeyValueW", syscall.HKEY_CURRENT_USER, uintptr(unsafe.Pointer(key)), uintptr(unsafe.Pointer(name)))
		if rc != 0 && rc != 2 && rc != 3 {
			return fmt.Errorf("无法取消登录启动（Windows 错误 %d）", rc)
		}
		return nil
	}
	command, err := startupCommand()
	if err != nil {
		return err
	}
	data, err := syscall.UTF16FromString(command)
	if err != nil {
		return err
	}
	if len(data)-1 > 260 {
		return fmt.Errorf("Windows 的登录启动命令最多支持 260 个字符，请将桌宠移到路径较短的目录。")
	}
	rc := call(registry, "RegSetKeyValueW", syscall.HKEY_CURRENT_USER, uintptr(unsafe.Pointer(key)), uintptr(unsafe.Pointer(name)), 1, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)*2))
	if rc != 0 {
		return fmt.Errorf("无法设置登录启动（Windows 错误 %d）", rc)
	}
	return nil
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
	frameCache = make(map[scene][]byte)
	cacheOrder = nil
	currentMasterName, gazeCanvas.frame, gazeCanvas.hobby, last = scene{}, scene{}, scene{}, scene{}
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
	last = scene{}
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

type expression struct {
	smile  bool
	amount int // 0=open, 64=half, 128=closed
	heart  int // 0=absent, 1..6=the exported heart phases
}
type scene struct {
	hand     string
	face     expression
	desk     deskMouse
	zzz      int // 1..25 in the sleeping cycle
	wakeRest int // 0=awake, 64..256 are the four accessory poses
	mood     moodLayer
	toy      toyPose
	armTween int // 0..256 between the two measured palm poses
}
type moodLayer struct{ number, weight int }
type toyPose struct {
	visible bool
	x, y    int // center in master pixels
}

type toyLayer struct {
	pixels []byte
	bounds image.Rectangle
	desk   []byte
	arms   [5]armSprite
}

type armSprite struct {
	pixels []byte
	bounds image.Rectangle
}

var palms = [5]image.Point{1: {433, 247}, 2: {436, 207}, 4: {437, 291}}

func palmCenter(from, to, weight int) (float64, float64) {
	a, b := palms[from], palms[to]
	return float64(a.X*(256-weight)+b.X*weight) / 256, float64(a.Y*(256-weight)+b.Y*weight) / 256
}

// Coordinates use signed 1/256-pixel inverse sampling with transparent borders.
func (s armSprite) sample(x256, y256 int) (color [4]int) {
	x, y := x256>>8, y256>>8
	if x+1 < s.bounds.Min.X || y+1 < s.bounds.Min.Y || x >= s.bounds.Max.X || y >= s.bounds.Max.Y {
		return
	}
	fx, fy := x256&255, y256&255
	for row, wy := range [2]int{256 - fy, fy} {
		for col, wx := range [2]int{256 - fx, fx} {
			xx, yy := x+col, y+row
			if wx*wy == 0 || !image.Pt(xx, yy).In(s.bounds) {
				continue
			}
			i := 4 * ((yy-s.bounds.Min.Y)*s.bounds.Dx() + xx - s.bounds.Min.X)
			for c := range color {
				color[c] += int(s.pixels[i+c]) * wx * wy
			}
		}
	}
	for c := range color {
		color[c] = (color[c] + 32768) >> 16
	}
	return
}

func (l *toyLayer) tweenArms(dst []byte, hand string, weight int) {
	from, to := 1, 2
	if hand == "toss4" {
		from, to = 4, 1
	}
	cx, cy := palmCenter(from, to, weight)
	a, b := l.arms[from], l.arms[to]
	bounds := a.bounds.Union(b.bounds)
	bounds = image.Rect(bounds.Min.X-5, bounds.Min.Y-45, bounds.Max.X+5, bounds.Max.Y+45).Intersect(image.Rect(0, 0, masterWidth, masterHeight))
	for x := bounds.Min.X; x < bounds.Max.X; x++ {
		t := clampUnit(float64(x-365) / 56)
		g := 256 * t * t * (3 - 2*t)
		ax := x*256 - int(math.Round((cx-float64(palms[from].X))*g))
		bx := x*256 - int(math.Round((cx-float64(palms[to].X))*g))
		ay := int(math.Round((cy - float64(palms[from].Y)) * g))
		by := int(math.Round((cy - float64(palms[to].Y)) * g))
		for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
			ca, cb := a.sample(ax, y*256-ay), b.sample(bx, y*256-by)
			alpha := (ca[3]*(256-weight) + cb[3]*weight + 128) >> 8
			if alpha == 0 {
				continue
			}
			i := 4 * (y*masterWidth + x)
			for c := 0; c < 4; c++ {
				s := (ca[c]*(256-weight) + cb[c]*weight + 128) >> 8
				dst[i+c] = byte(min(255, s+(int(dst[i+c])*(255-alpha)+127)/255))
			}
		}
	}
}

var toyArt *toyLayer

func (l *toyLayer) draw(dst []byte, pose toyPose) {
	offset := image.Pt(pose.x-300, pose.y-270)
	bounds := l.bounds.Add(offset).Intersect(image.Rect(0, 0, masterWidth, masterHeight))
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			i := 4 * (y*masterWidth + x)
			j := 4 * ((y-offset.Y)*masterWidth + x - offset.X)
			a := int(l.pixels[j+3])
			if a == 0 {
				continue
			}
			for c := 0; c < 4; c++ {
				dst[i+c] = byte(min(255, int(l.pixels[j+c])+(int(dst[i+c])*(255-a)+127)/255))
			}
		}
	}
}

type expressionLayers struct {
	blinkHalf, blinkFull, smileHalf, smileFull []byte
	hearts                                     [6][]byte
	moods                                      [6][]byte
}

var faceRect = image.Rect(208, 108, 389, 254)
var heartRect = image.Rect(420, 39, 496, 162)
var moodRect = image.Rect(230, 123, 374, 243)

func extractRegion(full []byte, rect image.Rectangle) []byte {
	stride := rect.Dx() * 4
	out := make([]byte, stride*rect.Dy())
	for y := rect.Min.Y; y < rect.Max.Y; y++ {
		offset := 4 * (y*masterWidth + rect.Min.X)
		copy(out[(y-rect.Min.Y)*stride:], full[offset:offset+stride])
	}
	return out
}

func loadExpressionLayers(atlas *frameAtlas, moodCount int) *expressionLayers {
	l := &expressionLayers{}
	temp := make([]byte, masterWidth*masterHeight*4)
	for _, asset := range []struct {
		name string
		dest *[]byte
	}{
		{"blinkHalf", &l.blinkHalf}, {"idle7", &l.blinkFull}, {"smileHalf", &l.smileHalf}, {"smile0", &l.smileFull},
	} {
		if !atlas.copyFrame(asset.name, temp) {
			return nil
		}
		*asset.dest = extractRegion(temp, faceRect)
	}
	for i := range l.hearts {
		if !atlas.copyFrame(fmt.Sprintf("smile%d", i), temp) {
			return nil
		}
		l.hearts[i] = extractRegion(temp, heartRect)
	}
	for i := 0; i < moodCount; i++ {
		if !atlas.copyFrame(fmt.Sprintf("mood%d", i+1), temp) {
			return nil
		}
		l.moods[i] = extractRegion(temp, moodRect)
	}
	return l
}

func (l *expressionLayers) applyMood(full []byte, mood moodLayer, meal bool) {
	art := l.moods[mood.number-1]
	next := 0
	for y := moodRect.Min.Y; y < moodRect.Max.Y; y++ {
		for x := moodRect.Min.X; x < moodRect.Max.X; x++ {
			i := 4 * (y*masterWidth + x)
			// Leave painted chopsticks, rice and the mouth in front of the face.
			if !meal || bytes.Equal(full[i:i+4], baseFrame[i:i+4]) {
				for c := 0; c < 4; c++ {
					full[i+c] = byte((int(full[i+c])*(64-mood.weight) + int(art[next+c])*mood.weight + 32) / 64)
				}
			}
			next += 4
		}
	}
}

func (l *expressionLayers) apply(full []byte, face expression) {
	if face.amount > 0 {
		half, closed := l.blinkHalf, l.blinkFull
		if face.smile {
			half, closed = l.smileHalf, l.smileFull
		}
		stride := 4 * faceRect.Dx()
		for y := faceRect.Min.Y; y < faceRect.Max.Y; y++ {
			start := 4 * (y*masterWidth + faceRect.Min.X)
			dest := full[start : start+stride]
			src := (y - faceRect.Min.Y) * stride
			from, to, weight := dest, half[src:src+stride], face.amount
			if face.amount > 64 {
				from, to, weight = to, closed[src:src+stride], face.amount-64
			}
			for j := range dest {
				dest[j] = byte((int(from[j])*(64-weight) + int(to[j])*weight + 32) >> 6)
			}
		}
	}
	if face.heart > 0 {
		layer := l.hearts[face.heart-1]
		stride := 4 * heartRect.Dx()
		for y := heartRect.Min.Y; y < heartRect.Max.Y; y++ {
			start := 4 * (y*masterWidth + heartRect.Min.X)
			row := (y - heartRect.Min.Y) * stride
			copy(full[start:start+stride], layer[row:row+stride])
		}
	}
}

type deskMouse struct {
	layer    int // 1/2 are entry or release; 3 is the separate grip and mouse.
	quadrant int
	dx, dy   int // eighths of a master pixel
}
type desktopLayers struct {
	free, pointer []byte
	approach      [2][4][]byte
	wrists        [4][]byte
	rest          [5][]byte
	pointerBounds image.Rectangle
}

var deskArt *desktopLayers
var deskArea = image.Rect(0, keyPatchY, 314, masterHeight)
var accessoryArea = image.Rect(426, 300, masterWidth, 430)
var deskTarget, deskOffset direction
var deskUpdated, deskMoved time.Time

func alphaBounds(pixels []byte) image.Rectangle {
	minX, minY, maxX, maxY := masterWidth, masterHeight, 0, 0
	for y := 0; y < masterHeight; y++ {
		for x := 0; x < masterWidth; x++ {
			if pixels[4*(y*masterWidth+x)+3] > 0 {
				minX, minY, maxX, maxY = min(minX, x), min(minY, y), max(maxX, x+1), max(maxY, y+1)
			}
		}
	}
	if minX >= maxX || minY >= maxY {
		return image.Rectangle{}
	}
	return image.Rect(minX, minY, maxX, maxY)
}

func loadDesktopLayers(atlas *frameAtlas) *desktopLayers {
	// Only the mouse-side rectangle is needed for the desk and approach frames.
	tmp := make([]byte, masterWidth*masterHeight*4)
	if !atlas.copyFrame("deskFree", tmp) {
		return nil
	}
	d := &desktopLayers{free: extractRegion(tmp, deskArea)}
	d.pointer = make([]byte, len(tmp))
	if !atlas.copyFrame("pointer", d.pointer) {
		return nil
	}
	bounds := alphaBounds(d.pointer)
	if bounds.Empty() {
		return nil
	}
	d.pointerBounds = image.Rect(bounds.Min.X-13, bounds.Min.Y-9, bounds.Max.X+13, bounds.Max.Y+9).Intersect(image.Rect(0, 0, masterWidth, masterHeight))
	for stage := range d.rest {
		name := "idle0"
		if stage > 0 {
			name = fmt.Sprintf("rest%d", stage)
		}
		if !atlas.copyFrame(name, tmp) {
			return nil
		}
		d.rest[stage] = extractRegion(tmp, accessoryArea)
	}
	for i := range d.wrists {
		if !atlas.copyFrame(fmt.Sprintf("wrist%d", i), tmp) {
			return nil
		}
		d.wrists[i] = extractRegion(tmp, deskArea)
	}
	for level := 1; level <= 2; level++ {
		for q := 0; q < 4; q++ {
			if !atlas.copyFrame(fmt.Sprintf("mouse%d%d", level, q), tmp) {
				return nil
			}
			d.approach[level-1][q] = extractRegion(tmp, deskArea)
		}
	}
	return d
}

// The first waking keystroke keeps its contact and highlight. Move only the
// accessory pixels where the action still has the neutral background.
func (d *desktopLayers) recoverAccessories(full []byte, level int) {
	low := (level - 1) / 64
	weight := level - low*64
	a, b := d.rest[low], d.rest[low+1]
	row := 0
	for y := accessoryArea.Min.Y; y < accessoryArea.Max.Y; y++ {
		for x := accessoryArea.Min.X; x < accessoryArea.Max.X; x++ {
			i := 4 * (y*masterWidth + x)
			if bytes.Equal(full[i:i+4], d.rest[0][row:row+4]) {
				for c := 0; c < 4; c++ {
					full[i+c] = byte((int(a[row+c])*(64-weight) + int(b[row+c])*weight + 32) / 64)
				}
			}
			row += 4
		}
	}
}

func updateDeskMotion(now time.Time, p point) {
	if size.X == 0 || size.Y == 0 {
		return
	}
	if p != cur {
		if now.Sub(deskMoved) >= 850*time.Millisecond {
			deskTarget, deskOffset = direction{}, direction{}
		}
		dx := float64(p.X-cur.X) * logicalWidth / float64(size.X)
		dy := float64(p.Y-cur.Y) * logicalHeight / float64(size.Y)
		deskTarget.x = max(-12, min(12, deskTarget.x+.16*dx))
		deskTarget.y = max(-8, min(8, deskTarget.y+.16*dy))
		deskMoved = now
	}
	dt := now.Sub(deskUpdated).Seconds()
	if deskUpdated.IsZero() {
		dt = 1. / 60
	}
	if dt > 0 {
		deskOffset = easeDirection(deskOffset, deskTarget, dt, .065)
		deskUpdated = now
	}
}

func desktopAt(now time.Time, level int) deskMouse {
	if level == 0 {
		return deskMouse{}
	}
	d := deskMouse{layer: level, quadrant: quadrant}
	if level < 3 {
		return d
	}
	entry := int64(95)
	if bridgeToMouse {
		entry = 40
	}
	weight := max(0., min(1., float64(now.Sub(mouseStart).Milliseconds()-entry)/35, float64(690-now.Sub(mouseAt).Milliseconds())/65))
	d.dx = int(math.Round(deskOffset.x * weight * 8))
	d.dy = int(math.Round(deskOffset.y * weight * 8))
	return d
}

func (d *desktopLayers) apply(full []byte, motion deskMouse, concurrentKey bool) {
	back := d.free
	if motion.layer < 0 {
		back = d.wrists[-motion.layer-1]
	} else if motion.layer < 3 {
		back = d.approach[motion.layer-1][motion.quadrant]
	}
	for y := deskArea.Min.Y; y < deskArea.Max.Y; y++ {
		i := 4 * (y*masterWidth + deskArea.Min.X)
		row := 4 * (y - deskArea.Min.Y) * deskArea.Dx()
		if !concurrentKey {
			copy(full[i:i+deskArea.Dx()*4], back[row:row+deskArea.Dx()*4])
			continue
		}
		for x := 0; x < deskArea.Dx(); x++ {
			off := i + 4*x
			if bytes.Equal(full[off:off+4], baseFrame[off:off+4]) {
				copy(full[off:off+4], back[row+4*x:row+4*x+4])
			}
		}
	}
	if motion.layer != 3 {
		return
	}
	// Body-side attachment stays put, while the fingers and mouse share the
	// same rigid offset. Sample premultiplied sprites before source-over.
	for y := d.pointerBounds.Min.Y; y < d.pointerBounds.Max.Y; y++ {
		f := max(0., min(1., float64(y-312)/78))
		f = f * f * (3 - 2*f)
		shiftX := int(math.Round(float64(motion.dx) * 32 * f))
		shiftY := int(math.Round(float64(motion.dy) * 32 * f))
		paintSpriteRow(full, d.pointer, y, d.pointerBounds.Min.X, d.pointerBounds.Max.X, shiftX, shiftY)
	}
}

func paintSpriteRow(full, sprite []byte, y, x0, x1, shiftX, shiftY int) {
	sy := y*256 - shiftY
	top := sy >> 8
	fy := sy & 255
	for x := x0; x < x1; x++ {
		sx := x*256 - shiftX
		left := sx >> 8
		fx := sx & 255
		var sample [4]int
		for row := 0; row < 2; row++ {
			yy := top + row
			if yy < 0 || yy >= masterHeight {
				continue
			}
			wy := 256 - fy
			if row != 0 {
				wy = fy
			}
			for col := 0; col < 2; col++ {
				xx := left + col
				if xx < 0 || xx >= masterWidth {
					continue
				}
				wx := 256 - fx
				if col != 0 {
					wx = fx
				}
				w := wx * wy
				at := 4 * (yy*masterWidth + xx)
				for c := 0; c < 4; c++ {
					sample[c] += int(sprite[at+c]) * w
				}
			}
		}
		alpha := (sample[3] + 32768) >> 16
		if alpha == 0 {
			continue
		}
		dst := 4 * (y*masterWidth + x)
		for c := 0; c < 4; c++ {
			src := (sample[c] + 32768) >> 16
			full[dst+c] = byte(min(255, src+(int(full[dst+c])*(255-alpha)+127)/255))
		}
	}
}

func selectCharacter(index int) bool {
	atlas := loadAtlas(index)
	if atlas == nil {
		return false
	}
	role := characters[index].id
	prefix := map[string]string{"blue": "rice", "amber": "book", "frost": "toss"}[role]
	for i := 1; i <= 4; i++ {
		if atlas.frames[fmt.Sprintf("%s%d", prefix, i)].height != masterHeight {
			return false
		}
	}
	idle := make([]byte, 4*masterWidth*masterHeight)
	if !atlas.copyFrame("idle0", idle) {
		return false
	}
	rig := loadGazeRig(index)
	if rig == nil {
		return false
	}
	moodCount := 3
	if role == "blue" {
		moodCount = 6
	}
	parts := loadExpressionLayers(atlas, moodCount)
	if parts == nil {
		return false
	}
	desk := loadDesktopLayers(atlas)
	if desk == nil {
		return false
	}
	var toy *toyLayer
	if role == "frost" {
		toy = &toyLayer{pixels: make([]byte, len(idle))}
		if !atlas.copyFrame("toy", toy.pixels) {
			return false
		}
		toy.bounds = alphaBounds(toy.pixels)
		if toy.bounds.Empty() {
			return false
		}
		toy.desk = make([]byte, len(idle))
		if !atlas.copyFrame("tossDesk", toy.desk) {
			return false
		}
		tmp := make([]byte, len(idle))
		for _, i := range []int{1, 2, 4} {
			if !atlas.copyFrame(fmt.Sprintf("tossArm%d", i), tmp) {
				return false
			}
			bounds := alphaBounds(tmp)
			if bounds.Empty() {
				return false
			}
			toy.arms[i] = armSprite{extractRegion(tmp, bounds), bounds}
		}
	}
	toyArt = toy
	character, activeAtlas, activeRig, baseFrame, layers, deskArt = index, atlas, rig, idle, parts, desk
	smileAt, patAt, resumeAt = time.Time{}, time.Time{}, time.Time{}
	stroke = headStroke{}
	clearFrameCache()
	paint(scene{hand: "idle0"})
	return true
}

var currentGazeMask []bool

func masterFrame(view scene) []byte {
	view.toy = toyPose{} // the independent plush stays in front of the warped face
	if view == currentMasterName && currentMaster != nil {
		return currentMaster
	}
	name := view.hand
	source := baseFrame
	if view.armTween > 0 {
		source = bytes.Clone(toyArt.desk)
		toyArt.tweenArms(source, name, view.armTween)
	} else if name != "idle0" {
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
	if name == "idle0" && (view.face != (expression{}) || view.desk.layer != 0 || view.zzz > 0 || view.wakeRest > 0 || view.mood.number > 0) {
		source = bytes.Clone(baseFrame)
	}
	if view.desk.layer != 0 {
		deskArt.apply(source, view.desk, strings.HasPrefix(name, "key"))
	}
	if view.wakeRest > 0 {
		deskArt.recoverAccessories(source, view.wakeRest)
	}
	if strings.HasPrefix(name, "book") || strings.HasPrefix(name, "toss") {
		r := activeRig
		if len(currentGazeMask) != r.w*r.h {
			currentGazeMask = make([]bool, r.w*r.h)
		}
		for y := 0; y < r.h; y++ {
			for x := 0; x < r.w; x++ {
				i := 4 * ((r.y+y)*masterWidth + r.x + x)
				currentGazeMask[y*r.w+x] = bytes.Equal(source[i:i+4], baseFrame[i:i+4])
			}
		}
	}
	if view.mood.number > 0 {
		layers.applyMood(source, view.mood, !strings.HasPrefix(name, "idle"))
	}
	if view.face != (expression{}) {
		layers.apply(source, view.face)
	}
	if view.zzz > 0 {
		drawSleepingLetters(source, view.zzz)
	}
	currentMasterName, currentMaster = view, source
	return source
}

func framePixels(name scene) []byte {
	if pixels, ok := frameCache[name]; ok {
		return pixels
	}
	source := masterFrame(name)
	if source == nil {
		return nil
	}
	if name.toy.visible {
		source = bytes.Clone(source)
		toyArt.draw(source, name.toy)
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

func (s *gazeState) poseAt(view scene, now time.Time) gazePose {
	if strings.HasPrefix(view.hand, "rice") {
		return gazePose{} // bowl, chopsticks, face and gaze share one painted pose
	}
	head, eyes := posture(now, s.head, s.eyes)
	if strings.HasPrefix(view.hand, "book") {
		sweep := math.Sin(2 * math.Pi * float64(idleSince(now).Milliseconds()-45000) / 1600)
		head, eyes = direction{.04 * sweep, .12}, direction{.14 * sweep, .35}
	}
	if view.toy.visible {
		u := max(-1., min(1., float64(view.toy.x-300)/175))
		v := max(-1., min(1., float64(view.toy.y-160)/130))
		head, eyes = direction{.14 * u, .14 * v}, direction{.38 * u, .45 * v}
	}
	if (strings.HasPrefix(view.hand, "book") && view.mood.number == 2) || (view.toy.visible && view.mood.number == 3) {
		eyes = direction{} // smiling crescent lids have no visible iris
	}
	q := func(v float64) int { return int(math.Round(v * 64)) }
	p := gazePose{headX: q(head.x), headY: q(head.y)}
	amount := view.face.amount
	eyeWeight := float64(192-2*amount) / 192
	if amount > 64 {
		eyeWeight = float64(128-amount) / 192
	}
	if view.mood.weight > 0 && strings.HasPrefix(view.hand, "idle") {
		// The painted eyes already contain the direction and lid shape.
		eyeWeight *= float64(64-view.mood.weight) / 64
	}
	p.eyeX = int(math.Round(float64(q(eyes.x)) * eyeWeight))
	p.eyeY = int(math.Round(float64(q(eyes.y)) * eyeWeight))
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

func (r *gazeRig) warp(src, dst []byte, pose gazePose, allowed []bool) {
	for row := 0; row < r.h; row++ {
		y := r.y + row
		for col := 0; col < r.w; col++ {
			if allowed != nil && !allowed[row*r.w+col] {
				continue
			}
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
	frame              scene
	master, horizontal []byte
	hobby              scene
	neutral            []byte
}

// A book, raised hand or sleeve that crosses the gaze region must keep its
// painted silhouette. The inverse sampler reads the prop-free neutral face.
func (work *gazeWork) hobbySource(view scene) []byte {
	key := scene{hand: view.hand, mood: view.mood}
	if work.hobby != key {
		if len(work.neutral) != len(baseFrame) {
			work.neutral = make([]byte, len(baseFrame))
		}
		copy(work.neutral, baseFrame)
		if view.mood.number > 0 {
			layers.applyMood(work.neutral, view.mood, false)
		}
		work.hobby = key
	}
	return work.neutral
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

func (work *gazeWork) render(dst []byte, name scene, pose gazePose) {
	r := activeRig
	if r == nil || pose == (gazePose{}) {
		return
	}
	source := masterFrame(name)
	if source == nil {
		return
	}
	if work.frame != name || name.toy.visible {
		if len(work.master) != len(source) {
			work.master = make([]byte, len(source))
		}
		copy(work.master, source)
		work.frame = name
	}
	var allowed []bool
	if name.toy.visible || strings.HasPrefix(name.hand, "book") {
		source, allowed = work.hobbySource(name), currentGazeMask
	}
	r.warp(source, work.master, pose, allowed)
	if name.toy.visible {
		toyArt.draw(work.master, name.toy)
	}
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

func paint(name scene) {
	now := time.Now()
	pose := gaze.poseAt(name, now)
	if bits == nil || baseFrame == nil || (name == last && pose == lastPose) {
		return
	}
	pixels := framePixels(name)
	if pixels == nil {
		name = scene{hand: "idle0"}
		pose = gaze.poseAt(name, now)
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
	case age < 18:
		return 1
	case age < 42:
		return 2
	case age < 100:
		return 3
	case age < 150:
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
	case sinceMove > 770:
		return 1
	case sinceMove > 690:
		return 2
	case reach < 40:
		return 1
	case reach < 95:
		return 2
	default:
		return 3
	}
}

type keyMotion int

const (
	standaloneKey keyMotion = iota
	rapidKey
	fromMouseKey
)

var keyMode keyMotion
var mouseRequested, bridgeToMouse, returningToMouse bool
var startWrist, contactMS int
var contactTimer *time.Timer
var contactTicket uintptr
var patAt, resumeAt time.Time
var resumeAmount int

func keyDuration() int64 {
	switch keyMode {
	case rapidKey:
		return 150
	case fromMouseKey:
		return 205
	default:
		return 220
	}
}
func contactBeforeMouse() int64 {
	switch keyMode {
	case rapidKey:
		return 45
	case fromMouseKey:
		return 85
	default:
		return 90
	}
}
func typingHand(age int64) string {
	var phase int
	switch keyMode {
	case rapidKey:
		switch {
		case age < int64(contactMS):
			phase = 3
		case age < 95:
			phase = 4
		default:
			phase = 5
		}
	case fromMouseKey:
		switch {
		case age < 35:
			return fmt.Sprintf("wrist%d", startWrist+int(age)*(4-startWrist)/35)
		case age < 44:
			phase = 2
		case age < 105:
			phase = 3
		case age < 150:
			phase = 4
		default:
			phase = 5
		}
	default:
		phase = keyStage(age)
	}
	return fmt.Sprintf("key%d-%d", symbol, phase)
}
func keyboardLeft(v int) bool {
	return v == 32 || strings.ContainsRune("12345QWERTASDFGZXCVB", rune(v))
}

func recordMouse(now time.Time) {
	if returningToMouse && !now.Before(mouseStart) {
		returningToMouse = false
	}
	if returningToMouse || !mouseRequested || now.Sub(mouseAt) >= 850*time.Millisecond {
		returningToMouse = false
		mouseStart = now
		bridgeToMouse = !keyboardLeft(symbol) && !keyAt.IsZero() && now.Sub(keyAt).Milliseconds() < keyDuration()
		if bridgeToMouse {
			earliest := keyAt.Add(time.Duration(contactBeforeMouse()) * time.Millisecond)
			if mouseStart.Before(earliest) {
				mouseStart = earliest
			}
		}
	}
	mouseAt, mouseRequested = now, true
}

func mouseHand(now time.Time) string {
	mouseAge := now.Sub(mouseAt).Milliseconds()
	if mouseRequested && !now.Before(mouseStart) && mouseAge < 850 {
		reach := now.Sub(mouseStart).Milliseconds()
		if bridgeToMouse {
			if reach < 40 {
				return fmt.Sprintf("wrist%d", 3-reach/10)
			}
			reach = 95 // the wrist has already arrived at the mouse
		}
		return fmt.Sprintf("mouse%d%d", mouseStage(reach, mouseAge), quadrant)
	}
	return ""
}

func handFrame(now time.Time) string {
	if age := now.Sub(keyAt).Milliseconds(); keyboardLeft(symbol) && !keyAt.IsZero() && age < keyDuration() {
		return typingHand(age)
	}
	if m := mouseHand(now); m != "" {
		return m
	}
	if age := now.Sub(keyAt).Milliseconds(); !keyAt.IsZero() && age < keyDuration() {
		return typingHand(age)
	}
	return fmt.Sprintf("idle%d", now.Sub(started).Milliseconds()/240%7)
}

func beginKey(v int, now time.Time) {
	previous := handFrame(now)
	gap := now.Sub(keyAt).Milliseconds()
	grip := mouseHand(now)
	onMouse := strings.HasPrefix(grip, "mouse")
	onWrist := mouseRequested && bridgeToMouse && !now.Before(mouseStart) && strings.HasPrefix(previous, "wrist")
	leavingConcurrentGrip := !keyboardLeft(v) && keyboardLeft(symbol) && (onMouse || onWrist)
	contactMS = 45
	switch {
	case !keyAt.IsZero() && gap <= 150 && !leavingConcurrentGrip:
		keyMode = rapidKey
		if v == symbol && gap < 45 {
			contactMS = max(12, int(gap/2))
		}
	case !keyboardLeft(v) && onMouse:
		keyMode = fromMouseKey
		switch grip[5] {
		case '1':
			startWrist = 3
		case '2':
			startWrist = 1
		default:
			startWrist = 0
		}
	case !keyboardLeft(v) && onWrist:
		keyMode = fromMouseKey
		startWrist = int(previous[5] - '0')
	default:
		keyMode = standaloneKey
	}
	keyAt, symbol = now, v
	if !keyboardLeft(v) {
		// The right hand returns to a recently used mouse when this keystroke
		// finishes. This animation does not extend the last physical movement.
		returningToMouse = mouseRequested && now.Sub(mouseAt) < 850*time.Millisecond
		mouseRequested, bridgeToMouse = returningToMouse, returningToMouse
		mouseStart = now.Add(time.Duration(keyDuration()) * time.Millisecond)
	}
}

func mixAmount(a, b int, elapsed, duration int64) int {
	t := int(max(0, min(duration, elapsed)))
	return (a*(int(duration)-t) + b*t + int(duration/2)) / int(duration)
}
func smileAmount(now time.Time) int {
	age, quiet := now.Sub(smileAt).Milliseconds(), now.Sub(patAt).Milliseconds()
	switch {
	case quiet >= 900:
		return 0
	case quiet >= 815:
		return mixAmount(64, 0, quiet-815, 85)
	case quiet >= 735:
		return 64
	case quiet >= 680:
		return mixAmount(128, 64, quiet-680, 55)
	case !resumeAt.IsZero() && now.Sub(resumeAt) < 80*time.Millisecond:
		return mixAmount(resumeAmount, 128, now.Sub(resumeAt).Milliseconds(), 80)
	case age < 45:
		return mixAmount(0, 64, age, 45)
	case age < 100:
		return 64
	case age < 160:
		return mixAmount(64, 128, age-100, 60)
	default:
		return 128
	}
}
func faceAt(now time.Time) expression {
	age, quiet := now.Sub(smileAt).Milliseconds(), now.Sub(patAt).Milliseconds()
	if !patAt.IsZero() && quiet < 900 {
		heart := 1
		switch {
		case age < 100:
			heart = 1
		case age < 220:
			heart = 2
		case quiet < 500:
			heart = 3 + int((age-220)/180%2)
		case quiet < 680:
			heart = 5
		default:
			heart = 6
		}
		return expression{smile: true, amount: smileAmount(now), heart: heart}
	}
	age = now.Sub(started).Milliseconds()
	if age < 4700 {
		return expression{}
	}
	t := age % 4700
	var amount int
	switch {
	case t < 32:
		amount = mixAmount(0, 64, t, 32)
	case t < 55:
		amount = 64
	case t < 78:
		amount = mixAmount(64, 128, t-55, 23)
	case t < 110:
		amount = 128
	case t < 135:
		amount = mixAmount(128, 64, t-110, 25)
	case t < 150:
		amount = 64
	case t < 185:
		amount = mixAmount(64, 0, t-150, 35)
	}
	return expression{amount: amount}
}

type restState struct {
	drowsy, asleep float64
	drop           float64
	level          int
}

var lastActivity, wakeAt time.Time
var wakeLevel, wakeStage int
var wakeDrop, wakeDrowsy float64
var wakingFromSleep bool
var pressTime, nuzzleAt, nuzzleReleased time.Time
var nuzzleEndWeight float64
var nuzzleCursor direction
var lastInputStamp uint32
var haveInputStamp bool

func clampUnit(v float64) float64 { return max(0., min(1., v)) }

func idleSince(now time.Time) time.Duration {
	if lastActivity.IsZero() {
		return now.Sub(started)
	}
	return now.Sub(lastActivity)
}

const drowsyAt int64 = 57000

func ricePose(idleMS int64) string {
	if idleMS < 45000 || idleMS >= 56550 {
		return ""
	}
	for _, beat := range [...]struct {
		until int64
		pose  string
	}{
		{47400, "rice1"}, {48550, "rice2"}, {49400, "rice3"}, {50500, "rice4"},
		{51200, "rice3"}, {52250, "rice2"}, {53100, "rice3"}, {54500, "rice4"},
		{55200, "rice3"}, {55950, "rice2"}, {56550, "rice1"},
	} {
		if idleMS < beat.until {
			return beat.pose
		}
	}
	return ""
}

func bookPose(idle int64) string {
	switch {
	case idle < 46300:
		return "book1"
	case idle < 48700:
		return "book2"
	case idle < 49500:
		return "book3"
	case idle < 52300:
		return "book2"
	case idle < 53100:
		return "book3"
	case idle < 55600:
		return "book2"
	default:
		return "book4"
	}
}

// Master-pixel centers are measured at the drawn palm. The quadratic
// flight clears the head to its right and returns to the receiving palm.
func tossScene(idle int64) (string, toyPose, int) {
	x, y := 433., 247.
	weight := 0
	name := "toss1"
	if idle >= 46200 && idle < 55200 {
		age := (idle - 46200) % 3000
		switch {
		case age < 380:
		case age < 620:
			name = "toss2"
		case age < 1550:
			name = "toss3"
		case age < 1940:
			name = "toss4"
		}
		switch {
		case age < 380:
			t := float64(age) / 380
			t = t * t * (3 - 2*t)
			weight = int(math.Round(256 * t))
			x, y = palmCenter(1, 2, weight)
		case age < 1670:
			t := float64(age-380) / 1290
			a := 1 - t
			x = a*a*436 + 2*a*t*501.5 + t*t*437
			y = a*a*207 - 2*a*t*39 + t*t*291
		case age < 1940:
			t := float64(age-1670) / 270
			t = t * t * (3 - 2*t)
			weight = int(math.Round(256 * t))
			x, y = palmCenter(4, 1, weight)
		}
	}
	return name, toyPose{true, int(math.Round(x)), int(math.Round(y))}, weight
}

type moodBeat struct {
	start, end int64
	number     int
}

var moodRandom = rand.New(rand.NewSource(time.Now().UnixNano()))
var quietMoods struct {
	started                       time.Time
	beats                         []moodBeat
	role, anticipation, enjoyment int
	lastShown                     [3]int
}

// Plan once per quiet spell. Refreshes and contact-frame prewarming must not
// reroll a face while a pose is on screen or a bite is in progress.
func activityMood(idle int64, hobby string) moodLayer {
	if idle < 4000 {
		return moodLayer{}
	}
	since := lastActivity
	if since.IsZero() {
		since = started
	}
	if quietMoods.started != since || quietMoods.role != character {
		quietMoods.started, quietMoods.role = since, character
		quietMoods.beats = quietMoods.beats[:0]
		previous := quietMoods.lastShown[character]
		count := 3
		if characters[character].id == "blue" {
			count = 5
		}
		var end int64
		for {
			start := end + 4000 + int64(moodRandom.Intn(4001))
			if start >= 45000 {
				break
			}
			end = start + 1200 + int64(moodRandom.Intn(801))
			if end > 45000 {
				break
			}
			var kind int
			if previous == 0 {
				kind = 1 + moodRandom.Intn(count)
			} else {
				kind = 1 + (previous+moodRandom.Intn(count-1))%count
			}
			quietMoods.beats = append(quietMoods.beats, moodBeat{start, end, kind})
			previous = kind
		}
		quietMoods.anticipation, quietMoods.enjoyment = moodRandom.Intn(2), moodRandom.Intn(2)
	}
	if hobby != "" {
		switch hobby {
		case "book1", "book2":
			if idle >= 51000 {
				return moodLayer{2, 64}
			}
			return moodLayer{1, 64}
		case "book3", "toss4":
			return moodLayer{3, 64}
		case "book4":
			return moodLayer{2, 64}
		case "toss1":
			return moodLayer{1, 64}
		case "toss2", "toss3":
			return moodLayer{2, 64}
		}
		pair := [2]int{1, 5}
		choice := quietMoods.anticipation
		switch hobby {
		case "rice4":
			pair, choice = [2]int{4, 6}, quietMoods.enjoyment
		case "rice3":
			return moodLayer{}
		}
		if idle >= 50500 {
			choice = 1 - choice
		}
		return moodLayer{pair[choice], 64}
	}
	for _, beat := range quietMoods.beats {
		if idle < beat.start {
			break
		}
		if idle < beat.end {
			weight := mixAmount(0, 64, min(idle-beat.start, beat.end-idle), 150)
			if weight > 0 {
				quietMoods.lastShown[character] = beat.number
				return moodLayer{beat.number, weight}
			}
		}
	}
	return moodLayer{}
}

func resting(now time.Time) restState {
	if !nuzzleAt.IsZero() && nuzzleReleased.IsZero() {
		return restState{}
	}
	idle := idleSince(now).Milliseconds()
	d := clampUnit(float64(idle-drowsyAt) / float64(60000-drowsyAt))
	sleep := clampUnit(float64(idle-60000) / 600)
	r := restState{drowsy: d, asleep: sleep, level: int(math.Round(64*d + 64*sleep))}
	r.drop = .65*d + .07*sleep*math.Sin(2*math.Pi*float64(idle-60000)/3200)
	return r
}
func userActivity(now time.Time) {
	if !lastActivity.IsZero() && now.Before(lastActivity) {
		return
	}
	r := resting(now)
	idle := idleSince(now).Milliseconds()
	if idle >= drowsyAt && (nuzzleAt.IsZero() || !nuzzleReleased.IsZero()) {
		wakeAt, wakeDrop, wakeLevel, wakeDrowsy = now, r.drop, r.level, r.drowsy
		wakeStage = 0
		if characters[character].id != "blue" {
			wakeStage = restStage(idle)
		}
		wakingFromSleep = idle >= 60000
	}
	lastActivity = now
}
func wakeGain(now time.Time) float64 {
	if wakeAt.IsZero() {
		return 0
	}
	return clampUnit(1 - now.Sub(wakeAt).Seconds()/.18)
}

func restStage(idleMS int64) int { return min(4, 1+int(idleMS-drowsyAt)/750) }
func awakeShake(now time.Time) float64 {
	if !wakingFromSleep || wakeAt.IsZero() {
		return 0
	}
	t := now.Sub(wakeAt).Seconds() / .48
	if t < 0 || t >= 1 {
		return 0
	}
	return .55 * math.Sin(4*math.Pi*t) * (1 - t)
}

func headPoint(p point) direction {
	x, y := logicalPoint(p)
	return direction{(x - 150) / 43, (y - 77) / 52}
}
func insideHead(p point, radius float64) bool {
	if size.X <= 0 || size.Y <= 0 {
		return false
	}
	v := headPoint(p)
	return v.x*v.x+v.y*v.y <= radius*radius
}
func nuzzleWeight(now time.Time) float64 {
	if nuzzleAt.IsZero() {
		return 0
	}
	if !nuzzleReleased.IsZero() {
		return nuzzleEndWeight * clampUnit(1-now.Sub(nuzzleReleased).Seconds()/.22)
	}
	return clampUnit(now.Sub(nuzzleAt).Seconds() / .18)
}
func advanceHold(now time.Time, p point) {
	if !buttonDown || !pressedOnHead || dragging {
		return
	}
	if nuzzleAt.IsZero() || !nuzzleReleased.IsZero() {
		if now.Sub(pressTime) < 350*time.Millisecond || crossedDragThreshold(p) || !insideHead(p, 1) {
			return
		}
		userActivity(now)
		nuzzleAt = pressTime.Add(350 * time.Millisecond)
		nuzzleReleased = time.Time{}
		smileAt, patAt, resumeAt = time.Time{}, time.Time{}, time.Time{}
	}
	v := headPoint(p)
	nuzzleCursor = direction{max(-1, min(1, v.x)), max(-1, min(1, v.y))}
}
func releaseNuzzle(now time.Time) bool {
	if nuzzleAt.IsZero() || !nuzzleReleased.IsZero() {
		return false
	}
	nuzzleEndWeight = nuzzleWeight(now)
	nuzzleReleased = now
	// The entire hold was interaction, even with a stationary pointer.
	lastActivity = now
	return true
}

func faceDuringActivity(now time.Time) expression {
	if !nuzzleAt.IsZero() {
		age := now.Sub(nuzzleAt).Milliseconds()
		rel := now.Sub(nuzzleReleased).Milliseconds()
		if nuzzleReleased.IsZero() || rel < 220 {
			h := 1
			switch {
			case !nuzzleReleased.IsZero():
				if rel < 110 {
					h = 5
				} else {
					h = 6
				}
			case age < 100:
				h = 1
			case age < 220:
				h = 2
			default:
				h = 3 + int((age-220)/180%2)
			}
			return expression{smile: true, heart: h, amount: int(math.Round(84 * nuzzleWeight(now)))}
		}
	}
	f := faceAt(now)
	if f.smile {
		return f
	}
	r := resting(now)
	if idleSince(now).Milliseconds() >= drowsyAt {
		return expression{amount: r.level}
	}
	if wg := wakeGain(now); wg > 0 {
		return expression{amount: int(math.Round(float64(wakeLevel) * wg))}
	}
	return f
}

func posture(now time.Time, head, eyes direction) (direction, direction) {
	r := resting(now)
	gain := 1 - r.drowsy - wakeDrowsy*wakeGain(now)
	head.x *= gain
	head.y = head.y*gain + r.drop + wakeDrop*wakeGain(now)
	head.x += awakeShake(now)
	eyes.x *= gain
	eyes.y *= gain
	if weight := nuzzleWeight(now); weight > 0 {
		t := 2 * math.Pi * now.Sub(nuzzleAt).Seconds() / .9
		hx := .65*nuzzleCursor.x + .12*math.Sin(t)
		hy := .45*nuzzleCursor.y + .08*(math.Cos(t)-1)
		head.x = head.x*(1-weight) + hx*weight
		head.y = head.y*(1-weight) + hy*weight
		eyes.x *= 1 - weight
		eyes.y *= 1 - weight
	}
	head.x = max(-1, min(1, head.x))
	head.y = max(-1, min(1, head.y))
	return head, eyes
}

// GetLastInputInfo also observes clicks, scrolling and unmapped keys outside
// the pet, including input that does not change the global cursor position.
func observeSessionInput(now time.Time) {
	info := struct{ size, stamp uint32 }{size: 8}
	if call(u, "GetLastInputInfo", uintptr(unsafe.Pointer(&info))) == 0 {
		return
	}
	if haveInputStamp && info.stamp != lastInputStamp {
		userActivity(now)
	}
	lastInputStamp, haveInputStamp = info.stamp, true
}

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
				dx := float64(px) + .5 - x
				dy := float64(py) + .5 - y
				n := max(0., min(w, dx))
				diag := max(0., min(w, (w-dx+dy)*.5))
				dist := min(math.Hypot(dx-n, dy), math.Hypot(dx-n, dy-w), math.Hypot(dx-(w-diag), dy-diag))
				edge := clampUnit(2.7 - dist)
				if edge == 0 {
					continue
				}
				ink := clampUnit(1.65 - dist)
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

func animationFrame(now time.Time) scene {
	hand := handFrame(now)
	v := scene{hand: hand, face: faceDuringActivity(now)}
	m := mouseHand(now)
	if strings.HasPrefix(hand, "mouse") && hand[5] == '3' {
		v.hand = "idle0"
		v.desk = desktopAt(now, 3)
	} else if strings.HasPrefix(hand, "key") && keyboardLeft(symbol) && m != "" {
		if strings.HasPrefix(m, "mouse") {
			v.desk = desktopAt(now, int(m[5]-'0'))
		} else {
			v.desk = deskMouse{layer: -1 - int(m[5]-'0')}
		}
	}
	idle := idleSince(now).Milliseconds()
	restingHands := strings.HasPrefix(v.hand, "idle") && v.desk.layer == 0 && (nuzzleAt.IsZero() || !nuzzleReleased.IsZero())
	if restingHands && idle >= 45000 {
		if idle < 56550 {
			var hobby scene
			switch characters[character].id {
			case "blue":
				hobby.hand = ricePose(idle)
			case "amber":
				hobby.hand = bookPose(idle)
			case "frost":
				hobby.hand, hobby.toy, hobby.armTween = tossScene(idle)
			}
			hobby.mood = activityMood(idle, hobby.hand)
			return hobby
		}
		v.hand = "idle0"
		if characters[character].id != "blue" && idle >= drowsyAt {
			v.hand = fmt.Sprintf("rest%d", restStage(idle))
		}
		if idle >= 60000 {
			v.zzz = 1 + int((idle-60000)/80%25)
		}
	}
	if restingHands && !buttonDown && idle < 45000 && v.face == (expression{}) {
		v.mood = activityMood(idle, "")
	}
	if !wakeAt.IsZero() && now.Sub(wakeAt) < 300*time.Millisecond {
		v.wakeRest = int(math.Round(float64(64*wakeStage) * clampUnit(1-now.Sub(wakeAt).Seconds()/.3)))
	}
	return v
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

func onHead(p point) bool { return insideHead(p, 1) }

type headStroke struct {
	since, lastMove                    time.Time
	startX, startY, extreme, direction float64
	horizontal                         bool
}

var stroke headStroke

func startSmile(now time.Time) {
	quiet := now.Sub(patAt)
	switch {
	case patAt.IsZero() || quiet >= 900*time.Millisecond:
		smileAt = now
		resumeAt = time.Time{}
	case quiet >= 680*time.Millisecond:
		resumeAmount = smileAmount(now)
		resumeAt = now
	}
	patAt = now
}

func strokeHead(p point, now time.Time) {
	if !onHead(p) {
		stroke = headStroke{}
		return
	}
	x, y := logicalPoint(p)
	if stroke.since.IsZero() || now.Sub(stroke.lastMove) > 350*time.Millisecond || now.Sub(stroke.since) > 900*time.Millisecond {
		stroke = headStroke{since: now, lastMove: now, startX: x, startY: y}
		return
	}
	stroke.lastMove = now
	if stroke.direction == 0 {
		dx, dy := x-stroke.startX, y-stroke.startY
		if max(math.Abs(dx), math.Abs(dy)) < 7 {
			return
		}
		stroke.horizontal = math.Abs(dx) >= math.Abs(dy)
		delta, pos := dy, y
		if stroke.horizontal {
			delta, pos = dx, x
		}
		stroke.direction, stroke.extreme = math.Copysign(1, delta), pos
		return
	}
	pos := y
	if stroke.horizontal {
		pos = x
	}
	progress := (pos - stroke.extreme) * stroke.direction
	if progress > 0 {
		stroke.extreme = pos
	} else if progress <= -7 {
		startSmile(now)
		stroke.since, stroke.extreme, stroke.direction = now, pos, -stroke.direction
	}
}

func crossedDragThreshold(p point) bool {
	dx, dy := p.X-pressAt.X, p.Y-pressAt.Y
	return float64(dx)*float64(dx)+float64(dy)*float64(dy) > float64(dragThreshold.X)*float64(dragThreshold.X)
}

func cursorPosition() point {
	var p point
	call(u, "GetCursorPos", uintptr(unsafe.Pointer(&p)))
	return p
}

func sampleCursor(now time.Time) {
	p := cursorPosition()
	observeSessionInput(now)
	advanceHold(now, p)
	updateDeskMotion(now, p)
	gaze.advance(now, gazeTarget(p, xy, size))
	if p != cur {
		userActivity(now)
		if !dragging && !buttonDown && !menuOpen {
			strokeHead(p, now)
			recordMouse(now)
		}
		cur = p
	}
	quadrant = mouseQuadrant(p)
}

func tick() {
	now := time.Now()
	sampleCursor(now)
	paint(animationFrame(now))
}

// WM_TIMER is generated only when the message queue has no higher-priority
// work. Give initial contact its own posted notification during fast input.
func cancelContact() {
	contactTicket++
	if contactTimer != nil {
		contactTimer.Stop()
		contactTimer = nil
	}
}

func scheduleContact(due time.Time) {
	window, ticket := hwnd, contactTicket
	contactTimer = time.AfterFunc(time.Until(due), func() {
		postWindowMessage.Call(window, contactMessage, ticket, 0)
	})
}

func keyEventStart(now time.Time, queued, current uint32) time.Time {
	// Both Win32 clocks wrap every 2^32 ms. Bound latency so a delayed message
	// does not jump directly to the release pose when the queue recovers.
	delay := min(int32(25), max(int32(0), int32(current-queued)))
	start := now.Add(-time.Duration(delay) * time.Millisecond)
	if start.Before(keyAt) {
		return keyAt
	}
	return start
}

func input(l uintptr) {
	var data [64]byte
	sz := uint32(len(data))
	n := call(u, "GetRawInputData", l, 0x10000003, uintptr(unsafe.Pointer(&data[0])), uintptr(unsafe.Pointer(&sz)), 24)
	if n < 40 || n > 64 || data[0] != 1 || data[26]&1 != 0 {
		return
	}
	userActivity(time.Now())
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
	now := time.Now()
	start := keyEventStart(now, uint32(call(u, "GetMessageTime")), uint32(call(k, "GetTickCount")))
	cancelContact()
	sampleCursor(now)
	beginKey(v, start)
	var due time.Time
	if keyMode != rapidKey {
		offset := 42 * time.Millisecond
		if keyMode == fromMouseKey {
			offset = 44 * time.Millisecond
		}
		due = start.Add(offset)
		scheduleContact(due)
	}
	paint(animationFrame(time.Now()))
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
	if !due.IsZero() && time.Until(due) > 10*time.Millisecond {
		// Prepare the expensive scaled contact pixels once, ahead of presentation.
		framePixels(animationFrame(due))
	}
}
func proc(h, m, w, l uintptr) uintptr {
	if taskbarCreated != 0 && m == taskbarCreated && tray.Window != 0 {
		addTrayIcon() // Explorer recreates the notification area when it restarts.
		return 0
	}
	switch m {
	case contactMessage:
		if w == contactTicket && contactTimer != nil {
			contactTimer = nil
			tick()
		}
		return 0
	case 0xff:
		input(l)
	case 0x113:
		tick()
		return 0
	case 0x201: // WM_LBUTTONDOWN
		pressTime = time.Now()
		userActivity(pressTime)
		buttonDown = true
		pressAt = cursorPosition()
		pressedOnHead = onHead(pressAt)
		stroke = headStroke{}
		dpi := call(u, "GetDpiForWindow", h)
		if dpi == 0 {
			dpi = 96
		}
		threshold := max(1, int32(math.Round(3*float64(dpi)/96)))
		dragThreshold = point{threshold, threshold}
		call(u, "SetCapture", h)
		if call(u, "GetCapture") != h {
			buttonDown, pressedOnHead = false, false
		}
		return 0
	case 0x200: // WM_MOUSEMOVE, while captured
		if buttonDown {
			p := cursorPosition()
			now := time.Now()
			advanceHold(now, p)
			holding := !nuzzleAt.IsZero() && nuzzleReleased.IsZero()
			if holding && insideHead(p, 1.15) {
				return 0
			}
			if holding || crossedDragThreshold(p) {
				releaseNuzzle(now)
				pressedOnHead = false
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
			now := time.Now()
			p := cursorPosition()
			advanceHold(now, p)
			held := releaseNuzzle(now)
			click := !held && pressedOnHead && !crossedDragThreshold(p) && onHead(p)
			buttonDown, pressedOnHead = false, false
			userActivity(now)
			call(u, "ReleaseCapture")
			if click {
				startSmile(now)
			}
			paint(animationFrame(now))
		}
		return 0
	case 0x1f, 0x215: // WM_CANCELMODE or WM_CAPTURECHANGED
		if buttonDown || pressedOnHead {
			now := time.Now()
			releaseNuzzle(now)
			buttonDown, pressedOnHead = false, false
			paint(animationFrame(now))
		}
		if m == 0x1f {
			return call(u, "DefWindowProcW", h, m, w, l)
		}
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
	case 0x205, trayMessage:
		p := cursorPosition()
		if m == trayMessage {
			switch uint16(l) {
			case 0x7b: // WM_CONTEXTMENU may be requested by keyboard.
				id := notifyIconIdentifier{Window: h, ID: tray.ID}
				id.Size = uint32(unsafe.Sizeof(id))
				var bounds rect
				if call(shell, "Shell_NotifyIconGetRect", uintptr(unsafe.Pointer(&id)), uintptr(unsafe.Pointer(&bounds))) == 0 {
					p = point{bounds.left, bounds.bottom}
				}
			case 0x400, 0x401: // NIN_SELECT, NIN_KEYSELECT
				anchor := point{int32(int16(w)), int32(int16(w >> 16))}
				if anchor != (point{-1, -1}) {
					p = anchor
				}
			case 0x202, 0x205: // Legacy Shell callback if NIM_SETVERSION failed.
				if l>>16 != 0 { // Version 4 also emits a separate activation or context notification.
					return 0
				}
			default:
				return 0
			}
		}
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
		registered, readErr := registeredStartup()
		command, pathErr := startupCommand()
		startsAtLogin := registered != "" && strings.EqualFold(registered, command)
		startupLabel := "登录时启动"
		var startupFlag uintptr
		switch {
		case readErr != nil || pathErr != nil:
			startupLabel += "（无法读取）"
			startupFlag = 1
		case startsAtLogin:
			startupFlag = 8
		case registered != "":
			startupLabel += "（改用当前程序）"
		}
		call(u, "AppendMenuW", menu, startupFlag, 3, uintptr(unsafe.Pointer(str(startupLabel))))
		call(u, "AppendMenuW", menu, 0, 2, uintptr(unsafe.Pointer(str("退出三色桌宠"))))
		call(u, "SetForegroundWindow", h)
		menuOpen = true
		cmd := call(u, "TrackPopupMenu", menu, 0x102, uintptr(p.X), uintptr(p.Y), 0, h, 0)
		menuOpen = false
		call(u, "DestroyMenu", menu)
		call(u, "PostMessageW", h, 0, 0, 0) // Let the Shell dismiss the tracking menu.
		if m == trayMessage {
			call(shell, "Shell_NotifyIconW", 3, uintptr(unsafe.Pointer(&tray))) // NIM_SETFOCUS
		}
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
		case cmd == 3 && readErr == nil && pathErr == nil:
			if err := configureStartup(!startsAtLogin); err != nil {
				call(u, "MessageBoxW", h, uintptr(unsafe.Pointer(str(err.Error()))), uintptr(unsafe.Pointer(str("三色桌宠"))), 0x30)
			}
		case cmd == 2:
			call(u, "DestroyWindow", h)
		}
		return 0
	case 2:
		cancelContact()
		if tray.Window != 0 {
			call(shell, "Shell_NotifyIconW", 2, uintptr(unsafe.Pointer(&tray))) // NIM_DELETE
			tray.Window = 0
		}
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
	// Load group icon resource #1 at the system's window and notification sizes.
	c.Icon = call(u, "LoadImageW", inst, 1, 1, call(u, "GetSystemMetrics", 11), call(u, "GetSystemMetrics", 12), 0x8000)
	c.Small = call(u, "LoadImageW", inst, 1, 1, call(u, "GetSystemMetrics", 49), call(u, "GetSystemMetrics", 50), 0x8000)
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
	if c.Small != 0 {
		taskbarCreated = call(u, "RegisterWindowMessageW", uintptr(unsafe.Pointer(str("TaskbarCreated"))))
		tray = notifyIconData{Size: uint32(unsafe.Sizeof(tray)), Window: hwnd, ID: 1, Flags: 0x87, Callback: trayMessage, Icon: c.Small}
		tip, _ := syscall.UTF16FromString("三色桌宠")
		copy(tray.Tip[:], tip)
		addTrayIcon()
	}
	call(u, "SetTimer", hwnd, 1, 16, 0)
	var m msg
	for int32(call(u, "GetMessageW", uintptr(unsafe.Pointer(&m)), 0, 0, 0)) > 0 {
		call(u, "TranslateMessage", uintptr(unsafe.Pointer(&m)))
		call(u, "DispatchMessageW", uintptr(unsafe.Pointer(&m)))
	}
}
