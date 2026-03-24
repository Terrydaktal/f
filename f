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
                       [--dir|-d] [--file|-f] [--regex|-r] [--bypass|-b]
                       [--absolute-paths|-A]
                       [--timeout N] [--sort date|size|name asc|desc]
                       [--no-recurse|-R] [--follow-links]
                       [--ignore] [--visible-only] [--threads N] [--cache-raw]
  f (--version|-V)

Arguments:
   <filename/dirname>:
      The file or directory name to search for. Supports exact and partial
      matching by default; use --regex/-r for regex matching.

   SEARCH MATRIX:

   Goal           | Shorthand  | Wildcard Format | Regex Format
   ---------------|------------|-----------------|------------------
   Contains (All) | f abc      | f "*abc*"       | f -r "abc"
   Contains (File)| f abc -f   | f "*abc*" -f    | f -r "abc" -f
   Contains (Dir) | f abc -d   | f "*abc*" -d    | f -r "abc" -d
   Exact (All)    | -          | -               | f -r "^abc$"
   Exact (File)   | -          | -               | f -r "^abc$" -f
   Exact (Dir)    | f /abc/    | -               | f -r "^abc$" -d
   Starts (All)   | f /abc     | f "abc*"        | f -r "^abc"
   Starts (File)  | f /abc -f  | f "abc*" -f     | f -r "^abc" -f
   Starts (Dir)   | f /abc -d  | f "abc*" -d     | f -r "^abc" -d
   Ends (All)     | -          | f "*abc"        | f -r "abc$"
   Ends (File)    | -          | f "*abc" -f     | f -r "abc$" -f
   Ends (Dir)     | f abc/     | f "*abc" -d     | f -r "abc$" -d

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

   Goal           | Shorthand | Wildcard Format | Regex Format
   ---------------|-----------|-----------------|------------------
   Contains       | abc       | "*abc*"         | -r "abc"
   Exact          | /abc/     | -               | -r "^abc$"
   Starts         | /abc      | "abc*"          | -r "^abc"
   Ends           | abc/      | "*abc"          | -r "abc$"

   Note: If the 1st check (Literal Path) fails, the script performs a global


   The --full flag matches against the full absolute path instead of just the basename.
   It supports multiple patterns (implicit AND) and prunes redundant child results.
   
   Example: f --full "src" "main"   # Matches BOTH (hides children)
   Example: f --full "test"         # Returns /path/to/test, but hides /path/to/test/file

Notes:
  - Use quotes around patterns containing $ or * to prevent shell expansion.
  - Regex mode is only enabled with --regex/-r.
  - Plain patterns are contains. For exact matches use regex anchors
    (e.g., --regex "^word$"), or /word/ for exact-directory shorthand.

Options:
  --dir, -d
      Limit results to directories.
  --file, -f
      Limit results to files.
  --counts
      Show a summary of matches by parent folder (folder path + count), instead
      of listing every matching file. If a directory itself matches, it counts
      as 1 match for its parent folder. Note: --long does not change --counts
      output.
      Renamed from --audit (which is no longer accepted).
  --full, -F
      Match against the full absolute path instead of just the basename.
  --absolute-paths, -A
      Print absolute paths in output (display only). Does not change matching
      behavior.
  --regex, -r
      Treat filename/dirname and search_dir patterns as regular expressions.
  --long, -l
      Show the date and time of last modification and size
      (B, KiB, MiB, GiB, TiB) at the start of each line.
  -L, --long-true-dirsize
      Extended long output for directories:
      YYYY-MM-DD HH:MM:SS REALDIRSIZE FILECOUNT PATH
      Symlinked directories are not traversed (shown as link size, count 0).
  --sort FIELD ORDER
      Sort listed results by metadata. Supported:
      --sort date asc|desc, --sort size asc|desc, --sort name asc|desc
      For directories, size sort uses real allocated directory size.
      With --no-recurse/-R, size sort uses direct entry size for speed.
      Note: --counts output is always sorted by count/folder and ignores --sort.
  --no-recurse, -R
      Search only the immediate entries in each search root (no recursion).
  --follow-links
      Follow symlinked directories while searching.
  --ignore
      Respect ignore rules (.gitignore/.ignore/.fdignore). By default, f
      bypasses ignore rules.
  --visible-only
      Exclude hidden files/directories (dotfiles). By default, f includes
      hidden entries.
  --threads N
      Set worker thread count for fd and directory size calculations.
      Must be a positive integer. Default: 8.
  --cache-raw
      Save matched directories to:
      /tmp/fzf-history-$USER/universal-last-dirs-<fish pid>
      and files to:
      /tmp/fzf-history-$USER/universal-last-files-<fish pid>
      For every match, also save its parent directory to the dirs file.
      Renamed from --cache (which is no longer accepted).
  --timeout N
      Per-invocation timeout for each fd call. Default: 6s
      Examples: --timeout 10, --timeout 10s, --timeout 2m
  --bypass, -b
      Force treating the search_dir as a pattern, even if it exists as a directory.
  --version, -V
      Show version and exit.
