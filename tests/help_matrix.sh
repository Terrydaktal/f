#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="${ROOT_DIR}/f"
F_TIMEOUT="2"

assert_eq() {
  local name="$1"
  local got="$2"
  local want="$3"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: ${name}" >&2
    echo "----- got -----" >&2
    printf '%s\n' "$got" >&2
    echo "----- want ----" >&2
    printf '%s\n' "$want" >&2
    exit 1
  fi
}

list_rel() {
  local root="$1"
  shift
  "$F" --timeout "$F_TIMEOUT" "$@" "$root" | sed "s#^${root}/##" | sort
}

list_parent_dirs() {
  "$F" --timeout "$F_TIMEOUT" "$@" | xargs -r -n1 dirname | sort -u
}

TMP_BASE="/tmp/f_help_matrix_${RANDOM}_$$"
FILE_ROOT="${TMP_BASE}/file_root"
DIR_ROOT="${TMP_BASE}/dir_root"
SD_BASE="${TMP_BASE}/search_dir_root"
TOKEN="sdtok_${RANDOM}_$$"
NEEDLE="needle_${RANDOM}_$$"
trap 'rm -rf "$TMP_BASE"' EXIT

mkdir -p "$FILE_ROOT" "$DIR_ROOT"
touch "${FILE_ROOT}/abc" "${FILE_ROOT}/xabc" "${FILE_ROOT}/abcx" "${FILE_ROOT}/xabcx"
mkdir -p "${DIR_ROOT}/abc" "${DIR_ROOT}/xabc" "${DIR_ROOT}/abcx" "${DIR_ROOT}/xabcx"

want_contains=$'abc\nabcx\nxabc\nxabcx'
want_starts=$'abc\nabcx'
want_ends=$'abc\nxabc'
want_exact='abc'
want_contains_d=$'abc/\nabcx/\nxabc/\nxabcx/'
want_starts_d=$'abc/\nabcx/'
want_ends_d=$'abc/\nxabc/'
want_exact_d='abc/'

# SEARCH MATRIX: contains
assert_eq "contains all (shorthand files)" "$(list_rel "$FILE_ROOT" abc)" "$want_contains"
assert_eq "contains all (wildcard files)" "$(list_rel "$FILE_ROOT" '*abc*')" "$want_contains"
assert_eq "contains all (regex files)" "$(list_rel "$FILE_ROOT" 'r"abc"')" "$want_contains"
assert_eq "contains file (shorthand)" "$(list_rel "$FILE_ROOT" abc -f)" "$want_contains"
assert_eq "contains file (wildcard)" "$(list_rel "$FILE_ROOT" '*abc*' -f)" "$want_contains"
assert_eq "contains file (regex)" "$(list_rel "$FILE_ROOT" 'r"abc"' -f)" "$want_contains"
assert_eq "contains all (shorthand dirs)" "$(list_rel "$DIR_ROOT" abc)" "$want_contains_d"
assert_eq "contains all (wildcard dirs)" "$(list_rel "$DIR_ROOT" '*abc*')" "$want_contains_d"
assert_eq "contains all (regex dirs)" "$(list_rel "$DIR_ROOT" 'r"abc"')" "$want_contains_d"
assert_eq "contains dir (shorthand)" "$(list_rel "$DIR_ROOT" abc -d)" "$want_contains_d"
assert_eq "contains dir (wildcard)" "$(list_rel "$DIR_ROOT" '*abc*' -d)" "$want_contains_d"
assert_eq "contains dir (regex)" "$(list_rel "$DIR_ROOT" 'r"abc"' -d)" "$want_contains_d"

# SEARCH MATRIX: exact
assert_eq "exact all (wildcard format files)" "$(list_rel "$FILE_ROOT" '"abc"')" "$want_exact"
assert_eq "exact all (regex files)" "$(list_rel "$FILE_ROOT" 'r"^abc$"')" "$want_exact"
assert_eq "exact file (wildcard format)" "$(list_rel "$FILE_ROOT" '"abc"' -f)" "$want_exact"
assert_eq "exact file (regex)" "$(list_rel "$FILE_ROOT" 'r"^abc$"' -f)" "$want_exact"
assert_eq "exact all (wildcard format dirs)" "$(list_rel "$DIR_ROOT" '"abc"')" "$want_exact_d"
assert_eq "exact all (regex dirs)" "$(list_rel "$DIR_ROOT" 'r"^abc$"')" "$want_exact_d"
assert_eq "exact dir (shorthand)" "$(list_rel "$DIR_ROOT" /abc/)" "$want_exact_d"
assert_eq "exact dir (wildcard format)" "$(list_rel "$DIR_ROOT" '"abc"' -d)" "$want_exact_d"
assert_eq "exact dir (regex)" "$(list_rel "$DIR_ROOT" 'r"^abc$"' -d)" "$want_exact_d"

