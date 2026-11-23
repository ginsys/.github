#!/usr/bin/env bash
# check-dist.sh — check the archives a Go build left in a directory (docs/release.md, "The Go build workflow").
#
# Usage: check-dist.sh <dir> <tag>
#
# <dir> must hold at least one archive (*.tar.gz or *.zip), and every archive's name must contain the
# version, which is the tag without its leading v. A name that does not carry the version means the
# GoReleaser snapshot template of the caller is not stamped with the tag, and the release would publish
# files that say nothing about which release they belong to. Other files in <dir> are not checked.

set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "usage: check-dist.sh <dir> <tag>" >&2
	exit 2
fi
dir=$1
tag=$2
if ! [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
	echo "check-dist: '$tag' is not a version tag (vMAJOR.MINOR.PATCH, optionally with a pre-release part)" >&2
	exit 2
fi
version=${tag#v}
if [ ! -d "$dir" ]; then
	echo "check-dist: $dir is not a directory" >&2
	exit 1
fi

found=0
wrong=()
for f in "$dir"/*.tar.gz "$dir"/*.zip; do
	[ -f "$f" ] || continue
	found=$((found + 1))
	name=${f##*/}
	[[ $name == *"$version"* ]] || wrong+=("$name")
done
if [ "$found" -eq 0 ]; then
	echo "check-dist: no archive (*.tar.gz or *.zip) in $dir" >&2
	exit 1
fi
if [ "${#wrong[@]}" -gt 0 ]; then
	echo "check-dist: these archives do not carry the version $version in their name:" >&2
	printf '  %s\n' "${wrong[@]}" >&2
	exit 1
fi
echo "check-dist: $found archives in $dir, each named for $version"
