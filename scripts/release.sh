#!/bin/sh
# Makes a draft GitHub release of the package: every framework in Frameworks/ (from
# scripts/build-ffmpeg.sh and scripts/build-libass.sh) zipped and attached, and the release's
# URL and checksums written into Package.swift.
#
#     scripts/release.sh <version>        e.g. scripts/release.sh 0.1.0
#
# The upload goes through the gh CLI as whoever is signed in to it (`gh auth login`, or
# GH_TOKEN), to the repository below. Anyone without write access there is turned away by
# GitHub; a fork that wants its own binaries changes REPO. Building never needs this script.
#
# The release stays a draft, so nothing is public until it is published. Commit and push the
# Package.swift this writes, then publish the draft with that commit as its target, so the tag
# names the code that points at these binaries. Package.swift keeps using the local frameworks
# while they are in Frameworks/; remove them to try the release.
set -eu

REPO=chafinchris97/enhancednativeplayer
FRAMEWORKS="EPLibavutil EPLibswresample EPLibavcodec EPLibavformat EPLibass"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${1:?usage: scripts/release.sh <version>}
OUT="$ROOT/.build/release/$VERSION"

# The pinned version of a source in a build script, e.g. pinned build-libass.sh FRIBIDI.
pinned() { sed -n "s/^$2=//p" "$ROOT/scripts/$1"; }

command -v gh >/dev/null || { echo "needs the gh CLI (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in; run gh auth login" >&2; exit 1; }
if gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1; then
	echo "$REPO already has a release $VERSION; pick a new version" >&2
	exit 1
fi
for name in $FRAMEWORKS; do
	[ -d "$ROOT/Frameworks/$name.xcframework" ] \
		|| { echo "Frameworks/$name.xcframework is missing; run scripts/build-ffmpeg.sh and scripts/build-libass.sh" >&2; exit 1; }
done

ffmpeg=$(pinned build-ffmpeg.sh FFMPEG)
fribidi=$(pinned build-libass.sh FRIBIDI)
notes="Prebuilt frameworks:

- EPLibavutil, EPLibswresample, EPLibavcodec, EPLibavformat: FFmpeg $ffmpeg with dav1d $(pinned build-ffmpeg.sh DAV1D) in EPLibavcodec, built by scripts/build-ffmpeg.sh with the patches in scripts/patches/ffmpeg.
- EPLibass: libass $(pinned build-libass.sh LIBASS) with FreeType $(pinned build-libass.sh FREETYPE), FriBidi $fribidi and HarfBuzz $(pinned build-libass.sh HARFBUZZ), built by scripts/build-libass.sh.

All are dynamic frameworks. FFmpeg and FriBidi are LGPL-2.1-or-later: their source is https://ffmpeg.org/releases/ffmpeg-$ffmpeg.tar.xz and https://github.com/fribidi/fribidi/releases/tag/v$fribidi, and this tag's scripts/ rebuild the frameworks from it. dav1d is BSD-2-Clause, libass ISC, FreeType FTL, HarfBuzz MIT; the texts are in LICENSES/."

# ditto keeps the symlinks inside macOS frameworks, which a plain zip would flatten.
rm -rf "$OUT"
mkdir -p "$OUT"
for name in $FRAMEWORKS; do
	(cd "$ROOT/Frameworks" && ditto -c -k --sequesterRsrc --keepParent "$name.xcframework" "$OUT/$name.xcframework.zip")
done
gh release create "$VERSION" --repo "$REPO" --draft --title "$VERSION" --notes "$notes" "$OUT"/*.zip

# The block between the BINARIES_RELEASE markers in Package.swift.
block="$OUT/block.swift"
{
	echo "// BINARIES_RELEASE_BEGIN"
	echo "let binariesRelease = \"https://github.com/$REPO/releases/download/$VERSION\""
	echo "let binaryChecksums = ["
	for name in $FRAMEWORKS; do
		echo "    \"$name\": \"$(swift package --package-path "$ROOT" compute-checksum "$OUT/$name.xcframework.zip")\","
	done
	echo "]"
	echo "// BINARIES_RELEASE_END"
} >"$block"
awk -v block="$block" '
	$0 == "// BINARIES_RELEASE_BEGIN" { while ((getline line < block) > 0) print line; skip = 1; next }
	$0 == "// BINARIES_RELEASE_END" { skip = 0; next }
	!skip { print }
' "$ROOT/Package.swift" >"$OUT/Package.swift"
mv "$OUT/Package.swift" "$ROOT/Package.swift"

echo "uploaded draft release $VERSION to $REPO and wrote it into Package.swift"
echo "commit and push Package.swift, then publish the draft with that commit as its target"
