#!/usr/bin/env bash
# contextify
# Recursively print project structure and text file contents in an AI-friendly format.
# Optional: copy output to clipboard (-c), open containing folder (-o)
#
# Usage: ./contextify [options] [directory]

set -euo pipefail

INCLUDE_HIDDEN=0
MAX_BYTES="${MAX_BYTES:-5242880}" # 5 MB
INCLUDE_EXT=""
EXCLUDE_EXT=""
ROOT="."
COPY_TO_CLIPBOARD=0
OPEN_FILE_EXPLORER=0

usage() {
  cat <<USG
Usage: $0 [options] [directory]

Options:
  -a              include hidden files and directories
  -m MAX_BYTES    limit max bytes per file (default: 5MB)
  -i EXTLIST      include only listed extensions (comma-separated, e.g. py,txt,md)
  -x EXTLIST      exclude listed extensions (comma-separated, e.g. jpg,pdf,png)
  -c, --copy      copy output to clipboard (macOS, Linux, WSL supported)
  -o, --open      open file explorer where output file was created
  -h, --help      show this help message

Example:
  ./contextify -a -x "jpg,pdf" -c -o .
USG
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -a) INCLUDE_HIDDEN=1 ;;
    -m) MAX_BYTES="$2"; shift ;;
    -i) INCLUDE_EXT="$2"; shift ;;
    -x) EXCLUDE_EXT="$2"; shift ;;
    -c|--copy) COPY_TO_CLIPBOARD=1 ;;
    -o|--open) OPEN_FILE_EXPLORER=1 ;;
    -h|--help) usage ;;
    *) ROOT="$1" ;;
  esac
  shift || true
done

ROOT="${ROOT%/}"
[ -e "$ROOT" ] || { echo "Error: path not found: $ROOT" >&2; exit 1; }

# Create organized temp directory
TMPDIR="/tmp/contextify"
mkdir -p "$TMPDIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
TMPFILE="$TMPDIR/contextify_output.${TIMESTAMP}.txt"

# Extension filters
_is_ext_allowed() {
  local f="$1"
  local ext="${f##*.}"
  [ "$ext" = "$f" ] && ext=""
  ext="${ext,,}"
  if [ -n "$INCLUDE_EXT" ]; then
    IFS=',' read -r -a arr <<<"$INCLUDE_EXT"
    for e in "${arr[@]}"; do
      [ "$e" = "$ext" ] && return 0
    done
    return 1
  fi
  if [ -n "$EXCLUDE_EXT" ]; then
    IFS=',' read -r -a arr <<<"$EXCLUDE_EXT"
    for e in "${arr[@]}"; do
      [ "$e" = "$ext" ] && return 1
    done
  fi
  return 0
}

# Hidden files filter
_is_hidden() {
  local p="$1"
  [ "$INCLUDE_HIDDEN" -eq 1 ] && return 1
  case "$p" in
    .*|*/.*) return 0 ;;
    *) return 1 ;;
  esac
}

# Detect MIME and encoding
_detect_mime() {
  local f="$1"
  local mt enc
  mt="$(file --mime-type -b -- "$f" 2>/dev/null || echo "application/octet-stream")"
  enc="$(file --mime-encoding -b -- "$f" 2>/dev/null || echo "binary")"
  printf "%s|%s" "$mt" "$enc"
}

# Clipboard helper
_copy_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  elif grep -qi microsoft /proc/version 2>/dev/null; then
    clip.exe
  else
    echo "⚠️  No clipboard tool found. Install pbcopy, xclip, or xsel." >&2
    cat
  fi
}

# File explorer opener
_open_file_explorer() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"

  if [[ "$OSTYPE" == "darwin"* ]]; then
    open "$dir"
  elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if grep -qi microsoft /proc/version 2>/dev/null; then
      explorer.exe "$(wslpath -w "$dir")"
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "$dir" >/dev/null 2>&1 &
    elif command -v nautilus >/dev/null 2>&1; then
      nautilus "$dir" >/dev/null 2>&1 &
    else
      echo "⚠️  No file explorer found. Folder: $dir" >&2
    fi
  else
    echo "⚠️  File explorer opening not supported on this system." >&2
  fi
}

{
  echo "File structure:"
  echo

  find "$ROOT" -print | sort | while IFS= read -r path; do
    rel="${path#$ROOT/}"
    [ "$rel" = "$path" ] && rel="."
    _is_hidden "$rel" && continue
    depth=$(awk -F"/" '{print NF-1}' <<<"$rel")
    indent="$(printf "%${depth}s" "" | tr " " "  ")"
    if [ -d "$path" ]; then
      printf "%s%s/\n" "$indent" "$(basename -- "$rel")"
    elif [ -L "$path" ]; then
      target=$(readlink "$path" 2>/dev/null || echo "?")
      printf "%s%s -> %s\n" "$indent" "$(basename -- "$rel")" "$target"
    else
      printf "%s%s\n" "$indent" "$(basename -- "$rel")"
    fi
  done

  echo
  echo "------------------------------------------------"
  echo

  find "$ROOT" -type f -print0 | sort -z | while IFS= read -r -d '' f; do
    rel="${f#$ROOT/}"
    _is_hidden "$rel" && continue
    _is_ext_allowed "$rel" || continue

    if [ ! -r "$f" ]; then
      echo "###"
      echo "$rel"
      echo "size: [unreadable] mime: [unknown] encoding: [unknown] truncated: no"
      echo
      echo "[SKIPPED: not readable]"
      echo
      continue
    fi

    size=$(stat -c%s -- "$f" 2>/dev/null || stat -f%z -- "$f" 2>/dev/null || echo 0)
    mime_enc="$(_detect_mime "$f")"
    mime="${mime_enc%%|*}"
    enc="${mime_enc##*|}"

    case "$mime" in
      image/*|application/pdf|application/zip|application/x-rar|application/octet-stream)
        continue ;;
    esac
    if [ "$enc" = "binary" ] && [[ "$mime" != text/* && "$mime" != application/json && "$mime" != application/xml && "$mime" != application/javascript ]]; then
      continue
    fi

    truncated="no"
    [ "$size" -gt "$MAX_BYTES" ] && truncated="yes"

    echo "###"
    echo "$rel"
    echo "size: $size  mime: $mime  encoding: $enc  truncated: $truncated"
    echo

    if [ "$size" -le "$MAX_BYTES" ]; then
      cat -- "$f"
    else
      head -c "$MAX_BYTES" -- "$f"
      echo
      echo "[... content truncated after $MAX_BYTES bytes ...]"
    fi
    echo
  done
} | tee "$TMPFILE"

echo
echo "📄 Output saved to: $TMPFILE"

if [ "$COPY_TO_CLIPBOARD" -eq 1 ]; then
  echo "📋 Copying to clipboard..."
  cat "$TMPFILE" | _copy_to_clipboard
  echo "✅ Copied!"
fi

if [ "$OPEN_FILE_EXPLORER" -eq 1 ]; then
  echo "📂 Opening file explorer..."
  _open_file_explorer "$TMPFILE"
fi