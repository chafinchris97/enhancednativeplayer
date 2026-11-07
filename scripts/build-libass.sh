#!/bin/sh
# Builds Frameworks/Libass.xcframework: libass with its optimised assembly (NEON on arm64,
# AVX2/SSE on x86_64), and the FreeType, FriBidi and HarfBuzz it needs, merged into one
# static library per platform. Fonts come from attached files and CoreText; no fontconfig.
#
#     scripts/build-libass.sh [work directory]
#
# Needs Xcode, autoconf, automake, libtool, pkg-config and nasm (Homebrew has them all).
set -eu

LIBASS=0.17.5
FREETYPE=2.15.0
FRIBIDI=1.0.18
HARFBUZZ=15.1.0
IOS_MIN=17.0
TVOS_MIN=17.0
MACOS_MIN=14.0

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-${TMPDIR:-/tmp}/enp-libass-build}
OUT="$ROOT/Frameworks/Libass.xcframework"
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$WORK/src"

fetch() {
	name=$1 url=$2
	[ -d "$WORK/src/$name" ] && return
	curl -fsSL "$url" | tar -xJ -C "$WORK/src"
}
fetch "libass-$LIBASS" "https://github.com/libass/libass/releases/download/$LIBASS/libass-$LIBASS.tar.xz"
fetch "freetype-$FREETYPE" "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE.tar.xz"
fetch "fribidi-$FRIBIDI" "https://github.com/fribidi/fribidi/releases/download/v$FRIBIDI/fribidi-$FRIBIDI.tar.xz"
fetch "harfbuzz-$HARFBUZZ" "https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ/harfbuzz-$HARFBUZZ.tar.xz"

# Builds every library for one SDK and architecture into $WORK/<slice>/prefix and merges
# them into $WORK/<slice>/libass-merged.a.
build_slice() {
	slice=$1 sdk=$2 arch=$3 target=$4
	prefix="$WORK/$slice/prefix"
	build="$WORK/$slice/build"
	rm -rf "$WORK/$slice"
	mkdir -p "$prefix/lib/pkgconfig" "$prefix/include" "$build"
	sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
	cc="$(xcrun --sdk "$sdk" -f clang)"
	cxx="$(xcrun --sdk "$sdk" -f clang++)"
	flags="-target $target -isysroot $sysroot -O2 -fPIC"
	case $arch in arm64) host=aarch64-apple-darwin ;; *) host=x86_64-apple-darwin ;; esac
	export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=""

	# configure <source> <install targets> <configure options...>
	configure() {
		dir=$1 targets=$2; shift 2
		rm -rf "$build/$dir" && cp -Rp "$WORK/src/$dir" "$build/$dir"
		(cd "$build/$dir" && CC="$cc" CXX="$cxx" CFLAGS="$flags" CXXFLAGS="$flags" LDFLAGS="$flags" \
			./configure --host=$host --prefix="$prefix" --enable-static --disable-shared "$@" >configure.log 2>&1 \
			&& make -j"$JOBS" $targets >make.log 2>&1) \
			|| { echo "$dir failed for $slice; see $build/$dir/*.log" >&2; exit 1; }
	}

	# Without Apple's HVF fonts: they need libhvf, which only newer systems have.
	ac_cv_header_hvf_Scaler_h=no configure "freetype-$FREETYPE" install --with-zlib=no --with-bzip2=no --with-png=no --with-harfbuzz=no --with-brotli=no
	# Only the library: the tools' man pages don't build when cross-compiling.
	configure "fribidi-$FRIBIDI" "-C lib install" --disable-deprecated
	(cd "$build/fribidi-$FRIBIDI" && make install-pkgconfigDATA >>make.log 2>&1)

	# HarfBuzz builds with Meson only; its single-file amalgamation needs no build system.
	hb="$WORK/src/harfbuzz-$HARFBUZZ"
	mkdir -p "$build/harfbuzz" "$prefix/include/harfbuzz"
	"$cxx" $flags -std=c++17 -fno-exceptions -fno-rtti -fvisibility-inlines-hidden -DNDEBUG \
		-DHAVE_FREETYPE=1 -DHAVE_PTHREAD=1 -I"$prefix/include/freetype2" \
		-c "$hb/src/harfbuzz.cc" -o "$build/harfbuzz/harfbuzz.o"
	ar rcs "$prefix/lib/libharfbuzz.a" "$build/harfbuzz/harfbuzz.o"
	cp "$hb"/src/hb.h "$hb"/src/hb-*.h "$prefix/include/harfbuzz/"
	cat >"$prefix/lib/pkgconfig/harfbuzz.pc" <<EOF
