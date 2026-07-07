# Timelapse Creator — Usage Guide

*Italiano: [usage.it.md](usage.it.md)*

This guide walks through installing ffmpeg, launching the plug-in, and
creating a timelapse. For features, requirements, and installation of the
plug-in itself, see the main [README](../README.md).

## 1. Check ffmpeg in the Plug-in Manager

Timelapse Creator needs ffmpeg ≥ 4.0 on the same machine. The first time you
enable the plug-in, open *File → Plug-in Manager…* and select **Timelapse
Creator** in the list to see its status.

![Plug-in Manager — Timelapse Creator section](screenshots/02-plugin-manager-ffmpeg.png)

- **Detect automatically** re-scans common install locations (Homebrew,
  `PATH`, `/usr/local/bin`, `/opt/homebrew/bin`).
- **Set ffmpeg path…** lets you point at a specific binary if auto-detection
  fails or you want to use a particular build.
- The panel also shows the plug-in's install path, version, and enabled
  state.

If ffmpeg isn't found, install it first (macOS: `brew install ffmpeg`), then
click *Detect automatically*.

## 2. Select photos and launch the plug-in

In the Library module, select the photos for your sequence (any videos in
the selection are ignored; photos are ordered by capture time regardless of
selection order). Then open the plug-in from either:

- *File → Plug-in Extras → Create Timelapse…*, or
- *Library → Plug-in Extras → Create Timelapse…*

*File → Plug-in Extras → Timelapse Diagnostics…* is a separate, optional tool
for probing HDR-related export capabilities — see the *HDR* section of the
README.

![File → Plug-in Extras → Create Timelapse…](screenshots/01-menu-launch.png)

## 3. The Create Timelapse dialog

![Create Timelapse dialog](screenshots/03-create-timelapse-dialog.png)

The header line summarizes the current settings: number of photos, output
resolution, frame rate, and resulting duration. Below it, **Photos HDR: n of
total** shows how many selected photos are HDR edits — full HDR output
requires *all* of them to be HDR (see the README's *HDR* section).

### Preview

- The slider and prev/next arrows step through the selected photos exactly as
  developed in Lightroom (crop/aspect from your own Develop settings, not
  the video's target crop/fit — see the note under the preview).
- **Build preview** renders a short, low-resolution clip (240p/480p, chosen
  from the dropdown) and opens it in the system's default video player, so
  you can sanity-check motion, deflicker, and framing before committing to a
  full encode.

### Format & Speed

- **Format**: output resolution (720p/1080p/2160p), orientation
  (landscape/portrait), and aspect handling — **Fill** center-crops the
  photo to the target aspect, **Fit** letterboxes it with black bars instead
  of cropping.
- **Frame rate**: 24/25/30/60 fps, or *Custom…* for any value from 0–240 fps.
  One photo always maps to one frame — the frame rate only controls
  playback speed/duration, not which photos are included.

### Encoding

- **Codec**: H.264 (`libx264`), H.265/HEVC (`libx265`, tagged `hvc1` for
  Apple players), or ProRes 422 (Proxy/LT/standard/HQ, written as `.mov`).
  ProRes files are roughly 8–10x larger than H.264/H.265 for the same
  duration.
- **Quality**: High/Medium/Low presets, mapped internally to a CRF value per
  codec.
- **Use hardware acceleration (VideoToolbox)**: available for H.264/H.265 on
  Apple Silicon and supported Intel Macs. Much faster — often 5x or more for
  H.265 — at the cost of somewhat larger files. In this mode quality is
  controlled by target bitrate rather than CRF, so the Bitrate fields become
  the relevant controls instead of CRF/preset.
- **Deflicker**: enables ffmpeg's `deflicker` filter, with a configurable
  averaging window, to smooth brightness flicker between frames (common in
  long exposures or variable-aperture sequences).
- **Advanced settings** exposes:
  - **CRF** and **Encoder preset** (software encoding only).
  - **Keyframes**: min/max interval in frames — this is the GOP size. Min
    interval is disabled in hardware-acceleration mode (VideoToolbox doesn't
    expose it).
  - **Max bitrate** (0 = unlimited) and **Target bitrate**, in kbit/s — the
    controls that matter most when hardware acceleration is on.

### Output

- **Save to**: choose a destination folder, or check **Save in the photos'
  original folder** to use the folder of the first photo in the sequence.
- The output filename is generated automatically
  (`timelapse_YYYYMMDD_HHMMSS.<ext>`); the extension follows the chosen
  codec (`.mp4` for H.264/H.265, `.mov` for ProRes).

Click **Create timelapse** to start. Frames are rendered to a temporary
folder through Lightroom's export engine (full develop settings applied,
at the size implied by your crop/fit choice), then encoded with ffmpeg; the
temporary frames are deleted afterward. Both the frame-render and the
encode steps are cancelable mid-run. Budget disk space for one full-size
JPEG per photo during the render phase.

## 4. After encoding

When the export finishes, a confirmation dialog offers to **open the
video**, **show it in the file browser (Finder)**, or simply **close**.

## Troubleshooting

- **"ffmpeg not found"** in the dialog or Plug-in Manager: install ffmpeg
  (`brew install ffmpeg` on macOS) and click *Detect automatically*, or set
  an explicit path via *Set ffmpeg path…*.
- **HDR fields greyed out / 0 of n HDR photos**: HDR output requires every
  selected photo to be an HDR edit; mixed selections fall back to SDR. Use
  *Timelapse Diagnostics…* to inspect what your Lightroom version reports.
- **Deflicker option unavailable**: it requires ffmpeg ≥ 3.4; upgrade
  ffmpeg if the checkbox stays disabled.
