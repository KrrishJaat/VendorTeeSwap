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
#  Unlike scripts/unpack_fw.sh (which only understands Samsung's
#  AP/BL/CP/CSC.tar.md5 stock-firmware layout), a Port ROM ZIP is a normal
#  flashable ZIP the user already has (META-INF/com/google/android/, an
#  updater-script, and either a standalone vendor.img or a dynamic
#  super.img at/near the root — the same shape scripts/kitchen/make_zip.sh
#  itself produces). This file only figures out WHERE the vendor image is;
#  every actual extraction step below calls the same functions already used
#  for stock firmware (SPARSE_TO_RAW, DETECT_FILESYSTEM, UNPACK_PARTITION).
#

# [
GET_SUPER_METADATA()
{
    # Mirrors the lpdump-parsing block inside EXTRACT_FIRMWARE
    # (scripts/unpack_fw.sh). Not exposed there as a standalone function,
    # so it's factored out here for reuse by the super.img rebuild step.
    local SUPER_IMG="$1"
    local LPDUMP_OUT
    LPDUMP_OUT=$("$PREBUILTS/android-tools/lpdump" "$SUPER_IMG" 2>&1) \
        || { ERROR_EXIT "Failed to read super.img metadata from Port ROM"; return 1; }

    PORT_SUPER_SIZE=$(echo "$LPDUMP_OUT" | awk '/Partition name: super/,/Flags:/ {if ($1 == "Size:") {print $2; exit}}')
    PORT_METADATA_SIZE=$(echo "$LPDUMP_OUT" | awk '/Metadata max size:/ {print $4}')
    PORT_METADATA_SLOTS=$(echo "$LPDUMP_OUT" | awk '/Metadata slot count:/ {print $4}')
    read -r PORT_GROUP_NAME PORT_GROUP_SIZE <<< "$(echo "$LPDUMP_OUT" | awk '
        /Group table:/ {in_table=1}
        in_table && /Name:/ {name=$2}
        in_table && /Maximum size:/ {size=$3; if(size+0 > 0){print name, size; exit}}
    ')"

    [[ -z "$PORT_SUPER_SIZE" || -z "$PORT_GROUP_NAME" ]] \
        && { ERROR_EXIT "Could not parse super.img metadata from Port ROM"; return 1; }

    export PORT_SUPER_SIZE PORT_METADATA_SIZE PORT_METADATA_SLOTS PORT_GROUP_NAME PORT_GROUP_SIZE
}

