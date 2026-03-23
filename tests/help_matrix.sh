#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
F="${ROOT_DIR}/f"
F_TIMEOUT="6"

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

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "FAIL: ${name}" >&2
    echo "----- got -----" >&2
    printf '%s\n' "$haystack" >&2
    echo "----- missing ----" >&2
    printf '%s\n' "$needle" >&2
    exit 1
  fi
}

assert_regex() {
  local name="$1"
  local text="$2"
  local pattern="$3"
  if ! printf '%s\n' "$text" | grep -Eq "$pattern"; then
    echo "FAIL: ${name}" >&2
    echo "----- got -----" >&2
    printf '%s\n' "$text" >&2
    echo "----- pattern ----" >&2
    printf '%s\n' "$pattern" >&2
    exit 1
  fi
}

list_rel() {
  local root="$1"
  shift
  "$F" --timeout "$F_TIMEOUT" "$@" "$root" 2>/dev/null | sed "s#^${root}/##" | sort
}

list_rel_raw() {
  local root="$1"
  shift
  "$F" --timeout "$F_TIMEOUT" "$@" "$root" 2>/dev/null | sed "s#^${root}/##"
}

list_parent_dirs() {
  "$F" --timeout "$F_TIMEOUT" "$@" 2>/dev/null | xargs -r -n1 dirname | sort -u
}

TMP_BASE="/tmp/f_help_matrix_${RANDOM}_$$"
FILE_ROOT="${TMP_BASE}/file_root"
DIR_ROOT="${TMP_BASE}/dir_root"
SD_BASE="${TMP_BASE}/search_dir_root"
TOKEN="sdtok_${RANDOM}_$$"
NEEDLE="needle_${RANDOM}_$$"
trap 'rm -rf "$TMP_BASE"' EXIT

mkdir -p "$FILE_ROOT" "$DIR_ROOT"
touch "${FILE_ROOT}/abc" "${FILE_ROOT}/xabc" "${FILE_ROOT}/abcx" "${FILE_ROOT}/xabcx" "${FILE_ROOT}/x.tecneq"
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
assert_eq "contains all (regex files)" "$(list_rel "$FILE_ROOT" -r 'abc')" "$want_contains"
assert_eq "contains file (shorthand)" "$(list_rel "$FILE_ROOT" abc -f)" "$want_contains"
assert_eq "contains file (wildcard)" "$(list_rel "$FILE_ROOT" '*abc*' -f)" "$want_contains"
assert_eq "contains file (regex)" "$(list_rel "$FILE_ROOT" -r 'abc' -f)" "$want_contains"
assert_eq "contains all (shorthand dirs)" "$(list_rel "$DIR_ROOT" abc)" "$want_contains_d"
assert_eq "contains all (wildcard dirs)" "$(list_rel "$DIR_ROOT" '*abc*')" "$want_contains_d"
assert_eq "contains all (regex dirs)" "$(list_rel "$DIR_ROOT" -r 'abc')" "$want_contains_d"
assert_eq "contains dir (shorthand)" "$(list_rel "$DIR_ROOT" abc -d)" "$want_contains_d"
assert_eq "contains dir (wildcard)" "$(list_rel "$DIR_ROOT" '*abc*' -d)" "$want_contains_d"
assert_eq "contains dir (regex)" "$(list_rel "$DIR_ROOT" -r 'abc' -d)" "$want_contains_d"
assert_eq "legacy r-prefix is literal without -r" "$(list_rel "$FILE_ROOT" 'r.tecneq')" ""
assert_eq "contains regex dot (flag mode)" "$(list_rel "$FILE_ROOT" -r '.tecneq$')" "x.tecneq"

# SEARCH MATRIX: exact
assert_eq "exact all (wildcard format files)" "$(list_rel "$FILE_ROOT" '"abc"')" "$want_exact"
assert_eq "exact all (regex files)" "$(list_rel "$FILE_ROOT" -r '^abc$')" "$want_exact"
assert_eq "exact file (wildcard format)" "$(list_rel "$FILE_ROOT" '"abc"' -f)" "$want_exact"
assert_eq "exact file (regex)" "$(list_rel "$FILE_ROOT" -r '^abc$' -f)" "$want_exact"
assert_eq "exact all (wildcard format dirs)" "$(list_rel "$DIR_ROOT" '"abc"')" "$want_exact_d"
assert_eq "exact all (regex dirs)" "$(list_rel "$DIR_ROOT" -r '^abc$')" "$want_exact_d"
assert_eq "exact dir (shorthand)" "$(list_rel "$DIR_ROOT" /abc/)" "$want_exact_d"
assert_eq "exact dir (wildcard format)" "$(list_rel "$DIR_ROOT" '"abc"' -d)" "$want_exact_d"
assert_eq "exact dir (regex)" "$(list_rel "$DIR_ROOT" -r '^abc$' -d)" "$want_exact_d"

