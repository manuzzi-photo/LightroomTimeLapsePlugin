# Timelapse Creator — Lightroom Classic plug-in

Creates a timelapse video (H.264 / H.265) from the photos selected in Adobe
Lightroom Classic, using [ffmpeg](https://ffmpeg.org) as the encoder. The
develop settings of every photo are applied, so what you graded in Lightroom
is what ends up in the video.

**Status: 0.1.0 — work in progress.** SDR pipeline complete; HDR output is
under investigation (see *HDR* below).

## Features

- 720p / 1080p / 4K output, landscape or portrait
- H.264 (libx264) and H.265 (libx265, `hvc1`-tagged for Apple players)
- Frame rate selection (24/25/30/60 fps, 1 photo = 1 frame)
- Fill (center crop) or fit (black bars) aspect handling
- Quality presets plus advanced controls: CRF, encoder preset,
  **min/max keyframe interval (GOP)**, max bitrate
- Optional ffmpeg `deflicker` filter
- Fast low-resolution preview (480p/240p) built from catalog previews and
  opened in the system video player
- UI in English and Italian

## Requirements

- Adobe Lightroom Classic 13+ (developed against LrC 15)
- ffmpeg on the same machine — macOS: `brew install ffmpeg`.
  The plug-in auto-detects Homebrew/PATH installs; a custom path can be set
  in the dialog.
- macOS today; the code is structured for a future Windows port.

## Installation

1. Clone or download this repository.
2. Lightroom Classic → *File → Plug-in Manager… → Add* and select the
   `TimelapseCreator.lrdevplugin` folder.
3. Select the photos of your sequence, then run
   *File → Plug-in Extras → Create Timelapse…*

## Usage notes

- Photos are sorted by capture time; videos in the selection are skipped.
- Frames are rendered to a temporary folder via the Lightroom export engine
  (full develop settings, correct size for the chosen crop), encoded, then
  the temporary files are removed. Budget disk space for one JPEG per photo.
- A running ffmpeg encode cannot be canceled from Lightroom yet.

## HDR

The goal is H.265 10-bit HDR output (PQ or HLG) when **all** selected photos
are HDR edits. The Lightroom SDK does not document any HDR export setting, so
the plug-in ships two diagnostic tools to probe what your Lightroom version
actually supports:

- *File → Plug-in Extras → Timelapse Diagnostics…* — probes export formats
  (AVIF/JXL/TIFF-16), speculative HDR keys, thumbnail latency and ffmpeg.
- The *"Timelapse: dump export settings"* post-process action in the Export
  dialog — export one photo with HDR output enabled and one without, then
  diff the two dumps to reveal the real HDR keys.

The ffmpeg side (10-bit, PQ/HLG tagging, `hdr10=1`) is already implemented
and unit-tested.

## Development

```sh
# unit tests for the command builder (pure Lua, no Lightroom needed)
lua tests/test_ffmpeg_command.lua

# integration test: real encodes with synthetic frames (needs ffmpeg)
sh tests/integration_ffmpeg.sh
```

See [PLAN.md](PLAN.md) for the full design and roadmap.

## License

GPL-3.0 — see [LICENSE](LICENSE).
