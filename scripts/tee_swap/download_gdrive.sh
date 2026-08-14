#!/usr/bin/env bash
#
# Google Drive downloader for large Port ROM ZIPs.
# Resolves the real Drive filename first, then downloads to that exact name.
#

DOWNLOAD_FROM_GDRIVE()
{
    local SOURCE="$1"
    local OUTPUT_DIR="$2"
    local NAME_OUT="${3:-}"

    [[ -n "$SOURCE" ]] || { echo "Google Drive source is empty" >&2; return 1; }
    [[ -n "$OUTPUT_DIR" ]] || { echo "Google Drive output directory is empty" >&2; return 1; }
    command -v gdown >/dev/null 2>&1 || {
        echo "gdown is not installed; the GitHub Actions workflow must install it first" >&2
        return 1
    }
    command -v jq >/dev/null 2>&1 || {
        echo "jq is required to resolve the Google Drive filename" >&2
        return 1
    }

    mkdir -p "$OUTPUT_DIR"

    local META_JSON FILENAME OUTPUT
    echo "Resolving Google Drive filename..." >&2
    META_JSON=$(gdown "$SOURCE" --json --quiet 2>/dev/null) || {
        echo "Could not resolve Google Drive file metadata." >&2
        return 1
    }

    FILENAME=$(jq -r '.[0].path // empty' <<< "$META_JSON")
    [[ -n "$FILENAME" && "$FILENAME" != "null" ]] || {
        echo "Google Drive did not return a filename." >&2
        return 1
    }

    # The workflow must process a ZIP ROM. Refuse ambiguous/non-ZIP inputs.
    [[ "$FILENAME" == *.zip || "$FILENAME" == *.ZIP ]] || {
        echo "Google Drive file is not a ZIP: $FILENAME" >&2
        return 1
    }

    # gdown may report a path containing directories. We only want the real
    # archive basename in our temporary work directory.
    FILENAME="$(basename -- "$FILENAME")"
    OUTPUT="$OUTPUT_DIR/$FILENAME"

    echo "Port ROM filename: $FILENAME" >&2
    echo "Downloading Port ROM from Google Drive..." >&2
    gdown "$SOURCE" --output "$OUTPUT" --continue >&2

    [[ -s "$OUTPUT" ]] || {
        echo "Google Drive download failed or produced an empty file" >&2
        return 1
    }

    if ! unzip -tq "$OUTPUT" >/dev/null 2>&1; then
        echo "Downloaded file is not a valid ZIP archive: $OUTPUT" >&2
        echo "Make sure the Drive file is shared as: Anyone with the link -> Viewer." >&2
        rm -f "$OUTPUT"
        return 1
    fi

    printf -v "$NAME_OUT" '%s' "$FILENAME" 2>/dev/null || true
    printf '%s\n' "$OUTPUT"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    DOWNLOAD_FROM_GDRIVE "$1" "$2"
fi