# SEARCH MATRIX: starts
assert_eq "starts all (shorthand files)" "$(list_rel "$FILE_ROOT" /abc)" "$want_starts"
assert_eq "starts all (wildcard files)" "$(list_rel "$FILE_ROOT" 'abc*')" "$want_starts"
assert_eq "starts all (regex files)" "$(list_rel "$FILE_ROOT" -r '^abc')" "$want_starts"
assert_eq "starts file (shorthand)" "$(list_rel "$FILE_ROOT" /abc -f)" "$want_starts"
assert_eq "starts file (wildcard)" "$(list_rel "$FILE_ROOT" 'abc*' -f)" "$want_starts"
assert_eq "starts file (regex)" "$(list_rel "$FILE_ROOT" -r '^abc' -f)" "$want_starts"
assert_eq "starts all (shorthand dirs)" "$(list_rel "$DIR_ROOT" /abc)" "$want_starts_d"
assert_eq "starts all (wildcard dirs)" "$(list_rel "$DIR_ROOT" 'abc*')" "$want_starts_d"
assert_eq "starts all (regex dirs)" "$(list_rel "$DIR_ROOT" -r '^abc')" "$want_starts_d"
assert_eq "starts dir (shorthand)" "$(list_rel "$DIR_ROOT" /abc -d)" "$want_starts_d"
assert_eq "starts dir (wildcard)" "$(list_rel "$DIR_ROOT" 'abc*' -d)" "$want_starts_d"
assert_eq "starts dir (regex)" "$(list_rel "$DIR_ROOT" -r '^abc' -d)" "$want_starts_d"

# SEARCH MATRIX: ends
assert_eq "ends all (wildcard files)" "$(list_rel "$FILE_ROOT" '*abc')" "$want_ends"
assert_eq "ends all (regex files)" "$(list_rel "$FILE_ROOT" -r 'abc$')" "$want_ends"
assert_eq "ends file (wildcard)" "$(list_rel "$FILE_ROOT" '*abc' -f)" "$want_ends"
assert_eq "ends file (regex)" "$(list_rel "$FILE_ROOT" -r 'abc$' -f)" "$want_ends"
assert_eq "ends all (wildcard dirs)" "$(list_rel "$DIR_ROOT" '*abc')" "$want_ends_d"
assert_eq "ends all (regex dirs)" "$(list_rel "$DIR_ROOT" -r 'abc$')" "$want_ends_d"
assert_eq "ends dir (shorthand)" "$(list_rel "$DIR_ROOT" abc/)" "$want_ends_d"
assert_eq "ends dir (wildcard)" "$(list_rel "$DIR_ROOT" '*abc' -d)" "$want_ends_d"
assert_eq "ends dir (regex)" "$(list_rel "$DIR_ROOT" -r 'abc$' -d)" "$want_ends_d"

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
assert_eq "search_dir contains (regex)" "$(list_parent_dirs -r "\"${NEEDLE}\"" "${TOKEN}")" "$want_sd_contains"

# SEARCH DIR MATRIX: exact
assert_eq "search_dir exact (shorthand)" "$(list_parent_dirs "\"${NEEDLE}\"" "/${TOKEN}/")" "$want_sd_exact"
assert_eq "search_dir exact (regex)" "$(list_parent_dirs -r "\"${NEEDLE}\"" "^${TOKEN}\$")" "$want_sd_exact"

# SEARCH DIR MATRIX: starts
assert_eq "search_dir starts (shorthand)" "$(list_parent_dirs "\"${NEEDLE}\"" "/${TOKEN}")" "$want_sd_starts"
assert_eq "search_dir starts (wildcard)" "$(list_parent_dirs "\"${NEEDLE}\"" "\"${TOKEN}*\"")" "$want_sd_starts"
assert_eq "search_dir starts (regex)" "$(list_parent_dirs -r "\"${NEEDLE}\"" "^${TOKEN}")" "$want_sd_starts"

# SEARCH DIR MATRIX: ends
assert_eq "search_dir ends (shorthand)" "$(list_parent_dirs "\"${NEEDLE}\"" "${TOKEN}/")" "$want_sd_ends"
assert_eq "search_dir ends (wildcard)" "$(list_parent_dirs "\"${NEEDLE}\"" "\"*${TOKEN}\"")" "$want_sd_ends"
assert_eq "search_dir ends (regex)" "$(list_parent_dirs -r "\"${NEEDLE}\"" "${TOKEN}\$")" "$want_sd_ends"

# SORT MATRIX: date
SORT_ROOT="${TMP_BASE}/sort_root"
mkdir -p "$SORT_ROOT"
touch -d '2020-01-01 00:00:00 UTC' "${SORT_ROOT}/z_old"
touch -d '2021-01-01 00:00:00 UTC' "${SORT_ROOT}/m_mid"
touch -d '2022-01-01 00:00:00 UTC' "${SORT_ROOT}/a_new"

