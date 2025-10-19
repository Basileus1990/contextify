#!/usr/bin/env bash
# dump_texts_ai.sh
# Recursively print a directory tree (directories included, in proper order) and then dump textual file contents.
# AI-friendly output: deterministic structure listing + per-file metadata + clean delimiters.
#
# Usage: ./dump_texts_ai.sh [options] [root-dir]
# Options:
#   -a            include hidden files/dirs (those starting with a dot)
#   -m MAX_BYTES  maximum bytes to print from each file (default 5MB)
#   -i EXTLIST    comma-separated whitelist of file extensions to INCLUDE (e.g. "py,txt,md")
#   -x EXTLIST    comma-separated blacklist of file extensions to EXCLUDE (e.g. "jpg,pdf")
#   -h            show help
#
# Requirements: bash, find, file, stat, sort, awk, sed, tr, head, readlink (for symlink targets)
set -euo pipefail

# defaults
INCLUDE_HIDDEN=0
MAX_BYTES="${MAX_BYTES:-5242880}"   # 5 MB
INCLUDE_EXT=""
EXCLUDE_EXT=""
ROOT="."

usage() {
  cat <<USG
Usage: $0 [options] [root-dir]
Options:
  -a            include hidden files/dirs
  -m MAX_BYTES  set maximum bytes to print per file (default: $MAX_BYTES)
  -i EXTLIST    include-only extensions (comma-separated, no dots): e.g. "py,txt,md"
  -x EXTLIST    exclude extensions (comma-separated): e.g. "jpg,pdf,bin"
  -h            show this help
Example:
  $0 -a -m 2000000 -x "jpg,png,pdf" /path/to/project
USG
  exit 1
}

# parse flags
while getopts ":am:i:x:h" opt; do
  case $opt in
    a) INCLUDE_HIDDEN=1 ;;
    m) MAX_BYTES="$OPTARG" ;;
    i) INCLUDE_EXT="$OPTARG" ;;
    x) EXCLUDE_EXT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))
if [ $# -gt 0 ]; then
  ROOT="$1"
fi

# Normalize root
ROOT="${ROOT%/}"  # remove trailing slash
[ -e "$ROOT" ] || { echo "Root path not found: $ROOT" >&2; exit 2; }

# small helpers
_is_ext_allowed() {
  local fname="$1"
  local ext="${fname##*.}"
  if [ "$ext" = "$fname" ]; then
    ext=""
  else
    ext="${ext,,}"  # lowercase
  fi

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

_is_hidden_path() {
  local p="$1"
  if [ "$INCLUDE_HIDDEN" -eq 1 ]; then
    return 1  # not hidden (allowed)
  fi
  case "$p" in
    .*|*/.*) return 0 ;;  # hidden
    *) return 1 ;;
  esac
}

# detect whether sort -z is supported (GNU sort)
SORT_Z_OK=0
if printf "" | sort -z >/dev/null 2>&1; then
  SORT_Z_OK=1
fi

# Print file structure (interleaved, in proper sorted order)
echo "File structure:"
echo

# build find root for printing relative paths
if [ "$ROOT" = "." ]; then
  FINDROOT="."
else
  FINDROOT="$ROOT"
fi

# Function to print a single entry with indentation, marking directories with '/' and symlinks with '-> target'
_print_entry() {
  local entry="$1"  # full path
  local rel="$2"
  # skip root path blankness
  if [ -z "$rel" ]; then
    rel="."
  fi

  # hidden filter
  _is_hidden_path "$rel" && return 0

  # determine depth (# slashes)
  if [ "$rel" = "." ]; then
    depth=0
  else
    # count '/' characters
    # safe: use awk to compute NF-1
    depth=$(awk -F"/" '{print NF-1}' <<<"$rel")
  fi

  indent=""
  for ((i=0;i<depth;i++)); do indent+="  "; done

  if [ -d "$entry" ]; then
    printf "%s%s/\n" "$indent" "$(basename -- "$rel")"
  elif [ -L "$entry" ]; then
    target=$(readlink -- "$entry" 2>/dev/null || echo "?")
    printf "%s%s -> %s\n" "$indent" "$(basename -- "$rel")" "$target"
  else
    printf "%s%s\n" "$indent" "$(basename -- "$rel")"
  fi
}

# produce sorted list of all entries (dirs+files+symlinks)
if [ "$SORT_Z_OK" -eq 1 ]; then
  # NUL-safe pipeline: find -print0 | sort -z | while read -d ''
  find "$FINDROOT" -print0 | sort -z | while IFS= read -r -d '' entry; do
    # compute relative path
    if [ "$FINDROOT" = "." ]; then
      rel="${entry#./}"
    else
      rel="${entry#$FINDROOT/}"
    fi
    # special-case: if rel==entry (root), handle
    [ -z "$rel" ] && rel="."
    _print_entry "$entry" "$rel"
  done