EOF
}

# ----------------------------
# Config
# ----------------------------
VERSION="0.7.7"
timeout_dur="6s"
kill_after="2s"
FORCE_PATTERN_MODE=false
LONG_FORMAT=false
LONG_EXTENDED=false
COUNTS=false
REGEX_MODE=false
SORT_FIELD=""
SORT_ORDER=""
NO_RECURSE=false
FOLLOW_LINKS=false
RESPECT_IGNORE=false
VISIBLE_ONLY=false
THREADS_OVERRIDE="8"
DIRSIZE_THREADS=8
CACHE_OUTPUT=false
ABSOLUTE_PATHS=false
HAVE_DIRSIZE=false
if command -v dirsize >/dev/null 2>&1; then
  HAVE_DIRSIZE=true
fi
declare -A DIR_STATS_FILES
declare -A DIR_STATS_BYTES
declare -A DIR_STATS_HUMAN

# Read colors from LS_COLORS when available; otherwise use built-in defaults.
COLOR_RESET=$'\033[0m'
COLOR_PREFIX_DIR="38;2;255;255;255"
COLOR_DIR="01;34"
COLOR_LINK="01;36"
COLOR_EXEC="01;32"
COLOR_SPEC="${LS_COLORS:-}"
declare -A COLOR_CODE_BY_KEY
declare -a COLOR_GLOB_PATTERNS
declare -a COLOR_GLOB_CODES
if [[ -n "$COLOR_SPEC" ]]; then
  IFS=':' read -r -a _ls_colors_entries <<< "$COLOR_SPEC"
  for _entry in "${_ls_colors_entries[@]}"; do
    [[ "$_entry" == *=* ]] || continue
    _key="${_entry%%=*}"
    _val="${_entry#*=}"
    if [[ "$_key" == \** ]]; then
      COLOR_GLOB_PATTERNS+=("$_key")
      COLOR_GLOB_CODES+=("$_val")
      continue
    fi
    COLOR_CODE_BY_KEY["$_key"]="$_val"
    case "$_key" in
      di) COLOR_DIR="$_val" ;;
      ln) COLOR_LINK="$_val" ;;
      ex) COLOR_EXEC="$_val" ;;
    esac
  done
fi

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

color_wrap() {
  local code="$1"
  local text="$2"
  if [[ -z "$code" ]]; then
    printf '%s' "$text"
  else
    printf '\033[%sm%s%s' "$code" "$text" "$COLOR_RESET"
  fi
}