want_sort_asc=$'z_old\nm_mid\na_new'
want_sort_desc=$'a_new\nm_mid\nz_old'
assert_eq "sort date asc" "$(list_rel_raw "$SORT_ROOT" --sort date asc '*')" "$want_sort_asc"
assert_eq "sort date desc" "$(list_rel_raw "$SORT_ROOT" --sort date desc '*')" "$want_sort_desc"

# SORT MATRIX: size
SIZE_ROOT="${TMP_BASE}/size_root"
mkdir -p "$SIZE_ROOT"
truncate -s 1 "${SIZE_ROOT}/b_small"
truncate -s 128 "${SIZE_ROOT}/c_mid"
truncate -s 4096 "${SIZE_ROOT}/a_big"

want_size_asc=$'b_small\nc_mid\na_big'
want_size_desc=$'a_big\nc_mid\nb_small'
assert_eq "sort size asc" "$(list_rel_raw "$SIZE_ROOT" --sort size asc '*')" "$want_size_asc"
assert_eq "sort size desc" "$(list_rel_raw "$SIZE_ROOT" --sort size desc '*')" "$want_size_desc"

# SORT MATRIX: size (directories by real size)
SIZE_DIR_ROOT="${TMP_BASE}/size_dir_root"
mkdir -p "${SIZE_DIR_ROOT}/big_dir" "${SIZE_DIR_ROOT}/small_dir"
dd if=/dev/zero of="${SIZE_DIR_ROOT}/big_dir/blob" bs=1024 count=1024 status=none
dd if=/dev/zero of="${SIZE_DIR_ROOT}/small_dir/tiny" bs=1024 count=1 status=none
want_size_dir_desc=$'big_dir/\nsmall_dir/'
assert_eq "sort size desc dirs" "$(list_rel_raw "$SIZE_DIR_ROOT" --sort size desc -d '*')" "$want_size_dir_desc"

# SORT MATRIX: name
NAME_ROOT="${TMP_BASE}/name_root"
mkdir -p "$NAME_ROOT"
touch "${NAME_ROOT}/Zulu" "${NAME_ROOT}/alpha" "${NAME_ROOT}/Beta"

want_name_asc=$'alpha\nBeta\nZulu'
want_name_desc=$'Zulu\nBeta\nalpha'
assert_eq "sort name asc" "$(list_rel_raw "$NAME_ROOT" --sort name asc '*')" "$want_name_asc"
assert_eq "sort name desc" "$(list_rel_raw "$NAME_ROOT" --sort name desc '*')" "$want_name_desc"

# RECURSION MATRIX
NONREC_ROOT="${TMP_BASE}/nonrec_root"
mkdir -p "${NONREC_ROOT}/sub"
touch "${NONREC_ROOT}/abc_top" "${NONREC_ROOT}/sub/abc_nested"

want_recursive=$'abc_top\nsub/abc_nested'
want_non_recursive='abc_top'
assert_eq "recursive default" "$(list_rel "$NONREC_ROOT" abc -f)" "$want_recursive"
assert_eq "no recurse" "$(list_rel "$NONREC_ROOT" abc -f --no-recurse)" "$want_non_recursive"
assert_eq "no recurse alias -R" "$(list_rel "$NONREC_ROOT" abc -f -R)" "$want_non_recursive"
assert_eq "threads flag (space form)" "$(list_rel "$NONREC_ROOT" abc -f --threads 1)" "$want_recursive"
assert_eq "threads flag (equals form)" "$(list_rel "$NONREC_ROOT" abc -f --threads=1)" "$want_recursive"

threads_err="$("$F" --timeout "$F_TIMEOUT" --threads 0 abc "$NONREC_ROOT" 2>&1 >/dev/null || true)"
assert_contains "threads invalid value errors" "$threads_err" "--threads requires a positive integer"

# VISIBILITY MATRIX
VISIBLE_ROOT="${TMP_BASE}/visible_root"
mkdir -p "$VISIBLE_ROOT"
touch "${VISIBLE_ROOT}/.hidden_hit" "${VISIBLE_ROOT}/visible_hit"
want_visible_default=$'.hidden_hit\nvisible_hit'
want_visible_only='visible_hit'
assert_eq "default includes hidden entries" "$(list_rel "$VISIBLE_ROOT" '*hit' -f)" "$want_visible_default"
assert_eq "visible-only excludes hidden entries" "$(list_rel "$VISIBLE_ROOT" '*hit' -f --visible-only)" "$want_visible_only"

