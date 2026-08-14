# Vendor tee Swap

Standalone `workflow_dispatch` that takes a Port ROM ZIP + a Samsung stock
(model, CSC, IMEI), downloads the latest stock firmware, and replaces
`vendor/tee` inside the Port ROM with the freshly downloaded stock
`vendor/tee`. Every other byte of the Port ROM ZIP — `META-INF`, the
updater-script, its own signing, other partitions, permissions, symlinks,
compression — is left untouched. Nothing here is device-specific; every
identifier comes from workflow inputs.

## Installing

Drop these files into the existing ReCoreUI repo at the same relative
paths (nothing here modifies any existing file):

```
.github/workflows/tee-swap.yml
scripts/tee_swap/orchestrate.sh
scripts/tee_swap/unpack_port_zip.sh
scripts/tee_swap/repack_super_and_zip.sh
scripts/tee_swap/download_gdrive.sh
scripts/tee_swap/upload_gofile.sh
scripts/tee_swap/selftest.sh
```

Add two repo secrets for the final GoFile upload: `GOFILE_TOKEN`,
`GOFILE_FOLDER_ID` (same secrets `build-rom.yml` already uses).

Then: Actions → **TEE Changer** → Run workflow, and fill in the Google Drive
file ID or share URL, stock model, stock CSC, and stock IMEI. The Drive file
must be shared as **Anyone with the link → Viewer**.

## What's reused vs. new

Reused verbatim (no changes to any existing file):
`DOWNLOAD_FW`/`FETCH_FW`, `EXTRACT_FIRMWARE`, `UNPACK_PARTITION`,
`DETECT_FILESYSTEM`, `SPARSE_TO_RAW`, `REMOVE`, `ADD_FROM_FW`,
`REPACK_PARTITION`, `LOG_*`/`ERROR_EXIT`/`RUN_CMD`/`CHECK_DEPENDENCY`, and
the same `lpmake`/`lpdump`/`lpunpack` prebuilt binaries used everywhere
else in the repo. `REMOVE "vendor" "tee"` + `ADD_FROM_FW "stock" "vendor"
"tee"` is the exact same call pattern already used in
`objectives/m35x/vendor-patches/patches.sh` — this module just points
`$WORKSPACE` at an ad hoc Port ROM vendor directory instead of the
device-build workspace.

New (small, single-purpose, documented in each file's header):
- `download_gdrive.sh` — resolves the real Google Drive filename with `gdown --json`, downloads the large file with resume support, and validates it as a ZIP.
- `unpack_port_zip.sh` — opens an arbitrary flashable ZIP (not the
  AP/BL/CP/CSC.tar.md5 layout `EXTRACT_FIRMWARE` expects) and locates its
  vendor image, standalone or inside `super.img`.
- `repack_super_and_zip.sh` — rebuilds `super.img` only if the Port ROM
  used one (reusing `lpmake`'s metadata-driven argument construction the
  same way `BUILD_SUPER_IMAGE` does, just sourced from the Port ROM's own
  metadata), then updates *only* that one file inside the original ZIP via
  an in-place `zip` update — `CREATE_FLASHABLE_ZIP` was not reused here on
  purpose, since it rebuilds the whole package from ReCoreUI's own
  installer template and re-signs it, which would defeat the point.
- `upload_gofile.sh` — the GoFile calls previously inlined in
  `build-rom.yml`, lifted out so both workflows share one implementation.

## What self-validation actually covered

I don't have a real Samsung device, firmware, or Port ROM to test against,
so I validated what's possible without those:

- **Static:** `bash -n` on every new script; the workflow YAML parses;
  every function `orchestrate.sh` calls resolves once sourced alongside
  the real repo (`declare -F`).
- **Structural, with real tools:** `scripts/tee_swap/selftest.sh` builds
  tiny synthetic "stock" and "Port ROM" `vendor.img` files using the
  repo's actual prebuilt `mke2fs.android`/`e2fsdroid`, assembles a
  synthetic flashable ZIP with a `META-INF`, then runs them through the
  *real* `UNPACK_PORT_VENDOR` → `REMOVE` → `ADD_FROM_FW` →
  `REPACK_PARTITION` → `REINSERT_VENDOR_IMAGE` call chain (not mocks) and
  checks: the port `tee/` content is correctly replaced with the stock
  content, unrelated port vendor files survive untouched, and the
  rebuilt ZIP's `META-INF`/updater-script come out byte-for-byte
  identical (SHA-256 compared) to the original. This currently passes for
  the **standalone `vendor.img`** layout. Run it yourself with:
  `sudo bash scripts/tee_swap/selftest.sh` (takes a couple of minutes,
  writes nothing outside `firmware/`, `out/`, `tmp_tee_swap/`).
- **Not exercised:** the `super.img` / dynamic-partition reinsertion path
  (`REBUILD_PORT_SUPER_IMAGE`) — building a synthetic multi-partition
  `super.img` was out of scope for this pass. It reuses the same
  `lpmake`/`lpdump` argument pattern as the already-proven
  `BUILD_SUPER_IMAGE`, just sourced from the Port ROM's own metadata
  instead of `$STOCK_MODEL`'s, but I'd want to test it against a real (or
  at least a synthetic multi-partition) `super.img` before trusting it on
  a real device. Also not exercised: the actual `samfirm.js` download
  against Samsung's servers, and a real device flash — neither is
  reachable from this environment.

## Bugs found and fixed during that validation (worth knowing about)

- Every pre-existing `.sh` file in the uploaded repo has CRLF line
  endings, which makes `source` fail outright — likely an artifact of how
  the ZIP was packaged rather than the real state of your git repo, but
  `orchestrate.sh`'s sourcing loop strips `\r` at source-time regardless,
  so this module works either way. Worth checking whether your actual
  checkout has the same issue, since `build.sh` uses the identical
  sourcing loop.
- `UNPACK_PARTITION` assumes `unpack.conf` already exists in its target
  dir (normally created by `EXTRACT_FIRMWARE` first) — `unpack_port_zip.sh`
  creates that marker file itself before calling it, since there's no
  `AP.tar.md5` for an arbitrary Port ROM ZIP.
- `rsync` (used by `ADD_FROM_FW`) isn't in `setup_env.sh`'s
  `DEPENDENCY_CONFIG` and wasn't in my own dependency list either — added
  to `orchestrate.sh`'s `CHECK_DEPENDENCY` calls after the self-test caught
  the gap.
- Any script sourced via `scripts/**/*.sh` that also contains top-level
  executing code (not just function definitions) will source *itself* as
  part of that same glob loop — `orchestrate.sh` and `selftest.sh` both
  explicitly exclude themselves for this reason. Worth keeping in mind if
  you add more top-level entry scripts under `scripts/`.
