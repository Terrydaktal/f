use chrono::{DateTime, Local};
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs::{self, File};
use std::io::{self, IsTerminal, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

const VERSION: &str = "0.7.7";
const KILL_AFTER: &str = "2s";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TypeFlag {
    File,
    Dir,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SortField {
    Date,
    Size,
    Name,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum SortOrder {
    Asc,
    Desc,
}

#[derive(Clone, Debug)]
struct NamePattern {
    type_flag: Option<TypeFlag>,
    regex: String,
}

#[derive(Clone, Debug)]
enum SearchDirMode {
    Path(String),
    Pattern(String),
}

#[derive(Clone, Debug)]
struct Options {
    timeout_dur: String,
    force_pattern_mode: bool,
    long_format: bool,
    long_extended: bool,
    counts: bool,
    regex_mode: bool,
    sort_field: Option<SortField>,
    sort_order: Option<SortOrder>,
    no_recurse: bool,
    follow_links: bool,
    respect_ignore: bool,
    visible_only: bool,
    threads_override: String,
    cache_output: bool,
    absolute_paths: bool,
    force_dir: bool,
    force_file: bool,
    force_full: bool,
    positional: Vec<String>,
}

#[derive(Clone, Debug)]
struct DirStats {
    files: u64,
    bytes: u64,
    human: String,
}

#[derive(Default)]
struct DirStatsCache {
    map: HashMap<String, DirStats>,
    have_dirsize: bool,
    dirsize_threads: String,
}

#[derive(Clone)]
struct ColorSpec {
    by_key: HashMap<String, String>,
    globs: Vec<(String, String)>,
    color_prefix_dir: String,
    color_dir: String,
    color_link: String,
    color_exec: String,
}

fn usage() -> String {
    let txt = r#"A parallel recursive file searcher

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
"#;
    txt.to_string()
}

fn normalize_timeout(t: &str) -> String {
    let is_number = Regex::new(r"^[0-9]+([.][0-9]+)?$").unwrap();
    if is_number.is_match(t) {
        format!("{}s", t)
    } else {
        t.to_string()
    }
}

fn parse_args() -> Result<Options, String> {
    let mut opts = Options {
        timeout_dur: "6s".to_string(),
        force_pattern_mode: false,
        long_format: false,
        long_extended: false,
        counts: false,
        regex_mode: false,
        sort_field: None,
        sort_order: None,
        no_recurse: false,
        follow_links: false,
        respect_ignore: false,
        visible_only: false,
        threads_override: "8".to_string(),
        cache_output: false,
        absolute_paths: false,
        force_dir: false,
        force_file: false,
        force_full: false,
        positional: Vec::new(),
    };

    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0usize;

    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "--timeout" => {
                i += 1;
                if i >= args.len() {
                    return Err("Error: --timeout requires a value.".to_string());
                }
                opts.timeout_dur = normalize_timeout(&args[i]);
            }
            _ if arg.starts_with("--timeout=") => {
                opts.timeout_dur = normalize_timeout(arg.trim_start_matches("--timeout="));
            }
            "--threads" => {
                i += 1;
                if i >= args.len() {
                    return Err("Error: --threads requires a value.".to_string());
                }
                validate_threads(&args[i])?;
                opts.threads_override = args[i].clone();
            }
            _ if arg.starts_with("--threads=") => {
                let v = arg.trim_start_matches("--threads=");
                validate_threads(v)?;
                opts.threads_override = v.to_string();
            }
            "--dir" | "-d" => opts.force_dir = true,
            "--file" | "-f" => opts.force_file = true,
            "--full" | "-F" => opts.force_full = true,
            "--absolute-paths" | "-A" => opts.absolute_paths = true,
            "--regex" | "-r" => opts.regex_mode = true,
            "--sort" => {
                if i + 2 >= args.len() {
                    return Err(
                        "Error: --sort requires FIELD and ORDER (e.g., --sort date desc)."
                            .to_string(),
                    );
                }
                let field = args[i + 1].as_str();
                let order = args[i + 2].as_str();
                opts.sort_field = match field {
                    "date" => Some(SortField::Date),
                    "size" => Some(SortField::Size),
                    "name" => Some(SortField::Name),
                    _ => {
                        return Err(format!(
                            "Error: unsupported sort field '{}'. Supported: date, size, name",
                            field
                        ))
                    }
                };
                opts.sort_order = match order {
                    "asc" => Some(SortOrder::Asc),
                    "desc" => Some(SortOrder::Desc),
                    _ => {
                        return Err(format!(
                            "Error: unsupported sort order '{}'. Supported: asc, desc",
                            order
                        ))
                    }
                };
                i += 2;
            }
            "--no-recurse" | "-R" => opts.no_recurse = true,
            "--follow-links" => opts.follow_links = true,
            "--ignore" => opts.respect_ignore = true,
            "--visible-only" => opts.visible_only = true,
            "--cache-raw" => opts.cache_output = true,
            "--cache" => return Err("f: --cache was renamed to --cache-raw".to_string()),
            "--bypass" | "-b" => opts.force_pattern_mode = true,
            "--long" | "-l" => opts.long_format = true,
            "-L" | "--long-true-dirsize" => {
                opts.long_format = true;
                opts.long_extended = true;
            }
            "--info" | "-i" => return Err("f: --info/-i was renamed to --long/-l".to_string()),
            "--counts" => opts.counts = true,
            "--audit" => return Err("f: --audit was renamed to --counts".to_string()),
            "--version" | "-V" => {
                println!("f {}", VERSION);
                std::process::exit(0);
            }
            "-h" | "--help" => {
                print!("{}", usage());
                std::process::exit(0);
            }
            "--" => {
                for x in args.iter().skip(i + 1) {
                    opts.positional.push(x.clone());
                }
                break;
            }
            _ => opts.positional.push(arg.clone()),
        }
        i += 1;
    }

    if opts.positional.is_empty() {
        return Err(usage());
    }

    Ok(opts)
}

fn validate_threads(v: &str) -> Result<(), String> {
    if v.is_empty() || !v.chars().all(|c| c.is_ascii_digit()) {
        return Err("Error: --threads requires a positive integer.".to_string());
    }
    if v.starts_with('0') {
        return Err("Error: --threads requires a positive integer.".to_string());
    }
    Ok(())
}

fn escape_regex_keep_star(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for ch in s.chars() {
        if "[](){}.^$|+?".contains(ch) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

fn to_regex_fragment(s: &str) -> String {
    let mut x = escape_regex_keep_star(s);
    x = x.replace(r"\*", "__LITERAL_STAR__");
    x = x.replace('*', ".*");
    x.replace("__LITERAL_STAR__", r"\*")
}

fn wildcard_to_regex(pat: &str) -> String {
    let lead_star = pat.starts_with('*');
    let trail_star = {
        if !pat.ends_with('*') {
            false
        } else {
            let bytes = pat.as_bytes();
            if bytes.len() < 2 {
                true
            } else {
                bytes[bytes.len() - 2] != b'\\'
            }
        }
    };
    let mut rx = to_regex_fragment(pat);
    if !lead_star {
        rx = format!("^{}", rx);
    }
    if !trail_star {
        rx.push('$');
    }
    rx
}

fn is_wrapped_quote(raw: &str) -> bool {
    (raw.starts_with('"') && raw.ends_with('"') && raw.len() >= 2)
        || (raw.starts_with('\'') && raw.ends_with('\'') && raw.len() >= 2)
}

fn parse_name_pattern(raw: &str, regex_mode: bool) -> NamePattern {
    let mut out = NamePattern {
        type_flag: None,
        regex: String::new(),
    };

    if is_wrapped_quote(raw) {
        let mut inner = raw[1..raw.len() - 1].to_string();
        inner = inner.trim_start_matches('/').to_string();
        if inner != "/" {
            inner = inner.trim_end_matches('/').to_string();
        }
        out.regex = if regex_mode {
            inner
        } else {
            wildcard_to_regex(&inner)
        };
        return out;
    }

    if regex_mode {
        out.regex = raw.to_string();
        return out;
    }

    if raw.starts_with('/') && raw.ends_with('/') {
        let frag = raw[1..raw.len() - 1].to_string();
        out.type_flag = Some(TypeFlag::Dir);
        out.regex = format!("^{}$", to_regex_fragment(&frag));
        return out;
    }

    if raw.starts_with('/') {
        let frag = raw.trim_start_matches('/');
        out.regex = format!("^{}", to_regex_fragment(frag));
        return out;
    }

    if raw != "/" && raw.ends_with('/') {
        out.type_flag = Some(TypeFlag::Dir);
        let no_slash = raw.trim_end_matches('/');
        out.regex = format!("{}$", to_regex_fragment(no_slash));
        return out;
    }

    if raw.contains('*') {
        out.regex = wildcard_to_regex(raw);
        return out;
    }

    out.regex = to_regex_fragment(raw);
    out
}

fn canonical_path(raw: &str) -> Option<String> {
    let p = Path::new(raw);
    if p.is_dir() {
        fs::canonicalize(p)
            .ok()
            .map(|x| x.to_string_lossy().to_string())
    } else {
        None
    }
}

fn parse_search_dir(raw: &str, regex_mode: bool, force_pattern_mode: bool) -> SearchDirMode {
    if !force_pattern_mode {
        if let Some(p) = canonical_path(raw) {
            return SearchDirMode::Path(p);
        }
    }

    let mut normalized = raw.to_string();
    if normalized != "/" {
        normalized = normalized.trim_end_matches('/').to_string();
    }

    if is_wrapped_quote(raw) {
        let inner = raw[1..raw.len() - 1].to_string();
        if !force_pattern_mode {
            if let Some(p) = canonical_path(&inner) {
                return SearchDirMode::Path(p);
            }
        }
        let mut pattern_inner = inner.trim_start_matches('/').to_string();
        if pattern_inner != "/" {
            pattern_inner = pattern_inner.trim_end_matches('/').to_string();
        }
        let rx = if regex_mode {
            pattern_inner
        } else {
            wildcard_to_regex(&pattern_inner)
        };
        return SearchDirMode::Pattern(rx);
    }

    if regex_mode {
        return SearchDirMode::Pattern(normalized);
    }

    if raw.starts_with('/') && raw.ends_with('/') {
        let frag = raw[1..raw.len() - 1].to_string();
        return SearchDirMode::Pattern(format!("^{}$", to_regex_fragment(&frag)));
    }
    if raw.starts_with("./") && raw.ends_with('/') {
        let frag = raw[2..raw.len() - 1].to_string();
        return SearchDirMode::Pattern(format!("^{}$", to_regex_fragment(&frag)));
    }

    if raw.starts_with('/') {
        let frag = raw.trim_start_matches('/');
        return SearchDirMode::Pattern(format!("^{}", to_regex_fragment(frag)));
    }
    if raw.starts_with("./") {
        let frag = raw.trim_start_matches("./");
        return SearchDirMode::Pattern(format!("^{}", to_regex_fragment(frag)));
    }

    if raw != "/" && raw.ends_with('/') {
        let frag = raw.trim_end_matches('/');
        return SearchDirMode::Pattern(format!("{}$", to_regex_fragment(frag)));
    }

    if normalized.contains('*') {
        return SearchDirMode::Pattern(wildcard_to_regex(&normalized));
    }

    SearchDirMode::Pattern(to_regex_fragment(&normalized))
}

fn run_fd(
    root: &str,
    type_flag: Option<TypeFlag>,
    rx: &str,
    full_path: bool,
    opts: &Options,
) -> Result<Vec<String>, String> {
    let mut cmd = Command::new("timeout");
    cmd.arg("--preserve-status")
        .arg(format!("--kill-after={}", KILL_AFTER))
        .arg(&opts.timeout_dur)
        .arg("fd")
        .arg("--color=never")
        .arg("-i")
        .arg("--exclude")
        .arg("proc")
        .arg("--exclude")
        .arg("sys")
        .arg("--exclude")
        .arg("dev")
        .arg("--exclude")
        .arg("run");

    if !opts.respect_ignore {
        cmd.arg("--no-ignore");
    }
    if !opts.threads_override.is_empty() {
        cmd.arg("--threads").arg(&opts.threads_override);
    }
    if !opts.visible_only {
        cmd.arg("--hidden");
    }
    if opts.follow_links {
        cmd.arg("--follow");
    }
    if opts.no_recurse {
        cmd.arg("--max-depth").arg("1");
    }

    if let Some(tf) = type_flag {
        cmd.arg("--type");
        match tf {
            TypeFlag::File => cmd.arg("f"),
            TypeFlag::Dir => cmd.arg("d"),
        };
    }
    if full_path {
        cmd.arg("--full-path");
    }

    cmd.arg("--regex").arg(rx).arg(root);
    let out = cmd
        .output()
        .map_err(|e| format!("failed to run fd: {}", e))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| !l.is_empty())
        .map(|s| s.to_string())
        .collect())
}

fn find_dirs_anywhere_nul(sd_dir_regex: &str, opts: &Options) -> Result<Vec<String>, String> {
    let mut cmd = Command::new("timeout");
    cmd.arg("--preserve-status")
        .arg(format!("--kill-after={}", KILL_AFTER))
        .arg(&opts.timeout_dur)
        .arg("fd")
        .arg("-i")
        .arg("--exclude")
        .arg("proc")
        .arg("--exclude")
        .arg("sys")
        .arg("--exclude")
        .arg("dev")
        .arg("--exclude")
        .arg("run");
    if !opts.respect_ignore {
        cmd.arg("--no-ignore");
    }
    if !opts.threads_override.is_empty() {
        cmd.arg("--threads").arg(&opts.threads_override);
    }
    if !opts.visible_only {
        cmd.arg("--hidden");
    }
    if opts.follow_links {
        cmd.arg("--follow");
    }

    cmd.arg("--type")
        .arg("d")
        .arg("--regex")
        .arg(sd_dir_regex)
        .arg("/")
        .arg("-0");

    let out = cmd
        .output()
        .map_err(|e| format!("failed to run fd: {}", e))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).to_string());
    }
    let mut dirs = Vec::new();
    for chunk in out.stdout.split(|b| *b == b'\0') {
        if chunk.is_empty() {
            continue;
        }
        dirs.push(String::from_utf8_lossy(chunk).to_string());
    }
    Ok(dirs)
}