# IGNORE MATRIX
IGNORE_ROOT="${TMP_BASE}/ignore_root"
mkdir -p "$IGNORE_ROOT"
touch "${IGNORE_ROOT}/ignore_me" "${IGNORE_ROOT}/keep_me"
printf 'ignore_me\n' > "${IGNORE_ROOT}/.gitignore"
git -C "$IGNORE_ROOT" init -q
want_ignore_default='ignore_me'
assert_eq "default bypasses gitignore" "$(list_rel "$IGNORE_ROOT" ignore_me -f)" "$want_ignore_default"
assert_eq "ignore respects gitignore" "$(list_rel "$IGNORE_ROOT" ignore_me -f --ignore)" ""

# FOLLOW-LINKS MATRIX
FOLLOW_ROOT="${TMP_BASE}/follow_root"
FOLLOW_EXTERNAL="${TMP_BASE}/follow_external"
mkdir -p "$FOLLOW_ROOT" "$FOLLOW_EXTERNAL"
touch "${FOLLOW_EXTERNAL}/follow_only"
ln -s "$FOLLOW_EXTERNAL" "${FOLLOW_ROOT}/linked_dir"
assert_eq "no follow-links does not traverse symlinked dirs" "$(list_rel "$FOLLOW_ROOT" follow_only -f)" ""
assert_eq "follow-links traverses symlinked dirs" "$(list_rel "$FOLLOW_ROOT" follow_only -f --follow-links)" "linked_dir/follow_only"

# RECURSION + SIZE SORT MATRIX (fast non-recursive size key for dirs)
NONREC_SIZE_ROOT="${TMP_BASE}/nonrec_size_root"
mkdir -p "${NONREC_SIZE_ROOT}/huge_dir"
dd if=/dev/zero of="${NONREC_SIZE_ROOT}/huge_dir/blob" bs=1024 count=1024 status=none
dd if=/dev/zero of="${NONREC_SIZE_ROOT}/top_file" bs=1024 count=64 status=none
want_nonrec_size_desc=$'top_file\nhuge_dir/'
assert_eq "no recurse size sort desc uses direct entry size" "$(list_rel_raw "$NONREC_SIZE_ROOT" --sort size desc -R '*')" "$want_nonrec_size_desc"

NONREC_SIZE_L_ROOT="${TMP_BASE}/nonrec_size_l_root"
mkdir -p "${NONREC_SIZE_L_ROOT}/big_dir" "${NONREC_SIZE_L_ROOT}/small_dir"
dd if=/dev/zero of="${NONREC_SIZE_L_ROOT}/big_dir/blob" bs=1024 count=1024 status=none
dd if=/dev/zero of="${NONREC_SIZE_L_ROOT}/small_dir/tiny" bs=1024 count=1 status=none
want_nonrec_size_l_desc=$'big_dir/\nsmall_dir/'
assert_eq "no recurse size sort desc with -L uses real dir size" "$(list_rel_raw "$NONREC_SIZE_L_ROOT" --sort size desc -R -L -d '*' | sed "s#^.*${NONREC_SIZE_L_ROOT}/##")" "$want_nonrec_size_l_desc"

# LONG EXTENDED MATRIX (-L)
LONG_ROOT="${TMP_BASE}/long_root"
mkdir -p "${LONG_ROOT}/folder_match/sub"
touch "${LONG_ROOT}/folder_match/a" "${LONG_ROOT}/folder_match/b" "${LONG_ROOT}/folder_match/sub/c"
long_out="$("$F" --timeout "$F_TIMEOUT" -L -d folder "$LONG_ROOT" 2>/dev/null)"
assert_regex "extended long format" "$long_out" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]+([.][0-9]+)? ?(B|KiB|MiB|GiB|TiB) [0-9]+ .+/$'
assert_contains "extended long file count value" "$long_out" " 3 "
long_out_alias="$("$F" --timeout "$F_TIMEOUT" --long-true-dirsize -d folder "$LONG_ROOT" 2>/dev/null)"
assert_regex "extended long alias format" "$long_out_alias" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]+([.][0-9]+)? ?(B|KiB|MiB|GiB|TiB) [0-9]+ .+/$'

LONG_SYM_ROOT="${TMP_BASE}/long_sym_root"
mkdir -p "${LONG_SYM_ROOT}/real_dir"
dd if=/dev/zero of="${LONG_SYM_ROOT}/real_dir/blob" bs=1024 count=1024 status=none
ln -s "${LONG_SYM_ROOT}/real_dir" "${LONG_SYM_ROOT}/sym_dir"
long_sym_out="$("$F" --timeout "$F_TIMEOUT" -L sym_dir "$LONG_SYM_ROOT" 2>/dev/null)"
assert_regex "extended long symlink dir not traversed" "$long_sym_out" '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]+([.][0-9]+)? ?(B|KiB|MiB|GiB|TiB) 0 .+/sym_dir$'

echo "PASS: help matrix suite"
