# HSTK for PowerShell

A PowerShell port of the Hammerspace CLI tool and toolkit, [hstk](https://github.com/hammer-space/hstk) (version 4.6.6.1).
It provides the same `hs` command, with the same subcommands, options and exit codes. There is no Python dependency.

It runs on Windows PowerShell 5.1 and PowerShell 7+ (Windows, Linux, macOS), against a Hammerspace SMB or NFS mount.
Like the original, it requires Hammerspace 4.6.5 or later (it uses the `.fs_command_gateway` shadow file).

## Install

Copy the `HSTK` folder into a module path, for example:

```powershell
# current user, PowerShell 7
Copy-Item -Recurse .\HSTK "$HOME\Documents\PowerShell\Modules\HSTK"
# current user, Windows PowerShell 5.1
Copy-Item -Recurse .\HSTK "$HOME\Documents\WindowsPowerShell\Modules\HSTK"

Import-Module HSTK
hs --help
```

Or run it without installing:

```powershell
pwsh -File .\HSTK\hs.ps1 eval -e THIS .
powershell.exe -ExecutionPolicy Bypass -File .\HSTK\hs.ps1 status volume \\server\share
```

On Linux and macOS, `chmod +x hs.ps1` and symlink it as `hs` somewhere on your `PATH`.

## Usage

The command line is identical to the Python tool. Run `hs --cmd-tree` for every command.

```powershell
hs eval -e THIS .\file.txt
hs -j sum -e 'IS_FILE?SUMS_TABLE{|KEY=OWNER,|VALUE=1}' \\server\share\dir
hs tag set -s -e blue color .\file.txt
hs objective add -e 'IF SIZE>33KB' keep-online .\dir
hs keep-on-site available \\server\share
hs rm -rf .\bigdir
hs cp -a .\src .\dest
hs rsync -a --delete .\src\ .\dest
'1+1' | hs eval -i
```

Quote expressions that contain `{ } ( ) ; $ @ ,` or spaces, so that PowerShell passes them through unchanged.

Output lines go to the pipeline, so you can capture or parse them:

```powershell
$vols = hs -j dump volumes | ConvertFrom-Json
```

Verbose and dry-run lines (`-v`, `-n`) go to the host and do not end up in captured output. The exit status is in `$LASTEXITCODE`.

### Library functions

These are equivalents of `hs_eval` / `hs_sum` from `hstk.hscli`. They return one object per path, with JSON output forced on:

```powershell
Invoke-HsEval -Expression 'THIS' -Path .\a, .\b -Recursive   # -> Path, Lines, Text
Invoke-HsSum  -Expression 'IS_FILE?SUMS_TABLE{|KEY=OWNER,|VALUE=1}' -Path \\server\share
```

## Windows notes

* The 50-byte NUL padding the Python tool adds on Windows is kept.
* `cp -a` and `rsync` need the file ID and volume serial number, which `os.stat` provides in Python. Here they come from `GetFileInformationByHandle`, through a small inline C# type compiled on first use, and give the same values.
* `rsync` copies the directory ACL on Windows, where Unix ownership and mode do not exist. In the Python tool, this step crashes on Windows because `os.chown` does not exist there.
* The fallback to the system `rm` / `cp` uses `rm`/`cp` executables if they are on `PATH` (for example from Git for Windows). If they are not, it emulates the common options with `Remove-Item` / `Copy-Item`.

## Differences from the Python tool

The hammerscript command written to the gateway was diffed against the Python tool for 160+ invocations covering every subcommand. It is identical, except where noted below.

* **Dry run (`-n`) works.** In upstream 4.6.6.1, every gateway command crashes in dry-run mode, with `TypeError: string argument expected, got 'bytes'`.
* **`-u/--unbound`** is declared upstream on `tag list`, `tag/rekognition-tag set|add`, `attribute set|add` and `objective add`. However, click never registers it there (it sits under the `param_defaults` wrapper), so upstream rejects it. This port accepts it on `tag list` and on `tag/rekognition-tag set|add`, where the code supports it. It is left off `attribute set|add` (where it is a no-op) and off `objective add` (where it is an error; objectives are always unbound anyway).
* **`hs rm --interactive=WHEN`** now disables fast mode, as its help says. Upstream checks the wrong variable and still does the fast `rm -rf`.
* **`hs rm` fallback passes `-r`/`-f` through.** Upstream drops them, so for example `hs rm -r dir` runs a plain `rm dir`. The fallback's exit code is also returned, where upstream always exits 0.
* **`hs cp` fallback** calls `cp -a` rather than `cp --archive`, which also works with BSD/macOS `cp`. Fallback error messages go to stderr instead of stdout.
* **`rsync` file into a new directory** (`hs rsync -a --delete file newdir/`) works. Upstream crashes on `os.stat('')`.
* When several paths are given, every result block ends with a newline before the next `##### path` header.
* `-i` only shows the `: ` prompt when stdin is a terminal.
* Running a command group with no subcommand (`hs attribute`) prints its help to stderr and exits 2, as click 8.2+ does.

Some upstream quirks are kept on purpose, so that the commands sent to the cluster stay the same:

* `attribute has` sends `get_attribute`.
* `status errors --dump` sends the summary table.
* The `perf` commands create `.stats` but send the command to the share path.

These are marked with `NOTE:` comments in `HSTK.psm1`.

## License

Apache License 2.0, same as the original. Copyright 2021 Hammerspace for the original implementation.
