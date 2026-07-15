#!/usr/bin/env pwsh
# Stage the built dwdiff into a self-contained dist archive. Windows.
#   TARGET    e.g. x86_64-windows
#   BUILD_DIR (default $PSScriptRoot/..\build)
#   DIST      (default $PSScriptRoot/..\dist)
#
# Stage layout inside dist\dwdiff-$TARGET\:
#   bin\dwdiff.exe     (the CLI binary)
#   bin\dwfilter.exe   (the post-processor launcher)
#   man\man1\dwdiff.1  (the dwdiff man page, source roff)
#   man\man1\dwfilter.1 (the dwfilter man page, source roff)
#   README.md          (link to ljh-sh/dwdiff)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ROOT = (Resolve-Path "$PSScriptRoot/..").Path
$BUILD_DIR = if ($env:BUILD_DIR) { $env:BUILD_DIR } else { "$ROOT\build" }
$DIST = if ($env:DIST) { $env:DIST } else { "$ROOT\dist" }
$TARGET = if ($env:TARGET) { $env:TARGET } else { throw "set TARGET, e.g. x86_64-windows" }

$DWDIFF_BIN  = "$BUILD_DIR\dwdiff\dwdiff.exe"
$DWFILTER_BIN = "$BUILD_DIR\dwdiff\dwfilter.exe"
if (-not (Test-Path $DWDIFF_BIN))  { throw "error: $DWDIFF_BIN not built" }

$DWDIFF_MAN_SRC  = "$ROOT\upstream\dwdiff\man\dwdiff.1"
$DWFILTER_MAN_SRC = "$ROOT\upstream\dwdiff\man\dwfilter.1"

$STAGE = "$DIST\dwdiff-$TARGET"
if (Test-Path $STAGE) { Remove-Item -Recurse -Force $STAGE }
New-Item -ItemType Directory -Force -Path "$STAGE\bin" | Out-Null
New-Item -ItemType Directory -Force -Path "$STAGE\man\man1" | Out-Null

Copy-Item $DWDIFF_BIN "$STAGE\bin\dwdiff.exe"
if (Test-Path $DWFILTER_BIN) { Copy-Item $DWFILTER_BIN "$STAGE\bin\dwfilter.exe" }

if (Test-Path $DWDIFF_MAN_SRC)   { Copy-Item $DWDIFF_MAN_SRC   "$STAGE\man\man1\dwdiff.1" }
if (Test-Path $DWFILTER_MAN_SRC) { Copy-Item $DWFILTER_MAN_SRC "$STAGE\man\man1\dwfilter.1" }

# Tiny README so the archive is self-explanatory.
$readme = @"
# dwdiff — single-binary release (Windows)

Self-contained archive from https://github.com/ljh-sh/dwdiff (release tag).
The wrapper LICENSE (MIT) and NOTICE (GPL-3.0 + ICU license attribution)
live there.

`dwdiff` is statically linked against `libicuuc` + `libicudata` from
ICU 78.3 (vendored under `upstream/icu/` in the source repo). The
runtime binary has no system ICU dependency and no PATH
requirement for ICU.

Install (optional, manual):

    # In an elevated PowerShell:
    Copy-Item bin\dwdiff.exe, bin\dwfilter.exe C:\Windows\System32\

Then:

    PS> dwdiff --version
    dwdiff 2.1.4
"@
Set-Content -Path "$STAGE\README.md" -Value $readme

$ARCHIVE = "$DIST\dwdiff-$TARGET.zip"
if (Test-Path $ARCHIVE) { Remove-Item -Force $ARCHIVE }
Compress-Archive -Path "$STAGE" -DestinationPath $ARCHIVE

Write-Host "==> $ARCHIVE"