fn prune_children(mut lines: Vec<String>) -> Vec<String> {
    lines.sort();
    let mut out = Vec::with_capacity(lines.len());
    let mut last = String::new();
    for line in lines {
        let prefix = last.trim_end_matches('/');
        if !last.is_empty() && line.starts_with(&format!("{}/", prefix)) {
            continue;
        }
        last = line.clone();
        out.push(line);
    }
    out
}

fn format_size_iec(bytes: u64) -> String {
    let units = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut unit = 0usize;
    let mut size = bytes as f64;
    while size >= 1024.0 && unit < units.len() - 1 {
        size /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{} {}", bytes, units[unit])
    } else if size >= 100.0 {
        format!("{:.0} {}", size, units[unit])
    } else if size >= 10.0 {
        format!("{:.1} {}", size, units[unit])
    } else {
        format!("{:.2} {}", size, units[unit])
    }
}

fn metadata_datetime_and_size(path: &str) -> Option<(String, u64)> {
    let meta = fs::metadata(path).ok()?;
    let modified = meta.modified().ok()?;
    let dt: DateTime<Local> = modified.into();
    let dt_str = dt.format("%Y-%m-%d %H:%M:%S").to_string();
    Some((dt_str, meta.len()))
}

fn is_symlink(path: &str) -> bool {
    fs::symlink_metadata(path)
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
}

