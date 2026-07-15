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
		# ICU's `runConfigureICU Linux` checks for clang++ but
		# mingw64 doesn't ship clang. We pass the mingw GCC as
		# both CC and CXX, and use --host=x86_64-w64-mingw32 so
		# the `Linux` probe goes through the GNU-on-MingW
		# path (which does NOT require clang++).
		export CC="x86_64-w64-mingw32-gcc"
		export CXX="x86_64-w64-mingw32-g++"
		export AR="x86_64-w64-mingw32-ar"
		export RANLIB="x86_64-w64-mingw32-ranlib"
		export CFLAGS="-O2 -std=gnu11"
		export CXXFLAGS="-O2 -std=gnu++17"
		export LIBS="-lbcrypt -lws2_32"
		# For runConfigureICU: this is x86_64-w64-mingw32 (the
		# mingw GCC triplet), and the OS_HINT is "windows" so
		# build.sh picks the windows case.
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
# We pass --host to runConfigureICU for cross-compile (windows
# target uses x86_64-w64-mingw32; everything else is native
# Linux so no --host needed).
ICU_HOST_FLAG=""
if [ "${WDIFF_OS_HINT:-}" = "windows" ] || [ "${DWDIFF_OS_HINT:-}" = "windows" ]; then
	ICU_HOST_FLAG="--host=x86_64-w64-mingw32"
fi
( cd "$ICU_BUILD" && \
	export CXXFLAGS="-Wno-error -Wno-error=deprecated-declarations -Wno-error=unused-but-set-variable" && \
	sh "$ICU_SRC/runConfigureICU" \
		Linux \
		$ICU_HOST_FLAG \
		--enable-static \
		--disable-shared \
		--disable-icuio \
		--disable-icusnfp \
		--disable-icuscriptbreaks \
		--disable-extras \
		--disable-samples \
		--disable-tests )

echo "==> ICU make -j$JOBS (slow, ~10 min on 4-core)"
# Post-process the generated ICU Makefiles to disable -Werror
# and inject -Wno-error into every CXXFLAGS expansion. This is
# the v0.5.0 fix that makes the CXXFLAGS env var actually
# apply to every sub-make. Two strategies:
#
#   1. Blanket -Wno-error after the CXXFLAGS expansion so
#      EVERY compile step (C and C++ alike) ignores warnings.
#      This handles the musl gcc-13 + ICU 78.3 interaction
#      where -Werror is enabled by default.
#   2. Strip any -Werror / -pedantic-errors from the
#      generated Makefile directly (in case ICU's configure
#      detected -pedantic and added -pedantic-errors to the
#      base CXXFLAGS).
( cd "$ICU_BUILD" && \
	find . -name Makefile -o -name Makefile.inc 2>/dev/null | \
		xargs sed -i.bak \
			-e 's|$(CXXFLAGS)|$(CXXFLAGS) -Wno-error -Wno-error=deprecated-declarations -Wno-error=unused-but-set-variable -Wno-error=array-bounds -Wno-error=stringop-overflow -Wno-error=stringop-overread -Wno-error=maybe-uninitialized|g' \
			-e 's|-Werror|-Wno-error|g' \
			-e 's|-pedantic-errors|-Wno-error|g' \
			-e '/^CXXFLAGS/d' && \
	rm -f $(find . -name Makefile.bak -o -name Makefile.inc.bak 2>/dev/null) && \
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
