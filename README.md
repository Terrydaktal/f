# f - Parallel Recursive File Searcher

`f` is now implemented in Rust.

Build:

```bash
cargo build --release
```

Run from this repo:

```bash
./target/release/f --help
```

Install to your PATH:

```bash
install -Dm755 ./target/release/f ~/.local/bin/f
```

```
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
      1. Local/Absolute Path: If the path exists on disk (e.g., '.', '/',
      or a specific path), the search is limited to that directory and
      will not fallback to a global search.
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


   The --full flag matches against the full absolute path instead of just
   the basename.
   It supports multiple patterns (implicit AND) and prunes redundant
   child results.

   Example: f --full "src" "main"   # Matches BOTH (hides children)
   Example: f --full "test"         # Returns /path/to/test, but hides
   /path/to/test/file

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
      Force treating the search_dir as a pattern, even if it exists as
      a directory.
  --version, -V
      Show version and exit.
```
