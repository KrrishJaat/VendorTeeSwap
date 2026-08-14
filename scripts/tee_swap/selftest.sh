#!/usr/bin/env bash
#
# Synthetic, no-real-firmware-required self-test for the TEE-swap pipeline.
# Builds tiny fake 'stock' and 'port' vendor.img files with real mke2fs/e2fsdroid,
# runs them through the actual UNPACK_PORT_VENDOR / REMOVE / ADD_FROM_FW /
# REPACK_PARTITION / REINSERT_VENDOR_IMAGE functions, and verifies the tee
# swap happened correctly and that META-INF/updater-script came out byte-
# identical. Run from the repo root as: sudo bash scripts/tee_swap/selftest.sh
#
set -o pipefail

RECOREUI="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export RECOREUI
export ASTROROM="$RECOREUI"
PREBUILTS="$RECOREUI/prebuilts"
WORKDIR="$RECOREUI/firmware/unpacked"
DIROUT="$RECOREUI/out"
TEE_SWAP_TMP="$RECOREUI/tmp_tee_swap"
export PREBUILTS WORKDIR DIROUT TEE_SWAP_TMP
USABLE_THREADS=2
export USABLE_THREADS

chmod +x -R "$PREBUILTS"

cd "$RECOREUI"
shopt -s globstar
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
for f in scripts/**/*.sh; do
    [[ -f "$f" ]] || continue
    [[ "$(readlink -f "$f")" == "$SELF" ]] && continue
    [[ "$f" == "scripts/tee_swap/orchestrate.sh" ]] && continue
    source <(tr -d '\r' < "$f")
done

STOCK_MODEL="SM-M356B"
STOCK_CSC="INS"
export STOCK_MODEL STOCK_CSC

rm -rf "$WORKDIR" "$DIROUT" "$TEE_SWAP_TMP" "$RECOREUI/selftest_build"
mkdir -p "$WORKDIR" "$DIROUT" "$TEE_SWAP_TMP" "$RECOREUI/selftest_build"
BUILD="$RECOREUI/selftest_build"

echo "=== [1/8] Building synthetic STOCK vendor.img (real ext4, real tools) ==="
mkdir -p "$BUILD/stock_root/tee/tzsw" "$BUILD/stock_root/lib64" "$BUILD/stock_root/etc"
echo "STOCK_TEE_BLOB_v99" > "$BUILD/stock_root/tee/tzsw/tee.bin"
echo "stock_only_marker" > "$BUILD/stock_root/tee/stock_marker.txt"
echo "libstocksec" > "$BUILD/stock_root/lib64/libsec.so"
dd if=/dev/urandom of="$BUILD/stock_root/lib64/padding.bin" bs=1M count=20 status=none

find "$BUILD/stock_root" | xargs stat -c "%n %u %g %a capabilities=0x0" > "$BUILD/stock_fs_config.raw"
find "$BUILD/stock_root" | xargs -I {} sh -c 'echo "{} u:object_r:vendor_file:s0"' > "$BUILD/stock_file_contexts.raw"

truncate -s 96M "$BUILD/stock_vendor.img"
"$PREBUILTS/android-tools/mke2fs.android" -t ext4 -b 4096 -L "/vendor" -O ^has_journal -F -q "$BUILD/stock_vendor.img" 24576
MNT="$BUILD/stock_root"
sed -e "s|$MNT|/vendor|g" "$BUILD/stock_file_contexts.raw" > "$BUILD/stock_file_contexts"
sed -e "s|$MNT | |g" -e "s|$MNT|vendor|g" "$BUILD/stock_fs_config.raw" > "$BUILD/stock_fs_config"
sed -i '1s|^|/ |' "$BUILD/stock_fs_config"
echo "vendor/lost+found 0 0 700 capabilities=0x0" >> "$BUILD/stock_fs_config"
echo "/vendor/lost\+found u:object_r:vendor_file:s0" >> "$BUILD/stock_file_contexts"
"$PREBUILTS/android-tools/e2fsdroid" -e -T 1230735600 -C "$BUILD/stock_fs_config" -S "$BUILD/stock_file_contexts" -a "/vendor" -f "$BUILD/stock_root" "$BUILD/stock_vendor.img"
echo "OK: stock_vendor.img built ($(stat -c%s "$BUILD/stock_vendor.img") bytes)"

echo
echo "=== [2/8] Unpacking synthetic STOCK vendor via the real UNPACK_PARTITION ==="
# (test harness only: normally EXTRACT_FIRMWARE creates this before calling
# UNPACK_PARTITION; we're calling UNPACK_PARTITION directly here to avoid
# needing real Samsung firmware for this test)
mkdir -p "$WORKDIR/$STOCK_MODEL"
echo 'PARTITIONS=""' > "$WORKDIR/$STOCK_MODEL/unpack.conf"
mkdir -p "$BUILD/stock_unpack_stage"
cp "$BUILD/stock_vendor.img" "$BUILD/stock_unpack_stage/vendor.img"
UNPACK_PARTITION "$BUILD/stock_unpack_stage/vendor.img" "$STOCK_MODEL"
[[ -f "$WORKDIR/$STOCK_MODEL/vendor/tee/tzsw/tee.bin" ]] && echo "OK: stock tee unpacked" || { echo "FAIL: stock tee missing after unpack"; exit 1; }
STOCK_CONTENT=$(cat "$WORKDIR/$STOCK_MODEL/vendor/tee/tzsw/tee.bin")
echo "Stock tee.bin content: $STOCK_CONTENT"