fn is_dir_follow(path: &str) -> bool {
    fs::metadata(path).map(|m| m.is_dir()).unwrap_or(false)
}

fn du_size_bytes(path: &str) -> u64 {
    let out = Command::new("du")
        .arg("-sB1")
        .arg(path)
        .output()
        .ok()
        .filter(|o| o.status.success());
    if let Some(out) = out {
        let txt = String::from_utf8_lossy(&out.stdout);
        if let Some(first) = txt.split_whitespace().next() {
            return first.parse::<u64>().unwrap_or(0);
        }
    }
    0
}

fn find_file_count(path: &str) -> u64 {
    let out = Command::new("find")
        .arg(path)
        .arg("-type")
        .arg("f")
        .arg("-print")
        .output()
        .ok()
        .filter(|o| o.status.success());
    if let Some(out) = out {
        return String::from_utf8_lossy(&out.stdout).lines().count() as u64;
    }
    0
}

fn get_dirsize_stats(path: &str, cache: &mut DirStatsCache) -> Option<DirStats> {
    if is_symlink(path) {
        return None;
    }
    if let Some(v) = cache.map.get(path) {
        return Some(v.clone());
    }
    if !cache.have_dirsize {
        return None;
    }

    let out = Command::new("dirsize")
        .arg(path)
        .arg("--threads")
        .arg(&cache.dirsize_threads)
        .output()
        .ok()
        .filter(|o| o.status.success())?;

    let txt = String::from_utf8_lossy(&out.stdout);
    let mut files: Option<u64> = None;
    let mut bytes: Option<u64> = None;
    let mut human: Option<String> = None;

    for line in txt.lines() {
        if let Some(v) = line.strip_prefix("files:") {
            files = v.trim().parse::<u64>().ok();
        } else if let Some(v) = line.strip_prefix("bytes:") {
            bytes = v.trim().parse::<u64>().ok();
        } else if let Some(v) = line.strip_prefix("human:") {
            human = Some(v.trim().to_string());
        }
    }

    let stats = DirStats {
        files: files?,
        bytes: bytes?,
        human: human?,
    };
    cache.map.insert(path.to_string(), stats.clone());
    Some(stats)
}

