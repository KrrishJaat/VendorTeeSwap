#!/usr/bin/env bash
#
#  Copyright (c) 2026 Krrish Jaat
#  Licensed under the MIT License. See LICENSE file for details.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
#
#  TEE Changer — orchestrator
#  ---------------------------------------------------------------------------
#  Takes an arbitrary Port ROM ZIP + a Samsung stock (model, CSC, IMEI), and
#  replaces vendor/tee inside the Port ROM with the freshly downloaded stock
#  vendor/tee. Everything else in the Port ROM ZIP (META-INF, updater-script,
#  signing, other partitions) is left byte-identical.
#
#  This script does NOT reimplement firmware handling. It sources every
#  existing library under scripts/**/*.sh (same convention as build.sh) and
#  calls the functions that already do this work:
#    - DOWNLOAD_FW / FETCH_FW      (scripts/utils/download_utils.sh)
#    - EXTRACT_FIRMWARE            (scripts/unpack_fw.sh)
#    - UNPACK_PARTITION            (scripts/unpack_fw.sh)
#    - DETECT_FILESYSTEM           (scripts/unpack_fw.sh)
#    - SPARSE_TO_RAW               (scripts/unpack_fw.sh)
#    - REMOVE / ADD_FROM_FW        (scripts/utils/file_utils.sh)
#    - REPACK_PARTITION            (scripts/build_images.sh)
#    - LOG_* / ERROR_EXIT / RUN_CMD/ CHECK_DEPENDENCY (scripts/main/logs.sh, scripts/setup_env.sh)
#
#  New, minimal, clearly-scoped helpers live alongside this file:
#    - unpack_port_zip.sh   : opens an arbitrary Port ROM ZIP, locates its
#                              vendor image (standalone or inside super.img)
#    - repack_super_and_zip.sh : rebuilds super.img (only if the Port ROM used
#                              one) and updates the ORIGINAL zip in place
#    - upload_gofile.sh     : GoFile upload, lifted out of build-rom.yml so
#                              it's reusable/testable on its own
#

set -o pipefail

# ---------------------------------------------------------------------------
# Globals — mirrors the layout build.sh sets up, WITHOUT touching the
# device/objective/platform build pipeline (this module never calls
# _BUILD_ROM, SETUP_DEVICE_ENV, or the apktool/smali patch stages).
# ---------------------------------------------------------------------------
RECOREUI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export RECOREUI

# NOTE: scripts/utils/download_utils.sh and scripts/kitchen/make_zip.sh
# reference $ASTROROM instead of $RECOREUI (a leftover from before this repo
# was renamed). Rather than editing those shared files, we alias the
# variable here so FETCH_FW's firmware cache path resolves correctly. This
# is the only compensation this module makes for that pre-existing mismatch.
export ASTROROM="$RECOREUI"

PREBUILTS="$RECOREUI/prebuilts"
WORKDIR="$RECOREUI/firmware/unpacked"
DIROUT="$RECOREUI/out"
TEE_SWAP_TMP="$RECOREUI/tmp_tee_swap"
export PREBUILTS WORKDIR DIROUT TEE_SWAP_TMP

