#!/usr/bin/env sh
# Stage the built dwdiff into a self-contained dist archive. Linux + macOS.
#   TARGET    e.g. x86_64-linux-musl | aarch64-linux-musl | aarch64-macos
#   BUILD_DIR (default $ROOT/build)
#   DWDIFF_SRC (default $ROOT/upstream/dwdiff — for the man page)
#   DIST      (default $ROOT/dist)
#
# Stage layout inside dist/dwdiff-$TARGET/:
#   bin/dwdiff       (the CLI binary, +x)
#   bin/dwfilter     (the post-processor launcher, +x)
#   man/man1/dwdiff.1 (the man page, source roff)
#   README.md        (link to ljh-sh/dwdiff)
#
# Output: dist/dwdiff-$TARGET.tar.gz + .sha256 (basename-keyed for portability).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DWDIFF_SRC="${DWDIFF_SRC:-$ROOT/upstream/dwdiff}"
DIST="${DIST:-$ROOT/dist}"
TARGET="${TARGET:?set TARGET, e.g. x86_64-linux-musl}"

ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
DWDIFF_BIN="$(ext_for "$BUILD_DIR/dwdiff/dwdiff")"
DWFILTER_BIN="$(ext_for "$BUILD_DIR/dwdiff/dwfilter")"
[ -x "$DWDIFF_BIN" ] || { echo "error: $DWDIFF_BIN not built" >&2; exit 1; }
# dwfilter is optional; some configs don't build it.
DWFILTER_OK=0
if [ -x "$DWFILTER_BIN" ]; then DWFILTER_OK=1; fi

# Man page lives under upstream/dwdiff/doc/. Different from the wdiff
# layout which uses man/ — dwdiff keeps docs in doc/.
DWDIFF_MAN_SRC="$DWDIFF_SRC/man/dwdiff.1"
DWFILTER_MAN_SRC="$DWDIFF_SRC/man/dwfilter.1"

STAGE="$DIST/dwdiff-$TARGET"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/man/man1"

cp "$DWDIFF_BIN" "$STAGE/bin/dwdiff"
chmod +x "$STAGE/bin/dwdiff"
if [ "$DWFILTER_OK" = 1 ]; then
	cp "$DWFILTER_BIN" "$STAGE/bin/dwfilter"
	chmod +x "$STAGE/bin/dwfilter"
fi

# Man pages — ship if upstream has them.
[ -f "$DWDIFF_MAN_SRC" ]   && cp "$DWDIFF_MAN_SRC"   "$STAGE/man/man1/dwdiff.1"
[ -f "$DWFILTER_MAN_SRC" ] && [ "$DWFILTER_OK" = 1 ] && cp "$DWFILTER_MAN_SRC" "$STAGE/man/man1/dwfilter.1"

# A tiny README so the archive is self-explanatory.
cat > "$STAGE/README.md" <<'EOF'
# dwdiff — single-binary release

Self-contained archive from https://github.com/ljh-sh/dwdiff (release tag).
The wrapper LICENSE (MIT) and NOTICE (GPL-3.0 + ICU license attribution)
live there.

The `dwdiff` binary is statically linked against `libicuuc` +
`libicudata` from ICU 78.3 (vendored under `upstream/icu/` in the
source repo). The runtime binary has no system ICU dependency
and no `LD_LIBRARY_PATH` requirement.

Install (optional, manual):

    sudo install -m 0755 bin/dwdiff /usr/local/bin/
    sudo install -m 0644 man/man1/dwdiff.1 /usr/local/share/man/man1/

Then:  man dwdiff
       dwdiff --version     # → dwdiff 2.1.4
EOF

# Tar archive — keyed basename so downstream users can verify from any cwd.
ARCHIVE="$DIST/dwdiff-$TARGET.tar.gz"
( cd "$DIST" && tar czf "$ARCHIVE" "$(basename "$STAGE")" )

# SHA256 — basename-only so `sha256sum -c FILE.sha256` works from any
# cwd. Prefer coreutils sha256sum, then macOS shasum, then OpenSSL.
if   command -v sha256sum >/dev/null 2>&1; then
	HASH_CMD='sha256sum'
elif command -v shasum     >/dev/null 2>&1; then
	HASH_CMD='shasum -a 256'
else
	HASH_CMD='openssl dgst -sha256 -r'
fi
( cd "$DIST" && $HASH_CMD "dwdiff-$TARGET.tar.gz" \
	| awk '{printf "%s  dwdiff-'"$TARGET"'.tar.gz\n", $1}' ) > "$ARCHIVE.sha256"

echo "==> $ARCHIVE"
echo "==> $ARCHIVE.sha256"
