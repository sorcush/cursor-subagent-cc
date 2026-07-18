#!/usr/bin/env bash
# update-changelog.sh — insert or replace-in-place one Keep a Changelog
# section, read from stdin. Idempotent per version: never duplicates.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILE="$SCRIPT_DIR/../CHANGELOG.md"
VERSION=""

usage() {
  echo "usage: update-changelog.sh --version X.Y.Z [--file <path>] < section.md" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --file)    FILE="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "error: --version is required" >&2; usage; exit 2
fi

SECTION="$(cat)"
if [[ -z "$SECTION" ]]; then
  echo "error: no section text on stdin" >&2; exit 2
fi

HEADER='# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).'

if [[ ! -f "$FILE" ]]; then
  {
    printf '%s\n\n' "$HEADER"
    printf '%s\n' "$SECTION"
  } > "$FILE"
  exit 0
fi

ESC_VERSION="${VERSION//./\\.}"
TARGET_PATTERN="^## \\[${ESC_VERSION}\\]"

if grep -qE "$TARGET_PATTERN" "$FILE"; then
  MODE="replace"
else
  MODE="insert"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

export SECTION ESC_VERSION
awk -v version="$ESC_VERSION" -v mode="$MODE" '
BEGIN {
  target = "^## \\[" version "\\]"
  inserted = 0
  skipping = 0
  section = ENVIRON["SECTION"]
}
{
  if (mode == "replace") {
    if (!skipping && $0 ~ target) {
      print section
      print ""
      skipping = 1
      next
    }
    if (skipping) {
      if ($0 ~ /^## \[/) {
        skipping = 0
      } else {
        next
      }
    }
    print $0
  } else {
    if (!inserted && $0 ~ /^## \[/) {
      print section
      print ""
      inserted = 1
    }
    print $0
  }
}
END {
  if (mode == "insert" && !inserted) {
    print section
  }
}
' "$FILE" > "$TMP"

mv "$TMP" "$FILE"
