#!/usr/bin/env sh
# Build dwdiff as a true musl-static binary inside an Alpine container.
# dwdiff needs libicuuc + libicudata; we build ICU first (out-of-tree)
# and then dwdiff (POSIX make, with pkg-config finding the static ICU).
set -eu

echo "==> apk add: build deps (musl-native toolchain + ICU build deps)"
# `g++` is needed for ICU's C++ build. `texinfo` is needed by
# diffutils' autotools info-target even though we don't ship the
# diffutils doc.
apk add --no-cache \
	build-base \
	autoconf \
	automake \
	libtool \
	g++ \
	linux-headers \
	texinfo \
	bash

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"

# ----------------------------------------------------------------------
# Sub-build 1: ICU (musl-static, no shared libs, minimal components)
# ----------------------------------------------------------------------
ICU_BUILD="$BUILD_DIR/icu"
mkdir -p "$ICU_BUILD"

echo "==> ICU configure (musl-static + minimal)"
# CXXFLAGS=-Wno-error tells the musl gcc-13 to NOT treat the
# ICU 78.3 C++ warnings as errors. The warnings come from
# chnsecal.cpp, olsontz.cpp, parse.cpp — all of which are
# upstream ICU code that was clean on older gcc but trips
# newer musl gcc's stricter warning checks. The C++ source
# itself is correct; only the warning->error promotion breaks
# the build. Downgrading to ICU 76.1 would also work but
# costs us security patches.
( cd "$ICU_BUILD" && \
	CXXFLAGS="-Wno-error -Wno-error=deprecated-declarations -Wno-error=unused-but-set-variable" \
	sh "$ROOT/upstream/icu/source/runConfigureICU" \
		Linux \
		--enable-static \
		--disable-shared \
		--disable-icuio \
		--disable-icusnfp \
		--disable-icuscriptbreaks \
		--disable-extras \
		--disable-samples \
		--disable-tests )

echo "==> ICU make -j$(getconf _NPROCESSORS_ONLN) (slow, ~15 min)"
( cd "$ICU_BUILD" && make -j"$(getconf _NPROCESSORS_ONLN)" )

[ -f "$ICU_BUILD/lib/libicuuc.a" ] \
	|| { echo "error: libicuuc.a not built" >&2; exit 1; }
[ -f "$ICU_BUILD/lib/libicudata.a" ] \
	|| { echo "error: libicudata.a not built" >&2; exit 1; }

# ----------------------------------------------------------------------
# Sub-build 2: dwdiff (POSIX make, with bundled static ICU)
# ----------------------------------------------------------------------
ICU_PKGCONFIG_DIR="$BUILD_DIR/pkgconfig"
mkdir -p "$ICU_PKGCONFIG_DIR"
cat > "$ICU_PKGCONFIG_DIR/icu-uc.pc" <<EOF
prefix=$ICU_BUILD
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: ICU
Description: International Components for Unicode (vendored static build)
Version: 78.3
Libs: -L\${libdir} -licuuc -licudata -lstdc++
Cflags: -I\${includedir}
EOF
export PKG_CONFIG_PATH="$ICU_PKGCONFIG_DIR"

DWDIFF_BUILD="$BUILD_DIR/dwdiff"
mkdir -p "$DWDIFF_BUILD"

# dwdiff's custom configure is IN-SOURCE: it expects to find
# `./config.pkg` in its CWD. We copy config.pkg to the build dir
# to keep the upstream/ tree clean.
cp "$ROOT/upstream/dwdiff/config.pkg" "$DWDIFF_BUILD/config.pkg"

echo "==> configure dwdiff (musl-static + bundled ICU)"
( cd "$DWDIFF_BUILD" && "$ROOT/upstream/dwdiff/configure" --prefix=/usr/local )

echo "==> make dwdiff -j$(getconf _NPROCESSORS_ONLN)"
( cd "$DWDIFF_BUILD" && \
	make -j"$(getconf _NPROCESSORS_ONLN)" srcdir="$ROOT/upstream/dwdiff" )

DWDIFF_BIN="$DWDIFF_BUILD/dwdiff"
DWFILTER_BIN="$DWDIFF_BUILD/dwfilter"
[ -x "$DWDIFF_BIN" ] || { echo "error: $DWDIFF_BIN not built" >&2; exit 1; }

echo "==> built:"
ls -l "$DWDIFF_BIN" 2>/dev/null || true
[ -x "$DWFILTER_BIN" ] && ls -l "$DWFILTER_BIN"
