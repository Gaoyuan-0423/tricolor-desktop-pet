# Tricolor Desktop Pet

[简体中文](README.md) · **English**

Three desktop companions for macOS and Windows. Move your mouse and your pet follows the cursor with her eyes, then turns her head. Type a letter and she taps the matching key on her own keyboard. Give her a head pat and she smiles as little hearts float up.

[Download v1.2.0 · macOS / Windows / source](https://github.com/Gaoyuan-0423/tricolor-desktop-pet/releases/tag/v1.2.0)

## In the app

These two views show the white dragon running on a Mac. In the left panel the cursor is to the left of the window. In the right panel it has moved to the right. Watch how her pupils shift and her head tilts.

![Two Mac previews of the white dragon holding the mouse and looking toward opposite sides of the window](docs/images/cursor-tracking.png)

The columns below show the blue, orange and white characters. The top row shows their hands at rest. The bottom row shows how each character's right hand settles over the mouse buttons.

![Close-ups of all three characters' hands at rest and holding the mouse](docs/images/mouse-grip.png)

## Getting started

- **Mac** — Download the universal macOS ZIP, extract it and open `三色桌宠.app`. To make your pet respond while you type in other apps, right-click her, choose “开启输入监控…” (Open Input Monitoring), and allow access in System Settings.
- **Windows** — Download the Windows x64 EXE and run it.
- **Both platforms** — Drag your pet to move her. Right-click to switch characters, mute or unmute typing sounds, or change her size from 50% to 200%.

## Build from source

Start in the repository root. The macOS build requires the Xcode Command Line Tools. The Windows build requires Go.

**macOS**

```sh
cd BlackCat
bash build-mac.sh
```

**Windows x64 (PowerShell)**

```powershell
cd BlackCat/windows
$env:GOARCH = 'amd64'
go build -trimpath -ldflags='-s -w -H=windowsgui' -o TricolorPet.exe main.go
```

The [project guide](BlackCat/项目说明.md) covers cross-compilation and animation export. The [artwork notes](BlackCat/Artwork/素材说明.md) describe the source illustrations, hand poses and expressions. Both guides are in Chinese.
