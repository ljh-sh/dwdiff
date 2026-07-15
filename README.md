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

Every release builds **5 targets** via GitHub Actions on native
runners. Linux uses **musl-static** (Alpine toolchain) so the
binary runs on Alpine, Debian/Ubuntu, RHEL/Fedora, Arch —
every Linux distro — with zero system-library dependencies;
there is intentionally no separate glibc/dynamic Linux variant.

| target | runner | linkage | archive |
|---|---|---|---|
| `x86_64-linux-musl`  | `ubuntu-latest` + Alpine 3.20 docker | fully static musl | `.tar.gz` |
| `aarch64-linux-musl` | `ubuntu-24.04-arm` + Alpine 3.20 docker | fully static musl | `.tar.gz` |
| `aarch64-macos`      | `macos-14` | static, system libc/libSystem | `.tar.gz` |
| `x86_64-macos`       | `macos-14` (cross from aarch64) | static, system libc/libSystem | `.tar.gz` |
| `x86_64-windows`     | `windows-latest` + MSYS2 + mingw64 | fully static (no DLLs) | `.zip` |

aarch64-windows and additional targets are deferred.

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
