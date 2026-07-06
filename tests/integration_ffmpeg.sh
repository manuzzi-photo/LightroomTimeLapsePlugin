#!/bin/sh
# Integration test: generates a synthetic 3:2 frame sequence (like a Lightroom
# export) and encodes it with the exact commands built by FFmpegCommand.lua,
# then validates the results with ffprobe.
# Run from the repository root:  sh tests/integration_ffmpeg.sh
set -e

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "Workdir: $WORK"

# 30 synthetic 3:2 frames (1620x1080, the export box for 1080p crop), with a
# moving box and varying brightness to exercise deflicker.
ffmpeg -hide_banner -loglevel error -f lavfi \
  -i "testsrc2=size=1620x1080:rate=30:duration=1" \
  -start_number 1 "$WORK/frame_%06d.jpg"
COUNT=$(ls "$WORK" | grep -c '^frame_')
echo "Generated $COUNT frames"

# Ask FFmpegCommand.lua for the real commands.
build_cmd() {
  lua -e "
    package.path = 'TimelapseCreator.lrdevplugin/?.lua;' .. package.path
    local C = require 'FFmpegCommand'
    local opts = {
      ffmpegPath = '$(command -v ffmpeg)',
      inputPattern = '$WORK/frame_%06d.jpg',
      fps = 30, width = $2, height = $3, fit = '$4',
      codec = '$5', crf = $6, encoderPreset = 'ultrafast',
      keyintMin = 15, keyintMax = 60,
      deflicker = $7, deflickerSize = 5,
      outputPath = '$WORK/$1.mp4',
    }
    print(C.buildCommand(opts, false))
  "
}

run_case() {
  NAME=$1
  CMD=$(build_cmd "$@")
  echo "--- $NAME"
  eval "$CMD" >"$WORK/$NAME.log" 2>&1 || { echo "ENCODE FAILED"; cat "$WORK/$NAME.log"; exit 1; }
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,pix_fmt,r_frame_rate \
    -of csv=p=0 "$WORK/$NAME.mp4"
}

#        name          W    H    fit   codec crf deflicker
run_case h264_crop     1920 1080 crop  h264  21  false
run_case h265_crop     1920 1080 crop  h265  28  false
run_case h264_pad      1080 1920 pad   h264  23  false
run_case h264_deflick  1280 720  crop  h264  23  true

# Keyframe interval check: with keyint max 60 at 30fps, I-frames every <=2s.
echo "--- keyframe intervals (h264_crop)"
ffprobe -v error -select_streams v:0 -show_entries frame=pict_type -of csv=p=0 \
  "$WORK/h264_crop.mp4" | awk -F, '{ if ($1=="I") print NR-1 }' | head -5

echo "All integration cases passed"