fn sort_results(lines: Vec<String>, opts: &Options, cache: &mut DirStatsCache) -> Vec<String> {
    let Some(field) = opts.sort_field else {
        return lines;
    };
    let order = opts.sort_order.unwrap_or(SortOrder::Asc);

    let mut keyed: Vec<(String, String)> = lines
        .into_iter()
        .map(|line| {
            let key = match field {
                SortField::Date => fs::metadata(&line)
                    .ok()
                    .and_then(|m| m.modified().ok())
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs().to_string())
                    .unwrap_or_else(|| "0".to_string()),
                SortField::Size => {
                    let key_num = if is_dir_follow(&line) {
                        if opts.long_extended {
                            if is_symlink(&line) {
                                fs::symlink_metadata(&line).map(|m| m.len()).unwrap_or(0)
                            } else if let Some(stats) = get_dirsize_stats(&line, cache) {
                                stats.bytes
                            } else {
                                du_size_bytes(&line)
                            }
                        } else if opts.no_recurse {
                            fs::metadata(&line).map(|m| m.len()).unwrap_or(0)
                        } else {
                            du_size_bytes(&line)
                        }
                    } else {
                        fs::metadata(&line).map(|m| m.len()).unwrap_or(0)
                    };
                    key_num.to_string()
                }
                SortField::Name => line
                    .trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .unwrap_or("")
                    .to_string(),
            };
            (key, line)
        })
        .collect();

    keyed.sort_by(|a, b| match field {
        SortField::Name => {
            let ord =
                a.0.to_lowercase()
                    .cmp(&b.0.to_lowercase())
                    .then(a.1.cmp(&b.1));
            match order {
                SortOrder::Asc => ord,
                SortOrder::Desc => ord.reverse(),
            }
        }
        _ => {
            let an = a.0.parse::<u64>().unwrap_or(0);
            let bn = b.0.parse::<u64>().unwrap_or(0);
            let ord = an.cmp(&bn).then(a.1.cmp(&b.1));
            match order {
                SortOrder::Asc => ord,
                SortOrder::Desc => ord.reverse(),
            }
        }
    });

    keyed.into_iter().map(|(_, line)| line).collect()
}

