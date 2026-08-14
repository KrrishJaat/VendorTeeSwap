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
#  scripts/kitchen/make_zip.sh's BUILD_SUPER_IMAGE always rebuilds super.img
#  from scratch out of every freshly-repacked partition for a full device
#  build (reading metadata from $STOCK_MODEL/unpack.conf and $PARTITIONS).
#  That is not what we want here: a Port ROM's super.img must come back out
#  UNCHANGED except for the one partition we actually touched. This file
#  reuses the same lpmake/lpdump binaries and the same metadata-driven
#  --partition/--image argument construction as BUILD_SUPER_IMAGE, just
#  sourced from the Port ROM's own super.img metadata and its own
#  already-extracted (untouched) partition images instead.
#

# [
REBUILD_PORT_SUPER_IMAGE()
{
    local NEW_VENDOR_IMG="$1"
    local OUT_SUPER="$TEE_SWAP_TMP/super.img"

    local ORIG_VENDOR_FILE
    ORIG_VENDOR_FILE=$(find "$PORT_SUPER_LPUNPACK_DIR" -maxdepth 1 -type f \( -name "vendor.img" -o -name "vendor_a.img" \) | head -1)
    [[ -z "$ORIG_VENDOR_FILE" ]] && { ERROR_EXIT "Original vendor image missing from Port ROM super.img extraction"; return 1; }

    # Overwrite in place so the rebuilt super.img keeps this partition's
    # original slot naming (vendor.img vs vendor_a.img) exactly as shipped.
    cp -f "$NEW_VENDOR_IMG" "$ORIG_VENDOR_FILE" || { ERROR_EXIT "Failed to stage repacked vendor image"; return 1; }

    local LP_ARGS=(
        --device-size "$PORT_SUPER_SIZE"
        --metadata-size "$PORT_METADATA_SIZE"
        --metadata-slots "$PORT_METADATA_SLOTS"
        --group "$PORT_GROUP_NAME:$PORT_GROUP_SIZE"
        --output "$OUT_SUPER"
    )

    local IMG PART_NAME P_SIZE TOTAL_SIZE=0
    for IMG in "$PORT_SUPER_LPUNPACK_DIR"/*.img; do
        [[ -f "$IMG" ]] || continue
        PART_NAME="$(basename "$IMG" .img)"
        P_SIZE=$(stat -c%s "$IMG")
        TOTAL_SIZE=$(( TOTAL_SIZE + P_SIZE ))
        LP_ARGS+=(--partition "${PART_NAME}:readonly:${P_SIZE}:${PORT_GROUP_NAME}")
        LP_ARGS+=(--image "${PART_NAME}=$IMG")
    done

    if (( TOTAL_SIZE > PORT_GROUP_SIZE )); then
        ERROR_EXIT "Repacked partitions ($TOTAL_SIZE bytes) exceed the Port ROM's super group limit ($PORT_GROUP_SIZE bytes)"
        return 1
    fi

    RUN_CMD "Rebuilding Port ROM super.img" "$PREBUILTS/android-tools/lpmake ${LP_ARGS[*]}"
    [[ -f "$OUT_SUPER" ]] || { ERROR_EXIT "super.img rebuild produced no output"; return 1; }

    echo "$OUT_SUPER"
}

REINSERT_VENDOR_IMAGE()
{
    local NEW_VENDOR_IMG="$1"
    local FINAL_STAGE="$TEE_SWAP_TMP/final_port_rom.zip"

    case "$PORT_VENDOR_SOURCE" in
        standalone)
            # The original archive is kept pristine in the temporary workspace.
            # Replace only the standalone vendor.img entry in that archive.
            cp -f "$PORT_ORIGINAL_ZIP" "$FINAL_STAGE" \
                || { ERROR_EXIT "Failed to stage original Port ROM ZIP"; return 1; }

            rm -f -- "$PORT_EXTRACT_DIR/$PORT_VENDOR_ZIP_PATH"
            mkdir -p "$(dirname "$PORT_EXTRACT_DIR/$PORT_VENDOR_ZIP_PATH")"
            cp -f "$NEW_VENDOR_IMG" "$PORT_EXTRACT_DIR/$PORT_VENDOR_ZIP_PATH" \
                || { ERROR_EXIT "Failed to stage updated standalone vendor image"; return 1; }
            ;;
        super)
            local NEW_SUPER
            NEW_SUPER="$(REBUILD_PORT_SUPER_IMAGE "$NEW_VENDOR_IMG")" || return 1

            cp -f "$PORT_ORIGINAL_ZIP" "$FINAL_STAGE" \
                || { ERROR_EXIT "Failed to stage original Port ROM ZIP"; return 1; }

            rm -f -- "$PORT_EXTRACT_DIR/$PORT_VENDOR_ZIP_PATH"
            mkdir -p "$(dirname "$PORT_EXTRACT_DIR/$PORT_VENDOR_ZIP_PATH")"
            cp -f "$NEW_SUPER" "$PORT_EXTRACT_DIR/$PORT_VENDOR_ZIP_PATH" \
                || { ERROR_EXIT "Failed to stage rebuilt super.img"; return 1; }
            ;;
        *)
            ERROR_EXIT "Unknown Port ROM vendor source: $PORT_VENDOR_SOURCE"
            return 1
            ;;
    esac

    # IMPORTANT: never rebuild the whole ZIP. Start from the pristine original
    # archive, delete only the image entry we changed, then add that one entry
    # back. All other ZIP entries remain byte-for-byte untouched.
    (
        cd "$PORT_EXTRACT_DIR" || exit 1
        zip -q -d "$FINAL_STAGE" "$PORT_VENDOR_ZIP_PATH" >/dev/null
        zip -q -g "$FINAL_STAGE" "$PORT_VENDOR_ZIP_PATH"
    ) || { ERROR_EXIT "Failed to replace only $PORT_VENDOR_ZIP_PATH in the original ZIP"; return 1; }

    [[ -f "$FINAL_STAGE" ]] || { ERROR_EXIT "Final Port ROM ZIP was not created"; return 1; }
    unzip -tq "$FINAL_STAGE" >/dev/null 2>&1 \
        || { ERROR_EXIT "Final Port ROM ZIP failed integrity check"; return 1; }

    unzip -l "$FINAL_STAGE" | grep -qF "$PORT_VENDOR_ZIP_PATH" \
        || { ERROR_EXIT "Final ZIP is missing the updated image entry: $PORT_VENDOR_ZIP_PATH"; return 1; }

    FINAL_ZIP_STAGE="$FINAL_STAGE"
    export FINAL_ZIP_STAGE
}

# ]
