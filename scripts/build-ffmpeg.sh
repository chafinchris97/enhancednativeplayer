#!/bin/sh
# Builds Frameworks/EPLibavutil, EPLibavcodec, EPLibavformat and EPLibswresample.xcframework:
# FFmpeg, with dav1d linked into libavcodec, as one dynamic framework per library.
#
#     scripts/build-ffmpeg.sh [work directory]
#
# Dynamic, because FFmpeg is LGPL: an app that links these keeps the right to ship closed
# source as long as the libraries stay replaceable. The build enables no GPL parts.
#
# Only what the engine uses is built: demuxing through our own AVIO (no protocols), the
# video decoders of the rendered route, the audio decoders the FLAC transcode reads, the
# FLAC encoder, swresample, and the fragmented MP4 muxer. Subtitles are parsed in Swift.
# The patches in scripts/patches/ffmpeg are applied on top of the release.
#
# Needs Xcode, meson, ninja, nasm and pkg-config (Homebrew has them all).
set -eu

FFMPEG=8.1.3
FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
DAV1D=1.5.4
DAV1D_SHA256=686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
IOS_MIN=17.0
TVOS_MIN=17.0
MACOS_MIN=14.0
LIBRARIES="avutil swresample avcodec avformat"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=${1:-${TMPDIR:-/tmp}/enp-ffmpeg-build}
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$WORK/src"

fetch() {
	name=$1 url=$2 sha=$3
	[ -d "$WORK/src/$name" ] && return
	curl -fsSL "$url" -o "$WORK/src/$name.tar.xz"
	echo "$sha  $WORK/src/$name.tar.xz" | shasum -a 256 -c - >/dev/null \
		|| { echo "$name.tar.xz does not match its pinned checksum" >&2; exit 1; }
	tar -xJ -C "$WORK/src" -f "$WORK/src/$name.tar.xz"
}
fetch "ffmpeg-$FFMPEG" "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" $FFMPEG_SHA256
fetch "dav1d-$DAV1D" "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D/dav1d-$DAV1D.tar.xz" $DAV1D_SHA256

