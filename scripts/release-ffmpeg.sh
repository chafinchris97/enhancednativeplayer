#!/bin/sh
# Uploads the FFmpeg frameworks in Frameworks/ (from scripts/build-ffmpeg.sh) as a draft
# GitHub release, and writes the release's URL and checksums into Package.swift.
#
#     scripts/release-ffmpeg.sh <tag>        e.g. scripts/release-ffmpeg.sh ffmpeg-8.1.3-1
#
# The upload goes through the gh CLI as whoever is signed in to it (`gh auth login`, or
# GH_TOKEN), to the repository below. Anyone without write access there is turned away by
# GitHub; a fork that wants its own binaries changes REPO. Building never needs this script.
#
# The release stays a draft, so nothing is public until it is published on GitHub. Package.swift
# keeps using the local frameworks while they are in Frameworks/; remove them to try the release.
set -eu

REPO=chafinchris97/enhancednativeplayer
FRAMEWORKS="EPLibavutil EPLibswresample EPLibavcodec EPLibavformat"

TAG=${1:?usage: scripts/release-ffmpeg.sh <tag>}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/.build/ffmpeg-release/$TAG"
command -v gh >/dev/null || { echo "needs the gh CLI (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in; run gh auth login" >&2; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
	echo "$REPO already has a release $TAG; pick a new tag" >&2
	exit 1
fi

for name in $FRAMEWORKS; do
	[ -d "$ROOT/Frameworks/$name.xcframework" ] \
		|| { echo "Frameworks/$name.xcframework is missing; run scripts/build-ffmpeg.sh" >&2; exit 1; }
done

# ditto keeps the symlinks inside the macOS frameworks, which a plain zip would flatten.
rm -rf "$OUT"
mkdir -p "$OUT"
for name in $FRAMEWORKS; do
	(cd "$ROOT/Frameworks" && ditto -c -k --sequesterRsrc --keepParent "$name.xcframework" "$OUT/$name.xcframework.zip")
done

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
	"$ROOT/Frameworks/EPLibavutil.xcframework/macos-arm64_x86_64/EPLibavutil.framework/Resources/Info.plist")
notes="FFmpeg $version built by scripts/build-ffmpeg.sh with the patches in scripts/patches/ffmpeg.

FFmpeg is LGPL-2.1-or-later; its source is at https://ffmpeg.org/releases/ffmpeg-$version.tar.xz."
gh release create "$TAG" --repo "$REPO" --draft --title "$TAG" --notes "$notes" "$OUT"/*.zip

# The block between the FFMPEG_RELEASE markers in Package.swift.
block="$OUT/block.swift"
{
	echo "// FFMPEG_RELEASE_BEGIN"
	echo "let ffmpegRelease = \"https://github.com/$REPO/releases/download/$TAG\""
	echo "let ffmpegChecksums = ["
	for name in $FRAMEWORKS; do
		echo "    \"$name\": \"$(swift package --package-path "$ROOT" compute-checksum "$OUT/$name.xcframework.zip")\","
	done
	echo "]"
	echo "// FFMPEG_RELEASE_END"
} >"$block"
awk -v block="$block" '
	/^\/\/ FFMPEG_RELEASE_BEGIN$/ { while ((getline line < block) > 0) print line; skip = 1; next }
	/^\/\/ FFMPEG_RELEASE_END$/ { skip = 0; next }
	!skip { print }
' "$ROOT/Package.swift" >"$OUT/Package.swift"
mv "$OUT/Package.swift" "$ROOT/Package.swift"

echo "uploaded draft release $TAG to $REPO and wrote it into Package.swift"
echo "publish it at https://github.com/$REPO/releases, then commit Package.swift"
