#!/usr/bin/env bash
set -euo pipefail

usage() {
  local cols
  cols=$(tput cols 2>/dev/null || echo 77)
  [[ $cols -gt 77 ]] && cols=77
  cat <<'EOF' | fmt -w "$cols" -s
A parallel recursive file searcher

Usage:
  f <filename/dirname> [<search_dir>]
  f (--full|-F) <pattern1>  [<pattern2> <pattern3>...]
                       [--dir|-d] [--file|-f] [--bypass|-b] [--timeout N]

Arguments:
   <filename/dirname>:
      The file or directory name to search for. Supports exact, partial,
      and regex matching based on the pattern format (see matrix below).

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

   <search_dir>:
      Location to search. Defaults to '.' (the current directory).
      Behavior follows this priority:
      1. Local/Absolute Path: If the path exists on disk (e.g., '.', '/', or
         a specific path), the search is limited to that directory and will
         not fallback to a global search.
      2. Global Pattern Match: If the path does not exist, the script
         searches the ENTIRE disk for all directories matching the pattern
         (see matrix below) and searches inside them.

   SEARCH DIR MATRIX:

   Goal           | Shorthand | Wildcard Format | Regex Format (r"")
   ---------------|-----------|-----------------|------------------
   Contains       | abc       | "*abc*"         | r"abc"
   Exact          | /abc/     | "abc"           | r"^abc$"
   Starts         | /abc      | "abc*"          | r"^abc"
   Ends           | abc/      | "*abc"          | r"abc$"

   Note: If the 1st check (Literal Path) fails, the script performs a global


   The --full flag matches against the full absolute path instead of just the basename.
   It supports multiple patterns (implicit AND) and prunes redundant child results.
   
   Example: f --full "src" "main"   # Matches BOTH (hides children)
   Example: f --full "test"         # Returns /path/to/test, but hides /path/to/test/file

   Note: In Wildcard/Regex formats, the quotes must be passed literally (e.g., f '"abc"').

Notes:
  - Use quotes around patterns containing $ or * to prevent shell expansion.
  - Prefix a pattern with r and wrap in quotes to treat it as a regex (e.g., f r"^test").

Options:
  --dir, -d
      Limit results to directories.
  --file, -f
      Limit results to files.
  --counts
      Show a summary of matches by parent folder (folder path + count), instead
      of listing every matching file. If a directory itself matches, it counts
      as 1 match for its parent folder. Note: --info does not change --counts
      output.
      Renamed from --audit (which is no longer accepted).
  --full, -F
      Match against the full absolute path instead of just the basename.
  --info, -i
      Show the date of last modification and size at the start of each line.
  --no-ignore, -I
      Show files and directories that are ignored by .gitignore, etc.
  --timeout N
      Per-invocation timeout for each fd call. Default: 6s
      Examples: --timeout 10, --timeout 10s, --timeout 2m
  --bypass, -b
      Force treating the search_dir as a pattern, even if it exists as a directory.
EOF
}

# ----------------------------
# Config
# ----------------------------
timeout_dur="6s"
kill_after="2s"
FORCE_PATTERN_MODE=false
SHOW_INFO=false
COUNTS=false
NO_IGNORE="--no-ignore"

# Detect if stdout is a TTY
if [ -t 1 ]; then
  IS_TTY=true
else
  IS_TTY=false
fi

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

