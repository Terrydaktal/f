#!/usr/bin/env bash
set -euo pipefail

usage() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 77)
  [[ $cols -gt 77 ]] && cols=77
  cat <<'EOF' | fmt -w "$cols" -s
A parallel recursive file searcher

Usage:
  f <name> [<search_dir>] [--dir|-d] [--file|-f] [--full] [--timeout N]

Arguments:
   SEARCH MATRIX:

   Goal           | Shorthand | Wildcard Format | Regex Format (r"")
   ---------------|-----------|-----------------|------------------
   Contains (All) | f abc     | f "*abc*"       | f r"abc"
   Contains (File)| f abc -f  | f "*abc*" -f    | f r"abc" -f
   Contains (Dir) | f abc -d  | f "*abc*" -d    | f r"abc" -d
   Exact (All)    | -         | f "abc"         | f r"^abc$"
   Exact (File)   | -         | f "abc" -f      | f r"^abc$" -f
   Exact (Dir)    | f /abc/   | f "abc" -d      | f r"^abc$" -d
   Starts (All)   | f /abc    | f "abc*"        | f r"^abc"
   Starts (File)  | f /abc -f | f "abc*" -f     | f r"^abc" -f
   Starts (Dir)   | f /abc -d | f "abc*" -d     | f r"^abc" -d
   Ends (All)     | -         | f "*abc"        | f r"abc$"
   Ends (File)    | -         | f "*abc" -f     | f r"abc$" -f
   Ends (Dir)     | f abc/    | f "*abc" -d     | f r"abc$" -d

   The --full flag matches against the full absolute path instead of just the basename.
   Example: f --full "*/src/main.c"
   Example: f --full r".*/test/.*\.py$"

   Note: In Wildcard/Regex formats, the quotes must be passed literally (e.g., f '"abc"').

   <search_dir>:
      Location to search. Behavior follows this priority:
      1. Local/Absolute Path: If the path exists on disk, the search is limited to that directory.
      2. Global Pattern Match: If the path does not exist, the script searches the ENTIRE disk for all directories matching the pattern (see matrix below) and searches inside them.

   SEARCH DIR MATRIX:

   Goal           | Shorthand | Wildcard Format | Regex Format (r"")
   ---------------|-----------|-----------------|------------------
   Contains (Rel) | -         | "*abc*"         | r"abc"
   Contains (Abs) | -         | "/*abc*"        | r"/abc/"
   Exact (Rel)    | abc       | "abc"           | r"^abc$"
   Exact (Abs)    | /abc      | "/abc"          | r"/^abc$/"
   Starts (Rel)   | -         | "abc*"          | r"^abc"
   Starts (Abs)   | -         | "/abc*"         | r"/^abc/"
   Ends (Rel)     | -         | "*abc"          | r"abc$"
   Ends (Abs)     | -         | "/*abc"         | r"/abc$/"

   Note: If the 1st check (Literal Path) fails, the script performs a global

Notes:
  - Use quotes around patterns containing $ or * to prevent shell expansion.
  - Prefix a pattern with r and wrap in quotes to treat it as a regex (e.g., f r"^test").

