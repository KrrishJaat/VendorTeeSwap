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
#  Same GoFile API calls that were previously inlined directly in
#  build-rom.yml's "Upload ROM to Gofile" step, lifted into a reusable
#  function so both workflows call one implementation.
#

# [
UPLOAD_TO_GOFILE()
{
    local FILE_PATH="$1"

    [[ -f "$FILE_PATH" ]] || { echo "GoFile upload failed: file not found: $FILE_PATH" >&2; return 1; }
    [[ -z "$GOFILE_TOKEN" ]] && { echo "GoFile upload failed: GOFILE_TOKEN secret not set" >&2; return 1; }

    echo "Searching for a GoFile upload server..."
    local SERVER
    SERVER=$(curl -s https://api.gofile.io/servers | jq -r '.data.servers[0].name')
    [[ -z "$SERVER" || "$SERVER" == "null" ]] && { echo "GoFile upload failed: could not resolve an upload server" >&2; return 1; }

    echo "Uploading $(basename "$FILE_PATH") ($(du -h "$FILE_PATH" | cut -f1)) to $SERVER..."
    local RESPONSE
    RESPONSE=$(curl -s \
        -H "Authorization: Bearer ${GOFILE_TOKEN}" \
        -F "file=@${FILE_PATH}" \
        -F "folderId=${GOFILE_FOLDER_ID}" \
        "https://${SERVER}.gofile.io/uploadFile")

    local STATUS
    STATUS=$(echo "$RESPONSE" | jq -r '.status')
    if [[ "$STATUS" != "ok" ]]; then
        echo "GoFile upload failed: $RESPONSE" >&2
        return 1
    fi

    local DOWNLOAD_LINK FILE_SIZE
    DOWNLOAD_LINK=$(echo "$RESPONSE" | jq -r '.data.downloadPage')
    FILE_SIZE=$(stat -c%s "$FILE_PATH")

    echo "=============================="
    echo "Upload status:   $STATUS"
    echo "File size:       $FILE_SIZE bytes"
    echo "Download URL:    $DOWNLOAD_LINK"
    echo "=============================="

    if [[ -n "$GITHUB_OUTPUT" ]]; then
        {
            echo "download_url=$DOWNLOAD_LINK"
            echo "file_size=$FILE_SIZE"
            echo "upload_status=$STATUS"
        } >> "$GITHUB_OUTPUT"
    fi
}
# ]

# Allow this file to be run directly (bash scripts/tee_swap/upload_gofile.sh <file>)
# as well as sourced as a library like every other scripts/**/*.sh file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    UPLOAD_TO_GOFILE "$1"
fi