UNPACK_PORT_VENDOR()
{
    local PORT_ZIP="$1"
    local TMP_DIR="$2"

    PORT_EXTRACT_DIR="$TMP_DIR/port_extracted"
    rm -rf "$PORT_EXTRACT_DIR" && mkdir -p "$PORT_EXTRACT_DIR"

    RUN_CMD "Extracting Port ROM ZIP" \
        "unzip -q -o '$PORT_ZIP' -d '$PORT_EXTRACT_DIR'"
    [[ -d "$PORT_EXTRACT_DIR/META-INF" ]] \
        || LOG_WARN "META-INF not found in Port ROM ZIP — is this really a flashable ZIP?"

    local STANDALONE_VENDOR
    STANDALONE_VENDOR=$(find "$PORT_EXTRACT_DIR" -maxdepth 3 -type f \( -name "vendor.img" -o -name "vendor_a.img" \) | head -1)

    local PORT_MODEL_TAG="PORT_VENDOR"
    local PORT_VENDOR_IMG="$TMP_DIR/vendor.img"

    # UNPACK_PARTITION (scripts/unpack_fw.sh) assumes unpack.conf already
    # exists under $WORKDIR/$MODEL_NAME/ — normally created by
    # EXTRACT_FIRMWARE before it's called. We're calling UNPACK_PARTITION
    # directly (there's no AP.tar.md5 for an arbitrary Port ROM ZIP), so we
    # create the same minimal marker file ourselves.
    mkdir -p "$WORKDIR/$PORT_MODEL_TAG"
    echo 'PARTITIONS=""' > "$WORKDIR/$PORT_MODEL_TAG/unpack.conf"

    if [[ -n "$STANDALONE_VENDOR" ]]; then
        PORT_VENDOR_SOURCE="standalone"
        PORT_VENDOR_ZIP_PATH="${STANDALONE_VENDOR#$PORT_EXTRACT_DIR/}"
        cp -f "$STANDALONE_VENDOR" "$PORT_VENDOR_IMG"
    else
        local SUPER_IMG
        SUPER_IMG=$(find "$PORT_EXTRACT_DIR" -maxdepth 3 -type f -name "super.img" | head -1)
        [[ -z "$SUPER_IMG" ]] && { ERROR_EXIT "vendor.img not found in Port ROM (no standalone vendor.img or super.img)"; return 1; }

        PORT_VENDOR_SOURCE="super"
        PORT_VENDOR_ZIP_PATH="${SUPER_IMG#$PORT_EXTRACT_DIR/}"
        PORT_SUPER_IMG_PATH="$SUPER_IMG"

        SPARSE_TO_RAW "$SUPER_IMG" || { ERROR_EXIT "Sparse conversion failed for Port ROM super.img"; return 1; }
        GET_SUPER_METADATA "$SUPER_IMG" || return 1

        PORT_SUPER_LPUNPACK_DIR="$TMP_DIR/port_super_unpacked"
        rm -rf "$PORT_SUPER_LPUNPACK_DIR" && mkdir -p "$PORT_SUPER_LPUNPACK_DIR"
        RUN_CMD "Extracting partitions from Port ROM super.img" \
            "\"$PREBUILTS/android-tools/lpunpack\" \"$SUPER_IMG\" \"$PORT_SUPER_LPUNPACK_DIR/\""

        # Drop empty B slots, same convention as scripts/unpack_fw.sh
        find "$PORT_SUPER_LPUNPACK_DIR" -maxdepth 1 -type f -name "*_b.img" -delete

        local FOUND_VENDOR
        FOUND_VENDOR=$(find "$PORT_SUPER_LPUNPACK_DIR" -maxdepth 1 -type f \( -name "vendor.img" -o -name "vendor_a.img" \) | head -1)
        [[ -z "$FOUND_VENDOR" ]] && { ERROR_EXIT "vendor.img not found inside Port ROM super.img"; return 1; }
        cp -f "$FOUND_VENDOR" "$PORT_VENDOR_IMG"

        export PORT_SUPER_LPUNPACK_DIR PORT_SUPER_IMG_PATH
    fi

    SPARSE_TO_RAW "$PORT_VENDOR_IMG" || { ERROR_EXIT "Sparse conversion failed for Port ROM vendor.img"; return 1; }
    PORT_VENDOR_FS=$(DETECT_FILESYSTEM "$PORT_VENDOR_IMG")
    [[ "$PORT_VENDOR_FS" == "unknown" ]] && { ERROR_EXIT "Could not detect filesystem of Port ROM vendor.img"; return 1; }

    UNPACK_PARTITION "$PORT_VENDOR_IMG" "$PORT_MODEL_TAG" || return 1

    # Point the reused REMOVE / ADD_FROM_FW / GET_PARTITION_PATH functions
    # (scripts/utils/file_utils.sh, scripts/main/make_workspace.sh) at the
    # Port ROM's unpacked vendor directory, exactly like the layered build
    # pipeline points them at $RECOREUI/workspace.
    WORKSPACE="$WORKDIR/$PORT_MODEL_TAG"

    export WORKSPACE PORT_VENDOR_FS PORT_VENDOR_SOURCE PORT_VENDOR_ZIP_PATH PORT_EXTRACT_DIR

    # The original archive is intentionally removed after successful extraction.
    # Repackaging later creates a fresh ZIP with the same original filename.
    rm -f -- "$PORT_ZIP" || { ERROR_EXIT "Failed to delete extracted Port ROM ZIP"; return 1; }
    [[ ! -e "$PORT_ZIP" ]] || { ERROR_EXIT "Old Port ROM ZIP still exists after extraction"; return 1; }
}
# ]
