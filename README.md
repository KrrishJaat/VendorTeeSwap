# VendorTeeSwap

VendorTeeSwap automates the TEE swap process for Samsung Port ROMs.

It:

- Downloads the Port ROM from Google Drive.
- Detects and preserves the original ROM filename.
- Unpacks the ROM and removes the downloaded ZIP from the workspace.
- Downloads the required Samsung stock firmware.
- Replaces the Port ROM `vendor/tee` with the stock version.
- Rebuilds `vendor.img` or `super.img` when required.
- Repackages the ROM while replacing only the modified image entry.
- Preserves all other files in the original ROM ZIP.
- Uploads the rebuilt ROM to GoFile.
- Provides the final GoFile download link.