fn absolute_paths_transform(lines: Vec<String>, opts: &Options) -> Vec<String> {
    if !opts.absolute_paths {
        return lines;
    }
    let cwd_abs = env::current_dir()
        .ok()
        .and_then(|p| fs::canonicalize(p).ok())
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let cwd_abs = cwd_abs.to_string_lossy().to_string();

    lines
        .into_iter()
        .map(|p| {
            if p.starts_with('/') {
                p
            } else {
                format!("{}/{}", cwd_abs, p.trim_start_matches("./"))
            }
        })
        .collect()
}

fn fish_pid() -> String {
    if let Ok(v) = env::var("FISH_PID") {
        if !v.is_empty() && v.chars().all(|c| c.is_ascii_digit()) {
            return v;
        }
    }
    if let Ok(v) = env::var("fish_pid") {
        if !v.is_empty() && v.chars().all(|c| c.is_ascii_digit()) {
            return v;
        }
    }
    if let Ok(ppid) = env::var("PPID") {
        if !ppid.is_empty() && ppid.chars().all(|c| c.is_ascii_digit()) {
            let out = Command::new("ps")
                .arg("-p")
                .arg(&ppid)
                .arg("-o")
                .arg("comm=")
                .output()
                .ok();
            if let Some(out) = out {
                if out.status.success() && String::from_utf8_lossy(&out.stdout).trim() == "fish" {
                    return ppid;
                }
            }
        }
    }
    std::process::id().to_string()
}

fn cache_transform(lines: Vec<String>, opts: &Options) -> Vec<String> {
    if !opts.cache_output {
        return lines;
    }

    let user = env::var("USER")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| {
            let out = Command::new("id").arg("-un").output().ok();
            out.map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|v| !v.is_empty())
                .unwrap_or_else(|| "unknown".to_string())
        });
    let pid = fish_pid();
    let cache_dir = format!("/tmp/fzf-history-{}", user);
    let dirs_file = format!("{}/universal-last-dirs-{}", cache_dir, pid);
    let files_file = format!("{}/universal-last-files-{}", cache_dir, pid);

    let _ = fs::create_dir_all(&cache_dir);

    let mut dirs = match File::create(&dirs_file) {
        Ok(f) => f,
        Err(_) => return lines,
    };
    let mut files = match File::create(&files_file) {
        Ok(f) => f,
        Err(_) => return lines,
    };

    let mut seen_dirs = HashSet::new();
    let mut seen_files = HashSet::new();

    for path in &lines {
        if path.ends_with('/') {
            if seen_dirs.insert(path.clone()) {
                let _ = writeln!(dirs, "{}", path);
            }
        } else if seen_files.insert(path.clone()) {
            let _ = writeln!(files, "{}", path);
        }

        let mut parent = path.trim_end_matches('/').to_string();
        if let Some(idx) = parent.rfind('/') {
            parent = parent[..idx].to_string();
            if parent.is_empty() {
                parent = "/".to_string();
            } else if !parent.ends_with('/') {
                parent.push('/');
            }
        } else {
            parent = "./".to_string();
        }

        if seen_dirs.insert(parent.clone()) {
            let _ = writeln!(dirs, "{}", parent);
        }
    }

    lines
}

fn add_info_transform(
    lines: Vec<String>,
    opts: &Options,
    cache: &mut DirStatsCache,
) -> Vec<String> {
    if !opts.long_format {
        return lines;
    }

    let mut out = Vec::new();
    for line in lines {
        if let Some((dt, size_bytes)) = metadata_datetime_and_size(&line) {
            let mut human_size = format_size_iec(size_bytes);
            let mut extra: Option<u64> = None;

            if opts.long_extended && is_dir_follow(&line) {
                if is_symlink(&line) {
                    let bytes = fs::symlink_metadata(&line).map(|m| m.len()).unwrap_or(0);
                    human_size = format_size_iec(bytes);
                    extra = Some(0);
                } else if let Some(stats) = get_dirsize_stats(&line, cache) {
                    human_size = stats.human;
                    extra = Some(stats.files);
                } else {
                    let file_count = find_file_count(&line);
                    let dir_bytes = du_size_bytes(&line);
                    human_size = format_size_iec(dir_bytes);
                    extra = Some(file_count);
                }
            }

            if let Some(c) = extra {
                out.push(format!("{} {} {} {}", dt, human_size, c, line));
            } else {
                out.push(format!("{} {} {}", dt, human_size, line));
            }
        }
    }
    out
}

