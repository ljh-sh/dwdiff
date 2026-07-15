#!/usr/bin/env sh
# Build dwdiff as a static, self-contained binary. Linux gnu + macOS + MinGW.
# dwdiff needs libicuuc + libicudata for Unicode-aware word segmentation,
# so this script first builds a static ICU from upstream/icu/, then
# runs dwdiff's custom `./configure` + make. dwdiff's Makefile is plain
# POSIX (not autotools), so the build is straightforward.
#
# ICU is slow to build (~10 min on a 4-core CI runner). We use
# --disable-icuio --disable-icusnfp --disable-icuscriptbreaks --disable-extras
# to keep the static lib under 30 MB.
#
# Out-of-tree build into BUILD_DIR (default ./build).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DWDIFF_SRC="${DWDIFF_SRC:-$ROOT/upstream/dwdiff}"
ICU_SRC="${ICU_SRC:-$ROOT/upstream/icu/source}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

[ -f "$DWDIFF_SRC/configure" ] \
	|| { echo "error: $DWDIFF_SRC/configure not found" >&2; exit 1; }
[ -f "$ICU_SRC/runConfigureICU" ] \
	|| { echo "error: $ICU_SRC/runConfigureICU not found" >&2; exit 1; }
command -v make >/dev/null 2>&1 \
	|| { echo "error: make not found in PATH" >&2; exit 1; }

JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.nproc 2>/dev/null || echo 4)"

# Cross-compile: DWDIFF_TARGET_ARCH + DWDIFF_TARGET_OS, etc.
HOST_ARCH="$(uname -m 2>/dev/null || echo unknown)"
TARGET_ARCH="${DWDIFF_TARGET_ARCH:-$HOST_ARCH}"
TRIPLET="${DWDIFF_TRIPLET:-}"
if [ -n "${DWDIFF_TARGET_OS:-}" ]; then
	TRIPLET="${TRIPLET:-${DWDIFF_TARGET_ARCH}-${DWDIFF_TARGET_OS}}"
fi
if [ "$TARGET_ARCH" != "$HOST_ARCH" ] || [ -n "${DWDIFF_TARGET_OS:-}" ]; then
	[ -z "$TRIPLET" ] && TRIPLET="$TARGET_ARCH"
	case "${DWDIFF_OS_HINT:-}" in
	darwin)
		export CC=clang
		export CXX=clang++
		# dwdiff's Makefile uses `pkg-config --cflags icu-uc` via
		# backticks in the compile rule; quoting parens like
		# `-D__has_c_attribute(x)=0` breaks the backtick command.
		# dwdiff 2.1.4 doesn't use the C23 attribute pattern
		# (only diffutils 3.10 does), so we leave the define off
		# for the dwdiff sub-build.
		export CFLAGS="-arch $TARGET_ARCH -O2 -std=gnu11"
		export CXXFLAGS="-arch $TARGET_ARCH -O2 -std=gnu++17"
		export LDFLAGS="-arch $TARGET_ARCH"
		;;
	windows)
		export CC="${TARGET_ARCH}-w64-mingw32-gcc"
		export CXX="${TARGET_ARCH}-w64-mingw32-g++"
		export AR="${TARGET_ARCH}-w64-mingw32-ar"
		export RANLIB="${TARGET_ARCH}-w64-mingw32-ranlib"
		export CFLAGS="-O2 -std=gnu11"
		export CXXFLAGS="-O2 -std=gnu++17"
		export LIBS="-lbcrypt -lws2_32"
		;;
	*)
		export CC=clang
		export CXX=clang++
		export CFLAGS="-arch $TARGET_ARCH -O2 -std=gnu11"
		export CXXFLAGS="-arch $TARGET_ARCH -O2 -std=gnu++17"
		export LDFLAGS="-arch $TARGET_ARCH"
		;;
	esac
	echo "==> cross-compile: host=$HOST_ARCH → target=$TARGET_ARCH ($TRIPLET)"
else
	# Host build (no cross).
	export CFLAGS="${CFLAGS:-} -O2 -std=gnu11"
	export CXX="${CXX:-clang++}"
	export CXXFLAGS="${CXXFLAGS:-} -O2 -std=gnu++17"
fi

# ----------------------------------------------------------------------
# Sub-build 1: ICU (out-of-tree, static, minimal)
# ----------------------------------------------------------------------
ICU_BUILD="$BUILD_DIR/icu"
mkdir -p "$ICU_BUILD"

echo "==> ICU configure (out-of-tree: $ICU_BUILD)"
# CXXFLAGS=-Wno-error tells the macOS clang to NOT treat the
# ICU 78.3 C++ warnings as errors. Same fix as the Alpine
# build — see comment in scripts/build-alpine.sh. We export
# CXXFLAGS into the subshell so it applies to BOTH the
# runConfigureICU invocation AND the subsequent make.
( cd "$ICU_BUILD" && \
	export CXXFLAGS="-Wno-error -Wno-error=deprecated-declarations -Wno-error=unused-but-set-variable" && \
	sh "$ICU_SRC/runConfigureICU" \
		Linux \
		--enable-static \
		--disable-shared \
		--disable-icuio \
		--disable-icusnfp \
		--disable-icuscriptbreaks \
		--disable-extras \
		--disable-samples \
		--disable-tests && \
	make -j"$JOBS" )

