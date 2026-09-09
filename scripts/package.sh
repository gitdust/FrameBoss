#!/usr/bin/env bash
#
# scripts/package.sh
#
# Build a CurseForge-ready release zip for FrameBoss.
#
# CurseForge (manual upload at curseforge.com) requires the zip to contain
# a top-level folder named exactly like the addon, e.g.:
#
#   FrameBoss/
#   ├── FrameBoss.toc
#   ├── Core.lua
#   ├── Auras.lua
#   ├── Options.lua
#   ├── Locales/
#   ├── Libs/
#   └── Media/
#
# The version is the ## Version: line in FrameBoss.toc (the single source of
# truth — CurseForge and the in-game addon list both read it) and the output
# is written to dist/FrameBoss-<version>.zip. Dev-only files (.git, docs,
# scripts, .superpowers, .DS_Store, ...) are never copied — the payload is
# an explicit allowlist matching the TOC file list.
#
# Usage:
#   scripts/package.sh            # build with the version currently in the TOC
#   scripts/package.sh 1.0.1      # bump ## Version: to 1.0.1 in the TOC, then build

set -euo pipefail

# --- paths ------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ADDON_NAME="FrameBoss"
TOC="$ROOT/$ADDON_NAME.toc"
DIST_DIR="$ROOT/dist"

# --- version ----------------------------------------------------------------

# Optional CLI arg: bump the TOC's ## Version: before packaging so the zip
# filename, the TOC, and the in-game version can never drift apart.
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    NEW_VERSION="$1"
    # Accept 1.2.3 plus an optional -beta / -rc.1 style suffix; reject anything
    # that is unsafe in a filename or empty.
    if ! [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$ ]]; then
        echo "ERROR: invalid version '$NEW_VERSION' (expected e.g. 1.0.1 or 1.0.1-rc.1)" >&2
        exit 1
    fi
    TMP_TOC="$(mktemp)"
    awk -v v="$NEW_VERSION" '
        BEGIN { updated = 0 }
        /^## Version:/ && !updated { print "## Version: " v; updated = 1; next }
        { print }
        END { if (!updated) exit 2 }
    ' "$TOC" > "$TMP_TOC" || { rm -f "$TMP_TOC"; echo "ERROR: no ## Version: line found in $TOC" >&2; exit 1; }
    mv "$TMP_TOC" "$TOC"
    echo "Bumped ## Version: -> $NEW_VERSION in $ADDON_NAME.toc"
fi

VERSION="$(awk -F': ' '/^## Version:/ { print $2; exit }' "$TOC" | tr -d '[:space:]')"
if [[ -z "$VERSION" ]]; then
    echo "ERROR: could not read ## Version: from $TOC" >&2
    exit 1
fi

OUT_ZIP="$DIST_DIR/$ADDON_NAME-$VERSION.zip"

# --- files shipped in the zip (allowlist, must match the TOC load list) -----

PAYLOAD_FILES=(
    "$ADDON_NAME.toc"
    "Core.lua"
    "Auras.lua"
    "Options.lua"
)
PAYLOAD_DIRS=(
    "Locales"
    "Libs"
    "Media"
)

# --- sanity checks ----------------------------------------------------------

for item in "${PAYLOAD_FILES[@]}" "${PAYLOAD_DIRS[@]}"; do
    if [[ ! -e "$ROOT/$item" ]]; then
        echo "ERROR: expected payload path missing: $item" >&2
        exit 1
    fi
done

if ! command -v zip >/dev/null 2>&1; then
    echo "ERROR: 'zip' not found (ships with macOS at /usr/bin/zip)." >&2
    exit 1
fi

# --- staging ----------------------------------------------------------------

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

TARGET="$STAGE/$ADDON_NAME"
mkdir -p "$TARGET"

for f in "${PAYLOAD_FILES[@]}"; do
    cp "$ROOT/$f" "$TARGET/"
done
for d in "${PAYLOAD_DIRS[@]}"; do
    cp -R "$ROOT/$d" "$TARGET/"
done

# Strip macOS / editor junk from the staged copy.
find "$STAGE" \( -name '.DS_Store' -o -name '*.swp' -o -name '__MACOSX' \) -delete

# --- zip ---------------------------------------------------------------------

mkdir -p "$DIST_DIR"
rm -f "$OUT_ZIP"

# -r recursive, -q quiet, -X strip extra attributes (avoids __MACOSX noise).
( cd "$STAGE" && zip -rqX "$OUT_ZIP" "$ADDON_NAME" )

# --- report ------------------------------------------------------------------

echo "Built: $OUT_ZIP"
echo ""
echo "Archive contents:"
unzip -l "$OUT_ZIP" | sed 's/^/  /'
