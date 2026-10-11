#!/usr/bin/env bash
# Regenerates the fragmented-MP4 test fixture: a synthetic test pattern with a
# 440 Hz tone, muxed the way go2rtc sends MSE streams (H.264 High + AAC-LC 16 kHz,
# empty moov, one moof/mdat per keyframe, default-base-is-moof).
# No camera footage is ever committed to the repo.
set -euo pipefail
out="$(dirname "$0")/../FrigateAppTests/Fixtures/test-pattern-h264-aac.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i testsrc2=size=320x240:rate=15 \
  -f lavfi -i sine=frequency=440:sample_rate=16000 \
  -t 2 -c:v libx264 -profile:v high -pix_fmt yuv420p -g 15 -bf 0 \
  -c:a aac -b:a 32k \
  -movflags frag_keyframe+empty_moov+default_base_moof \
  -f mp4 "$out"
echo "wrote $out"
