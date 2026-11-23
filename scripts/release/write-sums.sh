#!/usr/bin/env bash
# write-sums.sh — write SHA256SUMS over the files in a directory (docs/release.md, "The publish workflow").
#
# Usage: write-sums.sh <dir>
#
# SHA256SUMS lists every regular file of <dir> by name, in byte order, except itself and the signature
# bundles (*.sigstore.json), which are made from it afterwards. It is always rewritten, so a repository
# that built its own sums and one that did not end up with the same file. Fails when there is nothing to
# list: a release with no files is a mistake.

set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: write-sums.sh <dir>" >&2
	exit 2
fi
dir=$1
if [ ! -d "$dir" ]; then
	echo "write-sums: $dir is not a directory" >&2
	exit 1
fi

cd "$dir"
files=$(find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name '*.sigstore.json' -printf '%f\n' | LC_ALL=C sort)
if [ -z "$files" ]; then
	echo "write-sums: no files in $dir to sum" >&2
	exit 1
fi
printf '%s\n' "$files" | xargs -d '\n' sha256sum -- >SHA256SUMS.new
mv SHA256SUMS.new SHA256SUMS
echo "write-sums: $(wc -l <SHA256SUMS) files in $dir/SHA256SUMS"