fn counts_summary_transform(lines: Vec<String>, is_tty: bool) -> Vec<String> {
    let mut counts: HashMap<String, u64> = HashMap::new();
    let long_re = Regex::new(r"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]+([.][0-9]+)? ?(B|KiB|MiB|GiB|TiB)( [0-9]+)? ").unwrap();

    for mut line in lines {
        line = long_re.replace(&line, "").to_string();
        let mut p = line.trim_end_matches('/').to_string();
        let d = if let Some(idx) = p.rfind('/') {
            p.truncate(idx);
            if p.is_empty() {
                "/".to_string()
            } else {
                p
            }
        } else {
            ".".to_string()
        };
        *counts.entry(d).or_insert(0) += 1;
    }

    let mut rows: Vec<(String, u64)> = counts.into_iter().collect();
    rows.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));

    let mut out = Vec::new();
    if is_tty {
        out.push(format!("{:>7}  {}", "COUNT", "FOLDER"));
    }
    for (folder, n) in rows {
        out.push(format!("{:>7}  {}", n, folder));
    }
    out
}

fn escape_file_url_path(url_path: &str) -> String {
    url_path
        .replace('%', "%25")
        .replace(' ', "%20")
        .replace('#', "%23")
        .replace('?', "%3F")
}

fn color_wrap(code: &str, text: &str) -> String {
    if code.is_empty() {
        text.to_string()
    } else {
        format!("\x1b[{}m{}\x1b[0m", code, text)
    }
}

fn parse_ls_colors() -> ColorSpec {
    let mut by_key = HashMap::new();
    let mut globs = Vec::new();
    let mut color_dir = "01;34".to_string();
    let mut color_link = "01;36".to_string();
    let mut color_exec = "01;32".to_string();

    if let Ok(spec) = env::var("LS_COLORS") {
        for entry in spec.split(':') {
            if let Some((k, v)) = entry.split_once('=') {
                if k.starts_with('*') {
                    globs.push((k.to_string(), v.to_string()));
                } else {
                    by_key.insert(k.to_string(), v.to_string());
                    match k {
                        "di" => color_dir = v.to_string(),
                        "ln" => color_link = v.to_string(),
                        "ex" => color_exec = v.to_string(),
                        _ => {}
                    }
                }
            }
        }
    }

    ColorSpec {
        by_key,
        globs,
        color_prefix_dir: "38;2;255;255;255".to_string(),
        color_dir,
        color_link,
        color_exec,
    }
}

fn glob_match(pattern: &str, text: &str) -> bool {
    let mut rx = String::from("^");
    for ch in pattern.chars() {
        match ch {
            '*' => rx.push_str(".*"),
            '?' => rx.push('.'),
            '.' | '+' | '(' | ')' | '[' | ']' | '{' | '}' | '^' | '$' | '|' | '\\' => {
                rx.push('\\');
                rx.push(ch);
            }
            _ => rx.push(ch),
        }
    }
    rx.push('$');
    Regex::new(&rx).map(|r| r.is_match(text)).unwrap_or(false)
}

fn color_code_for_path(abs_path: &str, display_path: &str, colors: &ColorSpec) -> String {
    let path = Path::new(abs_path);
    let base = display_path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("");

    let symlink_meta = fs::symlink_metadata(path).ok();
    let metadata = fs::metadata(path).ok();

    let mut code = String::new();
    let mut allow_glob_overrides = false;

    if symlink_meta
        .as_ref()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        if !path.exists() {
            code = colors
                .by_key
                .get("or")
                .cloned()
                .unwrap_or_else(|| colors.color_link.clone());
        } else {
            code = colors
                .by_key
                .get("ln")
                .cloned()
                .unwrap_or_else(|| colors.color_link.clone());
        }
    } else if metadata.as_ref().map(|m| m.is_dir()).unwrap_or(false) {
        let mode = metadata
            .as_ref()
            .map(|m| m.permissions().mode())
            .unwrap_or(0);
        let sticky = mode & 0o1000 != 0;
        let other_writable = mode & 0o002 != 0;

        if sticky && other_writable {
            if let Some(v) = colors.by_key.get("tw") {
                code = v.clone();
            }
        }
        if code.is_empty() && sticky {
            if let Some(v) = colors.by_key.get("st") {
                code = v.clone();
            }
        }
        if code.is_empty() && other_writable {
            if let Some(v) = colors.by_key.get("ow") {
                code = v.clone();
            }
        }
        if code.is_empty() {
            code = colors
                .by_key
                .get("di")
                .cloned()
                .unwrap_or_else(|| colors.color_dir.clone());
        }
    } else if let Some(m) = symlink_meta.as_ref() {
        let ft = m.file_type();
        if ft.is_fifo() {
            code = colors.by_key.get("pi").cloned().unwrap_or_default();
        } else if ft.is_socket() {
            code = colors.by_key.get("so").cloned().unwrap_or_default();
        } else if ft.is_block_device() {
            code = colors.by_key.get("bd").cloned().unwrap_or_default();
        } else if ft.is_char_device() {
            code = colors.by_key.get("cd").cloned().unwrap_or_default();
        } else if ft.is_file() {
            let mode = m.mode();
            if mode & 0o4000 != 0 {
                code = colors.by_key.get("su").cloned().unwrap_or_default();
                allow_glob_overrides = true;
            } else if mode & 0o2000 != 0 {
                code = colors.by_key.get("sg").cloned().unwrap_or_default();
                allow_glob_overrides = true;
            } else if mode & 0o111 != 0 {
                code = colors
                    .by_key
                    .get("ex")
                    .cloned()
                    .unwrap_or_else(|| colors.color_exec.clone());
                allow_glob_overrides = true;
            } else {
                code = colors.by_key.get("fi").cloned().unwrap_or_default();
                allow_glob_overrides = true;
            }
        } else {
            code = colors.by_key.get("no").cloned().unwrap_or_default();
        }
    }

    if allow_glob_overrides {
        for (pat, val) in &colors.globs {
            if glob_match(pat, base) {
                code = val.clone();
                break;
            }
        }
    }

    code
}