echo
echo "=== [3/8] Building synthetic PORT vendor.img (different tee content + unrelated files) ==="
mkdir -p "$BUILD/port_root/tee/tzsw" "$BUILD/port_root/lib64" "$BUILD/port_root/etc"
echo "PORT_OLD_TEE_BLOB_v1" > "$BUILD/port_root/tee/tzsw/tee.bin"
echo "port_only_marker" > "$BUILD/port_root/tee/port_marker.txt"
echo "libportmisc" > "$BUILD/port_root/lib64/libmisc.so"
echo "some.prop=1" > "$BUILD/port_root/etc/vendor.prop"
dd if=/dev/urandom of="$BUILD/port_root/lib64/padding.bin" bs=1M count=20 status=none

find "$BUILD/port_root" | xargs stat -c "%n %u %g %a capabilities=0x0" > "$BUILD/port_fs_config.raw"
find "$BUILD/port_root" | xargs -I {} sh -c 'echo "{} u:object_r:vendor_file:s0"' > "$BUILD/port_file_contexts.raw"

truncate -s 96M "$BUILD/vendor.img"
"$PREBUILTS/android-tools/mke2fs.android" -t ext4 -b 4096 -L "/vendor" -O ^has_journal -F -q "$BUILD/vendor.img" 24576
MNT="$BUILD/port_root"
sed -e "s|$MNT|/vendor|g" "$BUILD/port_file_contexts.raw" > "$BUILD/port_file_contexts"
sed -e "s|$MNT | |g" -e "s|$MNT|vendor|g" "$BUILD/port_fs_config.raw" > "$BUILD/port_fs_config"
sed -i '1s|^|/ |' "$BUILD/port_fs_config"
echo "vendor/lost+found 0 0 700 capabilities=0x0" >> "$BUILD/port_fs_config"
echo "/vendor/lost\+found u:object_r:vendor_file:s0" >> "$BUILD/port_file_contexts"
"$PREBUILTS/android-tools/e2fsdroid" -e -T 1230735600 -C "$BUILD/port_fs_config" -S "$BUILD/port_file_contexts" -a "/vendor" -f "$BUILD/port_root" "$BUILD/vendor.img"
echo "OK: port vendor.img built ($(stat -c%s "$BUILD/vendor.img") bytes)"

echo
echo "=== [4/8] Assembling synthetic flashable Port ROM ZIP (META-INF + vendor.img, standalone layout) ==="
PORT_ZIP_ROOT="$BUILD/port_zip_root"
rm -rf "$PORT_ZIP_ROOT" && mkdir -p "$PORT_ZIP_ROOT/META-INF/com/google/android"
cat > "$PORT_ZIP_ROOT/META-INF/com/google/android/updater-script" <<'EOF'
ui_print("Installing Port ROM...");
show_progress(1.000000, 0);
update_zip vendor.img $(find_block vendor);
ui_print("Done.");
EOF
echo "original-untouched-marker-file" > "$PORT_ZIP_ROOT/META-INF/marker.txt"
cp "$BUILD/vendor.img" "$PORT_ZIP_ROOT/vendor.img"

ORIGINAL_UPDATER_SHA=$(sha256sum "$PORT_ZIP_ROOT/META-INF/com/google/android/updater-script" | awk '{print $1}')
ORIGINAL_MARKER_SHA=$(sha256sum "$PORT_ZIP_ROOT/META-INF/marker.txt" | awk '{print $1}')

PORT_ZIP="$TEE_SWAP_TMP/port.zip"
mkdir -p "$TEE_SWAP_TMP"
(cd "$PORT_ZIP_ROOT" && zip -q -r "$PORT_ZIP" .)
echo "OK: synthetic port.zip assembled ($(stat -c%s "$PORT_ZIP") bytes)"

echo
echo "=== [5/8] Running UNPACK_PORT_VENDOR (real function) ==="
UNPACK_PORT_VENDOR "$PORT_ZIP" "$TEE_SWAP_TMP"
echo "PORT_VENDOR_SOURCE=$PORT_VENDOR_SOURCE  PORT_VENDOR_FS=$PORT_VENDOR_FS  PORT_VENDOR_ZIP_PATH=$PORT_VENDOR_ZIP_PATH  WORKSPACE=$WORKSPACE"
[[ -f "$WORKSPACE/vendor/tee/tzsw/tee.bin" ]] && echo "OK: port tee unpacked" || { echo "FAIL: port tee missing"; exit 1; }
BEFORE_SWAP=$(cat "$WORKSPACE/vendor/tee/tzsw/tee.bin")
echo "Port tee.bin content BEFORE swap: $BEFORE_SWAP"
[[ "$BEFORE_SWAP" == "PORT_OLD_TEE_BLOB_v1" ]] && echo "OK: matches synthetic port content" || { echo "FAIL: unexpected pre-swap content"; exit 1; }

