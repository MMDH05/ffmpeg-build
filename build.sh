#!/usr/bin/env bash
#
# Builds a static, transcription-only ffmpeg with the whisper filter for macOS.
#
#   ./build.sh arm64   -> dist/ffmpeg-whisper-arm64   (Metal + Accelerate)
#                         dist/ffprobe-arm64
#   ./build.sh x64     -> dist/ffmpeg-whisper-x64     (CPU/AVX2 + Accelerate)
#                         dist/ffprobe-x64
#
# Both run on an Apple Silicon host; x64 is cross-compiled.
#
# The binary only covers what downlodr's transcriptHandler.ts does with it:
#   1. <any downloaded audio/video> -> 16 kHz mono pcm_s16le WAV
#   2. WAV -> whisper filter -> SRT/JSON/text via `-f null -`
# Everything else is disabled (--disable-everything + an allow-list), so it
# stays small and LGPL-only: no --enable-gpl, no external codec libraries.
# whisper.cpp is the only third-party library, and it is MIT.
#
# ffprobe comes from the same configure run. Downlodr uses it for duration and
# audio-stream detection, and yt-dlp uses it to inspect downloads, so every
# demuxer and parser is enabled: probing only reads container headers and
# needs no extra decoders.
#
# Requires: Xcode command line tools, cmake, pkg-config, nasm (x64 only).

set -euo pipefail
# Empty arrays below are expanded as ${a[@]+"${a[@]}"}: macOS ships bash 3.2,
# where "${a[@]}" on an empty array trips `set -u`.

ARCH="${1:-}"
case "$ARCH" in
  arm64)
    CMAKE_ARCH=arm64
    FF_ARCH=aarch64
    WHISPER_ARCH_FLAGS=(-DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON)
    FRAMEWORKS="-framework Accelerate -framework Foundation -framework Metal -framework MetalKit"
    ;;
  x64)
    CMAKE_ARCH=x86_64
    FF_ARCH=x86_64
    # No Metal on Intel: whisper.cpp's Metal path is unreliable on Intel/AMD
    # GPUs. AVX2/FMA/F16C/BMI2 need Haswell (2013) or newer — every Intel Mac
    # that runs macOS 11 except the late-2013 Mac Pro (Ivy Bridge). Without
    # them the CPU backend is too slow to be usable.
    WHISPER_ARCH_FLAGS=(-DGGML_METAL=OFF -DGGML_AVX=ON -DGGML_AVX2=ON
                        -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON)
    FRAMEWORKS="-framework Accelerate -framework Foundation"
    ;;
  *)
    echo "usage: $0 arm64|x64" >&2
    exit 64
    ;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=versions.env
source "$ROOT/versions.env"
export MACOSX_DEPLOYMENT_TARGET

JOBS="$(sysctl -n hw.ncpu)"
SRC="$ROOT/build/src"
WORK="$ROOT/build/$ARCH"
PREFIX="$WORK/prefix"
DIST="$ROOT/dist"
OUT="$DIST/ffmpeg-whisper-$ARCH"

rm -rf "$WORK"
mkdir -p "$SRC" "$WORK" "$PREFIX/lib/pkgconfig" "$DIST"

# fetch <url> <sha256> <dest>
fetch() {
  if [ ! -f "$3" ]; then
    echo "==> Downloading $1"
    curl -fL --retry 3 -o "$3.part" "$1"
    mv "$3.part" "$3"
  fi
  echo "$2  $3" | shasum -a 256 -c -
}

WHISPER_TGZ="$SRC/whisper.cpp-$WHISPER_VERSION.tar.gz"
FFMPEG_TXZ="$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz"
fetch "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v$WHISPER_VERSION.tar.gz" \
  "$WHISPER_SHA256" "$WHISPER_TGZ"
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" \
  "$FFMPEG_SHA256" "$FFMPEG_TXZ"

tar -xzf "$WHISPER_TGZ" -C "$WORK"
tar -xJf "$FFMPEG_TXZ" -C "$WORK"
WHISPER_SRC="$WORK/whisper.cpp-$WHISPER_VERSION"
FFMPEG_SRC="$WORK/ffmpeg-$FFMPEG_VERSION"

# ---------------------------------------------------------------------------
# 1. whisper.cpp (static)
# ---------------------------------------------------------------------------
echo "==> Building whisper.cpp $WHISPER_VERSION ($ARCH)"
cmake -S "$WHISPER_SRC" -B "$WORK/whisper-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_OSX_ARCHITECTURES="$CMAKE_ARCH" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF \
  -DGGML_ACCELERATE=ON \
  -DGGML_BLAS=ON \
  -DGGML_BLAS_VENDOR=Apple \
  "${WHISPER_ARCH_FLAGS[@]}"