fn display_path_to_abs_path(display_path: &str, cwd_abs: &str) -> String {
    if display_path.starts_with('/') {
        display_path.to_string()
    } else {
        format!("{}/{}", cwd_abs, display_path.trim_start_matches("./"))
    }
}

fn make_hyperlink_text(abs_target: &str, display_text: &str) -> String {
    format!(
        "\x1b]8;;file://{}\x1b\\{}\x1b]8;;\x1b\\",
        escape_file_url_path(abs_target),
        display_text
    )
}

fn render_split_hyperlinked_path(
    display_path: &str,
    abs_path: &str,
    cwd_abs: &str,
    colors: &ColorSpec,
) -> String {
    let (prefix_display, leaf_display) = if display_path.ends_with('/') {
        let path_core = display_path.trim_end_matches('/');
        if path_core.is_empty() {
            (String::new(), "/".to_string())
        } else if let Some((prefix, leaf)) = path_core.rsplit_once('/') {
            (format!("{}/", prefix), format!("{}/", leaf))
        } else {
            (String::new(), format!("{}/", path_core))
        }
    } else if let Some((prefix, leaf)) = display_path.rsplit_once('/') {
        (format!("{}/", prefix), leaf.to_string())
    } else {
        (String::new(), display_path.to_string())
    };

    let prefix_abs = if prefix_display.is_empty() {
        String::new()
    } else {
        display_path_to_abs_path(&prefix_display, cwd_abs)
    };

    let leaf_abs = if display_path.ends_with('/') && !prefix_abs.is_empty() {
        let leaf_name = leaf_display.trim_end_matches('/');
        format!("{}/{}/", prefix_abs.trim_end_matches('/'), leaf_name)
    } else {
        abs_path.to_string()
    };

    let leaf_code = color_code_for_path(abs_path, display_path, colors);
    let leaf_colored = color_wrap(&leaf_code, &leaf_display);

    if !prefix_display.is_empty() {
        let prefix_colored = color_wrap(&colors.color_prefix_dir, &prefix_display);
        format!(
            "{}{}",
            make_hyperlink_text(&prefix_abs, &prefix_colored),
            make_hyperlink_text(&leaf_abs, &leaf_colored)
        )
    } else {
        make_hyperlink_text(&leaf_abs, &leaf_colored)
    }
}

fn add_hyperlink_transform(
    lines: Vec<String>,
    opts: &Options,
    is_tty: bool,
    colors: &ColorSpec,
) -> Vec<String> {
    if !is_tty {
        return lines;
    }

    let cwd_abs = env::current_dir()
        .ok()
        .and_then(|p| fs::canonicalize(p).ok())
        .unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let cwd_abs = cwd_abs.to_string_lossy().to_string();

    let long_re = Regex::new(r"^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2})[[:space:]]+([0-9]+([.][0-9]+)?[[:space:]]?(B|KiB|MiB|GiB|TiB))([[:space:]][0-9]+)?[[:space:]]+(.*)$").unwrap();

    let mut out = Vec::with_capacity(lines.len());
    for line in lines {
        let mut datetime_part = String::new();
        let mut size_part = String::new();
        let mut count_part = String::new();
        let mut path_part = line.clone();

        if opts.long_format {
            if let Some(c) = long_re.captures(&line) {
                datetime_part = c.get(1).map(|m| m.as_str().to_string()).unwrap_or_default();
                size_part = c.get(2).map(|m| m.as_str().to_string()).unwrap_or_default();
                count_part = c.get(5).map(|m| m.as_str().to_string()).unwrap_or_default();
                path_part = c.get(6).map(|m| m.as_str().to_string()).unwrap_or_default();
            }
        }

        if path_part.is_empty() {
            out.push(line);
            continue;
        }

        let abs_path = if path_part.starts_with('/') {
            path_part.clone()
        } else {
            format!("{}/{}", cwd_abs, path_part.trim_start_matches("./"))
        };

        let linked_path = render_split_hyperlinked_path(&path_part, &abs_path, &cwd_abs, colors);
        if !datetime_part.is_empty() {
            let mut prefix = format!(
                "\x1b[37m{}\x1b[0m \x1b[1;36m{}\x1b[0m",
                datetime_part, size_part
            );
            if !count_part.is_empty() {
                prefix.push_str(&count_part);
            }
            prefix.push(' ');
            out.push(format!("{}{}", prefix, linked_path));
        } else {
            out.push(linked_path);
        }
    }
    out
}

