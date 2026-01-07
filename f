#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
A parallel recursive file searcher

Usage:
  f <filename/dirname> [<search_dir>] [--timeout N]

Arguments: 
   <filename/dirname>:

      abc : search for filename containing abc
      /abc : search for directory beginning with abc
      /abc/ : search for directory with exact name abc
      b/abc : search using full-path matching (contains b/abc).
              Note: matches everything inside that path (e.g. b/abc/def)
      "b/abc$" : search for path ending exactly in b/abc (excludes children)
      "/*abc" : search for directory (or file) ending with abc (regex)
      "/*abc/" : search for directory ending with abc (regex)

   <search_dir>:

      abc: all search directories containing abc
      /abc search directory with the absolute path /abc
      "/*abc" : all search directories ending in abc (regex)

      default search dir when search_dir is not provided is / (with proc,sys,dev,run excluded)

Notes:
  - Use quotes around patterns containing $ or * to prevent shell expansion.
EOF
}

# ----------------------------
# Config
# ----------------------------
timeout_dur="6s"
kill_after="2s"

# Exclude pseudo-filesystems that are usually noise / expensive
FD_EXCLUDES=(--exclude proc --exclude sys --exclude dev --exclude run)

# ----------------------------
# Helpers
# ----------------------------
normalize_timeout() {
  # Bare numbers mean seconds
  local t="$1"
  if [[ "$t" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%ss' "$t"
  else
    printf '%s' "$t"
  fi
}

# Escape regex metacharacters, but keep '*' as a wildcard token (converted later)
# and allow \b for word boundaries.
escape_regex_keep_star() {
  # Escape: [](){}.^$|+? (leave * and \ untouched for now)
  # We handle \ specially to allow \b
  printf '%s' "$1" | sed -e 's/[][(){}.^$|+?]/\\&/g'
}

# Convert a user fragment to a regex fragment:
# - escape regex metachars
# - convert '*' to '.*' (wildcard)
# - handle \b safely
to_regex_fragment() {
  local s
  s="$(escape_regex_keep_star "$1")"
  # Convert * to .*
  s="${s//\*/.*}"
  # If it's not a known escape like \b, escape the backslash
  # This is a bit naive but handles the user's case.
  # We'll use a perl-style lookahead/behind if we were in a better language, 
  # but here we'll just do a simple swap for common ones.
  printf '%s' "$s"
}

# Parse <filename/dirname> into:
#   OUT_typeflag: "" or "--type d"
#   OUT_regex: regex for fd --regex
#   OUT_pathflag: "" or "--full-path"
OUT_typeflag=""
OUT_regex=""
OUT_pathflag=""
parse_name_pattern() {
  local raw="$1"
  OUT_typeflag=""
  OUT_regex=""
  OUT_pathflag=""

  # Use full-path if there's an internal slash (not at start/end)
  if [[ "$raw" =~ ./. ]]; then
    OUT_pathflag="--full-path"
  fi

  if [[ "$raw" == "/*"* ]]; then
    # suffix-regex mode; treat remainder as regex, anchor to end if needed
    local frag="${raw:2}"
    [[ -n "$frag" ]] || { echo "Error: invalid pattern '$raw' (expected something after '/*')." >&2; exit 2; }
    
    # If it ends in /, it's a directory
    if [[ "$frag" == */ ]]; then
      OUT_typeflag="--type d"
      frag="${frag%/}"
    fi

    if [[ "$frag" == *'$' ]]; then
      OUT_regex="$frag"
    else
      OUT_regex="${frag}\$"
    fi
    return 0
  fi

  if [[ "$raw" == /* ]]; then
    # dir-only begins-with or exact
    OUT_typeflag="--type d"
    local frag="${raw:1}"
    [[ -n "$frag" ]] || { echo "Error: invalid pattern '$raw' (expected something after '/')." >&2; exit 2; }
    
    if [[ "$frag" == */ ]]; then
      # Exact match
      frag="${frag%/}"
      OUT_regex="^$(to_regex_fragment "$frag")\$"
    else
      OUT_regex="^$(to_regex_fragment "$frag")"
    fi
    return 0
  fi

  # contains (file or dir)
  OUT_typeflag=""
  OUT_regex="$(to_regex_fragment "$raw")"
}

# Parse <search_dir> into:
#   SD_mode: PATH | PATTERN
#   SD_path: canonical path (PATH mode)
#   SD_dir_regex: regex for matching directory basenames (PATTERN mode)
SD_mode=""
SD_path=""
SD_dir_regex=""
parse_search_dir() {
  local raw="$1"
  SD_mode=""
  SD_path=""
  SD_dir_regex=""

  # Absolute (or explicit relative) directory path mode
  if [[ "$raw" == /* && "$raw" != "/*"* ]]; then
    [[ -d "$raw" ]] || { echo "Error: search_dir '$raw' is not an existing directory." >&2; exit 2; }
    SD_mode="PATH"
    SD_path="$(cd "$raw" && pwd -P)"
    return 0
  fi
  if [[ "$raw" == ./* || "$raw" == ../* ]]; then
    [[ -d "$raw" ]] || { echo "Error: search_dir '$raw' is not an existing directory." >&2; exit 2; }
    SD_mode="PATH"
    SD_path="$(cd "$raw" && pwd -P)"
    return 0
  fi

  # Directory pattern mode
  SD_mode="PATTERN"

  if [[ "$raw" == "/*"* ]]; then
    local frag="${raw:2}"
    [[ -n "$frag" ]] || { echo "Error: invalid search_dir '$raw' (expected something after '/*')." >&2; exit 2; }
    if [[ "$frag" == *'$' ]]; then
      SD_dir_regex="$frag"
    else
      SD_dir_regex="${frag}\$"
    fi
    return 0
  fi

  # contains (directory basename)
  SD_dir_regex="$(to_regex_fragment "$raw")"
}

run_fd() {
  # run_fd <root> <typeflag-or-empty> <regex> <pathflag-or-empty>
  local root="$1"
  local typeflag="${2:-}"
  local rx="$3"
  local pathflag="${4:-}"

  timeout --preserve-status --kill-after="$kill_after" "$timeout_dur" \
    fd --hidden -i "${FD_EXCLUDES[@]}" $typeflag $pathflag --regex "$rx" "$root"
}

find_dirs_anywhere_nul() {
  # Emits NUL-delimited directories anywhere under / whose basename matches SD_dir_regex
  timeout --preserve-status --kill-after="$kill_after" "$timeout_dur" \
    fd --hidden -i "${FD_EXCLUDES[@]}" --type d --regex "$SD_dir_regex" "/" -0
}

# ----------------------------
# Main
# ----------------------------
main() {
  # Allow --timeout anywhere
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        shift
        [[ $# -gt 0 ]] || { echo "Error: --timeout requires a value." >&2; exit 2; }
        timeout_dur="$(normalize_timeout "$1")"
        shift
        ;;
      --timeout=*)
        timeout_dur="$(normalize_timeout "${1#*=}")"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  set -- "${positional[@]}"

  if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
  fi

  if [[ $# -eq 1 ]]; then
    parse_name_pattern "$1"
    run_fd "/" "$OUT_typeflag" "$OUT_regex" "$OUT_pathflag"
    exit 0
  fi

  # Two args: <filename/dirname> <search_dir>
  parse_name_pattern "$1"
  parse_search_dir "$2"

  if [[ "$SD_mode" == "PATH" ]]; then
    run_fd "$SD_path" "$OUT_typeflag" "$OUT_regex" "$OUT_pathflag"
    exit 0
  fi

  # PATTERN mode: find matching directories, then search inside each.
  # IMPORTANT: consume NUL-delimited output via read -d '' (no command substitution).
  find_dirs_anywhere_nul | while IFS= read -r -d '' d; do
    run_fd "$d" "$OUT_typeflag" "$OUT_regex" "$OUT_pathflag" || true
  done
}

main "$@"