Options:
  --dir, -d
      Limit results to directories.
  --file, -f
      Limit results to files.
  --full
      Match against the full absolute path instead of just the basename.
  --timeout N
      Per-invocation timeout for each fd call. Default: 6s
      Examples: --timeout 10, --timeout 10s, --timeout 2m
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
# - handle \b safely
to_regex_fragment() {
  local s
  s="$(escape_regex_keep_star "$1")"

  # Treat unescaped '*' as a wildcard; preserve escaped '\*' as a literal.
  s="$(printf '%s' "$s" | sed -e 's/\\\*/__LITERAL_STAR__/g' -e 's/\*/.*/g' -e 's/__LITERAL_STAR__/\\*/g')"

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
  local use_regex=false
  if [[ "$raw" == r'"'*'"' || "$raw" == r"'"* "'" ]]; then
    use_regex=true
    raw="${raw:1}"
  fi
  OUT_typeflag=""
  OUT_regex=""
  OUT_pathflag=""

  # If pattern is wrapped in literal double or single quotes
  if [[ ( "$raw" == '"'*'"' ) || ( "$raw" == "'"*"'" ) ]]; then
    local inner="${raw:1}"
    inner="${inner%?}"

    # Strip leading/trailing slashes for basename patterns (unless it's just "/")
    inner="${inner#/}"
    [[ "$inner" != "/" ]] && inner="${inner%/}"

    if [[ "$use_regex" == "true" ]]; then
      OUT_regex="$inner"
    else
      # Wildcard mode inside quotes
      if [[ "$inner" == "*"*"*" ]]; then
          # *foo* -> contains
          local frag="${inner#\*}"
          frag="${frag%\*}"
          OUT_regex="$(to_regex_fragment "$frag")"
      elif [[ "$inner" == "*"* ]]; then
          # *foo -> ends with
          local frag="${inner#\*}"
          OUT_regex="$(to_regex_fragment "$frag")\$"
      elif [[ "$inner" == *"*" ]]; then
          # foo* -> starts with
          local frag="${inner%\*}"
          OUT_regex="^$(to_regex_fragment "$frag")"
      else
          # foo -> exact match
          OUT_regex="^$(to_regex_fragment "$inner")\$"
      fi
    fi
    return 0
  fi

  if [[ "$use_regex" == "true" ]]; then
    OUT_regex="$raw"
    return 0
  fi

  # Shorthand (No Quotes)
  # Exact Dir /abc/
  if [[ "$raw" == /*/ ]]; then
      local frag="${raw:1}"
      frag="${frag%/}"
      OUT_typeflag="--type d"
      OUT_regex="^$(to_regex_fragment "$frag")\$"
      return 0
  fi

  # Starts-with /abc
  if [[ "$raw" == /* ]]; then
      local frag="${raw:1}"
      OUT_regex="^$(to_regex_fragment "$frag")"
      return 0
  fi

  # Ends-with abc/ (directory)
  if [[ "$raw" != "/" && "$raw" == */ ]]; then
    OUT_typeflag="--type d"
    local no_slash="${raw%/}"
    OUT_regex="$(to_regex_fragment "$no_slash")\$"
    return 0
  fi

  # Default: contains
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
  local use_regex=false
  if [[ "$raw" == r'"'*'"' || "$raw" == r"'"* "'" ]]; then
    use_regex=true
    raw="${raw:1}"
  fi
  SD_mode=""
  SD_path=""
  SD_dir_regex=""

  # If it exists as a directory (relative or absolute), use it as a PATH.
  if [[ "$use_regex" == "false" && -d "$raw" ]]; then
    SD_mode="PATH"
    SD_path="$(cd "$raw" && pwd -P)"
    return 0
  fi

  # Strip trailing slash for further processing if it's not just "/"
  local normalized="$raw"
  if [[ "$normalized" != "/" ]]; then
    normalized="${normalized%/}"
  fi

  SD_mode="PATTERN"

  # If pattern is wrapped in literal double or single quotes
  if [[ ( "$raw" == '"'*'"' ) || ( "$raw" == "'"*"'" ) ]]; then
    local inner="${raw:1}"
    inner="${inner%?}"

    # Path check for the inner content (Relative or Absolute)
    if [[ "$use_regex" == "false" && -d "$inner" ]]; then
      SD_mode="PATH"
      SD_path="$(cd "$inner" && pwd -P)"
      return 0
    fi

    # Strip leading/trailing slashes for basename patterns (unless it's just "/")
    local pattern_inner="$inner"
    pattern_inner="${pattern_inner#/}"
    [[ "$pattern_inner" != "/" ]] && pattern_inner="${pattern_inner%/}"

    if [[ "$use_regex" == "true" ]]; then
      SD_dir_regex="$pattern_inner"
    else
      # Wildcard mode inside quotes
      if [[ "$pattern_inner" == "*"*"*" ]]; then
          # *foo* -> contains
          local frag="${pattern_inner#\*}"
          frag="${frag%\*}"
          SD_dir_regex="$(to_regex_fragment "$frag")"
      elif [[ "$pattern_inner" == "*"* ]]; then
          # *foo -> ends with
          local frag="${pattern_inner#\*}"
          SD_dir_regex="$(to_regex_fragment "$frag")\$"
      elif [[ "$pattern_inner" == *"*" ]]; then
          # foo* -> starts with
          local frag="${pattern_inner%\*}"
          SD_dir_regex="^$(to_regex_fragment "$frag")"
      else
          # foo -> exact match
          SD_dir_regex="^$(to_regex_fragment "$pattern_inner")\$"
      fi
    fi
    return 0
  fi

  if [[ "$use_regex" == "true" ]]; then
    SD_dir_regex="$normalized"
    return 0
  fi

  # Shorthand (No Quotes)
  # Exact /abc/ or ./abc/
  if [[ "$raw" == /*/ ]]; then
      local frag="${raw:1}"
      frag="${frag%/}"
      SD_dir_regex="^$(to_regex_fragment "$frag")\$"
      return 0
  elif [[ "$raw" == ./*/ ]]; then
      local frag="${raw:2}"
      frag="${frag%/}"
      SD_dir_regex="^$(to_regex_fragment "$frag")\$"
      return 0
  fi

  # Starts-with /abc or ./abc
  if [[ "$raw" == /* ]]; then
      local frag="${raw:1}"
      SD_dir_regex="^$(to_regex_fragment "$frag")"
      return 0
  elif [[ "$raw" == ./* ]]; then
      local frag="${raw:2}"
      SD_dir_regex="^$(to_regex_fragment "$frag")"
      return 0
  fi

  # Ends-with abc/
  if [[ "$raw" != "/" && "$raw" == */ ]]; then
      local frag="${raw%/}"
      SD_dir_regex="$(to_regex_fragment "$frag")\$"
      return 0
  fi

  # Default: contains (Rel)
  SD_dir_regex="$(to_regex_fragment "$normalized")"
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
  # Allow --timeout, --dir/-d, --full/-f anywhere
  local positional=()
  local force_dir=false
  local force_file=false
  local force_full=false

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
      --dir|-d)
        force_dir=true
        shift
        ;;
      --file|-f)
        force_file=true
        shift
        ;;
      --full)
        force_full=true
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

  parse_name_pattern "$1"

  if [[ "$force_full" == "true" ]]; then
    OUT_pathflag="--full-path"
  fi

  if [[ "$force_dir" == "true" ]]; then
    OUT_typeflag="--type d"
  fi
  if [[ "$force_file" == "true" ]]; then
    OUT_typeflag="--type f"
  fi

  if [[ $# -eq 1 ]]; then
    run_fd "." "$OUT_typeflag" "$OUT_regex" "$OUT_pathflag"
    exit 0
  fi

  # Two args: <filename/dirname> <search_dir>
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