prefix=$prefix
Name: harfbuzz
Description: HarfBuzz text shaping library
Version: $HARFBUZZ
Libs: -L\${prefix}/lib -lharfbuzz -lc++
Cflags: -I\${prefix}/include/harfbuzz
EOF

	configure "libass-$LIBASS" install --enable-asm --disable-fontconfig --disable-libunibreak \
		--disable-require-system-font-provider --disable-test --disable-compare --disable-profile --disable-fuzz

	libtool -static -o "$WORK/$slice/libass-merged.a" \
		"$prefix/lib/libass.a" "$prefix/lib/libfreetype.a" "$prefix/lib/libfribidi.a" "$prefix/lib/libharfbuzz.a" 2>/dev/null
	# The assembly must be in, or this is the slow build all over again.
	nm "$WORK/$slice/libass-merged.a" 2>/dev/null | grep -qE "_ass_blur4_horz16_(neon|sse2|avx2)" \
		|| { echo "libass for $slice was built without its assembly" >&2; exit 1; }
	echo "built $slice"
}

build_slice ios-arm64 iphoneos arm64 "arm64-apple-ios$IOS_MIN"
build_slice ios-sim-arm64 iphonesimulator arm64 "arm64-apple-ios$IOS_MIN-simulator"
build_slice ios-sim-x86_64 iphonesimulator x86_64 "x86_64-apple-ios$IOS_MIN-simulator"
build_slice tvos-arm64 appletvos arm64 "arm64-apple-tvos$TVOS_MIN"
build_slice tvos-sim-arm64 appletvsimulator arm64 "arm64-apple-tvos$TVOS_MIN-simulator"
build_slice tvos-sim-x86_64 appletvsimulator x86_64 "x86_64-apple-tvos$TVOS_MIN-simulator"
build_slice macos-arm64 macosx arm64 "arm64-apple-macos$MACOS_MIN"
build_slice macos-x86_64 macosx x86_64 "x86_64-apple-macos$MACOS_MIN"

fat() {
	name=$1; shift
	mkdir -p "$WORK/fat/$name"
	lipo -create "$@" -output "$WORK/fat/$name/libass.a"
}
rm -rf "$WORK/fat"
fat ios-sim "$WORK/ios-sim-arm64/libass-merged.a" "$WORK/ios-sim-x86_64/libass-merged.a"
fat tvos-sim "$WORK/tvos-sim-arm64/libass-merged.a" "$WORK/tvos-sim-x86_64/libass-merged.a"
fat macos "$WORK/macos-arm64/libass-merged.a" "$WORK/macos-x86_64/libass-merged.a"
mkdir -p "$WORK/fat/ios" "$WORK/fat/tvos"
cp "$WORK/ios-arm64/libass-merged.a" "$WORK/fat/ios/libass.a"
cp "$WORK/tvos-arm64/libass-merged.a" "$WORK/fat/tvos/libass.a"

# Only libass's own headers are public; the module is `Libass`.
headers="$WORK/headers"
rm -rf "$headers"
mkdir -p "$headers/ass"
cp "$WORK/ios-arm64/prefix/include/ass/ass.h" "$WORK/ios-arm64/prefix/include/ass/ass_types.h" "$headers/ass/"
cat >"$headers/module.modulemap" <<EOF
module Libass {
    header "ass/ass.h"
    link "c++"
    link "iconv"
    export *
}
EOF

for platform in ios ios-sim tvos tvos-sim macos; do
	strip -S -x "$WORK/fat/$platform/libass.a" 2>/dev/null || true
done
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
	-library "$WORK/fat/ios/libass.a" -headers "$headers" \
	-library "$WORK/fat/ios-sim/libass.a" -headers "$headers" \
	-library "$WORK/fat/tvos/libass.a" -headers "$headers" \
	-library "$WORK/fat/tvos-sim/libass.a" -headers "$headers" \
	-library "$WORK/fat/macos/libass.a" -headers "$headers" \
	-output "$OUT" >/dev/null
echo "wrote $OUT (libass $LIBASS, FreeType $FREETYPE, FriBidi $FRIBIDI, HarfBuzz $HARFBUZZ)"