color_code_for_path() {
  # color_code_for_path <abs_path> <display_path>
  local abs_path="$1"
  local display_path="$2"
  local base="${display_path%/}"
  base="${base##*/}"
  local code=""
  local allow_glob_overrides=false

  # Base class color by filesystem type.
  if [[ -L "$abs_path" ]]; then
    if [[ ! -e "$abs_path" && -n "${COLOR_CODE_BY_KEY[or]:-}" ]]; then
      code="${COLOR_CODE_BY_KEY[or]}"
    else
      code="${COLOR_CODE_BY_KEY[ln]:-$COLOR_LINK}"
    fi
  elif [[ -d "$abs_path" ]]; then
    local dir_mode other_writable
    dir_mode="$(stat -c '%A' "$abs_path" 2>/dev/null || true)"
    other_writable=false
    if [[ ${#dir_mode} -ge 9 && "${dir_mode:8:1}" == "w" ]]; then
      other_writable=true
    fi

    if [[ -k "$abs_path" && "$other_writable" == "true" && -n "${COLOR_CODE_BY_KEY[tw]:-}" ]]; then
      code="${COLOR_CODE_BY_KEY[tw]}"
    elif [[ -k "$abs_path" && -n "${COLOR_CODE_BY_KEY[st]:-}" ]]; then
      code="${COLOR_CODE_BY_KEY[st]}"
    elif [[ "$other_writable" == "true" && -n "${COLOR_CODE_BY_KEY[ow]:-}" ]]; then
      code="${COLOR_CODE_BY_KEY[ow]}"
    else
      code="${COLOR_CODE_BY_KEY[di]:-$COLOR_DIR}"
    fi
  elif [[ -p "$abs_path" ]]; then
    code="${COLOR_CODE_BY_KEY[pi]:-}"
  elif [[ -S "$abs_path" ]]; then
    code="${COLOR_CODE_BY_KEY[so]:-}"
  elif [[ -b "$abs_path" ]]; then
    code="${COLOR_CODE_BY_KEY[bd]:-}"
  elif [[ -c "$abs_path" ]]; then
    code="${COLOR_CODE_BY_KEY[cd]:-}"
  elif [[ -f "$abs_path" && -u "$abs_path" && -n "${COLOR_CODE_BY_KEY[su]:-}" ]]; then
    code="${COLOR_CODE_BY_KEY[su]}"
    allow_glob_overrides=true
  elif [[ -f "$abs_path" && -g "$abs_path" && -n "${COLOR_CODE_BY_KEY[sg]:-}" ]]; then
    code="${COLOR_CODE_BY_KEY[sg]}"
    allow_glob_overrides=true
  elif [[ -f "$abs_path" && -x "$abs_path" ]]; then
    code="${COLOR_CODE_BY_KEY[ex]:-$COLOR_EXEC}"
    allow_glob_overrides=true
  elif [[ -f "$abs_path" ]]; then
    code="${COLOR_CODE_BY_KEY[fi]:-}"
    allow_glob_overrides=true
  else
    code="${COLOR_CODE_BY_KEY[no]:-}"
  fi

  # Apply glob/pattern overrides (e.g., *.md, *README) to regular files only.
  if [[ "$allow_glob_overrides" == "true" ]]; then
    local -a glob_patterns glob_codes
    glob_patterns=("${COLOR_GLOB_PATTERNS[@]-}")
    glob_codes=("${COLOR_GLOB_CODES[@]-}")
    local i pattern
    for ((i=0; i<${#glob_patterns[@]}; i++)); do
      pattern="${glob_patterns[$i]}"
      # shellcheck disable=SC2053 # intentional glob-style match against color pattern keys
      if [[ "$base" == $pattern ]]; then
        code="${glob_codes[$i]}"
        break
      fi
    done
  fi

  printf '%s' "$code"
}

colorize_path_display() {
  # colorize_path_display <display_path> <abs_path>
  local display_path="$1"
  local abs_path="$2"
  local code leaf_code prefix leaf path_core
  code="$(color_code_for_path "$abs_path" "$display_path")"
  leaf_code="$code"

  # Mimic fd-like rendering: prefix path in directory color, leaf in its own class color.
  if [[ "$display_path" == */* ]]; then
    if [[ "$display_path" == */ ]]; then
      path_core="${display_path%/}"
      prefix="${path_core%/*}/"
      leaf="${path_core##*/}/"
    else
      prefix="${display_path%/*}/"
      leaf="${display_path##*/}"
    fi

    if [[ -n "$prefix" ]]; then
      color_wrap "$COLOR_PREFIX_DIR" "$prefix"
    fi
    color_wrap "$leaf_code" "$leaf"
  else
    color_wrap "$leaf_code" "$display_path"
  fi
}

escape_file_url_path() {
  local url_path="$1"
  url_path="${url_path//%/%25}"
  url_path="${url_path// /%20}"
  url_path="${url_path//#/%23}"
  url_path="${url_path//\?/%3F}"
  printf '%s' "$url_path"
}

display_path_to_abs_path() {
  # display_path_to_abs_path <display_path> <cwd_abs>
  local display_path="$1"
  local cwd_abs="$2"
  if [[ "$display_path" == /* ]]; then
    printf '%s' "$display_path"
  else
    printf '%s/%s' "$cwd_abs" "${display_path#./}"
  fi
}

make_hyperlink_text() {
  # make_hyperlink_text <abs_target> <display_text>
  local abs_target="$1"
  local display_text="$2"
  printf '%b%s%b%s%b' \
    $'\033]8;;file://' \
    "$(escape_file_url_path "$abs_target")" \
    $'\033\\' \
    "$display_text" \
    $'\033]8;;\033\\'
}

render_split_hyperlinked_path() {
  # render_split_hyperlinked_path <display_path> <abs_path> <cwd_abs>
  # Emits two OSC-8 links when possible:
  # - prefix path -> parent directory
  # - leaf segment -> file/dir itself
  local display_path="$1"
  local abs_path="$2"
  local cwd_abs="$3"
  local prefix_display="" leaf_display=""
  local prefix_abs="" leaf_abs="$abs_path"
  local leaf_code leaf_colored prefix_colored leaf_name path_core

  if [[ "$display_path" == */ ]]; then
    path_core="${display_path%/}"
    if [[ -z "$path_core" ]]; then
      leaf_display="/"
    elif [[ "$path_core" == */* ]]; then
      prefix_display="${path_core%/*}/"
      leaf_display="${path_core##*/}/"
    else
      leaf_display="${path_core}/"
    fi
  else
    if [[ "$display_path" == */* ]]; then
      prefix_display="${display_path%/*}/"
      leaf_display="${display_path##*/}"
    else
      leaf_display="$display_path"
    fi
  fi

  if [[ -n "$prefix_display" ]]; then
    prefix_abs="$(display_path_to_abs_path "$prefix_display" "$cwd_abs")"
  fi

  if [[ "$display_path" == */ ]]; then
    if [[ -n "$prefix_abs" ]]; then
      leaf_name="${leaf_display%/}"
      leaf_abs="${prefix_abs%/}/${leaf_name}/"
    else
      leaf_abs="$abs_path"
    fi
  else
    leaf_abs="$abs_path"
  fi

  leaf_code="$(color_code_for_path "$abs_path" "$display_path")"
  leaf_colored="$(color_wrap "$leaf_code" "$leaf_display")"

  if [[ -n "$prefix_display" ]]; then
    prefix_colored="$(color_wrap "$COLOR_PREFIX_DIR" "$prefix_display")"
    printf '%s%s' \
      "$(make_hyperlink_text "$prefix_abs" "$prefix_colored")" \
      "$(make_hyperlink_text "$leaf_abs" "$leaf_colored")"
  else
    printf '%s' "$(make_hyperlink_text "$leaf_abs" "$leaf_colored")"
  fi
}

DIRSIZE_FILES=""
DIRSIZE_BYTES=""
DIRSIZE_HUMAN=""
get_dirsize_stats() {
  local path="$1"
  DIRSIZE_FILES=""
  DIRSIZE_BYTES=""
  DIRSIZE_HUMAN=""

  # Never resolve symlinked directories here.
  if [[ -L "$path" ]]; then
    return 1
  fi

  if [[ -n "${DIR_STATS_BYTES[$path]+x}" ]]; then
    DIRSIZE_FILES="${DIR_STATS_FILES[$path]}"
    DIRSIZE_BYTES="${DIR_STATS_BYTES[$path]}"
    DIRSIZE_HUMAN="${DIR_STATS_HUMAN[$path]}"
    return 0
  fi

  if [[ "$HAVE_DIRSIZE" != "true" ]]; then
    return 1
  fi

  local out files bytes human
  out=$(dirsize "$path" --threads "$DIRSIZE_THREADS" 2>/dev/null || true)
  [[ -n "$out" ]] || return 1

  files=$(printf '%s\n' "$out" | awk -F': *' '/^files:/ {print $2; exit}')
  bytes=$(printf '%s\n' "$out" | awk -F': *' '/^bytes:/ {print $2; exit}')
  human=$(printf '%s\n' "$out" | awk -F': *' '/^human:/ {print $2; exit}')

  files=$(printf '%s' "$files" | tr -d '[:space:]')
  bytes=$(printf '%s' "$bytes" | tr -d '[:space:]')
  human=$(printf '%s' "$human" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

  if [[ "$files" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ && -n "$human" ]]; then
    DIR_STATS_FILES["$path"]="$files"
    DIR_STATS_BYTES["$path"]="$bytes"
    DIR_STATS_HUMAN["$path"]="$human"
    DIRSIZE_FILES="$files"
    DIRSIZE_BYTES="$bytes"
    DIRSIZE_HUMAN="$human"
    return 0
  fi

  return 1
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
  local use_regex="$REGEX_MODE"
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
  local use_regex="$REGEX_MODE"
  SD_mode=""
  SD_path=""
  SD_dir_regex=""

  # If it exists as a directory (relative or absolute), use it as a PATH.
  if [[ "$FORCE_PATTERN_MODE" == "false" && -d "$raw" ]]; then
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
    if [[ "$FORCE_PATTERN_MODE" == "false" && -d "$inner" ]]; then
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

print_version() {
  printf 'f %s\n' "$VERSION"
}

set_threads_value() {
  local n="$1"
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: --threads requires a positive integer." >&2
    exit 2
  fi
  THREADS_OVERRIDE="$n"
  DIRSIZE_THREADS="$n"
}

run_fd() {
  # run_fd <root> <typeflag-or-empty> <regex> <pathflag-or-empty> [extra-fd-opts...]
  local root="$1"
  local typeflag="${2:-}"
  local rx="$3"
  local pathflag="${4:-}"
  shift 4
  local extra_opts=("$@")

  local fd_args=(fd --color=never -i "${FD_EXCLUDES[@]}")
  if [[ "$RESPECT_IGNORE" != "true" ]]; then
    fd_args+=(--no-ignore)
  fi
  if [[ -n "$THREADS_OVERRIDE" ]]; then
    fd_args+=(--threads "$THREADS_OVERRIDE")
  fi
  if [[ "$VISIBLE_ONLY" != "true" ]]; then
    fd_args+=(--hidden)
  fi
  if [[ "$FOLLOW_LINKS" == "true" ]]; then
    fd_args+=(--follow)
  fi
  if [[ "$NO_RECURSE" == "true" ]]; then
    fd_args+=(--max-depth 1)
  fi
  if [[ -n "$typeflag" ]]; then
    # typeflag can be two words (e.g., "--type f")
    # shellcheck disable=SC2206
    local tf_parts=($typeflag)
    fd_args+=("${tf_parts[@]}")
  fi
  [[ -n "$pathflag" ]] && fd_args+=("$pathflag")
  (( ${#extra_opts[@]} )) && fd_args+=("${extra_opts[@]}")
  fd_args+=(--regex "$rx" "$root")

  timeout --preserve-status --kill-after="$kill_after" "$timeout_dur" \
    "${fd_args[@]}"
}

find_dirs_anywhere_nul() {
  # Emits NUL-delimited directories anywhere under / whose basename matches SD_dir_regex
  local fd_args=(fd -i "${FD_EXCLUDES[@]}")
  if [[ "$RESPECT_IGNORE" != "true" ]]; then
    fd_args+=(--no-ignore)
  fi
  if [[ -n "$THREADS_OVERRIDE" ]]; then
    fd_args+=(--threads "$THREADS_OVERRIDE")
  fi
  if [[ "$VISIBLE_ONLY" != "true" ]]; then
    fd_args+=(--hidden)
  fi
  if [[ "$FOLLOW_LINKS" == "true" ]]; then
    fd_args+=(--follow)
  fi
  fd_args+=(--type d --regex "$SD_dir_regex" "/" -0)

  timeout --preserve-status --kill-after="$kill_after" "$timeout_dur" \
    "${fd_args[@]}"
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
  if [[ "$LONG_FORMAT" != "true" ]]; then
    cat
    return
  fi

  format_size_iec() {
    local bytes="$1"
    LC_ALL=C awk -v bytes="$bytes" '
      BEGIN {
        split("B KiB MiB GiB TiB", units, " ")
        if (bytes ~ /^[0-9]+$/) {
          size = bytes + 0
          unit = 1
          while (size >= 1024 && unit < 5) {
            size /= 1024
            unit++
          }
          if (unit == 1) {
            printf "%d %s", size, units[unit]
          } else if (size >= 100) {
            printf "%.0f %s", size, units[unit]
          } else if (size >= 10) {
            printf "%.1f %s", size, units[unit]
          } else {
            printf "%.2f %s", size, units[unit]
          }
        } else {
          printf "%s B", bytes
        }
      }
    '
  }

  while IFS= read -r line; do
    local clean_path
    clean_path="$line"

    # Get date/time and size
    # stat -c "%y %s" -> YYYY-MM-DD HH:MM:SS.NNN TZ SIZE
    local stat_out
    stat_out=$(stat -c "%y %s" "$clean_path" 2>/dev/null || true)

    if [[ -n "$stat_out" ]]; then
      local modified_date modified_time modified_datetime byte_size human_size extra
      modified_date="${stat_out%% *}"
      modified_time="${stat_out#* }"
      modified_time="${modified_time%% *}"
      modified_time="${modified_time%%.*}"
      modified_datetime="${modified_date} ${modified_time}"
      byte_size="${stat_out##* }"
      human_size="$(format_size_iec "$byte_size")"
      extra=""

      if [[ "$LONG_EXTENDED" == "true" && -d "$clean_path" ]]; then
        local file_count dir_size_bytes dir_size_human dir_size_compact
        if [[ -L "$clean_path" ]]; then
          file_count="0"
          dir_size_bytes=$(stat -c "%s" "$clean_path" 2>/dev/null || echo "0")
          dir_size_human="$(format_size_iec "$dir_size_bytes")"
          DIR_STATS_FILES["$clean_path"]="$file_count"
          DIR_STATS_BYTES["$clean_path"]="$dir_size_bytes"
          DIR_STATS_HUMAN["$clean_path"]="$dir_size_human"
        elif get_dirsize_stats "$clean_path"; then
          file_count="$DIRSIZE_FILES"
          dir_size_bytes="$DIRSIZE_BYTES"
          dir_size_human="$DIRSIZE_HUMAN"
        else
          file_count=$(find "$clean_path" -type f -print 2>/dev/null | wc -l | tr -d '[:space:]')
          [[ -z "$file_count" ]] && file_count="0"

          # Use allocated disk usage (not apparent size) for "real" folder size.
          dir_size_bytes=$(du -sB1 "$clean_path" 2>/dev/null | awk '{print $1}')
          [[ -z "$dir_size_bytes" ]] && dir_size_bytes="0"
          dir_size_human="$(format_size_iec "$dir_size_bytes")"
          DIR_STATS_FILES["$clean_path"]="$file_count"
          DIR_STATS_BYTES["$clean_path"]="$dir_size_bytes"
          DIR_STATS_HUMAN["$clean_path"]="$dir_size_human"
        fi
        dir_size_compact="${dir_size_human}"
        human_size="$dir_size_compact"
        extra="$file_count"
      fi

      if [[ -n "$extra" ]]; then
        printf '%s %s %s %s\n' "$modified_datetime" "$human_size" "$extra" "$line"
      else
        printf '%s %s %s\n' "$modified_datetime" "$human_size" "$line"
      fi
    fi
  done
}

sort_results_transform() {
  if [[ -z "$SORT_FIELD" ]]; then
    cat
    return
  fi

  while IFS= read -r line; do
    local clean_path key
    clean_path="$line"
    case "$SORT_FIELD" in
      date)
        key=$(stat -c "%Y" "$clean_path" 2>/dev/null || echo "0")
        ;;
      size)
        if [[ -d "$clean_path" ]]; then
          if [[ "$LONG_EXTENDED" == "true" ]]; then
            if [[ -L "$clean_path" ]]; then
              key=$(stat -c "%s" "$clean_path" 2>/dev/null || echo "0")
            elif get_dirsize_stats "$clean_path"; then
              key="$DIRSIZE_BYTES"
            else
              key=$(du -sB1 "$clean_path" 2>/dev/null | awk '{print $1}')
              [[ -z "$key" ]] && key="0"
            fi
          elif [[ "$NO_RECURSE" == "true" ]]; then
            # In non-recursive mode, keep size-sort fast by using direct entry size.
            key=$(stat -c "%s" "$clean_path" 2>/dev/null || echo "0")
          else
            # Sort directories by real allocated disk usage, not inode metadata size.
            key=$(du -sB1 "$clean_path" 2>/dev/null | awk '{print $1}')
            [[ -z "$key" ]] && key="0"
          fi
        else
          key=$(stat -c "%s" "$clean_path" 2>/dev/null || echo "0")
        fi
        ;;
      name)
        key="${clean_path%/}"
        key="${key##*/}"
        ;;
      *)
        key="0"
        ;;
    esac
    printf '%s\t%s\n' "$key" "$line"
  done \
  | {
      if [[ "$SORT_FIELD" == "name" ]]; then
        if [[ "$SORT_ORDER" == "asc" ]]; then
          sort -f -k1,1 -k2,2
        else
          sort -rf -k1,1 -k2,2
        fi
      else
        if [[ "$SORT_ORDER" == "asc" ]]; then
          sort -n -k1,1 -k2,2
        else
          sort -nr -k1,1 -k2,2
        fi
      fi
    } \
  | cut -f2-
}

counts_summary_transform() {
  # Summarize matches as: <count> <folder>
  # - strips optional long prefixes:
  #   --long: YYYY-MM-DD HH:MM:SS SIZE UNIT
  #   -L (dirs): YYYY-MM-DD HH:MM:SS REALDIRSIZE FILECOUNT
  # - normalizes directory matches by removing trailing "/"
  if [[ "$IS_TTY" == "true" ]]; then
    printf '%7s  %s\n' "COUNT" "FOLDER"
  fi

  awk '
    {
      line=$0
      sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]+([.][0-9]+)? ?(B|KiB|MiB|GiB|TiB)( [0-9]+)? /, "", line)

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

cache_transform() {
  # Cache raw matched paths before pretty rendering.
  # Also cache the parent directory of every match in dirs cache.
  if [[ "$CACHE_OUTPUT" != "true" ]]; then
    cat
    return
  fi

  local cache_user cache_pid cache_dir dirs_file files_file parent_comm
  cache_user="${USER:-$(id -un 2>/dev/null || echo unknown)}"
  cache_pid=""

  if [[ "${FISH_PID:-}" =~ ^[0-9]+$ ]]; then
    cache_pid="$FISH_PID"
  elif [[ "${fish_pid:-}" =~ ^[0-9]+$ ]]; then
    cache_pid="$fish_pid"
  elif [[ "${PPID:-}" =~ ^[0-9]+$ ]]; then
    parent_comm="$(ps -p "$PPID" -o comm= 2>/dev/null || true)"
    if [[ "$parent_comm" == "fish" ]]; then
      cache_pid="$PPID"
    fi
  fi
  if [[ -z "$cache_pid" ]]; then
    cache_pid="$$"
  fi

  cache_dir="/tmp/fzf-history-${cache_user}"
  dirs_file="${cache_dir}/universal-last-dirs-${cache_pid}"
  files_file="${cache_dir}/universal-last-files-${cache_pid}"

  mkdir -p "$cache_dir"
  : > "$dirs_file"
  : > "$files_file"
  awk -v dirs_file="$dirs_file" -v files_file="$files_file" '
    {
      path=$0
      print path

      # Cache matched file paths.
      if (path !~ /\/$/ && !(path in seen_files)) {
        print path >> files_file
        seen_files[path]=1
      }

      # Cache matched directory paths.
      if (path ~ /\/$/ && !(path in seen_dirs)) {
        print path >> dirs_file
        seen_dirs[path]=1
      }

      # Cache parent directory of every match.
      parent=path
      sub(/\/$/, "", parent)
      if (parent ~ /\//) {
        sub(/\/[^\/]+$/, "", parent)
        if (parent == "") {
          parent="/"
        } else if (parent !~ /\/$/) {
          parent=parent "/"
        }
      } else {
        parent="./"
      }
      if (!(parent in seen_dirs)) {
        print parent >> dirs_file
        seen_dirs[parent]=1
      }
    }
  '
}

add_hyperlink_transform() {
  # Render final output lines as clickable file:// links in TTYs.
  if [[ "$IS_TTY" != "true" ]]; then
    cat
    return
  fi

  local cwd_abs
  cwd_abs="$(pwd -P)"
  local date_color=$'\033[37m'
  local size_color=$'\033[1;36m'
  local color_reset=$'\033[0m'

  while IFS= read -r line; do
    local path_part
    local abs_path
    local display_line
    local linked_path
    local datetime_part
    local size_part
    local count_part

    datetime_part=""
    size_part=""
    count_part=""
    path_part="$line"
    if [[ "$LONG_FORMAT" == "true" && "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]]+([0-9]+([.][0-9]+)?[[:space:]]?(B|KiB|MiB|GiB|TiB))([[:space:]][0-9]+)?[[:space:]]+(.*)$ ]]; then
      datetime_part="${BASH_REMATCH[1]}"
      size_part="${BASH_REMATCH[2]}"
      count_part="${BASH_REMATCH[5]}"
      path_part="${BASH_REMATCH[6]}"
    fi

    if [[ -z "$path_part" ]]; then
      printf '%s\n' "$line"
      continue
    fi

    if [[ "$path_part" == /* ]]; then
      abs_path="$path_part"
    else
      abs_path="${cwd_abs}/${path_part#./}"
    fi

    linked_path="$(render_split_hyperlinked_path "$path_part" "$abs_path" "$cwd_abs")"

    if [[ -n "$datetime_part" ]]; then
      local prefix_colored
      prefix_colored="${date_color}${datetime_part}${color_reset} ${size_color}${size_part}${color_reset}"
      if [[ -n "$count_part" ]]; then
        prefix_colored+="${count_part}"
      fi
      prefix_colored+=" "
      display_line="${prefix_colored}${linked_path}"
    else
      display_line="$linked_path"
    fi

    printf '%s\n' "$display_line"
  done
}

absolute_paths_transform() {
  # Convert raw result paths to absolute paths for output/cache stages.
  if [[ "$ABSOLUTE_PATHS" != "true" ]]; then
    cat
    return
  fi

  local cwd_abs
  cwd_abs="$(pwd -P)"
  while IFS= read -r path; do
    if [[ "$path" == /* ]]; then
      printf '%s\n' "$path"
    else
      printf '%s/%s\n' "$cwd_abs" "${path#./}"
    fi
  done
}

final_transform() {
  if [[ "$COUNTS" == "true" ]]; then
    absolute_paths_transform | cache_transform | counts_summary_transform
  else
    sort_results_transform | absolute_paths_transform | cache_transform | add_info_transform | add_hyperlink_transform
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
      --threads)
        shift
        [[ $# -gt 0 ]] || { echo "Error: --threads requires a value." >&2; exit 2; }
        set_threads_value "$1"
        shift
        ;;
      --threads=*)
        set_threads_value "${1#*=}"
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
      --absolute-paths|-A)
        ABSOLUTE_PATHS=true
        shift
        ;;
      --regex|-r)
        REGEX_MODE=true
        shift
        ;;
      --sort)
        shift
        [[ $# -ge 2 ]] || { echo "Error: --sort requires FIELD and ORDER (e.g., --sort date desc)." >&2; exit 2; }
        local sort_key="$1"
        local sort_dir="$2"
        if [[ "$sort_key" != "date" && "$sort_key" != "size" && "$sort_key" != "name" ]]; then
          echo "Error: unsupported sort field '$sort_key'. Supported: date, size, name" >&2
          exit 2
        fi
        if [[ "$sort_dir" != "asc" && "$sort_dir" != "desc" ]]; then
          echo "Error: unsupported sort order '$sort_dir'. Supported: asc, desc" >&2
          exit 2
        fi
        SORT_FIELD="$sort_key"
        SORT_ORDER="$sort_dir"
        shift 2
        ;;
      --no-recurse|-R)
        NO_RECURSE=true
        shift
        ;;
      --follow-links)
        FOLLOW_LINKS=true
        shift
        ;;
      --ignore)
        RESPECT_IGNORE=true
        shift
        ;;
      --visible-only)
        VISIBLE_ONLY=true
        shift
        ;;
      --cache-raw)
        CACHE_OUTPUT=true
        shift
        ;;
      --cache)
        echo "f: --cache was renamed to --cache-raw" >&2
        exit 2
        ;;
      --bypass|-b)
        FORCE_PATTERN_MODE=true
        shift
        ;;
      --long|-l)
        LONG_FORMAT=true
        shift
        ;;
      -L|--long-true-dirsize)
        LONG_FORMAT=true
        LONG_EXTENDED=true
        shift
        ;;
      --info|-i)
        echo "f: --info/-i was renamed to --long/-l" >&2
        exit 2
        ;;
      --counts)
        COUNTS=true
        shift
        ;;
      --audit)
        echo "f: --audit was renamed to --counts" >&2
        exit 2
        ;;
      --version|-V)
        print_version
        exit 0
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
      # Use --full-path explicitly
      run_fd "$search_root" "$type_arg" "$first_regex" "--full-path" \
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