echo "==> ICU make complete"

[ -f "$ICU_BUILD/lib/libicuuc.a" ] \
	|| { echo "error: libicuuc.a not built" >&2; exit 1; }
[ -f "$ICU_BUILD/lib/libicudata.a" ] \
	|| { echo "error: libicudata.a not built" >&2; exit 1; }

# dwdiff uses pkg-config to find libicu. Build a shim .pc file so
# dwdiff's configure picks up our static ICU. ICU's `make` doesn't
# install headers by default; we point the .pc Cflags at the
# vendored upstream ICU source headers directly.
ICU_PKGCONFIG_DIR="$BUILD_DIR/pkgconfig"
mkdir -p "$ICU_PKGCONFIG_DIR"
cat > "$ICU_PKGCONFIG_DIR/icu-uc.pc" <<EOF
prefix=$ICU_BUILD
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=$ICU_SRC/common
unicode_includedir=$ICU_SRC/common/unicode
i18n_includedir=$ICU_SRC/i18n

Name: ICU
Description: International Components for Unicode (vendored static build)
Version: 78.3
Libs: -L\${libdir} -licuuc -licudata -lstdc++
Cflags: -I\${includedir} -I\${unicode_includedir} -I\${i18n_includedir}
EOF
export PKG_CONFIG_PATH="$ICU_PKGCONFIG_DIR:${PKG_CONFIG_PATH:-}"

# ----------------------------------------------------------------------
# Sub-build 2: dwdiff (POSIX make)
# ----------------------------------------------------------------------
DWDIFF_BUILD="$BUILD_DIR/dwdiff"
mkdir -p "$DWDIFF_BUILD"

# dwdiff's custom configure + Makefile is **in-source only** —
# it expects `config.pkg`, `Makefile.in`, and the `src/` tree to all
# be in the same directory. The configure script also writes back
# `config.pkg` and a `Makefile` in the source directory, so we have
# to build in-source. The `upstream/dwdiff/.gitignore` (we add one
# to the dist repo, not the vendored upstream) excludes the build
# artefacts.
#
# Why we tolerate in-source: dwdiff's build is small (~3s once
# the upstream `config.pkg` is sourced), and the dwdiff source
# tree is clean enough that an in-source build doesn't touch the
# C files. We `make distclean` after the build to restore the tree.
echo "==> configure dwdiff (in-source: $DWDIFF_SRC)"
# `--without-gettext` is needed because macOS doesn't ship GNU
# gettext by default (gettext is in /opt/homebrew but not in the
# default search path). The CI Linux runners do have gettext, but
# using `--without-gettext` keeps the build script portable.
( cd "$DWDIFF_SRC" && ./configure --prefix=/usr/local --without-gettext )

# dwdiff's Makefile.in declares `all: dwdiff ... linguas` and
# `linguas: cd po && $(MAKE) "LINGUAS=$(LINGUAS)" linguas`. When
# --without-gettext is set, the po/ sub-Makefile doesn't have a
# `linguas` target, and make aborts. Two-line patch:
#   1. the root Makefile's `linguas:` rule is replaced with a
#      no-op so the root make doesn't even try to recurse into po/
#   2. the `install:` rule's cd po && make line is also commented
#      out, for the same reason.
# The Dutch translations in po/ are not required for the dist.
echo "==> patch Makefile: no-op linguas + install-po (no gettext)"
( cd "$DWDIFF_SRC" && \
  sed -i.bak \
    -e 's|^linguas:$|linguas: ;|' \
    -e '/cd po && \$(MAKE) "LINGUAS=/d' \
    -e '/cd po && \$(MAKE) "LOCALEDIR=/d' \
    Makefile && \
  rm -f Makefile.bak )

echo "==> make dwdiff -j$JOBS"
( cd "$DWDIFF_SRC" && make -j"$JOBS" )

# Copy the freshly-built binaries to the build dir so package.sh
# (and downstream consumers) can find them in a stable location.
mkdir -p "$DWDIFF_BUILD"
ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
cp "$(ext_for "$DWDIFF_SRC/dwdiff")"   "$DWDIFF_BUILD/dwdiff"
cp "$(ext_for "$DWDIFF_SRC/dwfilter")" "$DWDIFF_BUILD/dwfilter" 2>/dev/null || true

# Restore the source tree to a clean state.
( cd "$DWDIFF_SRC" && [ -f Makefile ] && make distclean >/dev/null 2>&1 ) || true

ext_for() { [ -f "$1.exe" ] && printf '%s.exe' "$1" || printf '%s' "$1"; }
DWDIFF_BIN="$(ext_for "$DWDIFF_BUILD/dwdiff")"
DWFILTER_BIN="$(ext_for "$DWDIFF_BUILD/dwfilter")"
[ -x "$DWDIFF_BIN" ] || { echo "error: $DWDIFF_BIN not built" >&2; exit 1; }

echo "==> built:"
ls -l "$DWDIFF_BIN" 2>/dev/null || true
[ -x "$DWFILTER_BIN" ] && ls -l "$DWFILTER_BIN"
