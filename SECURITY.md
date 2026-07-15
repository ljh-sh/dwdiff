# Security Policy

## Supported versions

| version | supported          | status                                          |
|---------|--------------------|-------------------------------------------------|
| v0.1.x  | :white_check_mark: | current — vendored dwdiff 2.1.4 + libicu 78.3   |
| older   | :x:                | please upgrade to v0.1.1 or newer               |

Each release is a vendored snapshot of upstream `dwdiff 2.1.4` and
`ICU 78.3`. We re-vendor on every upstream security release and
bump the patch number. The build process is reproducible within a
single CI run (same toolchain, same source); bit-for-bit
cross-host reproducibility is a v0.2.0 follow-up.

## Reporting a vulnerability

Email **lijunhao@x-cmd.com** (GPG: see `cosign.pub` on the latest
release) with:

1. A clear description of the issue
2. A reproducer (input file + observed output)
3. The affected version tag(s)
4. Whether you've disclosed it elsewhere

**We will acknowledge within 72 hours** and provide a fix or
mitigation plan within 14 days for HIGH/CRITICAL findings. We
follow the [disclose.io](https://disclose.io/) coordinated
disclosure model — please give us 90 days before public disclosure.

For issues that turn out to be **upstream** (in dwdiff or ICU
themselves), we will:

1. File an upstream issue (or escalate an existing one)
2. Apply a local patch in `upstream/` with a clear
   `// AUDIT-FIX-N` comment
3. Document the patch in `AUDIT-2026-07-15.md` "Action plan"
4. Cut a v0.x.y release with the fix

## What counts as a vulnerability

A vulnerability is a defect in **our distribution layer** — the
build scripts, the CI, the static linking of ICU, the in-binary
dwdiff + dwfilter pairing. Upstream defects are reported
separately.

| in scope | out of scope |
|---|---|
| Build script producing a non-self-contained binary | Upstream dwdiff 2.1.4 `dwfilter execvp` (audit #1) — documented design, not our layer |
| Cosign signature broken | Upstream dwdiff 2.1.4 C code |
| CI failing to verify ICU linkage | Upstream ICU 78.3 internal bugs |
| dwdiff's `--without-unicode` build still ships (would mean a CI failure) | ICU 78.3 CVE in non-public API we don't use |
| Audit document disagrees with shipped binary | ICU per-cluster allocation patterns (audit #3) — bounded by design |

## Threat model we DO defend against

- Attacker uploads a malicious PR that swaps the dist binary
  → blocked by GitHub branch protection + manual review of
  the build script
- Attacker tampers with a release artifact on GitHub Releases
  → blocked by SHA256SUMS verification + (in v0.2.0) cosign
  keyless signatures
- Attacker controls the host's `libicuuc.so` (e.g. a malicious
  OCI image) → blocked by static linking of ICU 78.3 from the
  vendored source; `otool -L` / `readelf -d` confirm no dynamic
  libicu dependency
- Attacker controls the host's `libc.so` (e.g. hostile
  LD_LIBRARY_PATH) → blocked by musl-static link on Linux;
  dwdiff links only system libc/libSystem on macOS/Windows

## Threat model we do NOT defend against (v0.1.x)

- Attacker compromises `os.ghalkes.nl` (mirror MITM between
  vendor-refresh and the next release)
- Attacker compromises `github.com/unicode-org/icu` (same as
  above; pinned to release-78.3)
- Attacker compromises the GitHub Actions runner
- Attacker uses `dwfilter` on a post-processor they chose
  (this is dwdiff audit #1 — `dwfilter` is a developer tool
  that exec's whatever you pass; the `dwdiff` main binary does
  NOT exec anything)
- dwdiff's temp file in `/tmp` is observed by another local user
  (privacy leak, audit #2 — `mkstemp()` is race-free, so this is
  not code execution; deferred to v0.2.0 patch)

## Acknowledgements

The ICU project is maintained by the Unicode Consortium and IBM.
Thank you to the maintainers of dwdiff (G.P. Halkes) and ICU
for their rapid security response.
