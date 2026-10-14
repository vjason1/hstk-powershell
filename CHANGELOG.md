# Changelog

All notable changes to HSTK for PowerShell. The port is versioned independently of
upstream [hammer-space/hstk](https://github.com/hammer-space/hstk); every release so far
mirrors hstk **4.6.6.1**.

## 1.1.0 — 2026-10-13

### Added
- **macOS SMB detection.** The Hammerspace command gateway rejects every command sent through the macOS SMB client (`smbfs`) with an I/O error, even `1+1`, while the same share mounted over NFS works.
  - When the gateway returns that error on an SMB mount, `hs` now explains why and prints the NFS mount command for that share, built from its `mount` entry. It exits with status 1.
  - This is a check made after the error, not a block, so `hs` will work over SMB without changes if Hammerspace adds support.
  - Other errors, NFS mounts and other platforms are unaffected.
- Author, version and changelog header blocks in `HSTK.psm1`, `hs.ps1` and `HSTK.psd1`.
- This changelog.
- Release notes in the module manifest.

### Changed
- `ModuleVersion` now tracks this port's version (1.1.0) instead of the upstream hstk version (4.6.6.1).
- README:
  - new "macOS: use NFS, not SMB" section;
  - adding `hs` to your PowerShell profile;
  - running `hs` from bash/zsh.

## 1.0.2 — 2026-10-13

### Fixed
- **`hs.ps1` finds the module however it's launched.**
  - Run without the `.ps1` extension (`./hs`), pwsh leaves `$PSScriptRoot` empty, so the launcher failed with "Cannot bind argument to parameter 'Path'".
  - Run through a symlink, it looked in the symlink's folder instead of the module's.
  - It now reads the script path from the process command line and follows symlinks. If it still can't find the module, it falls back to an installed `HSTK` module.
- The release zip stores `hs.ps1` with its execute bit set. Without it, macOS opened the file with the Finder ("No application knows how to open URL …").

## 1.0.1 — 2026-10-13

### Changed
- Gateway file I/O on macOS and Linux uses plain POSIX `creat`/`write`/`close` and `open`/`read`/`close`, exactly the calls Python makes.
  - .NET `FileStream` adds an advisory `flock()` on every open, which is extra traffic to the server on a network mount.
  - Windows is unchanged.
- Compiled native helpers are cached in the temp folder, so only the first run pays the compile time.

## 1.0.0 — 2026-10-13

### Added
- Initial PowerShell port of hstk 4.6.6.1.
  - All 17 top-level commands and their subcommands.
  - The same options, exit codes and click-style help and error messages.
  - Command aliases and unique-prefix matching.
  - `Invoke-HsEval` / `Invoke-HsSum` library functions.
- Runs on Windows PowerShell 5.1 and PowerShell 7+ (Windows, Linux, macOS).
- Windows `cp -a` / `rsync` use `GetFileInformationByHandle` for the file ID and volume serial, the same values Python's `os.stat` returns.

### Fixed (relative to upstream 4.6.6.1)
- Dry run (`-n`) no longer crashes on every gateway command (`TypeError: string argument expected, got 'bytes'`).
- `-u/--unbound` works on `tag list` and `tag`/`rekognition-tag set|add`. Upstream declares it, but click never registered it.
- `hs rm --interactive=WHEN` disables fast mode, as documented.
- The `hs rm` fallback passes `-r`/`-f` through and returns the real exit code.
- `hs cp` fallback uses `cp -a`, which also works with BSD/macOS `cp`.
- `hs rsync -a --delete file newdir/` no longer crashes on `os.stat('')`.
- `rsync` on Windows copies the directory ACL. Upstream crashes there, because `os.chown` does not exist on Windows.
