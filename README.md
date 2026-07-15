# dwdiff — self-contained multi-platform builds of dwdiff + libicu

[Vendored](upstream/dwdiff/) [dwdiff 2.1.4](https://os.ghalkes.nl/dwdiff.html)
(G.P. Halkes, GPL-3.0) plus [ICU 78.3](https://icu.unicode.org/)
(bundled, statically linked) with a native per-OS packaging layer
that produces **statically-linked, self-contained** binaries. No
glibc / libicu / libstdc++ to install on the target machine —
just download, extract, run.

This is a **distribution repo** (dwdiff source + vendored ICU +
build/packaging scripts + CI). See [`NOTICE.md`](NOTICE.md) for
upstream license attribution, and [`AUDIT-2026-07-15.md`](AUDIT-2026-07-15.md)
for the source-level security audit (covers **both** vendored
upstreams: dwdiff 2.1.4 AND ICU 78.3).

## Binary

Built into each release archive under `bin/`:

| binary | purpose |
|---|---|
| `dwdiff`  | the word-diff CLI &mdash; compare two files at the **Unicode-aware word level**; CJK segmentation works out of the box |
| `dwfilter` | a post-processor launcher for dwdiff output (e.g. for colourisation pipelines) |

The man page `dwdiff(1)` is shipped under `man/man1/` in the same
archive.

## Install

Every release publishes multi-architecture static binaries. The
fastest cross-platform one-line install uses x-cmd:

```bash
x eget ljh-sh/dwdiff
```

This installs `dwdiff` (and `dwfilter`, plus a man page) to
`~/.local/bin/`. See the `README.md` inside the archive for
manual install instructions.

## Platform matrix

Every release publishes the targets that successfully built.
The full 5-target matrix (linux-musl ×2, macos ×2, windows ×1)
is in `.github/workflows/release.yml`; targets that fail at
build time are **absent from the release** (no half-broken
artefacts). `always()` release policy: if any entry succeeds,
the release fires.

### v0.4.0 matrix status

| target | runner | linkage | v0.4.0? | blocked by |
|---|---|---|---|---|
| `x86_64-linux-musl`  | `ubuntu-latest` + Alpine 3.20 docker | fully static musl (incl. ICU) | ❌ | Same C++ warning issue as before — `CXXFLAGS=-Wno-error` env var is set in build.sh but doesn't propagate to the sub-make that compiles `chnsecal.cpp` / `olsontz.cpp` / `parse.cpp`. Need to post-process the ICU Makefile with `sed` after configure. Deferred to v0.5.0 |
| `aarch64-linux-musl` | `ubuntu-24.04-arm` + Alpine 3.20 docker | fully static musl (incl. ICU) | ❌ | same as x86_64-linux-musl |
| `aarch64-macos`      | `macos-14` | static, system libc/libSystem | ✅ | — |
| `x86_64-macos`       | `macos-14` (cross from aarch64) | static, system libc/libSystem | ❌ | libicutest.a build fails in ICU on the cross-compile; the same `CXXFLAGS` propagation issue as musl. Deferred to v0.5.0 |
| `x86_64-windows`     | `windows-latest` + MSYS2 + mingw64 | fully static (no DLLs) | ❌ | `libsicudt.a` build fails (`Error 127`); the mingw env vars I set in v0.4.0-rc1 didn't fully resolve. Need a real fix in scripts/build.sh's windows case. Deferred to v0.5.0 |

**v0.3.0 → v0.4.0:** **no new targets shipped** (still 1 of 5).
The v0.4.0 attempt exposed that the CXXFLAGS env-var trick
that worked for wdiff (where diffutils' Makefile is small)
doesn't work for dwdiff (where ICU's Makefile is much larger
and has multiple sub-makes that don't inherit the env var).
Documented in v0.5.0 plan below.

**v0.5.0 plan:**

1. **dwdiff linux-musl ×2**: `sed -i 's|$(CXXFLAGS)|$(CXXFLAGS) -Wno-error|' build/icu/*/Makefile`
   immediately after `runConfigureICU` and before `make`. This
   directly patches the Makefile to add `-Wno-error` to CXXFLAGS
   in EVERY C++ compile rule, regardless of subshell env var
   inheritance. (Same fix as #3.)
2. **dwdiff x86_64-windows**: rewrite the windows case in
   `scripts/build.sh` to actually pass
   `CC=x86_64-w64-mingw32-gcc CXX=x86_64-w64-mingw32-g++
   --host=x86_64-w64-mingw32` to `runConfigureICU`. The
   current v0.4.0 attempt had the env vars but the wrong
   `runConfigureICU` host triple.
3. **dwdiff x86_64-macos**: same fix as #1 — `sed` the ICU
   Makefile post-configure.

The current v0.4.0 ships **aarch64-macos** only (1 of 5).
aarch64-windows and additional targets remain deferred.

## Quick check after install

```bash
$ dwdiff --version | head -1
dwdiff 2.1.4

$ printf '今天天气很好\n' > a.txt
$ printf '今天天气不错\n' > b.txt
$ dwdiff -d '，' a.txt b.txt
[-今天天气很好，]{+今天天气不错，}
```

The `[-..-]{+..+}` markers are the **word-level** diff — for
comparison, stock `wdiff` (without ICU) would treat the entire
CJK line as one giant "word" and show it as a single delete+add.
dwdiff's bundled ICU does the Unicode segmentation that
makes this work.

For **character-level** diff (intra-word CJK changes), use
`dwdiff -d '，。'` to add Chinese punctuation as additional
delimiters, or pipe through `wdiff` for a different format.

## Build from source (vendoring update)

This repo ships `upstream/dwdiff/` and `upstream/icu/` as **clean
copies** (no local patches). To refresh:

```bash
# dwdiff
curl -L -o /tmp/dwdiff.tar.bz2 https://os.ghalkes.nl/dist/dwdiff-2.1.4.tar.bz2
rm -rf upstream/dwdiff && tar xjf /tmp/dwdiff.tar.bz2 -C /tmp/ \
  && mv /tmp/dwdiff-2.1.4 upstream/dwdiff

# ICU
curl -L -o /tmp/icu-sources.tgz \
  https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz
rm -rf upstream/icu && tar xzf /tmp/icu-sources.tgz -C /tmp/ \
  && mv /tmp/icu upstream/icu
```

Then run `bash scripts/build.sh && bash scripts/smoke.sh` to
reproduce the CI locally. The ICU build is the slow step
(~10 min) — be patient. For a true musl-static build:

```bash
docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w alpine:3.20 \
    sh -c 'apk add --no-cache bash autoconf automake libtool make g++ \
      linux-headers bash >/dev/null && bash /w/scripts/build-alpine.sh && bash /w/scripts/smoke.sh'
```

## Security

See [`AUDIT-2026-07-15.md`](AUDIT-2026-07-15.md) for the
source-level security audit (covers **both** vendored upstreams:
dwdiff 2.1.4 + ICU 78.3). Two HIGH findings (`dwfilter` execvp
+ `/tmp` hardcoded) are documented; both are accepted risks for
v0.1.0 (the `dwfilter` execvp is its documented design; `/tmp` is
mitigated by modern systemd's per-user tmpfs).

The audit's **CJK acceptance test** is the smoke-test gate for
every release: the build script's CJK round-trip fixture proves
ICU is actually linked in (without ICU, dwdiff's CJK output is
just `[-整行-]{+整行+}` with no intra-line visibility).

## Smoke test policy

CI runs the upstream `make check` regression suite (in
`upstream/dwdiff/tests/`) AND a hand-crafted CJK round-trip
fixture (the CJK acceptance gate from the audit) against the
freshly-built `dwdiff` binary on every push to main and every
PR. A tag push (`v*`) additionally bundles the per-target static
binary as a GitHub Release with `SHA256SUMS`.

The CI does **not** run smoke on Windows-target builds because
the ICU cross-compile for Windows is more involved and the
smoke fixtures are Linux-centric. Linux + macOS build-and-test
fully exercise the regression suite on every PR.
