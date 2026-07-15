#!/usr/bin/env bash
# Build + run the dwdiff + wdiff fuzz harnesses.
#
# Requires:
#   - clang (with libFuzzer support — comes with Homebrew llvm)
#   - the dwdiff / wdiff source vendored under upstream/ (with
#     their CFLAGS instrumented for ASan + UBSan + fuzzer-no-link)
#
# Usage:
#   bash fuzz/build.sh                      # build both harnesses
#   bash fuzz/build.sh dwdiff                # build only dwdiff harness
#   FUZZ_TIME=60 bash fuzz/build.sh run     # build + run for 60s
#
# The build step is the slow part (~30s for dwdiff because of ICU,
# ~5s for wdiff). The run step uses libFuzzer's default coverage-
# guided mode against /tmp/{dwdiff,wdiff}-corpus.
#
# In CI, this would be a scheduled workflow that uploads the
# coverage report + any crashes to a fuzzer-tracker; for v0.2.0
# we ship the harness + build script and let the local dev run it.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DWDIFF_SRC="$ROOT/upstream/dwdiff"
WDIFF_SRC="$ROOT/upstream/wdiff"
ICU_BUILD="$ROOT/build/icu-fuzz"
WDIFF_BUILD="$ROOT/build/wdiff-fuzz"
DWDIFF_BUILD="$ROOT/build/dwdiff-fuzz"
mkdir -p "$ICU_BUILD" "$WDIFF_BUILD" "$DWDIFF_BUILD"

CLANG="${CLANG:-clang}"
FUZZ_CFLAGS="-O1 -g -fsanitize=address,undefined,fuzzer-no-link"
FUZZ_LDFLAGS="-fsanitize=address,undefined,fuzzer"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.nproc 2>/dev/null || echo 4)"

# ---------------------------------------------------------------------
# 1. Build a fuzz-friendly ICU (static, minimal)
# ---------------------------------------------------------------------
build_icu() {
	if [ ! -f "$ICU_BUILD/lib/libicuuc.a" ]; then
		echo "==> ICU configure (fuzz-friendly)"
		( cd "$ICU_BUILD" && \
			sh "$ROOT/upstream/icu/source/runConfigureICU" \
				Linux \
				--enable-static \
				--disable-shared \
				--disable-icuio --disable-icusnfp \
				--disable-icuscriptbreaks --disable-extras \
				--disable-samples --disable-tests \
				CC="$CLANG" \
				CXX="$CLANG++" \
				CFLAGS="$FUZZ_CFLAGS" \
				CXXFLAGS="$FUZZ_CFLAGS" )
		echo "==> ICU make -j$JOBS (slow, ~10 min)"
		( cd "$ICU_BUILD" && make -j"$JOBS" )
	fi
}

# ---------------------------------------------------------------------
# 2. Build dwdiff with sanitizer instrumentation
# ---------------------------------------------------------------------
build_dwdiff() {
	build_icu

	if [ ! -f "$DWDIFF_BUILD/dwdiff-fuzz.o" ]; then
		echo "==> dwdiff: clean + in-source configure (sanitizers)"
		( cd "$DWDIFF_SRC" && [ -f Makefile ] && make distclean >/dev/null 2>&1 ) || true
		( cd "$DWDIFF_SRC" && \
			CC="$CLANG" \
			CXX="$CLANG++" \
			CFLAGS="$FUZZ_CFLAGS" \
			CXXFLAGS="$FUZZ_CFLAGS" \
			./configure --prefix=/usr/local --without-gettext )

		# dwdiff's Makefile picks up ICUFLAGS + ICULIBS from
		# pkg-config. We need a shim that points at our fuzz
		# ICU build.
		ICU_PC="$DWDIFF_BUILD/icu-uc.pc"
		mkdir -p "$DWDIFF_BUILD"
		cat > "$ICU_PC" <<EOF
prefix=$ICU_BUILD
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=$ROOT/upstream/icu/source/common
unicode_includedir=$ROOT/upstream/icu/source/common/unicode
i18n_includedir=$ROOT/upstream/icu/source/i18n

Name: ICU
Description: International Components for Unicode (fuzz build)
Version: 78.3
Libs: -L\${libdir} -licuuc -licudata -lstdc++
Cflags: -I\${includedir} -I\${unicode_includedir} -I\${i18n_includedir}
EOF
		export PKG_CONFIG_PATH="$DWDIFF_BUILD:${PKG_CONFIG_PATH:-}"

		echo "==> dwdiff: make -j$JOBS"
		( cd "$DWDIFF_SRC" && make -j"$JOBS" )
		# Save the instrumented objects so we can link the harness
		# against them without re-building dwdiff from scratch.
		mkdir -p "$DWDIFF_BUILD"
		cp -a "$DWDIFF_SRC/src" "$DWDIFF_BUILD/src"
		cp -a "$DWDIFF_SRC/.config.c" "$DWDIFF_BUILD/" 2>/dev/null || true
	fi

	# Link the fuzzer harness.
	$CLANG $FUZZ_CFLAGS -I"$DWDIFF_SRC" \
		-fno-omit-frame-pointer \
		-c "$ROOT/fuzz/fuzz_dwdiff.c" -o "$DWDIFF_BUILD/fuzz_dwdiff.o"
	$CLANG $FUZZ_LDFLAGS \
		"$DWDIFF_BUILD/fuzz_dwdiff.o" \
		$(find "$DWDIFF_BUILD/src" -name '*.o' | tr '\n' ' ') \
		-L"$ICU_BUILD/lib" -licuuc -licudata -lstdc++ \
		-o "$ROOT/fuzz/dwdiff_fuzz"
	echo "==> built $ROOT/fuzz/dwdiff_fuzz"
}

