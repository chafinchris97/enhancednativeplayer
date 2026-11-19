#!/bin/sh
# Uploads one set of frameworks from Frameworks/ as a draft GitHub release, and writes the
# release's URL and checksums into Package.swift.
#
#     scripts/release-binaries.sh ffmpeg <tag>     e.g. ffmpeg-8.1.3-1, from scripts/build-ffmpeg.sh
#     scripts/release-binaries.sh libass <tag>     e.g. libass-0.17.5-1, from scripts/build-libass.sh
#
# The upload goes through the gh CLI as whoever is signed in to it (`gh auth login`, or
# GH_TOKEN), to the repository below. Anyone without write access there is turned away by
# GitHub; a fork that wants its own binaries changes REPO. Building never needs this script.
#
# The release stays a draft, so nothing is public until it is published on GitHub, with the
# commit that has this Package.swift as its target. Package.swift keeps using the local
# frameworks while they are in Frameworks/; remove them to try the release.
set -eu

REPO=chafinchris97/enhancednativeplayer
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SET=${1:?usage: scripts/release-binaries.sh <ffmpeg|libass> <tag>}
TAG=${2:?usage: scripts/release-binaries.sh <ffmpeg|libass> <tag>}

# The pinned version of a source in a build script, e.g. pinned build-libass.sh FRIBIDI.
pinned() { sed -n "s/^$2=//p" "$ROOT/scripts/$1"; }

case $SET in
ffmpeg)
	FRAMEWORKS="EPLibavutil EPLibswresample EPLibavcodec EPLibavformat"
	version=$(pinned build-ffmpeg.sh FFMPEG)
	notes="FFmpeg $version with dav1d $(pinned build-ffmpeg.sh DAV1D), built by scripts/build-ffmpeg.sh with the patches in scripts/patches/ffmpeg.

FFmpeg is LGPL-2.1-or-later; its source is at https://ffmpeg.org/releases/ffmpeg-$version.tar.xz. dav1d is BSD-2-Clause."
	;;
libass)
	FRAMEWORKS="EPLibass"
	fribidi=$(pinned build-libass.sh FRIBIDI)
	notes="libass $(pinned build-libass.sh LIBASS) with FreeType $(pinned build-libass.sh FREETYPE), FriBidi $fribidi and HarfBuzz $(pinned build-libass.sh HARFBUZZ), built by scripts/build-libass.sh.

libass is ISC, FreeType FTL, HarfBuzz MIT. FriBidi is LGPL-2.1-or-later; its source is at https://github.com/fribidi/fribidi/releases/tag/v$fribidi."
	;;
*)
	echo "usage: scripts/release-binaries.sh <ffmpeg|libass> <tag>" >&2
	exit 1
	;;
esac
MARKER=$(echo "$SET" | tr a-z A-Z)_RELEASE
OUT="$ROOT/.build/binary-release/$TAG"

command -v gh >/dev/null || { echo "needs the gh CLI (brew install gh)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh is not signed in; run gh auth login" >&2; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
	echo "$REPO already has a release $TAG; pick a new tag" >&2
	exit 1
fi
for name in $FRAMEWORKS; do
	[ -d "$ROOT/Frameworks/$name.xcframework" ] \
		|| { echo "Frameworks/$name.xcframework is missing; run scripts/build-$SET.sh" >&2; exit 1; }
done
grep -q "^// ${MARKER}_BEGIN$" "$ROOT/Package.swift" \
	|| { echo "Package.swift has no ${MARKER} block" >&2; exit 1; }

# ditto keeps the symlinks inside macOS frameworks, which a plain zip would flatten.
rm -rf "$OUT"
mkdir -p "$OUT"
for name in $FRAMEWORKS; do
	(cd "$ROOT/Frameworks" && ditto -c -k --sequesterRsrc --keepParent "$name.xcframework" "$OUT/$name.xcframework.zip")
done
gh release create "$TAG" --repo "$REPO" --draft --title "$TAG" --notes "$notes" "$OUT"/*.zip

# The block between this set's markers in Package.swift.
block="$OUT/block.swift"
{
	echo "// ${MARKER}_BEGIN"
	echo "let ${SET}Release = \"https://github.com/$REPO/releases/download/$TAG\""
	echo "let ${SET}Checksums = ["
	for name in $FRAMEWORKS; do
		echo "    \"$name\": \"$(swift package --package-path "$ROOT" compute-checksum "$OUT/$name.xcframework.zip")\","
	done
	echo "]"
	echo "// ${MARKER}_END"
} >"$block"
awk -v block="$block" -v begin="// ${MARKER}_BEGIN" -v end="// ${MARKER}_END" '
	$0 == begin { while ((getline line < block) > 0) print line; skip = 1; next }
	$0 == end { skip = 0; next }
	!skip { print }
' "$ROOT/Package.swift" >"$OUT/Package.swift"
mv "$OUT/Package.swift" "$ROOT/Package.swift"

echo "uploaded draft release $TAG to $REPO and wrote it into Package.swift"
echo "commit and push Package.swift, then publish the draft with that commit as its target"
