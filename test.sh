#!/usr/bin/env bash
#
# End-to-end check of a built binary, run the same way downlodr runs it
# (src/core-app/ipc/main/transcriptHandler.ts):
#   1. resampleTo16kMono: ffmpeg -y -i <input> -ar 16000 -ac 1 -c:a pcm_s16le in.wav
#   2. ffmpeg -i in.wav -filter_complex "[0:a]whisper=model='...':language=..:
#        queue=30:destination='...':format=srt" -f null -     (cwd = work dir)
#
#   plus the two ffprobe calls it makes on the input (duration, audio streams).
#
#   ./test.sh arm64|x64 <path/to/ggml-model.bin>
#
# The input is whisper.cpp's JFK sample, re-encoded to AAC in an .m4a so step 1
# exercises a real container/decoder rather than just copying a WAV.

set -euo pipefail

ARCH="${1:?usage: $0 arm64|x64 <model>}"
MODEL="$(cd "$(dirname "${2:?usage: $0 arm64|x64 <model>}")" && pwd)/$(basename "$2")"

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"
BIN="$ROOT/dist/ffmpeg-whisper-$ARCH"
PROBE="$ROOT/dist/ffprobe-$ARCH"
SAMPLE="$ROOT/build/$ARCH/whisper.cpp-$WHISPER_VERSION/samples/jfk.wav"

RUN=("$BIN")
RUN_PROBE=("$PROBE")
if [ "$ARCH" = "x64" ] && [ "$(uname -m)" = "arm64" ]; then
  # Rosetta 2 only emulates AVX2 from macOS 15 on, so this needs a
  # macos-15+ host; on 14 the x64 build dies with SIGILL here.
  /usr/bin/pgrep -q oahd || sudo softwareupdate --install-rosetta --agree-to-license
  RUN=(arch -x86_64 "$BIN")
  RUN_PROBE=(arch -x86_64 "$PROBE")
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Version"
"${RUN[@]}" -hide_banner -version | head -n 1

echo "==> Whisper filter present"
"${RUN[@]}" -hide_banner -filters | grep -wq whisper \
  || { echo "!! whisper filter missing" >&2; exit 1; }

echo "==> Step 1: m4a (AAC) -> 16 kHz mono WAV"
afconvert -f m4af -d aac "$SAMPLE" "$WORK/input.m4a"
"${RUN[@]}" -hide_banner -loglevel error -y -i "$WORK/input.m4a" \
  -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/in.wav"

echo "==> ffprobe version"
"${RUN_PROBE[@]}" -hide_banner -version | head -n 1

# The two probes transcriptHandler.ts runs: getDurationMs / hasAudioStream.
echo "==> ffprobe: duration of the m4a"
DURATION="$("${RUN_PROBE[@]}" -v error -show_entries format=duration \
  -of default=noprint_wrappers=1:nokey=1 "$WORK/input.m4a")"
echo "$DURATION"
awk -v d="$DURATION" 'BEGIN { exit !(d + 0 > 0) }' \
  || { echo "!! ffprobe did not report a positive duration" >&2; exit 1; }

echo "==> ffprobe: audio streams of the m4a"
STREAMS="$("${RUN_PROBE[@]}" -v error -select_streams a \
  -show_entries stream=index -of csv=p=0 "$WORK/input.m4a")"
echo "$STREAMS"
[ -n "$STREAMS" ] \
  || { echo "!! ffprobe found no audio stream" >&2; exit 1; }

echo "==> Step 2: whisper filter -> SRT"
ln -s "$MODEL" "$WORK/model.bin"
(
  cd "$WORK"
  "${RUN[@]}" -hide_banner -i in.wav \
    -filter_complex "[0:a]whisper=model='model.bin':language=en:queue=30:destination='out.srt':format=srt" \
    -f null -
)

echo "==> Transcript:"
cat "$WORK/out.srt"

# JFK: "And so, my fellow Americans, ask not what your country can do for you..."
grep -qi "country" "$WORK/out.srt" \
  || { echo "!! transcript does not contain the expected text" >&2; exit 1; }
grep -q -- "-->" "$WORK/out.srt" \
  || { echo "!! output is not SRT" >&2; exit 1; }

echo "==> PASS ($ARCH)"