# ---------------------------------------------------------------------
# 3. Build wdiff with sanitizer instrumentation
# ---------------------------------------------------------------------
build_wdiff() {
	if [ ! -f "$WDIFF_BUILD/src/wdiff.o" ]; then
		echo "==> wdiff: distclean + autoreconf + configure (sanitizers)"
		( cd "$WDIFF_SRC" && [ -f Makefile ] && make distclean >/dev/null 2>&1 ) || true
		( cd "$WDIFF_SRC" && autoreconf -if --force )
		mkdir -p "$WDIFF_BUILD"
		( cd "$WDIFF_BUILD" && "$WDIFF_SRC/configure" \
			--srcdir="$WDIFF_SRC" \
			--disable-dependency-tracking \
			--disable-silent-rules \
			--disable-shared \
			--enable-static \
			CC="$CLANG" \
			CFLAGS="$FUZZ_CFLAGS" )
		echo "==> wdiff: make -j$JOBS"
		( cd "$WDIFF_BUILD" && make -j"$JOBS" )
	fi

	# Build the diffutils sub-project (wdiff shells out to diff)
	# ... or just stub: wdiff requires a `diff` binary; for the
	# fuzzer we set $PATH to point at the host /usr/bin/diff.
	# This means the fuzzer exercises wdiff's tokenizer + output
	# formatting but NOT the diff algorithm itself. That's
	# intentional — diffutils has its own upstream fuzz harness
	# (fuzzers/ in the GNU diffutils repo).

	# Link the fuzzer harness.
	$CLANG $FUZZ_CFLAGS -I"$WDIFF_SRC" -I"$WDIFF_SRC/lib" \
		-fno-omit-frame-pointer \
		-c "$ROOT/fuzz/fuzz_wdiff.c" -o "$WDIFF_BUILD/fuzz_wdiff.o"
	$CLANG $FUZZ_LDFLAGS \
		"$WDIFF_BUILD/fuzz_wdiff.o" \
		$(find "$WDIFF_BUILD/src" -name '*.o' | tr '\n' ' ') \
		-lintl \
		-o "$ROOT/fuzz/wdiff_fuzz"
	echo "==> built $ROOT/fuzz/wdiff_fuzz"
}

case "${1:-all}" in
	all)        build_dwdiff; build_wdiff ;;
	dwdiff)     build_dwdiff ;;
	wdiff)      build_wdiff ;;
	run)
		# Build first, then run.
		build_dwdiff
		build_wdiff
		mkdir -p /tmp/dwdiff-corpus /tmp/wdiff-corpus
		# Default 60s, override with FUZZ_TIME.
		TIME="${FUZZ_TIME:-60}"
		echo "==> fuzzing dwdiff for ${TIME}s"
		timeout "${TIME}" "$ROOT/fuzz/dwdiff_fuzz" /tmp/dwdiff-corpus -max_len=65536 -jobs="$(echo $JOBS/2 | bc)" || true
		echo "==> fuzzing wdiff for ${TIME}s"
		timeout "${TIME}" "$ROOT/fuzz/wdiff_fuzz" /tmp/wdiff-corpus -max_len=65536 -jobs="$(echo $JOBS/2 | bc)" || true
		;;
	*) echo "usage: $0 {all|dwdiff|wdiff|run}"; exit 1 ;;
esac