fn final_transform(
    mut lines: Vec<String>,
    opts: &Options,
    is_tty: bool,
    colors: &ColorSpec,
    cache: &mut DirStatsCache,
) -> Vec<String> {
    if opts.counts {
        lines = absolute_paths_transform(lines, opts);
        lines = cache_transform(lines, opts);
        counts_summary_transform(lines, is_tty)
    } else {
        lines = sort_results(lines, opts, cache);
        lines = absolute_paths_transform(lines, opts);
        lines = cache_transform(lines, opts);
        lines = add_info_transform(lines, opts, cache);
        add_hyperlink_transform(lines, opts, is_tty, colors)
    }
}

fn dedupe_preserve(lines: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for line in lines {
        if seen.insert(line.clone()) {
            out.push(line);
        }
    }
    out
}

fn run_standard(
    opts: &Options,
    cache: &mut DirStatsCache,
    colors: &ColorSpec,
) -> Result<Vec<String>, String> {
    let name = parse_name_pattern(&opts.positional[0], opts.regex_mode);
    let mut type_flag = name.type_flag;
    if opts.force_dir {
        type_flag = Some(TypeFlag::Dir);
    }
    if opts.force_file {
        type_flag = Some(TypeFlag::File);
    }

    let lines = if opts.positional.len() == 1 {
        run_fd(".", type_flag, &name.regex, false, opts)?
    } else {
        match parse_search_dir(
            &opts.positional[1],
            opts.regex_mode,
            opts.force_pattern_mode,
        ) {
            SearchDirMode::Path(p) => run_fd(&p, type_flag, &name.regex, false, opts)?,
            SearchDirMode::Pattern(sd_rx) => {
                let dirs = find_dirs_anywhere_nul(&sd_rx, opts)?;
                let mut all = Vec::new();
                for d in dirs {
                    if let Ok(mut rows) = run_fd(&d, type_flag, &name.regex, false, opts) {
                        all.append(&mut rows);
                    }
                }
                dedupe_preserve(all)
            }
        }
    };

    Ok(final_transform(
        lines,
        opts,
        io::stdout().is_terminal(),
        colors,
        cache,
    ))
}

fn run_full(
    opts: &Options,
    cache: &mut DirStatsCache,
    colors: &ColorSpec,
) -> Result<Vec<String>, String> {
    let mut search_root = ".".to_string();
    let mut patterns = opts.positional.clone();
    if opts.positional.len() > 1 {
        let last = opts.positional.last().cloned().unwrap_or_default();
        if Path::new(&last).is_dir() {
            search_root = last;
            patterns.pop();
        }
    }

    let mut type_flag = if opts.force_dir {
        Some(TypeFlag::Dir)
    } else if opts.force_file {
        Some(TypeFlag::File)
    } else {
        None
    };

    let mut regexes = Vec::new();
    for p in &patterns {
        let parsed = parse_name_pattern(p, opts.regex_mode);
        if parsed.type_flag == Some(TypeFlag::Dir) && !opts.force_file {
            type_flag = Some(TypeFlag::Dir);
        }
        regexes.push(parsed.regex);
    }

    if regexes.is_empty() {
        return Ok(Vec::new());
    }

    let mut rows = run_fd(&search_root, type_flag, &regexes[0], true, opts)?;

    for rx in regexes.iter().skip(1) {
        let re = Regex::new(rx).map_err(|e| format!("invalid regex '{}': {}", rx, e))?;
        rows = rows.into_iter().filter(|line| re.is_match(line)).collect();
    }

    rows.sort();
    let rows = prune_children(rows);

    Ok(final_transform(
        rows,
        opts,
        io::stdout().is_terminal(),
        colors,
        cache,
    ))
}

fn main() -> ExitCode {
    let opts = match parse_args() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{}", e);
            return ExitCode::from(2);
        }
    };

    let mut cache = DirStatsCache {
        map: HashMap::new(),
        have_dirsize: Command::new("dirsize")
            .arg("--help")
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false),
        dirsize_threads: opts.threads_override.clone(),
    };

    let colors = parse_ls_colors();

    let result = if opts.force_full {
        run_full(&opts, &mut cache, &colors)
    } else {
        run_standard(&opts, &mut cache, &colors)
    };

    match result {
        Ok(lines) => {
            let stdout = io::stdout();
            let mut lock = stdout.lock();
            for line in lines {
                let _ = writeln!(lock, "{}", line);
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            if !e.trim().is_empty() {
                eprintln!("{}", e.trim());
            }
            ExitCode::from(1)
        }
    }
}
