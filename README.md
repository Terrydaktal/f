# f - Parallel Recursive File Searcher

```
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
      1. Local/Absolute Path: If the path exists on disk (e.g., '.', '/',
      or a specific path), the search is limited to that directory and
      will not fallback to a global search.
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


   The --full flag matches against the full absolute path instead of just
   the basename.
   It supports multiple patterns (implicit AND) and prunes redundant
   child results.

   Example: f --full "src" "main"   # Matches BOTH (hides children)
   Example: f --full "test"         # Returns /path/to/test, but hides
   /path/to/test/file

   Note: In Wildcard/Regex formats, the quotes must be passed literally
   (e.g., f '"abc"').

Notes:
  - Use quotes around patterns containing $ or * to prevent shell expansion.
  - Prefix a pattern with r and wrap in quotes to treat it as a regex
  (e.g., f r"^test").

Options:
  --dir, -d
      Limit results to directories.
  --file, -f
      Limit results to files.
  --audit
      Show an overview of matches by folder (folder path + count), instead of
      listing every matching file.
  --full, -F
      Match against the full absolute path instead of just the basename.
  --info, -i
      Show the date of last modification and size at the start of each line.
  --timeout N
      Per-invocation timeout for each fd call. Default: 6s
      Examples: --timeout 10, --timeout 10s, --timeout 2m
  --bypass, -b
      Force treating the search_dir as a pattern, even if it exists as
      a directory.
```
