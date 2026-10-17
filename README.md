# Satsuma

A personal macOS menu-bar app for converting files by drag and drop.
Start dragging any file, tap a modifier key, and drop it on an option in the wheel that appears.

| Key (while dragging) | Wheel | Examples |
|---|---|---|
| ⇧ Shift | Convert | HEIC→JPG, MOV→MP4, WAV→MP3, PDF→Word, Markdown→PDF, CSV→JSON |
| ⌘ Command | Tools | Compress, resize, rotate, mute, merge/split PDF, ZIP/extract |
| ⌃ Control | Actions | AirDrop, Float shelf, copy, copy path, Terminal, move/copy to |

Keyboard: select files in Finder and press ⌃⌥Space. Keys can be changed from the menu-bar icon.
Results are saved next to the original. Everything runs locally.

## PDF → Word

`PDFScanner.swift`, `PDFToWord.swift` and `DocxWriter.swift` form a layout-preserving converter:
real fonts, sizes and colours are read from the PDF's content stream, lines are rebuilt into
paragraphs, and bullets, tab stops, rules, shading, links and images are written as native Word markup.

Not yet handled: table grids, icon fonts, multi-column layouts, scanned (image-only) PDFs.

## Build

Requires macOS 13+ and Xcode command-line tools. Video/audio needs `brew install ffmpeg`; WebP needs `brew install webp`.

```sh
./build.sh      # builds Satsuma.app and installs it to ~/Applications
```

Test a conversion without the UI:

```sh
swift build && .build/debug/Satsuma --run convert:docx file.pdf
```
