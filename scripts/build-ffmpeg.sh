#!/bin/sh
# Builds a static, LGPL-only ffmpeg (arm64) into Support/bin/ffmpeg.
# No GPL parts (no x264/x265): H.264/HEVC use Apple VideoToolbox.
# Shipping it means following LGPL 2.1: include the licence and let users relink (see Support/licenses).
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
WORK=$ROOT/.ffmpeg-build
PREFIX=$WORK/prefix
mkdir -p "$WORK/src" "$PREFIX" Support/bin
export PATH="/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0"
export LDFLAGS="-arch arm64 -mmacosx-version-min=14.0"
JOBS=$(sysctl -n hw.ncpu)

fetch() {  # url dir
  [ -d "$WORK/src/$2" ] && return
  echo "== fetch $2"
  curl -fsSL "$1" -o "$WORK/src/$2.tar"
  mkdir "$WORK/src/$2"
  tar -xf "$WORK/src/$2.tar" -C "$WORK/src/$2" --strip-components 1
}

autobuild() {  # dir [configure args...]
  d=$1; shift
  [ -f "$WORK/src/$d/.built" ] && return
  echo "== build $d"
  (cd "$WORK/src/$d" && ./configure --prefix="$PREFIX" --host=aarch64-apple-darwin --disable-shared --enable-static "$@" \
    && make -j"$JOBS" && make install) > "$WORK/$d.log" 2>&1 || { tail -30 "$WORK/$d.log"; exit 1; }
  touch "$WORK/src/$d/.built"
}

fetch https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz lame
fetch https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz ogg
fetch https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz vorbis
fetch https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz opus
fetch https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.5.0.tar.gz webp
fetch https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz vpx
fetch https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz ffmpeg

autobuild lame --disable-frontend --disable-decoder
autobuild ogg
# libvorbis 1.3.7 passes a flag modern clang rejects
sed -i '' 's/-force_cpusubtype_ALL//g' "$WORK/src/vorbis/configure"
autobuild vorbis --with-ogg="$PREFIX"
autobuild opus --disable-doc --disable-extra-programs
autobuild webp --disable-libwebpdemux --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic

if [ ! -f "$WORK/src/vpx/.built" ]; then
  echo "== build vpx"
  (cd "$WORK/src/vpx" && ./configure --prefix="$PREFIX" --target=arm64-darwin23-gcc --disable-shared --enable-static --enable-pic \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    && make -j"$JOBS" && make install) > "$WORK/vpx.log" 2>&1 || { tail -30 "$WORK/vpx.log"; exit 1; }
  touch "$WORK/src/vpx/.built"
fi

echo "== build ffmpeg"
(cd "$WORK/src/ffmpeg" && ./configure --prefix="$PREFIX" --arch=arm64 --target-os=darwin --cc=clang \
  --extra-cflags="$CFLAGS -I$PREFIX/include" --extra-ldflags="$LDFLAGS -L$PREFIX/lib" --pkg-config-flags=--static \
  --enable-static --disable-shared --disable-doc --disable-network --disable-autodetect \
  --disable-programs --enable-ffmpeg \
  --enable-zlib --enable-videotoolbox --enable-audiotoolbox \
  --enable-libmp3lame --enable-libvorbis --enable-libopus --enable-libvpx --enable-libwebp \
  --disable-encoders \
  --enable-encoder=libmp3lame,libvorbis,libopus,wmav2,aac,flac,alac,pcm_s16le,pcm_s16be,wmv2,mpeg4,libvpx_vp8,libvpx_vp9,h264_videotoolbox,hevc_videotoolbox,libwebp,libwebp_anim,gif,png,mjpeg,subrip,webvtt \
  --disable-muxers \
  --enable-muxer=mp3,ogg,opus,asf,matroska,webm,avi,mp4,mov,ipod,wav,flac,adts,aiff,webp,gif,image2,srt,webvtt \
  --disable-protocols --enable-protocol=file,pipe,fd \
  --disable-filters \
  --enable-filter=aresample,aformat,anull,null,format,scale,fps,palettegen,paletteuse,split,volume,pan,setpts,atempo,crop,trim,atrim,boxblur,drawbox,pad,transpose,concat,amix,anullsrc,color,overlay,loudnorm \
  && make -j"$JOBS") > "$WORK/ffmpeg.log" 2>&1 || { tail -40 "$WORK/ffmpeg.log"; exit 1; }

cp "$WORK/src/ffmpeg/ffmpeg" Support/bin/ffmpeg
strip Support/bin/ffmpeg
mkdir -p Support/licenses
cp "$WORK/src/ffmpeg/COPYING.LGPLv2.1" Support/licenses/ffmpeg-LGPL-2.1.txt
cp "$WORK/src/lame/COPYING" Support/licenses/lame-LGPL.txt
cp "$WORK/src/opus/COPYING" Support/licenses/opus-BSD.txt
cp "$WORK/src/vorbis/COPYING" Support/licenses/vorbis-BSD.txt
cp "$WORK/src/ogg/COPYING" Support/licenses/ogg-BSD.txt
cp "$WORK/src/vpx/LICENSE" Support/licenses/libvpx-BSD.txt
cp "$WORK/src/webp/COPYING" Support/licenses/libwebp-BSD.txt
ls -lh Support/bin/ffmpeg
Support/bin/ffmpeg -hide_banner -version | head -1
