# NOTICE

This repository (`ljh-sh/dwdiff`) provides self-contained, statically-linked
builds of **dwdiff** (2.1.4) — a Unicode-aware word-level diff tool — and
the build/packaging layer around it. dwdiff depends on **libicu** for
Unicode normalisation and grapheme cluster segmentation, so the repo also
**vendors ICU 78.3** and statically links it into the same archive.

## Wrapper license (this repo's own files)

`scripts/`, `.github/workflows/`, `README.md`, `NOTICE.md`, `AUDIT-2026-07-15.md`,
`.gitignore`, and the top-level `LICENSE` symlink are

    Copyright (c) 2026 Li Junhao
    Licensed under the MIT License — see LICENSE (MIT half).

The top-level `LICENSE` is the GPL-3.0 text — this is the licence
that ships with the dwdiff binary (per upstream). The wrapper code is
MIT; the upstream dwdiff code is GPL-3.0; the upstream ICU code is
under a permissive Unicode-style license (see below). All three are
tracked separately.

## Upstream license (`upstream/dwdiff/` and the `dwdiff` / `dwfilter` artifacts)

`upstream/dwdiff/` is a verbatim copy of
[os.ghalkes.nl/dist/dwdiff-2.1.4.tar.bz2](https://os.ghalkes.nl/dist/dwdiff-2.1.4.tar.bz2)
(dwdiff, by G.P. Halkes <gp.halkes@id.nl>, 2006-2015). Upstream
license is GPL-3.0:

    Copyright (C) 2006-2015 G.P. Halkes
    Licensed under the GNU General Public License, version 3 — see LICENSE.

## Upstream license (`upstream/icu/` and the `libicuuc.a` / `libicudata.a` artifacts)

`upstream/icu/` is a verbatim copy of
[unicode-org/icu release-78.3 sources](https://github.com/unicode-org/icu/releases/tag/release-78.3)
(ICU 78.3, by the Unicode Consortium + IBM + contributors, 1996-2026).
The `libicuuc.a` and `libicudata.a` static libraries built from this
source are linked into the dwdiff binary. ICU's license is a permissive
Unicode-style "no warranty, attribution required" license — see
`upstream/icu/LICENSE`. The relevant paragraph:

    ICU is released under a nonrestrictive open source license that is
    suitable for use in both commercial and non-commercial applications;
    see the LICENSE file in the ICU source distribution for details.

ICU's license is compatible with GPL-3.0 (we ship the dwdiff binary
under GPL-3.0; the ICU license imposes no additional copyleft).

## How vendoring is structured

`upstream/dwdiff/` was created with:

    curl -L -o dwdiff-2.1.4.tar.bz2 https://os.ghalkes.nl/dist/dwdiff-2.1.4.tar.bz2
    tar xjf dwdiff-2.1.4.tar.bz2
    mv dwdiff-2.1.4 upstream/dwdiff

`upstream/icu/` was created with:

    curl -L -o icu4c-78.3-sources.tgz \
      https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz
    tar xzf icu4c-78.3-sources.tgz
    mv icu upstream/icu

Both are clean copies — no local patches.

## ICU build cost

ICU 78.3 takes ~10 minutes to build on a 4-core CI runner and adds
~30 MB to the static binary (libicuuc + libicudata). We disable
optional ICU sub-components (`--disable-icuio --disable-icusnfp
--disable-icuscriptbreaks --disable-extras`) per the audit
recommendation (finding #12 in the private memo, reflowed in
`AUDIT-2026-07-15.md`).

## Why the binary statically links both dwdiff and ICU

`dwdiff` requires `libicuuc` and `libicudata` at runtime. If the
user has no ICU on the system (common on minimal images like
Alpine, Distroless, scratch), the ljh-sh dist binary is useless.
Vendoring ICU 78.3 and statically linking it makes the dist
binary self-contained — no system ICU, no `LD_LIBRARY_PATH`,
no `ICU_DATA` env var. Closes the CJK-targeting use case on
distroless containers.
