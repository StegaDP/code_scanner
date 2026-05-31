# code-scanner

Fast, multi-threaded recursive codebase scanner written in Zig.

It produces:
- Language/config "utilization" stats (GitHub-like) by **bytes** (default) or **lines**
- Top **largest** files (bytes) including line counts
- Top **longest** files (lines) including byte sizes

## Requirements

- Zig `0.16.0` (or compatible)

## Build (Windows x64, single .exe)

This project is set up to build a single executable for `x86_64-windows-gnu` with static linkage to the C runtime (system DLLs like `kernel32.dll` are still used as on any Windows program).

From the repo root:

```powershell
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
```

Binary output:

```text
zig-out\bin\code-scanner.exe
```

## Run

Scan current directory:

```powershell
.\zig-out\bin\code-scanner.exe .
```

Scan a different path:

```powershell
.\zig-out\bin\code-scanner.exe C:\path\to\repo
```

## Common workflows

Exclude market data directory and CSV files:

```powershell
.\zig-out\bin\code-scanner.exe . --exclude-path market_data --exclude-ext csv
```

Exclude multiple extensions/paths (comma-separated):

```powershell
.\zig-out\bin\code-scanner.exe . --exclude-ext "csv,parquet" --exclude-path "market_data,dist"
```

Count utilization by lines instead of bytes (slower; reads files):

```powershell
.\zig-out\bin\code-scanner.exe . --by lines
```

Disable built-in ignores (lock files, build/vendor dirs, etc.):

```powershell
.\zig-out\bin\code-scanner.exe . --no-ignore
```

Include hidden entries (dotfiles / dotdirs):

```powershell
.\zig-out\bin\code-scanner.exe . --include-hidden
```

## CLI

```text
code-scanner [path]
  [--by bytes|lines]
  [--top N]
  [--top-files N]
  [--exclude-ext ext1,ext2]
  [--exclude-path pathpart1,pathpart2]
  [--no-ignore]
  [--include-hidden]
```

Notes:
- `--exclude-ext` matches file extensions (case-insensitive), without the dot (e.g. `csv`, not `.csv`).
- `--exclude-path` matches if the *absolute path contains* the provided substring (case-insensitive). This is simple and fast; use a distinctive folder name (e.g. `market_data`).
- The output bars are ASCII (`#`/`.`) to avoid terminal encoding issues on Windows.

## Output format

- **Summary**: number of detected languages, scanned files, and total metric (bytes/lines)
- **Languages**: utilization table with percentages and bars
- **Largest files**: sorted by bytes, shows bytes + lines + path
- **Longest files**: sorted by lines, shows lines + bytes + path
