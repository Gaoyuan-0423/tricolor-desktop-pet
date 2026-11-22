// Pack the exported animation PNGs into lossless, independently addressable tiles.
// Run from the project root: go run tools/packframes/main.go
package main

import (
	"bytes"
	"compress/zlib"
	"encoding/binary"
	"flag"
	"fmt"
	"hash/crc32"
	"image"
	"image/draw"
	"image/png"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const frameWidth = 600

type frame struct {
	name   string
	height int
	tiles  []uint32
}

func loadImage(path string) (*image.NRGBA, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	im, err := png.Decode(f)
	if err != nil {
		return nil, err
	}
	if src, ok := im.(*image.NRGBA); ok {
		return src, nil
	}
	src := image.NewNRGBA(im.Bounds())
	draw.Draw(src, src.Bounds(), im, im.Bounds().Min, draw.Src)
	return src, nil
}

// An explicit sRGB chunk matches the colour declaration in the source artwork.
func srgbPNG(im *image.NRGBA) ([]byte, error) {
	var buf bytes.Buffer
	encoder := png.Encoder{CompressionLevel: png.BestCompression}
	if err := encoder.Encode(&buf, im); err != nil {
		return nil, err
	}
	data := buf.Bytes()
	const afterIHDR = 33
	chunk := []byte{0, 0, 0, 1, 's', 'R', 'G', 'B', 0, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(chunk[9:], crc32.ChecksumIEEE(chunk[4:9]))
	out := make([]byte, 0, len(data)+len(chunk))
	out = append(out, data[:afterIHDR]...)
	out = append(out, chunk...)
	out = append(out, data[afterIHDR:]...)
	return out, nil
}

func packRole(role, input, output string, tileSize, columns int) error {
	files, err := filepath.Glob(filepath.Join(input, role, "*.png"))
	if err != nil {
		return err
	}
	// Shared gestures plus each character's four idle poses and expressions.
	expectedFrames := 278 + map[string]int{"blue": 10, "amber": 7, "frost": 12}[role]
	if len(files) != expectedFrames {
		return fmt.Errorf("%s: expected %d animation frames, got %d", role, expectedFrames, len(files))
	}
	sort.Strings(files)
	known := make(map[string]uint32)
	var tiles []string
	frames := make([]frame, 0, len(files))
	scratch := make([]byte, tileSize*tileSize*4)
	for _, path := range files {
		im, err := loadImage(path)
		if err != nil {
			return err
		}
		name := strings.TrimSuffix(filepath.Base(path), ".png")
		width, height := im.Bounds().Dx(), im.Bounds().Dy()
		expected := 540
		if strings.HasPrefix(name, "key") {
			expected = 250
		}
		if width != frameWidth || height != expected {
			return fmt.Errorf("invalid dimensions: %s", path)
		}
		f := frame{name: name, height: height}
		for y := 0; y < height; y += tileSize {
			for x := 0; x < width; x += tileSize {
				w, h := min(tileSize, width-x), min(tileSize, height-y)
				if w != tileSize || h != tileSize {
					clear(scratch)
				}
				for row := 0; row < h; row++ {
					start := im.PixOffset(x, y+row)
					copy(scratch[row*tileSize*4:row*tileSize*4+w*4], im.Pix[start:start+w*4])
				}
				n, ok := known[string(scratch)]
				if !ok {
					n = uint32(len(tiles))
					tile := string(scratch)
					known[tile] = n
					tiles = append(tiles, tile)
				}
				f.tiles = append(f.tiles, n)
			}
		}
		frames = append(frames, f)
	}
	atlas := image.NewNRGBA(image.Rect(0, 0, columns*tileSize, (len(tiles)+columns-1)/columns*tileSize))
	for i, tile := range tiles {
		x, y := i%columns*tileSize, i/columns*tileSize
		for row := 0; row < tileSize; row++ {
			pos := atlas.PixOffset(x, y+row)
			copy(atlas.Pix[pos:pos+tileSize*4], tile[row*tileSize*4:(row+1)*tileSize*4])
		}
	}
	encoded, err := srgbPNG(atlas)
	if err != nil {
		return err
	}
	var index bytes.Buffer
	index.WriteString("TPK1")
	put16 := func(n int) { index.Write(binary.LittleEndian.AppendUint16(nil, uint16(n))) }
	put32 := func(n uint32) { index.Write(binary.LittleEndian.AppendUint32(nil, n)) }
	put16(tileSize)
	put16(columns)
	put32(uint32(len(tiles)))
	put16(len(frames))
	for _, f := range frames {
		index.WriteByte(byte(len(f.name)))
		index.WriteString(f.name)
		put16(f.height)
		for _, id := range f.tiles {
			put32(id)
		}
	}
	var compressed bytes.Buffer
	zw, err := zlib.NewWriterLevel(&compressed, zlib.BestCompression)
	if err != nil {
		return err
	}
	if _, err = zw.Write(index.Bytes()); err != nil {
		return err
	}
	if err = zw.Close(); err != nil {
		return err
	}
	dir := filepath.Join(output, role)
	if err = os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(dir, "atlas.png"), encoded, 0644); err != nil {
		return err
	}
	if err = os.WriteFile(filepath.Join(dir, "frames.z"), compressed.Bytes(), 0644); err != nil {
		return err
	}
	fmt.Printf("%s: %d unique tiles, %dx%d atlas, %d + %d bytes\n", role, len(tiles), atlas.Bounds().Dx(), atlas.Bounds().Dy(), len(encoded), compressed.Len())
	return nil
}

func main() {
	input := flag.String("input", "windows/assets", "directory of exported role PNGs")
	output := flag.String("output", "windows/packed", "destination for role atlases and index tables")
	tile := flag.Int("tile", 8, "tile edge in source pixels")
	columns := flag.Int("columns", 96, "tiles per atlas row")
	role := flag.String("role", "", "pack a single role, default all")
	flag.Parse()
	if *tile < 4 || *tile > 64 || *columns < 8 || *columns > 256 {
		log.Fatal("invalid atlas dimensions")
	}
	roles := []string{"blue", "amber", "frost"}
	if *role != "" {
		if *role != "blue" && *role != "amber" && *role != "frost" {
			log.Fatal("unknown role")
		}
		roles = []string{*role}
	}
	for _, r := range roles {
		if err := packRole(r, *input, *output, *tile, *columns); err != nil {
			log.Fatal(err)
		}
	}
}