wildcard_to_regex() {
  # Convert a glob-ish pattern to a regex with sensible anchoring:
  # - "word*"  => starts-with
  # - "*word"  => ends-with
  # - "*word*" => contains
  # - "word"   => exact
  #
  # We only look at leading/trailing '*' for anchoring; internal '*' are handled
  # by to_regex_fragment().
  local pat="$1"
  local lead_star=false
  local trail_star=false

  if [[ "${pat:0:1}" == "*" ]]; then
    lead_star=true
  fi

  if [[ "${pat: -1}" == "*" ]]; then
    # Treat a trailing "\*" as a literal star, not a wildcard.
    if [[ ${#pat} -lt 2 || "${pat: -2:1}" != "\\" ]]; then
      trail_star=true
    fi
  fi

  local rx
  rx="$(to_regex_fragment "$pat")"
  if [[ "$lead_star" != "true" ]]; then
    rx="^$rx"
  fi
  if [[ "$trail_star" != "true" ]]; then
    rx="${rx}\$"
  fi
  printf '%s' "$rx"
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
  if [[ "$raw" == r'"'*'"' || "$raw" == r"'"*"'" ]]; then
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
      OUT_regex="$(wildcard_to_regex "$inner")"
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

  # Wildcard semantics when the user provided '*' (e.g. "*.deb" => ends-with ".deb")
  if [[ "$raw" == *\** ]]; then
    OUT_regex="$(wildcard_to_regex "$raw")"
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
  if [[ "$raw" == r'"'*'"' || "$raw" == r"'"*"'" ]]; then
    use_regex=true
    raw="${raw:1}"
  fi
  SD_mode=""
  SD_path=""
  SD_dir_regex=""

  # If it exists as a directory (relative or absolute), use it as a PATH.
  if [[ "$FORCE_PATTERN_MODE" == "false" && "$use_regex" == "false" && -d "$raw" ]]; then
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
      SD_dir_regex="$(wildcard_to_regex "$pattern_inner")"
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

  # Wildcard semantics when the user provided '*'
  if [[ "$normalized" == *\** ]]; then
    SD_dir_regex="$(wildcard_to_regex "$normalized")"
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

  local color_opt=""
  # Force color if output is a TTY.
  # If showing info, we handle color stripping in the transform.
  if [[ "$IS_TTY" == "true" ]]; then
    color_opt="--color=always"
  fi

  timeout --preserve-status --kill-after="$kill_after" "$timeout_dur" \
    fd $color_opt --hidden $NO_IGNORE -i "${FD_EXCLUDES[@]}" $typeflag $pathflag --regex "$rx" "$root"
}

find_dirs_anywhere_nul() {
  # Emits NUL-delimited directories anywhere under / whose basename matches SD_dir_regex
  timeout --preserve-status --kill-after="$kill_after" "$timeout_dur" \
    fd --hidden $NO_IGNORE -i "${FD_EXCLUDES[@]}" --type d --regex "$SD_dir_regex" "/" -0
}

prune_children() {
  # Input must be sorted. Filters out paths that are children of the previous path.
  awk '{
    # Normalize last path: remove trailing slash for prefix construction
    prefix = last
    sub(/\/$/, "", prefix)
    
    # Check if current line starts with prefix + "/"
    # Ensure prefix is not empty or handled correctly
    if (last != "" && index($0, prefix "/") == 1) {
      next
    }
    print $0
    last = $0
  }'
}

add_info_transform() {
  if [[ "$SHOW_INFO" != "true" ]]; then
    cat
    return
  fi

  while IFS= read -r line; do
    # Strip ANSI escape codes to get the clean file path for stat
    # (Matches \e[...m)
    local clean_path
    clean_path=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')

    # Get date and size
    # stat -c "%y %s" -> YYYY-MM-DD HH:MM:SS.NNN TZ SIZE
    local stat_out
    stat_out=$(stat -c "%y %s" "$clean_path" 2>/dev/null || true)

    if [[ -n "$stat_out" ]]; then
      # Extract just YYYY-MM-DD and SIZE
      # Pattern: ^(YYYY-MM-DD) ... (SIZE)$
      # Cut or sed.
      # sed 's/^\([0-9-]*\) .* \([0-9]*\)$/\1 \2/'
      local info
      info=$(echo "$stat_out" | sed 's/^\([0-9-]*\) .* \([0-9]*\)$/\1 \2/')
      echo "$info $line"
    fi
  done
}

counts_summary_transform() {
  # Summarize matches as: <count> <folder>
  # - strips ANSI colors
  # - strips optional "YYYY-MM-DD SIZE " info prefix (from --info)
  # - normalizes directory matches by removing trailing "/"
  if [[ "$IS_TTY" == "true" ]]; then
    printf '%7s  %s\n' "COUNT" "FOLDER"
  fi

  awk '
    {
      line=$0
      gsub(/\x1b\[[0-9;]*m/, "", line)
      sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]+ /, "", line)

      p=line
      sub(/\/$/, "", p)

      d=p
      if (match(d, /\//)) {
        sub(/\/[^\/]+$/, "", d)
        if (d == "") d="/"
      } else {
        d="."
      }
      counts[d]++
    }
    END {
      for (d in counts) {
        printf "%d\t%s\n", counts[d], d
      }
    }
  ' \
  | sort -nr -k1,1 -k2,2 \
  | awk -F"\t" '{ printf "%7d  %s\n", $1, $2 }'
}

final_transform() {
  if [[ "$COUNTS" == "true" ]]; then
    counts_summary_transform
  else
    add_info_transform
  fi
}

# ----------------------------
# Main
# ----------------------------
main() {
  # Allow --timeout, --dir/-d, --full/-F anywhere
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
      --full|-F)
        force_full=true
        shift
        ;;
      --no-ignore|-I)
        NO_IGNORE="--no-ignore"
        shift
        ;;
      --bypass|-b)
        FORCE_PATTERN_MODE=true
        shift
        ;;
      --info|-i)
        SHOW_INFO=true
        shift
        ;;
      --counts)
        COUNTS=true
        shift
        ;;
      --audit)
        echo "f: --audit was renamed to --counts" >&2
        exit 2
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

  if [[ $# -lt 1 ]]; then
    usage
    exit 2
  fi

  # ---------------------------------------------------------
  # --full Mode: Support multiple patterns (AND logic) + Pruning
  # ---------------------------------------------------------
  if [[ "$force_full" == "true" ]]; then
    # Identify Search Directory
    # Rule: If the last argument is a valid directory, use it. Otherwise search "."
    # (Unless there's only 1 arg and it's not a dir? Then we search "." anyway)
    local search_root="."
    local patterns=()
    local last_arg="${!#}"

    if [[ $# -gt 1 && -d "$last_arg" ]]; then
      search_root="$last_arg"
      # Take all args except the last
      patterns=("${@:1:$#-1}")
    else
      # All args are patterns
      patterns=("${@}")
    fi

    # Determine type flags (dirs/files) based on flags and pattern hints
    local type_arg=""
    [[ "$force_dir" == "true" ]] && type_arg="--type d"
    [[ "$force_file" == "true" ]] && type_arg="--type f"

    # Pre-calculate regexes for all patterns
    local regexes=()
    for p in "${patterns[@]}"; do
      parse_name_pattern "$p"
      regexes+=("$OUT_regex")
      # If any pattern implies directory (e.g. "foo/"), force dir mode unless file mode is explicit
      if [[ "$OUT_typeflag" == "--type d" && "$force_file" == "false" ]]; then
        type_arg="--type d"
      fi
    done

    # Run the pipeline
    # 1. fd with the first regex
    # 2. grep for subsequent regexes
    # 3. sort
    # 4. prune_children (if searching directories, or mixed? Pruning valid for all paths really)
    #    Actually, if we found /a/b and /a/b/c, and both matched, user wants only /a/b.

    local first_regex="${regexes[0]}"
    
    # We use a subshell to construct the pipe chain
    (
      # Use --color=never for pipes to avoid escape codes confusing grep/awk
      # Use --full-path explicitly
      run_fd "$search_root" "$type_arg" "$first_regex" "--full-path" --color=never \
      | {
        # Loop through remaining patterns and pipe through grep -P
        for ((i=1; i<${#regexes[@]}; i++)); do
           grep -P "${regexes[$i]}" || true # || true to prevent pipe crash if empty
        done
        # Pass through cat if no more patterns (noop)
        cat
      } \
      | sort \
      | prune_children
    ) | final_transform

    exit 0
  fi

  # ---------------------------------------------------------
  # Standard Mode (Original Behavior)
  # ---------------------------------------------------------
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
    run_fd "." "$OUT_typeflag" "$OUT_regex" "$OUT_pathflag" | final_transform
    exit 0
  fi

  # Two args: <filename/dirname> <search_dir>
  parse_search_dir "$2"

  if [[ "$SD_mode" == "PATH" ]]; then
    run_fd "$SD_path" "$OUT_typeflag" "$OUT_regex" "$OUT_pathflag" | final_transform
    exit 0
  fi

  # PATTERN mode: find matching directories, then search inside each.
  # IMPORTANT: consume NUL-delimited output via read -d '' (no command substitution).
  find_dirs_anywhere_nul | while IFS= read -r -d '' d; do
    run_fd "$d" "$OUT_typeflag" "$OUT_regex" "$OUT_pathflag" || true
  done | awk '!seen[$0]++ { print; fflush() }' | final_transform
}

main "$@"