else
  # fallback (not NUL-safe): find -print | sort | while read -r
  find "$FINDROOT" -print | sort | while IFS= read -r entry; do
    if [ "$FINDROOT" = "." ]; then
      rel="${entry#./}"
    else
      rel="${entry#$FINDROOT/}"
    fi
    [ -z "$rel" ] && rel="."
    _print_entry "$entry" "$rel"
  done
fi

echo
echo "------------------------------------------------"
echo

# Now dump textual file contents (NUL-safe)
_detect_mime() {
  local f="$1"
  local mt enc
  mt="$(file --mime-type -b -- "$f" 2>/dev/null || echo "application/octet-stream")"
  enc="$(file --mime-encoding -b -- "$f" 2>/dev/null || echo "binary")"
  printf "%s|%s" "$mt" "$enc"
}

# iterate files NUL-safe
if [ "$SORT_Z_OK" -eq 1 ]; then
  find "$FINDROOT" -type f -print0 | sort -z | while IFS= read -r -d '' f; do
    # compute relative path
    if [ "$FINDROOT" = "." ]; then
      rel="${f#./}"
    else
      rel="${f#$FINDROOT/}"
    fi

    _is_hidden_path "$rel" && continue
    if ! _is_ext_allowed "$rel"; then
      continue
    fi

    if [ ! -r "$f" ]; then
      echo "###"
      echo "$rel"
      echo "size: [unreadable]  mime: [unknown]  encoding: [unknown]  truncated: no"
      echo
      echo "[SKIPPED: not readable]"
      echo
      continue
    fi

    if stat_size=$(stat -c%s -- "$f" 2>/dev/null); then
      size="$stat_size"
    elif stat_size=$(stat -f%z -- "$f" 2>/dev/null); then
      size="$stat_size"
    else
      size=0
    fi

    mime_enc_pair="$(_detect_mime "$f")"
    mime="${mime_enc_pair%%|*}"
    enc="${mime_enc_pair##*|}"

    case "$mime" in
      image/*|application/pdf|application/x-pdf|application/zip|application/x-rar|application/x-tar|application/octet-stream)
        continue
        ;;
    esac

    if [ "$enc" = "binary" ] && [[ "$mime" != text/* && "$mime" != application/json && "$mime" != application/xml && "$mime" != application/javascript && "$mime" != application/ecmascript ]]; then
      continue
    fi

    truncated="no"
    if [ "$size" -gt "$MAX_BYTES" ]; then
      truncated="yes"
    fi

    echo "###"
    echo "$rel"
    printf "size: %s  mime: %s  encoding: %s  truncated: %s\n" "$size" "$mime" "$enc" "$truncated"
    echo

    if [ "$size" -le "$MAX_BYTES" ]; then
      cat -- "$f" || echo "[ERROR: reading file]" >&2
    else
      head -c "$MAX_BYTES" -- "$f" || true
      echo
      echo "[... content truncated after $MAX_BYTES bytes ...]"
    fi
    echo
  done
else
  # fallback non-NUL (less safe for filenames with newlines)
  find "$FINDROOT" -type f -print | sort | while IFS= read -r f; do
    if [ "$FINDROOT" = "." ]; then
      rel="${f#./}"
    else
      rel="${f#$FINDROOT/}"
    fi

    _is_hidden_path "$rel" && continue
    if ! _is_ext_allowed "$rel"; then
      continue
    fi

    if [ ! -r "$f" ]; then
      echo "###"
      echo "$rel"
      echo "size: [unreadable]  mime: [unknown]  encoding: [unknown]  truncated: no"
      echo
      echo "[SKIPPED: not readable]"
      echo
      continue
    fi

    if stat_size=$(stat -c%s -- "$f" 2>/dev/null); then
      size="$stat_size"
    elif stat_size=$(stat -f%z -- "$f" 2>/dev/null); then
      size="$stat_size"
    else
      size=0
    fi

    mime_enc_pair="$(_detect_mime "$f")"
    mime="${mime_enc_pair%%|*}"
    enc="${mime_enc_pair##*|}"

    case "$mime" in
      image/*|application/pdf|application/x-pdf|application/zip|application/x-rar|application/x-tar|application/octet-stream)
        continue
        ;;
    esac

    if [ "$enc" = "binary" ] && [[ "$mime" != text/* && "$mime" != application/json && "$mime" != application/xml && "$mime" != application/javascript && "$mime" != application/ecmascript ]]; then
      continue
    fi

    truncated="no"
    if [ "$size" -gt "$MAX_BYTES" ]; then
      truncated="yes"
    fi

    echo "###"
    echo "$rel"
    printf "size: %s  mime: %s  encoding: %s  truncated: %s\n" "$size" "$mime" "$enc" "$truncated"
    echo

    if [ "$size" -le "$MAX_BYTES" ]; then
      cat -- "$f" || echo "[ERROR: reading file]" >&2
    else
      head -c "$MAX_BYTES" -- "$f" || true
      echo
      echo "[... content truncated after $MAX_BYTES bytes ...]"
    fi
    echo
  done
fi
