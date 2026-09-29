# downlodr-ffmpeg-whisper

Static macOS ffmpeg builds with the `whisper` filter, for Downlodr's
transcription. No public macOS ffmpeg build (evermeet.cx, martin-riedl.de) is
configured with `--enable-whisper`, so Downlodr builds its own.

These are **transcription-only**: they decode common audio/video containers,
resample to 16 kHz mono WAV, and run the whisper filter. Downloading and
merging in Downlodr keep using the regular ffmpeg builds.

| Asset | Target | Acceleration |
|---|---|---|
| `ffmpeg-whisper-arm64` | Apple Silicon, macOS 11+ | Metal + Accelerate |
| `ffmpeg-whisper-x64` | Intel (Haswell+), macOS 11+ | AVX2 + Accelerate |

## Releasing a new version

1. Edit `versions.env` (version + sha256 of each source tarball:
   `curl -fsSL <url> | shasum -a 256`).
2. Open a PR. CI builds both arches and transcribes a sample with each.
3. Once it's merged, tag `v<ffmpeg>-w<whisper>-r<n>` (e.g. `v9.0.1-w1.9.4-r1`)
   and push the tag. CI publishes a release with both binaries, `SHA256SUMS`,
   build info and the source tarballs.
4. In Downlodr, update the URL + sha256 in `package.json`.

## Building locally (on an Apple Silicon Mac)

```bash
brew install nasm pkgconf cmake
./build.sh arm64            # or x64
curl -fLO https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin
./test.sh arm64 ggml-tiny.en.bin
```

## Licence

ffmpeg is built LGPL-2.1-or-later (no `--enable-gpl`, no `--enable-nonfree`);
whisper.cpp is MIT. Each release attaches the exact source tarballs used, and
`build.sh` at the release tag is the complete build recipe.
