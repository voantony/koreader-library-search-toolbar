# Shared pins for the headless KOReader used by tools/emulator.
# Sourced by setup.sh and shoot.sh. The binary stays in the cache, not in git.

KOREADER_VERSION=v2026.07.1
KOREADER_ASSET="koreader-linux-x86_64-${KOREADER_VERSION}.tar.xz"
# sha256 published on the GitHub release asset for this exact tarball.
KOREADER_SHA256=299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0
KOREADER_URL="https://github.com/koreader/koreader/releases/download/${KOREADER_VERSION}/${KOREADER_ASSET}"

KOREADER_CACHE_ROOT="${KOREADER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/koreader-library-gui}"
KOREADER_PREFIX="${KOREADER_CACHE_ROOT}/${KOREADER_VERSION}"

# Kindle Colorsoft. Override with EMU_W / EMU_H / EMU_DPI.
EMU_W="${EMU_W:-1264}"
EMU_H="${EMU_H:-1680}"
EMU_DPI="${EMU_DPI:-300}"