echo
echo "=== [6/8] REMOVE + ADD_FROM_FW (real functions, exact same call as objectives/m35x/vendor-patches/patches.sh) ==="
REMOVE "vendor" "tee"
[[ -d "$WORKSPACE/vendor/tee" ]] && { echo "FAIL: tee still present after REMOVE"; exit 1; } || echo "OK: tee removed"
ADD_FROM_FW "stock" "vendor" "tee"
[[ -f "$WORKSPACE/vendor/tee/tzsw/tee.bin" ]] || { echo "FAIL: tee not restored after ADD_FROM_FW"; exit 1; }
AFTER_SWAP=$(cat "$WORKSPACE/vendor/tee/tzsw/tee.bin")
echo "Port tee.bin content AFTER swap: $AFTER_SWAP"
[[ "$AFTER_SWAP" == "$STOCK_CONTENT" ]] && echo "OK: tee now matches STOCK content" || { echo "FAIL: tee content does not match stock"; exit 1; }
[[ -f "$WORKSPACE/vendor/lib64/libmisc.so" ]] && echo "OK: unrelated port file (lib64/libmisc.so) untouched" || { echo "FAIL: unrelated port file was lost"; exit 1; }

echo
echo "=== [7/8] REPACK_PARTITION (real function) ==="
REPACK_PARTITION "vendor" "$PORT_VENDOR_FS" "$TEE_SWAP_TMP" "$WORKSPACE"
[[ -f "$TEE_SWAP_TMP/vendor.img" ]] && echo "OK: vendor.img repacked ($(stat -c%s "$TEE_SWAP_TMP/vendor.img") bytes)" || { echo "FAIL: repack produced no image"; exit 1; }

echo
echo "=== [8/8] REINSERT_VENDOR_IMAGE (real function) — in-place ZIP update ==="
REINSERT_VENDOR_IMAGE "$TEE_SWAP_TMP/vendor.img"

VERIFY_DIR="$BUILD/verify_extracted"
rm -rf "$VERIFY_DIR" && mkdir -p "$VERIFY_DIR"
unzip -q -o "$PORT_ZIP" -d "$VERIFY_DIR"

NEW_UPDATER_SHA=$(sha256sum "$VERIFY_DIR/META-INF/com/google/android/updater-script" | awk '{print $1}')
NEW_MARKER_SHA=$(sha256sum "$VERIFY_DIR/META-INF/marker.txt" | awk '{print $1}')

[[ "$NEW_UPDATER_SHA" == "$ORIGINAL_UPDATER_SHA" ]] && echo "OK: updater-script byte-identical to original" || { echo "FAIL: updater-script was modified!"; exit 1; }
[[ "$NEW_MARKER_SHA" == "$ORIGINAL_MARKER_SHA" ]] && echo "OK: META-INF/marker.txt byte-identical to original" || { echo "FAIL: META-INF/marker.txt was modified!"; exit 1; }

MNT=$(mktemp -d)
mount -o ro "$VERIFY_DIR/vendor.img" "$MNT"
FINAL_TEE_CONTENT=$(cat "$MNT/tee/tzsw/tee.bin")
FINAL_HAS_PORT_MARKER=$([[ -f "$MNT/lib64/libmisc.so" ]] && echo yes || echo no)
FINAL_HAS_STOCK_MARKER=$([[ -f "$MNT/tee/stock_marker.txt" ]] && echo yes || echo no)
umount "$MNT"; rmdir "$MNT"

echo "Final repacked vendor.img -> tee/tzsw/tee.bin: $FINAL_TEE_CONTENT"
echo "Final repacked vendor.img -> lib64/libmisc.so (should survive, from port): $FINAL_HAS_PORT_MARKER"
echo "Final repacked vendor.img -> tee/stock_marker.txt (should exist, from stock): $FINAL_HAS_STOCK_MARKER"

[[ "$FINAL_TEE_CONTENT" == "$STOCK_CONTENT" ]] && echo "OK: final ZIP's vendor.img has STOCK tee content" || { echo "FAIL: final content mismatch"; exit 1; }
[[ "$FINAL_HAS_PORT_MARKER" == "yes" ]] && echo "OK: non-tee port vendor files survived repack" || { echo "FAIL: non-tee port files lost"; exit 1; }
[[ "$FINAL_HAS_STOCK_MARKER" == "yes" ]] && echo "OK: stock-only tee file present in final image" || { echo "FAIL: stock tee content incomplete"; exit 1; }

echo
echo "===================================================================="
echo "ALL SELF-TEST CHECKS PASSED"
echo "===================================================================="