cmake --build "$WORK/whisper-build" --config Release -j "$JOBS"
cmake --install "$WORK/whisper-build"

# The ggml backend archives (cpu/metal/blas) are not always installed for a
# static build, so collect every archive the build produced.
find "$WORK/whisper-build" -name '*.a' -exec cp -f {} "$PREFIX/lib/" \;

# whisper.cpp's whisper.pc only lists -lwhisper -lggml -lggml-base, which is
# enough for a shared build but not a static one: the backends, the Apple
# frameworks they use and libc++ are missing, and ffmpeg's configure check
# fails to link. Write a complete one.
GGML_BACKENDS=""
for lib in "$PREFIX"/lib/libggml-*.a; do
  name="$(basename "$lib" .a)"
  name="${name#lib}"
  [ "$name" = "ggml-base" ] && continue
  GGML_BACKENDS="$GGML_BACKENDS -l$name"
done
cat > "$PREFIX/lib/pkgconfig/whisper.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: whisper
Description: whisper.cpp (static, downlodr build)
Version: $WHISPER_VERSION
Libs: -L\${libdir} -lwhisper -lggml$GGML_BACKENDS -lggml-base $FRAMEWORKS -lc++
Cflags: -I\${includedir}
EOF
echo "==> whisper.pc:"
cat "$PREFIX/lib/pkgconfig/whisper.pc"

# ---------------------------------------------------------------------------
# 2. ffmpeg (static, transcription-only)
# ---------------------------------------------------------------------------
echo "==> Building ffmpeg $FFMPEG_VERSION ($ARCH)"

CROSS_FLAGS=()
if [ "$(uname -m)" != "$CMAKE_ARCH" ]; then
  CROSS_FLAGS=(--enable-cross-compile --host-cc=clang)
fi
X86ASM_FLAGS=()
if [ "$ARCH" = "x64" ]; then
  X86ASM_FLAGS=(--x86asmexe=nasm)
fi

cd "$FFMPEG_SRC"
PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" \
./configure \
  --prefix="$PREFIX" \
  --arch="$FF_ARCH" \
  --target-os=darwin \
  --cc="clang -arch $CMAKE_ARCH" \
  --cxx="clang++ -arch $CMAKE_ARCH" \
  ${CROSS_FLAGS[@]+"${CROSS_FLAGS[@]}"} \
  ${X86ASM_FLAGS[@]+"${X86ASM_FLAGS[@]}"} \
  --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
  --extra-version="downlodr-whisper$WHISPER_VERSION" \
  --pkg-config=pkg-config \
  --pkg-config-flags=--static \
  --enable-static \
  --disable-shared \
  --disable-autodetect \
  --enable-zlib \
  --disable-doc \
  --disable-network \
  --disable-programs \
  --enable-ffmpeg \
  --enable-ffprobe \
  --disable-everything \
  --enable-whisper \
  --enable-filter=whisper,aresample,aformat,anull,atrim,format,null,trim \
  --enable-protocol=file,pipe \
  --enable-demuxers \
  --enable-parsers \
  --enable-decoder=aac,aac_latm,ac3,eac3,alac,flac,mp3,mp3float,opus,vorbis,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_f32be \
  --enable-encoder=pcm_s16le \
  --enable-muxer=wav,null \
  || { echo "==> configure failed; tail of ffbuild/config.log:"; tail -n 60 ffbuild/config.log; exit 1; }

make -j "$JOBS"
make install

cp -f "$PREFIX/bin/ffmpeg" "$OUT"
strip -x "$OUT" || true
chmod +x "$OUT"

PROBE_OUT="$DIST/ffprobe-$ARCH"
cp -f "$PREFIX/bin/ffprobe" "$PROBE_OUT"
strip -x "$PROBE_OUT" || true
chmod +x "$PROBE_OUT"

# ---------------------------------------------------------------------------
# 3. Sanity checks that don't need to run the binaries
# ---------------------------------------------------------------------------
for bin in "$OUT" "$PROBE_OUT"; do
  echo "==> $(file "$bin")"
  lipo -info "$bin" | grep -q "$CMAKE_ARCH" \
    || { echo "!! wrong architecture: $bin" >&2; exit 1; }

  # Must be self-contained: only system libraries/frameworks may be linked.
  echo "==> Linked libraries:"
  otool -L "$bin"
  if otool -L "$bin" | tail -n +2 | awk '{print $1}' \
       | grep -vE '^(/usr/lib/|/System/Library/)'; then
    echo "!! non-system dynamic dependency found in $bin (listed above)" >&2
    exit 1
  fi

  ls -lh "$bin"
  echo "==> Built $bin"
done