# SEARCH MATRIX: starts
assert_eq "starts all (shorthand files)" "$(list_rel "$FILE_ROOT" /abc)" "$want_starts"
assert_eq "starts all (wildcard files)" "$(list_rel "$FILE_ROOT" 'abc*')" "$want_starts"
assert_eq "starts all (regex files)" "$(list_rel "$FILE_ROOT" 'r"^abc"')" "$want_starts"
assert_eq "starts file (shorthand)" "$(list_rel "$FILE_ROOT" /abc -f)" "$want_starts"
assert_eq "starts file (wildcard)" "$(list_rel "$FILE_ROOT" 'abc*' -f)" "$want_starts"
assert_eq "starts file (regex)" "$(list_rel "$FILE_ROOT" 'r"^abc"' -f)" "$want_starts"
assert_eq "starts all (shorthand dirs)" "$(list_rel "$DIR_ROOT" /abc)" "$want_starts_d"
assert_eq "starts all (wildcard dirs)" "$(list_rel "$DIR_ROOT" 'abc*')" "$want_starts_d"
assert_eq "starts all (regex dirs)" "$(list_rel "$DIR_ROOT" 'r"^abc"')" "$want_starts_d"
assert_eq "starts dir (shorthand)" "$(list_rel "$DIR_ROOT" /abc -d)" "$want_starts_d"
assert_eq "starts dir (wildcard)" "$(list_rel "$DIR_ROOT" 'abc*' -d)" "$want_starts_d"
assert_eq "starts dir (regex)" "$(list_rel "$DIR_ROOT" 'r"^abc"' -d)" "$want_starts_d"

# SEARCH MATRIX: ends
assert_eq "ends all (wildcard files)" "$(list_rel "$FILE_ROOT" '*abc')" "$want_ends"
assert_eq "ends all (regex files)" "$(list_rel "$FILE_ROOT" 'r"abc$"')" "$want_ends"
assert_eq "ends file (wildcard)" "$(list_rel "$FILE_ROOT" '*abc' -f)" "$want_ends"
assert_eq "ends file (regex)" "$(list_rel "$FILE_ROOT" 'r"abc$"' -f)" "$want_ends"
assert_eq "ends all (wildcard dirs)" "$(list_rel "$DIR_ROOT" '*abc')" "$want_ends_d"
assert_eq "ends all (regex dirs)" "$(list_rel "$DIR_ROOT" 'r"abc$"')" "$want_ends_d"
assert_eq "ends dir (shorthand)" "$(list_rel "$DIR_ROOT" abc/)" "$want_ends_d"
assert_eq "ends dir (wildcard)" "$(list_rel "$DIR_ROOT" '*abc' -d)" "$want_ends_d"
assert_eq "ends dir (regex)" "$(list_rel "$DIR_ROOT" 'r"abc$"' -d)" "$want_ends_d"

# SEARCH DIR MATRIX setup
mkdir -p "$SD_BASE"
SD_EXACT="${SD_BASE}/${TOKEN}"
SD_CONTAINS="${SD_BASE}/pre_${TOKEN}_mid"
SD_STARTS="${SD_BASE}/${TOKEN}_start"
SD_ENDS="${SD_BASE}/end_${TOKEN}"
mkdir -p "$SD_EXACT" "$SD_CONTAINS" "$SD_STARTS" "$SD_ENDS"
touch "${SD_EXACT}/${NEEDLE}" "${SD_CONTAINS}/${NEEDLE}" "${SD_STARTS}/${NEEDLE}" "${SD_ENDS}/${NEEDLE}"

want_sd_contains=$(printf '%s\n' "$SD_CONTAINS" "$SD_ENDS" "$SD_EXACT" "$SD_STARTS" | sort)
want_sd_exact=$(printf '%s\n' "$SD_EXACT")
want_sd_starts=$(printf '%s\n' "$SD_EXACT" "$SD_STARTS" | sort)
want_sd_ends=$(printf '%s\n' "$SD_ENDS" "$SD_EXACT" | sort)

# SEARCH DIR MATRIX: contains
assert_eq "search_dir contains (shorthand)" "$(list_parent_dirs "\"${NEEDLE}\"" "$TOKEN")" "$want_sd_contains"
assert_eq "search_dir contains (wildcard)" "$(list_parent_dirs "\"${NEEDLE}\"" "*${TOKEN}*")" "$want_sd_contains"
assert_eq "search_dir contains (regex)" "$(list_parent_dirs "\"${NEEDLE}\"" "r\"${TOKEN}\"")" "$want_sd_contains"

# SEARCH DIR MATRIX: exact
assert_eq "search_dir exact (shorthand)" "$(list_parent_dirs "\"${NEEDLE}\"" "/${TOKEN}/")" "$want_sd_exact"
assert_eq "search_dir exact (wildcard)" "$(list_parent_dirs "\"${NEEDLE}\"" "\"${TOKEN}\"")" "$want_sd_exact"
assert_eq "search_dir exact (regex)" "$(list_parent_dirs "\"${NEEDLE}\"" "r\"^${TOKEN}\$\"")" "$want_sd_exact"

# SEARCH DIR MATRIX: starts
assert_eq "search_dir starts (shorthand)" "$(list_parent_dirs "\"${NEEDLE}\"" "/${TOKEN}")" "$want_sd_starts"
assert_eq "search_dir starts (wildcard)" "$(list_parent_dirs "\"${NEEDLE}\"" "\"${TOKEN}*\"")" "$want_sd_starts"
assert_eq "search_dir starts (regex)" "$(list_parent_dirs "\"${NEEDLE}\"" "r\"^${TOKEN}\"")" "$want_sd_starts"

# SEARCH DIR MATRIX: ends
assert_eq "search_dir ends (shorthand)" "$(list_parent_dirs "\"${NEEDLE}\"" "${TOKEN}/")" "$want_sd_ends"
assert_eq "search_dir ends (wildcard)" "$(list_parent_dirs "\"${NEEDLE}\"" "\"*${TOKEN}\"")" "$want_sd_ends"
assert_eq "search_dir ends (regex)" "$(list_parent_dirs "\"${NEEDLE}\"" "r\"${TOKEN}\$\"")" "$want_sd_ends"

echo "PASS: help matrix suite"
