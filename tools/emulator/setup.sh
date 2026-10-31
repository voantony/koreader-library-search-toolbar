#!/usr/bin/env bash
# Download and cache the official KOReader Linux x86_64 release.
# Prints the install prefix on stdout. Does not put the binary in the repo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=config.sh
. "$HERE/config.sh"

mkdir -p "$KOREADER_CACHE_ROOT"
archive="$KOREADER_CACHE_ROOT/$KOREADER_ASSET"
prefix="$KOREADER_PREFIX"

verify() {
    echo "${KOREADER_SHA256}  ${archive}" | sha256sum -c -
}

if [[ ! -f "$archive" ]]; then
    echo "downloading ${KOREADER_URL}" >&2
    tmp="${archive}.partial"
    curl -fL --retry 3 --retry-delay 2 -o "$tmp" "$KOREADER_URL"
    mv "$tmp" "$archive"
fi
verify >&2

if [[ ! -x "$prefix/bin/koreader" || ! -f "$prefix/lib/koreader/reader.lua" ]]; then
    echo "extracting into ${prefix}" >&2
    rm -rf "$prefix"
    mkdir -p "$prefix"
    tar -xJf "$archive" -C "$prefix"
fi

if [[ ! -x "$prefix/bin/koreader" ]]; then
    echo "setup: ${prefix}/bin/koreader is missing after extract" >&2
    exit 1
fi

echo "$prefix"