# A patched copy of FFmpeg, made again whenever this script runs so a changed patch counts.
rm -rf "$WORK/ffmpeg"
cp -Rp "$WORK/src/ffmpeg-$FFMPEG" "$WORK/ffmpeg"
for patch in "$ROOT"/scripts/patches/ffmpeg/*.patch; do
	patch -d "$WORK/ffmpeg" -p1 --forward --quiet <"$patch" \
		|| { echo "$(basename "$patch") does not apply to FFmpeg $FFMPEG" >&2; exit 1; }
done

list() { kind=$1; shift; for name in "$@"; do printf -- '--enable-%s=%s ' "$kind" "$name"; done; }
COMPONENTS="--disable-everything --enable-avcodec --enable-avformat --enable-avutil --enable-swresample \
$(list demuxer matroska mov mpegts mpegps avi flv asf ogg \
	h264 hevc vc1 m4v mpegvideo aac ac3 eac3 dts truehd mlp loas mp3 flac) \
$(list parser h264 hevc av1 vc1 mpeg4video mpegvideo vp8 vp9 \
	aac aac_latm ac3 dca mlp mpegaudio flac opus vorbis) \
$(list decoder h264 hevc libdav1d vc1 wmv1 wmv2 wmv3 mpeg1video mpeg2video mpeg4 \
	msmpeg4v1 msmpeg4v2 msmpeg4v3 h263 flv vp8 vp9 theora \
	aac aac_latm ac3 eac3 dca truehd mlp mp1 mp2 mp3 opus vorbis flac alac \
	wmav1 wmav2 wmapro wmalossless pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le \
	pcm_f32le pcm_bluray pcm_dvd) \
$(list encoder flac) \
$(list muxer mp4)"

# Builds dav1d and FFmpeg for one SDK and architecture into $WORK/<slice>/prefix.
build_slice() {
	slice=$1 sdk=$2 arch=$3 target=$4
	prefix="$WORK/$slice/prefix"
	build="$WORK/$slice/build"
	rm -rf "$WORK/$slice"
	mkdir -p "$prefix" "$build/dav1d" "$build/ffmpeg"
	sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
	cc=$(xcrun --sdk "$sdk" -f clang)
	flags="-target $target -isysroot $sysroot"
	case $arch in arm64) family=aarch64 ;; *) family=x86_64 ;; esac

	cat >"$build/dav1d/cross.txt" <<EOF
[binaries]
c = '$cc'
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
nasm = '$(command -v nasm)'
[built-in options]
c_args = ['-target', '$target', '-isysroot', '$sysroot']
c_link_args = ['-target', '$target', '-isysroot', '$sysroot']
[properties]
needs_exe_wrapper = true
[host_machine]
system = 'darwin'
cpu_family = '$family'
cpu = '$arch'
endian = 'little'
EOF
	(meson setup "$build/dav1d" "$WORK/src/dav1d-$DAV1D" --cross-file "$build/dav1d/cross.txt" \
		--prefix="$prefix" --libdir=lib --buildtype=release --default-library=static \
		-Denable_tools=false -Denable_tests=false -Denable_examples=false \
		&& ninja -C "$build/dav1d" install) >"$build/dav1d.log" 2>&1 \
		|| { echo "dav1d failed for $slice; see $build/dav1d.log" >&2; exit 1; }

	# The install names point into the framework each library ships in.
	(cd "$build/ffmpeg" && PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH="" \
		"$WORK/ffmpeg/configure" --prefix="$prefix" --enable-cross-compile --target-os=darwin \
		--arch="$arch" --cc="$cc" --sysroot="$sysroot" \
		--extra-cflags="$flags" --extra-ldflags="$flags -Wl,-headerpad_max_install_names" \
		--enable-shared --disable-static --enable-pic --install-name-dir=@rpath \
		--disable-autodetect --enable-pthreads --enable-libdav1d \
		--disable-programs --disable-doc --disable-network --disable-stripping \
		--disable-avdevice --disable-avfilter --disable-swscale \
		$COMPONENTS >configure.log 2>&1 \
		&& make -j"$JOBS" install >make.log 2>&1) \
		|| { echo "FFmpeg failed for $slice; see $build/ffmpeg/*.log" >&2; exit 1; }

	# The decoder must be in, or AV1 has nothing to play it.
	nm "$prefix/lib/libavcodec.dylib" | grep -q _ff_libdav1d_decoder \
		|| { echo "libavcodec for $slice was built without dav1d" >&2; exit 1; }
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

# dylib <slice> <library>: the library's dylib in that slice.
dylib() { echo "$WORK/$1/prefix/lib/lib$2.dylib"; }

# Headers that only build for other platforms' hardware APIs.
foreign_header() {
	case $1 in
	hwcontext_*.h | d3d11va.h | d3d12va.h | dxva2.h | qsv.h | vdpau.h | mediacodec.h | jni.h) return 0 ;;
	esac
	return 1
}

# make_framework <platform> <library> <min OS> <slices...>: one framework per platform,
# its binary the slices' dylibs combined, at $WORK/frameworks/<platform>/EP<Lib>.framework.
make_framework() {
	platform=$1 lib=$2 min=$3; shift 3
	name="EPLib$lib"
	fw="$WORK/frameworks/$platform/$name.framework"
	rm -rf "$fw" "$WORK/frameworks/$platform/$name.framework.dSYM"
	case $platform in
	macos) contents="$fw/Versions/A"; resources="$contents/Resources" ;;
	*) contents="$fw"; resources="$fw" ;;
	esac
	mkdir -p "$contents/Headers" "$contents/Modules" "$resources"

	inputs=""
	for slice in "$@"; do
		inputs="$inputs $(dylib "$slice" "$lib")"
	done
	lipo -create $inputs -output "$contents/$name"
	install_name_tool -id "@rpath/$name.framework/$name" "$contents/$name"
	for other in $LIBRARIES; do
		linked=$(otool -D "$(dylib "$1" "$other")" | tail -1)
		install_name_tool -change "$linked" "@rpath/EPLib$other.framework/EPLib$other" "$contents/$name"
	done
	dsymutil "$contents/$name" -o "$WORK/frameworks/$platform/$name.framework.dSYM" 2>/dev/null
	strip -x "$contents/$name"

	# FFmpeg's headers include each other as "libavutil/…"; in a framework that is "EPLibavutil/…".
	excludes=""
	for header in "$WORK/$1/prefix/include/lib$lib"/*.h; do
		file=$(basename "$header")
		if foreign_header "$file"; then
			excludes="$excludes    exclude header \"$file\"
"
		fi
		sed -E 's#([<"])lib(avutil|avcodec|avformat|swresample)/#\1EPLib\2/#g' "$header" >"$contents/Headers/$file"
	done
	cat >"$contents/Modules/module.modulemap" <<EOF
framework module $name [system] {
    umbrella "."
$excludes    export *
}
EOF

	case $platform in
	ios) supported=iPhoneOS ;; ios-sim) supported=iPhoneSimulator ;;
	tvos) supported=AppleTVOS ;; tvos-sim) supported=AppleTVSimulator ;; macos) supported=MacOSX ;;
	esac
	case $platform in
	macos) minkey=LSMinimumSystemVersion ;;
	*) minkey=MinimumOSVersion ;;
	esac
	cat >"$resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>org.ffmpeg.$name</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>$FFMPEG</string>
	<key>CFBundleVersion</key><string>$FFMPEG</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
	<key>$minkey</key><string>$min</string>
</dict>
</plist>
EOF
	if [ "$platform" = macos ]; then
		ln -s A "$fw/Versions/Current"
		for item in "$name" Headers Modules Resources; do ln -s "Versions/Current/$item" "$fw/$item"; done
	fi
}

rm -rf "$WORK/frameworks"
for lib in $LIBRARIES; do
	make_framework ios "$lib" $IOS_MIN ios-arm64
	make_framework ios-sim "$lib" $IOS_MIN ios-sim-arm64 ios-sim-x86_64
	make_framework tvos "$lib" $TVOS_MIN tvos-arm64
	make_framework tvos-sim "$lib" $TVOS_MIN tvos-sim-arm64 tvos-sim-x86_64
	make_framework macos "$lib" $MACOS_MIN macos-arm64 macos-x86_64

	out="$ROOT/Frameworks/EPLib$lib.xcframework"
	rm -rf "$out"
	args=""
	for platform in ios ios-sim tvos tvos-sim macos; do
		dir="$WORK/frameworks/$platform"
		args="$args -framework $dir/EPLib$lib.framework -debug-symbols $dir/EPLib$lib.framework.dSYM"
	done
	xcodebuild -create-xcframework $args -output "$out" >/dev/null
	echo "wrote $out"
done
echo "FFmpeg $FFMPEG with dav1d $DAV1D"