shopt -s globstar
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
for UTIL in "$RECOREUI"/scripts/**/*.sh; do
    [[ -f "$UTIL" ]] || continue
    # This script itself matches scripts/**/*.sh — skip it, it's not a
    # pure function library like every other file in this loop, it's the
    # entry point currently running.
    [[ "$(readlink -f "$UTIL")" == "$SELF" ]] && continue
    # TEE-swap scripts are executable entry points/helpers, not part of the
    # ReCoreUI library environment. Some (notably selftest.sh) execute work
    # at source time, so never source anything from scripts/tee_swap here.
    [[ "$UTIL" == "$RECOREUI"/scripts/tee_swap/*.sh ]] && continue
    # Defensive: some checkouts/zip exports of this repo carry CRLF line
    # endings, which makes `source` fail outright on any function
    # declaration line. Strip CR at source-time only — no files on disk
    # are modified. No-op for already-LF files (including this module's own).
    source <(tr -d '\r' < "$UTIL")
done

# TEE-swap-only helpers are intentionally excluded from the generic library
# sourcing above. Source the Google Drive downloader explicitly so its
# DOWNLOAD_FROM_GDRIVE function is available to the orchestrator.
source "$RECOREUI/scripts/tee_swap/download_gdrive.sh"

# USE_THREADS() lives inside build.sh itself (not under scripts/), and we
# deliberately do not source build.sh here (it ends with an unconditional
# call to _BUILD_ROM, which would try to run a full device build). This is
# the same 6-line calculation duplicated locally.
CPU_CORES="$(nproc)"
TOTAL_MEM_GB="$(free -g | awk '/^Mem:/{print $2}')"
USABLE_THREADS="$(( CPU_CORES > TOTAL_MEM_GB / 2 ? (TOTAL_MEM_GB / 2) : CPU_CORES ))"
(( USABLE_THREADS < 1 )) && USABLE_THREADS=1
export USABLE_THREADS

# ---------------------------------------------------------------------------
# Required inputs (set by the workflow / caller as environment variables)
# ---------------------------------------------------------------------------
PORT_ROM_GDRIVE="${PORT_ROM_GDRIVE:?PORT_ROM_GDRIVE is required}"
STOCK_MODEL="${STOCK_MODEL:?STOCK_MODEL is required}"
STOCK_CSC="${STOCK_CSC:?STOCK_CSC is required}"
STOCK_IMEI="${STOCK_IMEI:?STOCK_IMEI is required}"
export STOCK_MODEL STOCK_CSC STOCK_IMEI

[[ $EUID -ne 0 ]] && ERROR_EXIT "Root required (image mounting needs it, same as build.sh)"

LOG_BEGIN "TEE Changer"
LOG_INFO "Port ROM:    Google Drive ($PORT_ROM_GDRIVE)"
LOG_INFO "Stock model: $STOCK_MODEL ($STOCK_CSC)"

# ---------------------------------------------------------------------------
# 0. Dependencies
#    CHECK_ALL_DEPENDENCIES (setup_env.sh) installs the full device-build
#    toolchain (Java, python, ffmpeg, android-sdk-build-tools, ...), almost
#    none of which this module needs. We call the same underlying
#    CHECK_DEPENDENCY function (reused) with only the packages this module
#    actually touches.
# ---------------------------------------------------------------------------
LOG_BEGIN "Checking dependencies"
DETECTED_DISTRO_TYPE="$(GET_DISTRO_TYPE)"
[[ "$DETECTED_DISTRO_TYPE" == "unknown" ]] && ERROR_EXIT "Unsupported operating system."
[[ "$DETECTED_DISTRO_TYPE" == "debian" ]] && sudo apt-get update &>/dev/null
for PKG in "p7zip-full:7zip" "lz4:lz4" "attr:xattr" "zip:zip" "unzip:unzip" "rsync:rsync"; do
    IFS=":" read -r PKG_NAME PKG_DESC <<< "$PKG"
    CHECK_DEPENDENCY "$PKG_NAME" "$PKG_DESC" true
done
chmod +x -R "$PREBUILTS"
LOG_END "Dependencies OK"

rm -rf "$TEE_SWAP_TMP" && mkdir -p "$TEE_SWAP_TMP" "$WORKDIR" "$DIROUT"

# ---------------------------------------------------------------------------
# 1. Download the Port ROM ZIP from Google Drive
# ---------------------------------------------------------------------------
PORT_DOWNLOAD_DIR="$TEE_SWAP_TMP/port_download"
mkdir -p "$PORT_DOWNLOAD_DIR"
LOG_BEGIN "Downloading Port ROM from Google Drive"
PORT_ZIP="$(DOWNLOAD_FROM_GDRIVE "$PORT_ROM_GDRIVE" "$PORT_DOWNLOAD_DIR")" \
    || ERROR_EXIT "Port ROM Google Drive download failed"
[[ -f "$PORT_ZIP" ]] || ERROR_EXIT "Port ROM download did not produce a ZIP"
PORT_ROM_NAME="$(basename "$PORT_ZIP")"
export PORT_ROM_NAME
LOG_INFO "Port ROM filename: $PORT_ROM_NAME"
LOG_END "Port ROM downloaded ($(du -h "$PORT_ZIP" | cut -f1))"

# ---------------------------------------------------------------------------
# 2. Download the latest stock firmware (reused: DOWNLOAD_FW -> FETCH_FW,
#    which itself calls the existing prebuilts/samfirm/samfirm.js downloader)
# ---------------------------------------------------------------------------
LOG_BEGIN "Downloading latest stock firmware"
DOWNLOAD_FW "stock" || ERROR_EXIT "Stock firmware download failed"
LOG_END "Stock firmware download complete"

# ---------------------------------------------------------------------------
# 3+4. Extract & unpack the STOCK firmware (reused: EXTRACT_FIRMWARE, which
#    internally calls SPARSE_TO_RAW + lpunpack + UNPACK_PARTITION for every
#    partition, including vendor)
# ---------------------------------------------------------------------------
LOG_BEGIN "Unpacking stock firmware"
EXTRACT_FIRMWARE "$STOCK_MODEL" "$STOCK_CSC" "stock" || ERROR_EXIT "Stock vendor unpack failed"
[[ -d "$WORKDIR/$STOCK_MODEL/vendor" ]] || ERROR_EXIT "Stock vendor.img not found after extraction"
[[ -d "$WORKDIR/$STOCK_MODEL/vendor/tee" ]] || ERROR_EXIT "vendor/tee missing in stock firmware"
LOG_END "Stock vendor unpacked"

# ---------------------------------------------------------------------------
# 5. Unpack the Port ROM's vendor image (new: unpack_port_zip.sh, which
#    itself calls the same reused SPARSE_TO_RAW / DETECT_FILESYSTEM /
#    UNPACK_PARTITION functions used above)
# ---------------------------------------------------------------------------
LOG_BEGIN "Unpacking Port ROM vendor"
UNPACK_PORT_VENDOR "$PORT_ZIP" "$TEE_SWAP_TMP" || ERROR_EXIT "Port vendor unpack failed"
# UNPACK_PORT_VENDOR sets: WORKSPACE, PORT_VENDOR_FS, PORT_VENDOR_SOURCE,
# PORT_VENDOR_ZIP_PATH, PORT_EXTRACT_DIR (see unpack_port_zip.sh)
[[ -d "$WORKSPACE/vendor" ]] || ERROR_EXIT "Port vendor.img not found in Port ROM"
[[ -d "$WORKSPACE/vendor/tee" ]] || ERROR_EXIT "vendor/tee missing in Port ROM vendor image"
LOG_END "Port ROM vendor unpacked (source: $PORT_VENDOR_SOURCE, fs: $PORT_VENDOR_FS)"

# ---------------------------------------------------------------------------
# 6+7. Swap vendor/tee (reused verbatim: REMOVE + ADD_FROM_FW). These read
#    and write via $WORKSPACE / GET_PARTITION_PATH, which we've pointed at
#    the Port ROM's unpacked vendor directory above — this is the exact same
#    call pattern already used in objectives/m35x/vendor-patches/patches.sh.
# ---------------------------------------------------------------------------
LOG_BEGIN "Replacing vendor/tee"
REMOVE "vendor" "tee" || ERROR_EXIT "Failed to delete Port ROM vendor/tee"
ADD_FROM_FW "stock" "vendor" "tee" || ERROR_EXIT "Failed to copy stock vendor/tee"
[[ -d "$WORKSPACE/vendor/tee" ]] || ERROR_EXIT "vendor/tee copy did not complete"
LOG_END "vendor/tee replaced"

# ---------------------------------------------------------------------------
# 8. Repack the vendor partition (reused verbatim: REPACK_PARTITION)
# ---------------------------------------------------------------------------
LOG_BEGIN "Repacking vendor image"
REPACK_PARTITION "vendor" "$PORT_VENDOR_FS" "$TEE_SWAP_TMP" "$WORKSPACE" \
    || ERROR_EXIT "Vendor repack failed"
[[ -f "$TEE_SWAP_TMP/vendor.img" ]] || ERROR_EXIT "Repacked vendor.img missing"
LOG_END "Vendor image repacked"

# ---------------------------------------------------------------------------
# 9. Rebuild the Port ROM ZIP — only vendor (or super.img, if the Port ROM
#    used dynamic partitions) is touched. META-INF, updater-script, other
#    partitions, permissions, symlinks and compression are untouched.
#    (new: repack_super_and_zip.sh)
# ---------------------------------------------------------------------------
LOG_BEGIN "Rebuilding Port ROM ZIP"
REINSERT_VENDOR_IMAGE "$TEE_SWAP_TMP/vendor.img" || ERROR_EXIT "ROM rebuild failed"
LOG_END "Port ROM ZIP updated in place"

# ---------------------------------------------------------------------------
# 10. Place final ZIP using the EXACT original Port ROM filename.
# ---------------------------------------------------------------------------
FINAL_NAME="$PORT_ROM_NAME"
FINAL_ZIP="$DIROUT/$FINAL_NAME"
[[ -n "${FINAL_ZIP_STAGE:-}" && -f "$FINAL_ZIP_STAGE" ]] \
    || ERROR_EXIT "Final ZIP stage was not created"
mkdir -p "$DIROUT"
mv -f "$FINAL_ZIP_STAGE" "$FINAL_ZIP" \
    || ERROR_EXIT "Failed to place final ZIP at $FINAL_ZIP"
LOG_INFO "Final ZIP: $FINAL_ZIP ($(du -h "$FINAL_ZIP" | cut -f1))"

echo "final_zip_path=$FINAL_ZIP" >> "${GITHUB_OUTPUT:-/dev/null}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 12. Clean up temporary files — keep only the final ZIP (+ logs)
# ---------------------------------------------------------------------------
rm -rf "$TEE_SWAP_TMP" "$WORKDIR"

LOG_END "TEE Changer finished" "Output: $FINAL_ZIP"