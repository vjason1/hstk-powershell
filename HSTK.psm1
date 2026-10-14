# ==============================================================================
#  HSTK.psm1 — Hammerspace Toolkit (hs) for PowerShell
# ==============================================================================
#
#  Author:       Jason Ventresco
#  Version:      1.1.0
#  Last Updated: 2026-10-13
#
#  PowerShell port of the Hammerspace hstk Python CLI (hammer-space/hstk 4.6.6.1):
#  the same `hs` command, subcommands, options and exit codes, with no Python
#  dependency.  Runs on Windows PowerShell 5.1 and PowerShell 7+ (Windows, Linux,
#  macOS) against a Hammerspace share, using the .fs_command_gateway shadow file
#  (Hammerspace 4.6.5 or later).
#
#  CHANGELOG:
#    1.1.0  (2026-10-13)  macOS SMB mounts: an I/O error from the command gateway
#                         now explains that the macOS SMB client is not supported
#                         and prints the NFS mount command for that share.
#                         Author/changelog headers, CHANGELOG.md, docs update.
#    1.0.2  (2026-10-13)  hs.ps1 finds the module when run without the .ps1
#                         extension or through a symlink, else falls back to an
#                         installed HSTK module.  Execute bit set in the zip.
#    1.0.1  (2026-10-13)  Gateway I/O on macOS/Linux uses plain POSIX
#                         creat/write/read/close (the same calls as Python)
#                         instead of .NET FileStream, which adds flock() calls.
#                         Native helper DLLs are compiled once and cached.
#    1.0.0  (2026-10-13)  Initial port of hstk 4.6.6.1.  All 17 commands and
#                         subcommands, click-compatible parsing and errors,
#                         Invoke-HsEval / Invoke-HsSum library functions.  Fixes
#                         upstream bugs: dry run (-n) crash, missing -u/--unbound,
#                         rm --interactive and -r/-f fallback, rsync os.stat('')
#                         crash, rsync on Windows (ACL copy instead of chown).
#
# ==============================================================================
#
#  Original implementation: Copyright 2021 Hammerspace
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#      http://www.apache.org/licenses/LICENSE-2.0
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
#
#  Layout of this file mirrors the Python package:
#    1. hsscript   - builds the hammerscript command strings  (hstk/hsscript.py)
#    2. gateway    - writes/reads the .fs_command_gateway file (ShadCmd in hscli.py)
#    3. cli engine - a small click-compatible argument parser
#    4. commands   - every `hs` subcommand                     (hscli.py)
#

$ErrorActionPreference = 'Stop'

$script:HsVersion = '1.1.0'            # this port
$script:HstkUpstreamVersion = '4.6.6.1'  # hammer-space/hstk release it mirrors
$script:IsWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or ((Test-Path variable:IsWindows) -and $IsWindows)
$script:IsMac = (Test-Path variable:IsMacOS) -and $IsMacOS
# For windows clients the write to the gateway file must be big enough to be pushed
# all the way through the stack, so it is padded with NULs (same as the Python tool).
if ($script:IsWin) { $script:WinPadding = New-Object byte[] 50 } else { $script:WinPadding = New-Object byte[] 0 }
$script:SHADESC = '?.'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function New-HsGlobals {
    @{ verbose = 0; dry_run = $false; debug = $false; output_json = $false }
}
$script:G = New-HsGlobals
$script:Ctx = $null
$script:PipeInput = @()
$script:PipeIdx = 0
$script:ToolExit = 0
$script:GnsSiteCache = $null

#region ---------------------------------------------------------------- helpers

function New-HsDict { New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal) }

# Raise to unwind out of the CLI with a specific exit code (stands in for sys.exit)
function Exit-Hs([int]$Code) {
    $e = New-Object System.Exception "hs exit $Code"
    $e.Data['HsExit'] = $Code
    throw $e
}

function Write-HsErr([string]$Msg) { [Console]::Error.WriteLine($Msg) }

# click.UsageError / ctx.fail equivalent
function Stop-HsUsage([string]$Msg) {
    if ($script:Ctx) {
        Write-HsErr ('Usage: ' + (Get-HsUsageLine $script:Ctx.Node $script:Ctx.Path))
        Write-HsErr ("Try '" + $script:Ctx.Path + " --help' for help.")
        Write-HsErr ''
    }
    Write-HsErr ('Error: ' + $Msg)
    Exit-Hs 2
}

# Python RuntimeError equivalent (bad option combinations inside hsscript)
function Stop-HsError([string]$Msg) {
    Write-HsErr ('Error: ' + $Msg)
    Exit-Hs 1
}

# vnprint: print a line if verbose or dry-run
function Write-HsVerbose([string]$Line) {
    if ($script:G.verbose -gt 0 -or $script:G.dry_run) {
        $tag = 'V: '
        if ($script:G.dry_run) { $tag = 'N: ' }
        Write-Host ($tag + $Line)
    }
}

# click checkopt: present and not None/False
function Test-HsOpt($Kw, [string]$Key) {
    if ($null -eq $Kw -or -not $Kw.ContainsKey($Key)) { return $false }
    $v = $Kw[$Key]
    if ($null -eq $v) { return $false }
    if ($v -is [bool]) { return $v }
    return $true
}

function ConvertTo-PyBool($v) { if ($v) { 'True' } else { 'False' } }

function Get-HsSeps { if ($script:IsWin) { [char[]]@('\', '/') } else { [char[]]@('/') } }

function Resolve-HsFullPath([string]$Path) {
    if ([string]::IsNullOrEmpty($Path)) { $Path = '.' }
    $p = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [System.IO.Path]::GetFullPath($p)
}

function Test-HsDir([string]$Path)    { [System.IO.Directory]::Exists((Resolve-HsFullPath $Path)) }
function Test-HsFile([string]$Path)   { [System.IO.File]::Exists((Resolve-HsFullPath $Path)) }
function Test-HsExists([string]$Path) { $f = Resolve-HsFullPath $Path; [System.IO.File]::Exists($f) -or [System.IO.Directory]::Exists($f) }

# os.path.basename
function Get-PyBasename([string]$Path) {
    $i = $Path.LastIndexOfAny((Get-HsSeps))
    if ($i -lt 0) { return $Path }
    $Path.Substring($i + 1)
}

# os.path.dirname
function Get-PyDirname([string]$Path) {
    $seps = Get-HsSeps
    $i = $Path.LastIndexOfAny($seps)
    if ($i -lt 0) { return '' }
    $head = $Path.Substring(0, $i + 1)
    $trimmed = $head.TrimEnd($seps)
    if ($trimmed -eq '') { return $head }
    $trimmed
}

# os.path.abspath
function Get-PyAbspath([string]$Path) {
    $f = Resolve-HsFullPath $Path
    $root = [System.IO.Path]::GetPathRoot($f)
    $t = $f.TrimEnd((Get-HsSeps))
    if ($t.Length -lt $root.Length) { return $root }
    $t
}

# os.path.join(a, b)
function Join-PyPath([string]$A, [string]$B) {
    if ($A -eq '') { return $B }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    if ((Get-HsSeps) -contains $A[$A.Length - 1]) { return $A + $B }
    $A + $sep + $B
}

# str(pathlib.Path(p)) - normalise for display the way Python does
function Format-PyPath([string]$Path) {
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $seps = Get-HsSeps
    $prefix = ''
    if ($script:IsWin -and $Path -match '^[\\/]{2}[^\\/]') { $prefix = '\\' }
    elseif ($script:IsWin -and $Path -match '^[A-Za-z]:') { $prefix = $Path.Substring(0, 2); $Path = $Path.Substring(2) }
    if ($prefix -ne '\\' -and $Path.Length -gt 0 -and $seps -contains $Path[0]) { $prefix += $sep }
    $parts = @($Path.Split($seps) | Where-Object { $_ -ne '' -and $_ -ne '.' })
    $r = $prefix + ($parts -join $sep)
    if ($r -eq '') { return '.' }
    $r
}

# repr() of a Python bytes object, used for verbose output
function Format-PyBytes([byte[]]$Bytes) {
    $hasSingle = $Bytes -contains 39
    $hasDouble = $Bytes -contains 34
    $q = "'"
    if ($hasSingle -and -not $hasDouble) { $q = '"' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('b').Append($q)
    foreach ($b in $Bytes) {
        if ($b -eq 92) { [void]$sb.Append('\\') }
        elseif ($b -eq 9) { [void]$sb.Append('\t') }
        elseif ($b -eq 10) { [void]$sb.Append('\n') }
        elseif ($b -eq 13) { [void]$sb.Append('\r') }
        elseif ([char]$b -eq $q) { [void]$sb.Append('\').Append($q) }
        elseif ($b -lt 32 -or $b -ge 127) { [void]$sb.Append('\x').Append($b.ToString('x2')) }
        else { [void]$sb.Append([char]$b) }
    }
    [void]$sb.Append($q)
    $sb.ToString()
}

# json.dumps(list_of_strings) with Python's default formatting
function ConvertTo-PyJsonList([string[]]$Items) {
    $out = foreach ($s in $Items) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        foreach ($c in $s.ToCharArray()) {
            $n = [int]$c
            switch ($n) {
                34 { [void]$sb.Append('\"'); continue }
                92 { [void]$sb.Append('\\'); continue }
                10 { [void]$sb.Append('\n'); continue }
                13 { [void]$sb.Append('\r'); continue }
                9  { [void]$sb.Append('\t'); continue }
                8  { [void]$sb.Append('\b'); continue }
                12 { [void]$sb.Append('\f'); continue }
                default {
                    if ($n -lt 32 -or $n -gt 126) { [void]$sb.Append('\u').Append($n.ToString('x4')) }
                    else { [void]$sb.Append($c) }
                }
            }
        }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    '[' + (@($out) -join ', ') + ']'
}

# Split gateway output into lines for the pipeline
function Split-HsLines([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return }
    $t = $Text -replace "`r`n", "`n"
    if ($t.EndsWith("`n")) { $t = $t.Substring(0, $t.Length - 1) }
    $t.Split("`n")
}

# stat(): device + inode (+ uid/gid/mode on Unix).  Follows symlinks like os.stat.
$script:NativeSrc = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace Hstk {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle h, out BY_HANDLE_FILE_INFORMATION info);

        // returns { volume serial (st_dev), file index (st_ino) } exactly as Python's os.stat on Windows
        public static ulong[] GetFileId(string path) {
            const uint FILE_READ_ATTRIBUTES = 0x80;
            const uint SHARE_ALL = 0x7;
            const uint OPEN_EXISTING = 3;
            const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;  // required to open directories
            SafeFileHandle h = CreateFileW(path, FILE_READ_ATTRIBUTES, SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (h.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "stat " + path);
            using (h) {
                BY_HANDLE_FILE_INFORMATION info;
                if (!GetFileInformationByHandle(h, out info))
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error(), "stat " + path);
                return new ulong[] { info.VolumeSerialNumber, ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow };
            }
        }
    }
}
'@

# Plain POSIX I/O for the gateway file on macOS/Linux.  .NET's FileStream takes an advisory flock()
# on every open (and drops it on close); on an SMB/NFS Hammerspace mount that lock goes to the server
# and the gateway rejects it with EIO.  Python's open() takes no lock, so do the same syscalls it does.
# creat() is used instead of open(..., O_CREAT, mode) because open is variadic, which P/Invoke can't
# call correctly on Apple arm64.
$script:PosixSrc = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
namespace Hstk {
    public static class Posix {
        const string LIBC = "@LIBC@";
        [DllImport(LIBC, SetLastError = true)] static extern int creat(string path, uint mode);
        [DllImport(LIBC, SetLastError = true)] static extern int open(string path, int flags);
        [DllImport(LIBC, SetLastError = true)] static extern IntPtr write(int fd, byte[] buf, IntPtr count);
        [DllImport(LIBC, SetLastError = true)] static extern IntPtr read(int fd, byte[] buf, IntPtr count);
        [DllImport(LIBC, SetLastError = true)] static extern int close(int fd);
        const int EINTR = 4;

        static IOException Err(string op, string path) {
            int errno = Marshal.GetLastWin32Error();
            string msg = new System.ComponentModel.Win32Exception(errno).Message;
            return new IOException("[Errno " + errno + "] " + msg + ": " + op + " '" + path + "'", errno);
        }

        // open(path, 'wb'); write(data); close()
        public static void WriteFile(string path, byte[] data) {
            int fd = creat(path, 438 /* 0666, umask applies */);
            if (fd < 0) throw Err("open", path);
            bool ok = false;
            try {
                int off = 0;
                while (off < data.Length) {
                    byte[] chunk = data;
                    if (off > 0) { chunk = new byte[data.Length - off]; Array.Copy(data, off, chunk, 0, chunk.Length); }
                    long n = (long)write(fd, chunk, (IntPtr)chunk.Length);
                    if (n < 0) { if (Marshal.GetLastWin32Error() == EINTR) continue; throw Err("write", path); }
                    off += (int)n;
                }
                ok = true;
            } finally {
                int rc = close(fd);
                if (rc != 0 && ok) throw Err("close", path);
            }
        }

        // open(path, 'r').read()
        public static byte[] ReadFile(string path) {
            int fd = open(path, 0 /* O_RDONLY */);
            if (fd < 0) throw Err("open", path);
            try {
                MemoryStream ms = new MemoryStream();
                byte[] buf = new byte[65536];
                while (true) {
                    long n = (long)read(fd, buf, (IntPtr)buf.Length);
                    if (n < 0) { if (Marshal.GetLastWin32Error() == EINTR) continue; throw Err("read", path); }
                    if (n == 0) break;
                    ms.Write(buf, 0, (int)n);
                }
                return ms.ToArray();
            } finally { close(fd); }
        }
    }
}
'@

# Compile a helper type once and cache the DLL, so later runs don't pay the compile cost
function Import-HsNativeType([string]$TypeName, [string]$Source) {
    if ($TypeName -as [type]) { return }
    $hash = [BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($script:Utf8.GetBytes($Source + $PSVersionTable.PSVersion))).Replace('-', '').Substring(0, 16)
    $dll = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'hstk-' + $hash + '.dll')
    try {
        if (-not [System.IO.File]::Exists($dll)) {
            $tmp = $dll + '.' + [guid]::NewGuid().ToString('N')
            Add-Type -TypeDefinition $Source -OutputAssembly $tmp -OutputType Library
            try { [System.IO.File]::Move($tmp, $dll) } catch { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
        }
        if (-not ($TypeName -as [type])) { Add-Type -Path $dll }
    } catch {
        if (-not ($TypeName -as [type])) { Add-Type -TypeDefinition $Source }
    }
}

function Initialize-HsNative { Import-HsNativeType 'Hstk.Native' $script:NativeSrc }

function Initialize-HsPosix {
    if ($script:IsMac) { $lib = '/usr/lib/libSystem.B.dylib' } else { $lib = 'libc.so.6' }
    Import-HsNativeType 'Hstk.Posix' ($script:PosixSrc.Replace('@LIBC@', $lib))
}

# Write the command to / read the reply from the gateway file
function Write-HsGatewayFile([string]$Path, [byte[]]$Bytes) {
    if (-not $script:IsWin) { Initialize-HsPosix; [Hstk.Posix]::WriteFile($Path, $Bytes); return }
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    try { $fs.Write($Bytes, 0, $Bytes.Length); $fs.Flush() } finally { $fs.Dispose() }
}

function Read-HsGatewayFile([string]$Path) {
    if (-not $script:IsWin) { Initialize-HsPosix; return $script:Utf8.GetString([Hstk.Posix]::ReadFile($Path)) }
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($fs, $script:Utf8)
        $reader.ReadToEnd()
    } finally { $fs.Dispose() }
}

# --- macOS SMB detection -------------------------------------------------------------
# The Hammerspace command gateway rejects every command sent through the macOS SMB client
# (smbfs) with EIO, while the same share mounted over NFS works.  When that happens, explain
# it and print the NFS mount command for that share rather than a bare I/O error.

$script:MountTable = $null

# Parsed `mount` output: @{ Source; Point; Type } per mount (macOS format)
function Get-HsMountTable {
    if ($null -ne $script:MountTable) { return $script:MountTable }
    $rows = @()
    try {
        $mountExe = Get-Command -Name mount -CommandType Application -ErrorAction Stop | Select-Object -First 1
        foreach ($l in (& $mountExe.Source 2>$null)) {
            # macOS:  //user@host/share on /Volumes/share (smbfs, nodev, nosuid, mounted by user)
            if ([string]$l -match '^(.+?) on (.+) \(([^,\s)]+)') {
                $rows += @{ Source = $Matches[1]; Point = $Matches[2]; Type = $Matches[3] }
            }
        }
    } catch { }
    $script:MountTable = $rows
    $rows
}

# The mount holding $FullPath (longest matching mount point), or $null
function Get-HsMountFor([string]$FullPath) {
    $best = $null
    foreach ($m in (Get-HsMountTable)) {
        $pt = $m.Point.TrimEnd('/')
        if ($FullPath -eq $m.Point -or $FullPath -eq $pt -or $FullPath.StartsWith($pt + '/', [StringComparison]::OrdinalIgnoreCase)) {
            if ($null -eq $best -or $pt.Length -gt $best.Point.TrimEnd('/').Length) { $best = $m }
        }
    }
    $best
}

# True if the exception chain contains an EIO (errno 5) IOException from the POSIX gateway I/O
function Test-HsEio($Exception) {
    $ex = $Exception
    while ($null -ne $ex) {
        if ($ex -is [System.IO.IOException] -and $ex.HResult -eq 5) { return $true }
        $ex = $ex.InnerException
    }
    $false
}

# Explanation for a gateway EIO on a macOS SMB mount, or $null if that's not the situation
function Get-HsSmbHint([string]$GatewayPath) {
    if (-not $script:IsMac) { return $null }
    $m = Get-HsMountFor $GatewayPath
    if ($null -eq $m -or $m.Type -ne 'smbfs') { return $null }
    $server = '<server>'; $share = '<share>'
    if ($m.Source -match '^//(?:[^@/]*@)?([^/]+)/(.+)$') {
        $server = $Matches[1]
        $share = [Uri]::UnescapeDataString($Matches[2]).TrimEnd('/')
    }
    $nfsPoint = $m.Point.TrimEnd('/') + '-nfs'
    # single-quote for the shell only when needed
    $q = { param($v) if ($v -match '^[A-Za-z0-9._/:@%+=-]+$') { $v } else { "'" + $v.Replace("'", "'\''") + "'" } }
    @(
        ("Error: the Hammerspace command gateway returned an I/O error on '" + $m.Point + "'."),
        ("'" + $m.Point + "' is an SMB mount (" + $m.Source + "), and Hammerspace commands do not work"),
        'through the macOS SMB client. Mount the same share over NFS and run hs from there:',
        '',
        ('    sudo mkdir -p ' + (& $q $nfsPoint)),
        ('    sudo mount -t nfs -o vers=3,resvport ' + (& $q ($server + ':/' + $share)) + ' ' + (& $q $nfsPoint)),
        '',
        ("If the export path differs, 'showmount -e " + $server + "' lists them.")
    ) -join "`n"
}

# Run a gateway file operation; turn a macOS-SMB EIO into the explanation above
function Invoke-HsGatewayIo([string]$GatewayPath, [scriptblock]$Op) {
    try {
        & $Op
    } catch {
        if (Test-HsEio $_.Exception) {
            $hint = Get-HsSmbHint $GatewayPath
            if ($hint) { Write-HsErr $hint; Exit-Hs 1 }
        }
        throw
    }
}

function Get-HsStat([string]$Path) {
    $p = $Path
    if ($p -eq '') { $p = '.' }
    if (-not (Test-HsExists $p)) {
        throw (New-Object System.IO.FileNotFoundException "[Errno 2] No such file or directory: '$Path'")
    }
    $full = Resolve-HsFullPath $p
    if ($script:IsWin) {
        Initialize-HsNative
        $id = [Hstk.Native]::GetFileId($full)
        return @{ dev = [uint64]$id[0]; ino = [uint64]$id[1]; uid = $null; gid = $null; mode = $null }
    }
    if ($script:IsMac) { $out = & stat -L -f '%d %i %u %g %p' -- $full } else { $out = & stat -L -c '%d %i %u %g %f' -- $full }
    if ($LASTEXITCODE -ne 0) { throw "stat failed on '$Path'" }
    $f = ([string]$out).Trim().Split(' ')
    if ($script:IsMac) { $mode = [Convert]::ToInt32($f[4], 8) } else { $mode = [Convert]::ToInt32($f[4], 16) }
    @{ dev = [uint64]::Parse($f[0]); ino = [uint64]::Parse($f[1]); uid = [int64]$f[2]; gid = [int64]$f[3]; mode = $mode }
}

# os.mkdir: single level, fails if the parent is missing or the path exists
function New-HsDir([string]$Path) {
    $full = Resolve-HsFullPath $Path
    if ([System.IO.File]::Exists($full) -or [System.IO.Directory]::Exists($full)) { throw "[Errno 17] File exists: '$Path'" }
    $parent = [System.IO.Path]::GetDirectoryName($full.TrimEnd((Get-HsSeps)))
    if ($parent -and -not [System.IO.Directory]::Exists($parent)) { throw "[Errno 2] No such file or directory: '$Path'" }
    [void][System.IO.Directory]::CreateDirectory($full)
}

function Get-HsStrError([int]$Code) {
    try { (New-Object System.ComponentModel.Win32Exception $Code).Message } catch { "error $Code" }
}

#endregion
#region ---------------------------------------------------------------- 1. hsscript

function New-HsExp([string]$Exp, [switch]$String, [switch]$InputJson, [switch]$Unbound) {
    @{ exp = $Exp; string = [bool]$String; input_json = [bool]$InputJson; unbound = [bool]$Unbound; __hsexp = $true }
}

function ConvertTo-HsExpString($V) {
    if ($V.unbound) { $r = 'EXPRESSION(' + $V.exp + ')' } else { $r = $V.exp }
    if ($V.string) { $r = '"' + $r + '"' }
    $r
}

function Test-HsExp($V) { ($V -is [hashtable]) -and $V.ContainsKey('__hsexp') }

function Build-HsEval($Kw) {
    if ((Test-HsOpt $Kw 'compact') -and (Test-HsOpt $Kw 'raw')) { Stop-HsError 'Select only one of compact / raw' }
    $r = 'eval'
    if (Test-HsOpt $Kw 'compact') { $r += '_compact' }
    if (Test-HsOpt $Kw 'raw') { $r += '_raw' }
    if (Test-HsOpt $Kw 'nonfiles') { $r += '_rec_nofiles' }
    elseif (Test-HsOpt $Kw 'recursive') { $r += '_rec' }
    if (Test-HsOpt $Kw 'json') { $r += '_json' }
    $r
}

function Build-HsSum($Kw) {
    if ((Test-HsOpt $Kw 'compact') -and (Test-HsOpt $Kw 'raw')) { Stop-HsError 'Select only one of compact / raw' }
    $r = 'sum'
    if (Test-HsOpt $Kw 'compact') { $r += '_compact' }
    if (Test-HsOpt $Kw 'raw') { $r += '_raw' }
    if (Test-HsOpt $Kw 'nonfiles') { $r += '_nofiles' }
    if (Test-HsOpt $Kw 'json') { $r += '_json' }
    $r
}

function Build-HsSet($Kw) {
    $r = 'set'
    if (Test-HsOpt $Kw 'nonfiles') { $r += '_rec_nofiles' }
    elseif (Test-HsOpt $Kw 'recursive') { $r += '_rec' }
    $r
}

function Build-HsInheritance($Kw) {
    $keys = @('local', 'inherited', 'object', 'active', 'effective', 'share')
    for ($a = 0; $a -lt $keys.Count; $a++) {
        for ($b = $a + 1; $b -lt $keys.Count; $b++) {
            if ((Test-HsOpt $Kw $keys[$a]) -and (Test-HsOpt $Kw $keys[$b])) {
                Stop-HsError ('Select only one of ' + $keys[$a] + ' / ' + $keys[$b])
            }
        }
    }
    foreach ($k in $keys) { if (Test-HsOpt $Kw $k) { return '_' + $k } }
    ''
}

# _clean_str: the UCHARS remap table is empty upstream, so this is just the shadow prefix
function Format-HsShad([string]$Value) { $script:SHADESC + $Value }

function Format-HsValueArg($V) {
    if ($V.input_json) { ', EXPRESSION_FROM_JSON(' + (ConvertTo-HsExpString $V) + ')' }
    else { ', EXPRESSION_FROM_TEXT(' + (ConvertTo-HsExpString $V) + ')' }
}

function Get-HsListCmd([string]$MdType, $Kw) {
    $r = (Build-HsEval $Kw) + ' list_' + $MdType + 's' + (Build-HsInheritance $Kw)
    if (Test-HsOpt $Kw 'unbound') { $r += '_unbound' }
    Format-HsShad $r
}

function Get-HsReadCmd([string]$MdType, [string]$ReadType, $Kw) {
    $value = $Kw['value']
    $unbound = Test-HsOpt $Kw 'unbound'
    if ($MdType -eq 'objective') {
        if ($null -eq $value) { $value = New-HsExp 'true' }
        # Objectives are always unbound and string
        $value.unbound = $true
        $value.string = $true
    } elseif ($null -ne $value) {
        Stop-HsError 'Only specify a value for objectives'
    }
    if ($ReadType -eq 'has' -and $unbound) { Stop-HsError 'unbound only allowed on get, not on has' }
    $r = (Build-HsEval $Kw) + ' ' + $ReadType + '_' + $MdType + (Build-HsInheritance $Kw)
    if ($ReadType -eq 'get' -and $unbound) { $r += '_unbound' }
    $r += '("' + $Kw['name'] + '"'
    if ($null -ne $value) { $r += Format-HsValueArg $value }
    $r += ')'
    Format-HsShad $r
}

function Get-HsUpdateCmd([string]$MdType, [string]$UpdateType, [string]$Table, $Kw) {
    $value = $Kw['value']
    if ($null -eq $value) { $value = New-HsExp 'true' -String }
    if (-not (Test-HsExp $value)) { Stop-HsError 'value must be of type HSExp' }
    $unbound = Test-HsOpt $Kw 'unbound'
    if ($UpdateType -eq 'add' -and $unbound) { Stop-HsError 'unbound only allowed on set, not on add' }

    $r = Build-HsSet $Kw
    if ($MdType -eq 'attribute') {
        # annoying special case
        if ($value.input_json) { $r += '_json' }
        $r += ' ' + $Kw['name'] + '=' + (ConvertTo-HsExpString $value)
    } else {
        $r += ' #' + $Table + '=' + $UpdateType + '_' + $MdType + '("' + $Kw['name'] + '"'
        if ($UpdateType -eq 'set' -or $MdType -eq 'objective') {
            if ($unbound -or $MdType -eq 'objective') { $value.unbound = $true }
            $value.string = $true
            $r += Format-HsValueArg $value
        }
        $r += ')'
    }
    Format-HsShad $r
}

function Get-HsDelCmd([string]$MdType, [string]$Table, $Kw) {
    $value = $Kw['value']
    if ($MdType -eq 'objective' -and $null -eq $value) { $value = New-HsExp 'true' }
    $r = (Build-HsSet $Kw) + ' '
    if ($MdType -eq 'attribute') {
        $r += $Kw['name'] + '=#EMPTY'
    } else {
        if (Test-HsOpt $Kw 'force') { $r += '#' + $Table + '=delete_force_' + $MdType }
        else { $r += '#' + $Table + '=delete_' + $MdType }
        $r += '("' + $Kw['name'] + '"'
        if ($MdType -eq 'objective') {
            $value.unbound = $true
            $value.string = $true
            $r += Format-HsValueArg $value
        }
        $r += ')'
    }
    Format-HsShad $r
}

# Thrown when eval/sum have no expression; caught by the gateway runner (ValueError upstream)
function Stop-HsNoExpression {
    $e = New-Object System.ArgumentException 'No expression'
    $e.Data['HsNoExpression'] = $true
    throw $e
}

function Get-HsEvalCmd($Kw, [switch]$Sum) {
    $value = $Kw['value']
    if (-not (Test-HsExp $value)) { Stop-HsNoExpression }
    if ($Sum) { $r = Build-HsSum $Kw } else { $r = Build-HsEval $Kw }
    if ($value.input_json) { $r += " EVAL(EXPRESSION_FROM_JSON('" + (ConvertTo-HsExpString $value) + "'))" }
    else { $r += ' ' + (ConvertTo-HsExpString $value) }
    Format-HsShad $r
}

$script:MdTables = @{
    attribute       = $null
    tag             = 'tags'
    rekognition_tag = 'rekognition_tags'
    label           = 'assigned_labels'
    keyword         = 'keywords'
    objective       = 'objectives'
    keep_on_site    = 'keep_on_sites'
}

# Map a generator name (hsscript.py function name) to its command string
function Invoke-HsGen([string]$Gen, $Kw) {
    switch -Regex -CaseSensitive ($Gen) {
        '^eval$'       { return Get-HsEvalCmd $Kw }
        '^sum$'        { return Get-HsEvalCmd $Kw -Sum }
        '^rm_rf$'      { return Format-HsShad 'rm-rf' }
        '^cp_a$'       { return Format-HsShad ('cp-a ' + $Kw['dest_inode']) }
        '^inode_info$' { return Format-HsShad 'attribute=inode_info' }
        '^(attribute|tag|rekognition_tag|label|keyword|objective|keep_on_site)_(list|get|has|set|add|del)$' {
            $md = $Matches[1]; $op = $Matches[2]
            switch ($op) {
                'list' { return Get-HsListCmd $md $Kw }
                'get'  { return Get-HsReadCmd $md 'get' $Kw }
                'has'  { return Get-HsReadCmd $md 'has' $Kw }
                'set'  { return Get-HsUpdateCmd $md 'set' $script:MdTables[$md] $Kw }
                'add'  { return Get-HsUpdateCmd $md 'add' $script:MdTables[$md] $Kw }
                'del'  { return Get-HsDelCmd $md $script:MdTables[$md] $Kw }
            }
        }
        default { throw "unknown hsscript generator $Gen" }
    }
}

#endregion
#region ---------------------------------------------------------------- 2. gateway (ShadCmd)

# click.prompt('') replacement, used by -i/--exp-stdin and --interactive
function Read-HsExpression {
    while ($true) {
        if ($script:PipeIdx -lt $script:PipeInput.Count) {
            $line = [string]$script:PipeInput[$script:PipeIdx]
            $script:PipeIdx++
        } elseif ([Console]::IsInputRedirected) {
            $line = [Console]::In.ReadLine()
            if ($null -eq $line) { Write-HsErr 'Aborted!'; Exit-Hs 1 }
        } elseif ($script:PipeInput.Count -gt 0) {
            # pipeline input was supplied and is now exhausted
            Write-HsErr 'Aborted!'; Exit-Hs 1
        } else {
            Write-Host -NoNewline ': '
            $line = Read-Host
            if ($null -eq $line) { Write-HsErr 'Aborted!'; Exit-Hs 1 }
        }
        if ($line -ne '') { return $line }
    }
}

# ShadCmd.process_kwargs
function Initialize-HsShadKwargs($Kw) {
    $sets = @(
        @('local', 'inherited', 'object', 'active', 'effective', 'share'),
        @('raw', 'compact'),
        @('exp_file', 'exp_stdin', 'exp')
    )
    foreach ($set in $sets) {
        $cnt = 0
        foreach ($a in $set) { if (Test-HsOpt $Kw $a) { $cnt++ } }
        if ($cnt -gt 1) {
            $tuple = '(' + ((@($set | ForEach-Object { "'" + $_ + "'" })) -join ', ') + ')'
            Stop-HsUsage ('specify only one of the following options, found ' + $cnt + ': ' + $tuple)
        }
    }

    $Kw['json'] = (Test-HsOpt $Kw 'force_json') -or [bool]$script:G.output_json

    $exp = $null
    if (Test-HsOpt $Kw 'exp_file') {
        $reader = New-Object System.IO.StreamReader((Resolve-HsFullPath $Kw['exp_file']), $script:Utf8)
        try { $exp = $reader.ReadLine() } finally { $reader.Dispose() }
        if ($null -eq $exp) { $exp = '' }
    } elseif (Test-HsOpt $Kw 'exp_stdin') {
        $exp = Read-HsExpression
    } elseif (Test-HsOpt $Kw 'exp') {
        $exp = [string]$Kw['exp']
    }
    if ($null -ne $exp) { $Kw['value'] = New-HsExp $exp }

    if ((Test-HsOpt $Kw 'string') -and (Test-HsOpt $Kw 'value')) { $Kw['value'].string = $true }
    if ((Test-HsOpt $Kw 'input_json') -and (Test-HsOpt $Kw 'value')) { $Kw['value'].input_json = $true }
}

# ShadCmd.run_cmd: send one command through the gateway file next to/inside $Path, return the reply text
function Invoke-HsGatewayCmd([string]$Path, [string]$Gen, $Kw) {
    $disp = Format-PyPath $Path
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    $workId = '0x' + ('{0:x}' -f (Get-Random -Minimum 0 -Maximum 100000000))
    $gwName = '.fs_command_gateway ' + $workId
    $full = Resolve-HsFullPath $Path

    if ([System.IO.Directory]::Exists($full)) {
        $gwFull = [System.IO.Path]::Combine($full, $gwName)
        $parentDisp = $disp
        $prefix = './'
    } else {
        $gwFull = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($full), $gwName)
        $i = $disp.LastIndexOf($sep, [StringComparison]::Ordinal)
        if ($i -lt 0) { $parentDisp = '.' } elseif ($i -eq 0) { $parentDisp = $sep } else { $parentDisp = $disp.Substring(0, $i) }
        $prefix = './' + (Get-PyBasename $disp)
    }
    if ($parentDisp -eq '.') { $gwDisp = $gwName }
    elseif ($parentDisp.EndsWith($sep)) { $gwDisp = $parentDisp + $gwName }
    else { $gwDisp = $parentDisp + $sep + $gwName }

    Write-HsVerbose ('open( ' + $gwDisp + ' )')
    try {
        $cmdStr = $prefix + (Invoke-HsGen $Gen $Kw)
    } catch {
        if ($_.Exception.Data.Contains('HsNoExpression')) {
            Write-HsErr 'No expression (-e) provided'
            Exit-Hs 2
        }
        throw
    }
    $body = $script:Utf8.GetBytes($cmdStr)
    $bytes = New-Object byte[] ($body.Length + $script:WinPadding.Length)
    [Array]::Copy($body, $bytes, $body.Length)

    Write-HsVerbose ('write( ' + (Format-PyBytes $bytes) + ' )')
    Write-HsVerbose 'flush()'
    Write-HsVerbose ('close( ' + $gwDisp + ' )')
    if (-not $script:G.dry_run) { Invoke-HsGatewayIo $gwFull { Write-HsGatewayFile $gwFull $bytes } }

    # open again to collect the results
    Write-HsVerbose ('open( ' + $gwDisp + ' )')
    Write-HsVerbose 'calling read()'
    if ($script:G.dry_run) {
        $text = 'dry run output'
    } else {
        $text = Invoke-HsGatewayIo $gwFull { Read-HsGatewayFile $gwFull }
        $text = $text -replace "`r`n", "`n"
    }
    $nlines = ([regex]::Matches($text, "`n")).Count
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $nlines++ }
    Write-HsVerbose ('read() returned ' + $nlines + ' lines ' + $text.Length + ' bytes')
    Write-HsVerbose ('close( ' + $gwDisp + ' )')
    $text
}

# ShadCmd(...).runshad(): returns a list of @{ Path; Display; Text }
function Invoke-HsShad([string]$Gen, $Kw) {
    Initialize-HsShadKwargs $Kw
    $results = New-Object System.Collections.ArrayList
    $index = New-HsDict
    foreach ($p in @($Kw['pathnames'])) {
        if ($null -eq $p) { continue }
        $text = Invoke-HsGatewayCmd ([string]$p) $Gen $Kw
        $disp = Format-PyPath ([string]$p)
        if ($index.ContainsKey($disp)) {
            $results[$index[$disp]].Text = $text
        } else {
            $index[$disp] = $results.Count
            [void]$results.Add([pscustomobject]@{ Path = [string]$p; Display = $disp; Text = $text })
        }
    }
    , $results
}

# ShadCmd.run() output
function Write-HsShadResults($Results) {
    $printNames = $Results.Count -gt 1
    foreach ($r in $Results) {
        if ($printNames) { '##### ' + $r.Display }
        Split-HsLines $r.Text
    }
}

# _cmd_retcode
function Invoke-HsRetcode([string]$Gen, $Kw) {
    $res = Invoke-HsShad $Gen $Kw
    Write-HsShadResults $res
    Exit-Hs 0
}

# hs_eval / hs_sum: run per path with JSON output and return hashtable path -> lines
function Get-HsCaptured([string]$Gen, $Kw) {
    $ret = New-HsDict
    foreach ($p in @($Kw['pathnames'])) {
        $k = @{}
        foreach ($key in $Kw.Keys) { $k[$key] = $Kw[$key] }
        $k['force_json'] = $true
        $k['pathnames'] = @($p)
        $res = Invoke-HsShad $Gen $k
        $lines = @()
        foreach ($r in $res) { $lines += @(Split-HsLines $r.Text) }
        $ret[[string]$p] = $lines
    }
    $ret
}

function Invoke-HsDirsCount([string[]]$Paths) {
    [void](Get-HsCaptured 'sum' @{ exp = '1'; nonfiles = $true; pathnames = $Paths })
}

#endregion
#region ---------------------------------------------------------------- 3. cli engine (click-alike)

function New-HsOpt([string]$Key, [string[]]$Flags, [string]$Help, [string]$Kind = 'flag', $Default = $null) {
    @{ Key = $Key; Flags = $Flags; Help = $Help; Kind = $Kind; Default = $Default }
}

function New-HsArg([string]$Key, [int]$Nargs = 1, [bool]$Required = $true, $Default = $null, [string]$Check = $null, [string]$Metavar = $null) {
    # click's error hint is the metavar as declared, else the upper-cased name
    if ($Metavar) { $hint = $Metavar } else { $Metavar = $Key; $hint = $Key.ToUpper() }
    @{ Key = $Key; Nargs = $Nargs; Required = $Required; Default = $Default; Check = $Check; Metavar = $Metavar; Hint = $hint }
}

function New-HsCmd([string]$Name, [string]$Help, [object[]]$Opts = @(), [object[]]$Arguments = @(), [scriptblock]$Handler, [switch]$DefaultPaths, [switch]$IgnoreUnknown, [string]$ShortHelp = $null) {
    @{ Kind = 'command'; Name = $Name; Help = $Help; ShortHelp = $ShortHelp; Opts = @($Opts); Args = @($Arguments); Handler = $Handler; DefaultPaths = [bool]$DefaultPaths; IgnoreUnknown = [bool]$IgnoreUnknown }
}

function New-HsGroup([string]$Name, [string]$Help, [string]$ShortHelp = $null, [object[]]$Opts = @()) {
    @{ Kind = 'group'; Name = $Name; Help = $Help; ShortHelp = $ShortHelp; Opts = @($Opts); Args = @(); Order = (New-Object System.Collections.ArrayList); Children = (New-HsDict); Aliases = (New-HsDict); IgnoreUnknown = $false }
}

function Add-HsChild($Group, $Child) {
    [void]$Group.Order.Add($Child.Name)
    $Group.Children[$Child.Name] = $Child
    $Child
}

# OrderedGroup.get_command: exact name, then alias, then unique prefix
function Resolve-HsChild($Group, [string]$Name) {
    if ($Group.Children.ContainsKey($Name)) { return $Group.Children[$Name] }
    if ($Group.Aliases.ContainsKey($Name)) { return $Group.Children[$Group.Aliases[$Name]] }
    $m = @($Group.Order | Where-Object { $_.StartsWith($Name, [StringComparison]::Ordinal) })
    if ($m.Count -eq 0) { Stop-HsUsage ("No such command '" + $Name + "'.") }
    if ($m.Count -ne 1) { Stop-HsUsage ($Name + ' matched too many commands: ' + ((@($m | Sort-Object)) -join ', ')) }
    $Group.Children[$m[0]]
}

function Get-HsArgMetavar($A) {
    $m = $A.Metavar.ToUpper()
    if ($A.Nargs -eq -1) {
        if ($A.Required) { return $m + '...' }
        return '[' + $m + ']...'
    }
    if ($A.Required) { return $m }
    '[' + $m + ']'
}

function Get-HsUsageLine($Node, [string]$Path) {
    if ($Node.Kind -eq 'group') { return $Path + ' [OPTIONS] COMMAND [ARGS]...' }
    $parts = @($Path, '[OPTIONS]')
    foreach ($a in $Node.Args) { $parts += Get-HsArgMetavar $a }
    $parts -join ' '
}

function Get-HsShortHelp($Node) {
    if ($Node.ShortHelp) { return $Node.ShortHelp }
    if ($Node.Help) { return (($Node.Help.Trim() -split "`n")[0]).Trim() }
    ''
}

function Format-HsRows($Rows) {
    $w = 0
    foreach ($r in $Rows) { if ($r[0].Length -gt $w -and $r[0].Length -le 30) { $w = $r[0].Length } }
    foreach ($r in $Rows) {
        if ($r[0].Length -gt 30) { '  ' + $r[0]; if ($r[1]) { '  ' + (' ' * ($w + 2)) + $r[1] } }
        else { '  ' + $r[0].PadRight($w) + '  ' + $r[1] }
    }
}

function Show-HsHelp($Node, [string]$Path) {
    'Usage: ' + (Get-HsUsageLine $Node $Path)
    ''
    $help = $Node.Help
    if (-not $help) { $help = $Node.ShortHelp }
    if ($help) {
        foreach ($l in ($help.Trim() -split "`r?`n")) { if ($l.Trim()) { '  ' + $l.Trim() } else { '' } }
        ''
    }
    'Options:'
    $rows = @()
    foreach ($o in $Node.Opts) {
        $left = $o.Flags -join ', '
        if ($o.Kind -eq 'value') { $left += ' TEXT' }
        $right = $o.Help
        if ($o.Kind -eq 'value' -and $null -ne $o.Default) { $right += '  [default: ' + $o.Default + ']' }
        $rows += , @($left, $right)
    }
    $rows += , @('--help', 'Show this message and exit.')
    Format-HsRows $rows
    if ($Node.Kind -eq 'group') {
        ''
        'Commands:'
        $rows = @()
        foreach ($n in $Node.Order) { $rows += , @($n, (Get-HsShortHelp $Node.Children[$n])) }
        Format-HsRows $rows
    }
}

function Show-HsCmdTree($Group, [int]$Indent = 0) {
    foreach ($n in $Group.Order) {
        $c = $Group.Children[$n]
        $h = $c.Help
        if ($c.Kind -eq 'group') { $h = Get-HsShortHelp $c }
        ('  ' * $Indent) + ' ' + $n.PadRight(18) + ' ' + $h
        if ($c.Kind -eq 'group') { Show-HsCmdTree $c ($Indent + 1) }
    }
}

# Parse one level of argv.  Returns @{ Kw; Positional; Rest; Help }
#   groups stop at the first positional (the subcommand) like click's allow_interspersed_args=False
function ConvertFrom-HsArgv($Node, [string[]]$Argv) {
    $kw = @{}
    $flags = New-HsDict
    foreach ($o in $Node.Opts) {
        foreach ($f in $o.Flags) { $flags[$f] = $o }
        if ($o.Kind -eq 'flag') { $kw[$o.Key] = $false }
        elseif ($o.Kind -eq 'count') { $kw[$o.Key] = 0 }
        else { $kw[$o.Key] = $o.Default }
    }
    $flags['--help'] = @{ Key = '__help'; Kind = 'flag' }
    $kw['__help'] = $false

    $pos = New-Object System.Collections.Generic.List[string]
    $rest = New-Object System.Collections.Generic.List[string]
    $isGroup = $Node.Kind -eq 'group'
    $i = 0
    while ($i -lt $Argv.Count) {
        $t = [string]$Argv[$i]; $i++
        if ($t -eq '--') {
            while ($i -lt $Argv.Count) { $pos.Add([string]$Argv[$i]); $i++ }
            break
        }
        if ($t.StartsWith('--')) {
            $name = $t; $val = $null; $hasVal = $false
            $eq = $t.IndexOf('=')
            if ($eq -gt 0) { $name = $t.Substring(0, $eq); $val = $t.Substring($eq + 1); $hasVal = $true }
            if (-not $flags.ContainsKey($name)) {
                if ($Node.IgnoreUnknown) { $pos.Add($t); continue }
                Stop-HsUsage ("No such option '" + $name + "'.")
            }
            $o = $flags[$name]
            if ($o.Kind -eq 'value') {
                if (-not $hasVal) {
                    if ($i -ge $Argv.Count) { Stop-HsUsage ("Option '" + $name + "' requires an argument.") }
                    $val = [string]$Argv[$i]; $i++
                }
                $kw[$o.Key] = $val
            } else {
                if ($hasVal) { Stop-HsUsage ("Option '" + $name + "' does not take a value.") }
                if ($o.Kind -eq 'count') { $kw[$o.Key]++ } else { $kw[$o.Key] = $true }
            }
            continue
        }
        if ($t.StartsWith('-') -and $t.Length -gt 1) {
            $unknown = ''
            for ($j = 1; $j -lt $t.Length; $j++) {
                $f = '-' + $t[$j]
                if (-not $flags.ContainsKey($f)) {
                    if ($Node.IgnoreUnknown) { $unknown += $t[$j]; continue }
                    Stop-HsUsage ("No such option '" + $f + "'.")
                }
                $o = $flags[$f]
                if ($o.Kind -eq 'value') {
                    $val = $t.Substring($j + 1)
                    if ($val -eq '') {
                        if ($i -ge $Argv.Count) { Stop-HsUsage ("Option '" + $f + "' requires an argument.") }
                        $val = [string]$Argv[$i]; $i++
                    }
                    $kw[$o.Key] = $val
                    break
                }
                if ($o.Kind -eq 'count') { $kw[$o.Key]++ } else { $kw[$o.Key] = $true }
            }
            if ($unknown) { $pos.Add('-' + $unknown) }
            continue
        }
        $pos.Add($t)
        if ($isGroup) {
            while ($i -lt $Argv.Count) { $rest.Add([string]$Argv[$i]); $i++ }
            break
        }
    }
    @{ Kw = $kw; Positional = $pos; Rest = $rest; Help = $kw['__help'] }
}

# Hand positional values to the declared arguments (click _unpack_args) and validate click.Path checks
function Set-HsPositionals($Node, $Kw, $Pos) {
    $specs = @($Node.Args)
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Pos) { $tokens.Add($p) }
    for ($s = 0; $s -lt $specs.Count; $s++) {
        $a = $specs[$s]
        if ($a.Nargs -eq -1) {
            $after = $specs.Count - $s - 1
            $take = [Math]::Max(0, $tokens.Count - $after)
            $vals = @()
            for ($k = 0; $k -lt $take; $k++) { $vals += $tokens[0]; $tokens.RemoveAt(0) }
            $Kw[$a.Key] = $vals
        } else {
            if ($tokens.Count -gt 0) { $Kw[$a.Key] = $tokens[0]; $tokens.RemoveAt(0) }
            else { $Kw[$a.Key] = $a.Default }
        }
    }
    foreach ($a in $specs) {
        $v = $Kw[$a.Key]
        if ($a.Required -and ($null -eq $v -or ($a.Nargs -eq -1 -and @($v).Count -eq 0))) {
            Stop-HsUsage ("Missing argument '" + (Get-HsArgMetavar $a) + "'.")
        }
        if ($a.Check -and $null -ne $v) {
            foreach ($p in @($v)) {
                if (-not (Test-HsExists $p)) {
                    Stop-HsUsage ("Invalid value for '" + $a.Hint + "': Path '" + $p + "' does not exist.")
                }
                if ($a.Check -eq 'dir' -and (Test-HsFile $p)) {
                    Stop-HsUsage ("Invalid value for '" + $a.Hint + "': Directory '" + $p + "' is a file.")
                }
            }
        }
    }
    if ($tokens.Count -gt 0) {
        if ($tokens.Count -eq 1) { Stop-HsUsage ('Got unexpected extra argument (' + $tokens[0] + ')') }
        Stop-HsUsage ('Got unexpected extra arguments (' + ($tokens -join ' ') + ')')
    }
}

#endregion
#region ---------------------------------------------------------------- 4. commands

# --- reusable option / argument sets (param_* in hscli.py)
$script:OptRecursive = New-HsOpt 'recursive' @('-r', '--recursive') 'Apply recursively'
$script:OptNonfiles = New-HsOpt 'nonfiles' @('--nonfiles') 'Apply recursively to non files'
$script:OptForce = New-HsOpt 'force' @('--force') 'Force delete (suppress not found errors)'
$script:OptRaw = New-HsOpt 'raw' @('--raw') 'Print raw output'
$script:OptCompact = New-HsOpt 'compact' @('--compact') 'Print compact output'
$script:PEval = @($script:OptRecursive, $script:OptNonfiles, $script:OptRaw, $script:OptCompact)
$script:PSum = @($script:OptRaw, $script:OptCompact, $script:OptNonfiles)
$script:PRead = @(
    (New-HsOpt 'local' @('-l', '--local') 'Show only settings directly applied to this file'),
    (New-HsOpt 'inherited' @('-h', '--inherited') 'Show only settings inherited by this file from a parent'),
    (New-HsOpt 'object' @('-o', '--object') 'Show only settings inherited by this file from the data object')
)
$script:PObjRead = @(
    (New-HsOpt 'local' @('-l', '--local') 'Show only settings directly applied to this file'),
    (New-HsOpt 'inherited' @('-h', '--inherited') 'Show only settings inherited by this file from a parent'),
    (New-HsOpt 'active' @('-a', '--active') 'Show the active objectives'),
    (New-HsOpt 'effective' @('--effective') 'Show the effective objectives'),
    (New-HsOpt 'share' @('--share') 'Show the objectives from parent share')
)
$script:PValue = @(
    (New-HsOpt 'input_json' @('-j', '--json') 'Use JSON formatted input'),
    (New-HsOpt 'exp_stdin' @('-i', '--exp-stdin') 'Read expression from stdin'),
    (New-HsOpt 'exp' @('-e', '--exp') 'Read expression passed as parameter' 'value'),
    (New-HsOpt 'string' @('-s', '--string') 'Treat expression as raw string value')
)
$script:PUnbound = @(New-HsOpt 'unbound' @('-u', '--unbound') 'Delay binding of any expression, it will be evaluated fresh each time')

$script:ArgPaths = New-HsArg 'pathnames' -1 $false $null 'exists' 'paths'
$script:ArgDirpaths = New-HsArg 'pathnames' -1 $false $null 'dir' 'dirpaths'
$script:ArgSharepaths = New-HsArg 'pathnames' -1 $false $null 'dir' 'sharepaths'
$script:ArgPath = New-HsArg 'path' 1 $true '.' 'exists'
$script:ArgName = New-HsArg 'name'
$script:ArgSiteName = New-HsArg 'name' 1 $true $null $null 'site_name'

# Generic handler for commands that just run one generator with some fixed extra kwargs
$script:SimpleHandler = {
    param($kw, $node)
    if ($node.Stats) {
        # Upstream creates a .stats file in each share, but (because it passes the dict of
        # stats files where a list is expected) the command is still sent to the share path itself.
        Initialize-HsStatsFiles @($kw['pathnames'])
    }
    if ($node.ExtraFn) { $e = & $node.ExtraFn $kw } else { $e = $node.Extra }
    foreach ($k in $e.Keys) { $kw[$k] = $e[$k] }
    Invoke-HsRetcode $node.Gen $kw
}

function New-HsSimpleCmd([string]$Name, [string]$Help, [object[]]$Opts, [object[]]$Arguments, [string]$Gen, [hashtable]$Extra = @{}, [scriptblock]$ExtraFn = $null, [switch]$Stats) {
    $c = New-HsCmd $Name $Help $Opts $Arguments $script:SimpleHandler -DefaultPaths
    $c.Gen = $Gen; $c.Extra = $Extra; $c.ExtraFn = $ExtraFn; $c.Stats = [bool]$Stats
    $c
}

function Build-HsTree {
    $root = New-HsGroup 'hs' 'Hammerspace hammerscript cli' $null @(
        (New-HsOpt 'verbose' @('-v', '--verbose') 'Debug output' 'count'),
        (New-HsOpt 'dry_run' @('-n', '--dry-run') "Don't operate on files"),
        (New-HsOpt 'debug' @('-d', '--debug') 'Show debug output'),
        (New-HsOpt 'output_json' @('-j', '--json') 'Use JSON formatted output'),
        (New-HsOpt 'cmd_tree' @('--cmd-tree') 'Show help for available commands')
    )

    # --- eval / sum
    [void](Add-HsChild $root (New-HsCmd 'eval' 'Evaluate hsscript expressions on a file' `
        (@(New-HsOpt 'interactive' @('--interactive') 'Interactivly read expressions from terminal and apply live') + $script:PEval + $script:PValue) `
        @($script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            if ($kw.interactive) {
                $kw['exp_stdin'] = $true
                while ($true) {
                    $k = @{}; foreach ($key in $kw.Keys) { $k[$key] = $kw[$key] }
                    Write-HsShadResults (Invoke-HsShad 'eval' $k)
                }
            }
            Invoke-HsRetcode 'eval' $kw
        }))
    [void](Add-HsChild $root (New-HsSimpleCmd 'sum' 'Perform fast calculations on a set of files' ($script:PSum + $script:PValue) @($script:ArgPaths) 'sum'))

    # --- metadata groups
    $attribute = Add-HsChild $root (New-HsGroup 'attribute' @'
attribute: Manage Hammerspace embedded attribute metadata

Attributes can be defined on the fly, no schema pre-creation required.
Attributes can also hold a value.  Most values are string type (-s) but may
also be a number or expression (-e)

  ex: hs attribute set color -s -e blue path/to/file
'@ '[sub] inode metadata: schema no, value yes')
    $keyword = Add-HsChild $root (New-HsGroup 'keyword' @'
keyword: Manage Hammerspace embedded keyword metadata

Keyword is a flexable metadata type that is created on the fly.  A keyword can
not store a value.
'@ '[sub] inode metadata: schema no, value no')
    $label = Add-HsChild $root (New-HsGroup 'label' @'
label: Manage Hammerspace embedded label metadata

Before a label can be added, it must be added to the labels scema via the admin
interface using the label-* admin cli commands.  Labels are good for situations
where you want to enforce the same wording/spelling/capitilaization/etc as well
as if you want one label to imply a series of parents.
'@ '[sub] inode metadata: schema hierarchical, value no')
    $tag = Add-HsChild $root (New-HsGroup 'tag' @'
tag: Manage Hammerspace embedded tag metadata

Tags do not follow a schema (they can be created on the fly) and do not have a
value that can be stored with the key.  There is no list of tag names that have
been applied to the files of a share, the only way to generate a list is to
check all files in the share, which can be done via Hammerscript expression.
'@ '[sub] inode metadata: schema no, value yes')
    $rek = Add-HsChild $root (New-HsGroup 'rekognition-tag' @'
rekognition_tag
sub commands are used to view metadata added to an object by AWS's
rekognition service.  Contact support for details on how to configure
rekognition.
'@ '[sub] inode metadata: schema no, value yes')
    $objective = Add-HsChild $root (New-HsGroup 'objective' $null '[sub] control file placement on backend storage')

    $P = @{ eval = $script:PEval; read = $script:PRead; objread = $script:PObjRead; value = $script:PValue; unbound = $script:PUnbound }
    $delOpts = @($script:OptForce, $script:OptRecursive, $script:OptNonfiles)
    # -u/--unbound: upstream declares it on set/add and 'tag list' but click drops it (it sits under the
    # param_defaults wrapper).  Kept where it has an effect, omitted where it would be a no-op or an error.
    $setOpts = @($script:OptRecursive, $script:OptNonfiles) + $script:PValue
    $setOptsU = $setOpts + $script:PUnbound
    $nameArgs = @($script:ArgName, $script:ArgPaths)

    # attribute
    [void](Add-HsChild $attribute (New-HsSimpleCmd 'list' 'list all attributes and values applied' ($P.eval + $P.read) @($script:ArgPaths) 'attribute_list'))
    [void](Add-HsChild $attribute (New-HsSimpleCmd 'get' "Get the attribute's value" ($P.eval + $P.read + $P.unbound) $nameArgs 'attribute_get'))
    # NOTE: upstream wires 'attribute has' to get_attribute; kept identical
    [void](Add-HsChild $attribute (New-HsSimpleCmd 'has' "Is the inode's attribute value non-empty" ($P.eval + $P.read) $nameArgs 'attribute_get'))
    [void](Add-HsChild $attribute (New-HsSimpleCmd 'delete' 'remove attribute values from inode(s)' $delOpts $nameArgs 'attribute_del'))
    [void](Add-HsChild $attribute (New-HsSimpleCmd 'set' 'Add/Set value of attribute on inode(s)' $setOpts $nameArgs 'attribute_set'))
    [void](Add-HsChild $attribute (New-HsSimpleCmd 'add' 'Add/Set value of attribute on inode(s)' $setOpts $nameArgs 'attribute_set'))
    # keyword
    [void](Add-HsChild $keyword (New-HsSimpleCmd 'list' 'list all keywords applied' ($P.eval + $P.read) @($script:ArgPaths) 'keyword_list'))
    [void](Add-HsChild $keyword (New-HsSimpleCmd 'has' 'Is the keyword assigned to the file' ($P.eval + $P.read) $nameArgs 'keyword_has'))
    [void](Add-HsChild $keyword (New-HsSimpleCmd 'delete' 'remove keywords from inode(s)' $delOpts $nameArgs 'keyword_del'))
    [void](Add-HsChild $keyword (New-HsSimpleCmd 'add' 'add a keyword to inode(s)' @($script:OptRecursive, $script:OptNonfiles) $nameArgs 'keyword_add'))
    # label
    [void](Add-HsChild $label (New-HsSimpleCmd 'list' 'list all labels applied' ($P.eval + $P.read) @($script:ArgPaths) 'label_list'))
    [void](Add-HsChild $label (New-HsSimpleCmd 'has' 'Is the label assigned to the file' ($P.eval + $P.read) $nameArgs 'label_has'))
    [void](Add-HsChild $label (New-HsSimpleCmd 'delete' 'remove labels from inode(s)' $delOpts $nameArgs 'label_del'))
    [void](Add-HsChild $label (New-HsSimpleCmd 'add' 'add a label to inode(s)' @($script:OptRecursive, $script:OptNonfiles) $nameArgs 'label_add'))
    # tag
    [void](Add-HsChild $tag (New-HsSimpleCmd 'list' 'list all tags and values applied' ($P.eval + $P.read + $P.unbound) @($script:ArgPaths) 'tag_list'))
    [void](Add-HsChild $tag (New-HsSimpleCmd 'get' "Get the tag's value" ($P.eval + $P.read + $P.unbound) $nameArgs 'tag_get'))
    [void](Add-HsChild $tag (New-HsSimpleCmd 'has' "Is the inode's tag value non-empty" ($P.eval + $P.read) $nameArgs 'tag_has'))
    [void](Add-HsChild $tag (New-HsSimpleCmd 'delete' 'remove tag values from inode(s)' $delOpts $nameArgs 'tag_del'))
    [void](Add-HsChild $tag (New-HsSimpleCmd 'set' 'Add/Set value of tag on inode(s)' $setOptsU $nameArgs 'tag_set'))
    [void](Add-HsChild $tag (New-HsSimpleCmd 'add' 'Add/Set value of tag on inode(s)' $setOptsU $nameArgs 'tag_set'))
    # rekognition-tag
    [void](Add-HsChild $rek (New-HsSimpleCmd 'list' 'list all rekognition tags and values applied' ($P.eval + $P.read) @($script:ArgPaths) 'rekognition_tag_list'))
    [void](Add-HsChild $rek (New-HsSimpleCmd 'get' "Get the rekognition tag's value" ($P.eval + $P.read + $P.unbound) $nameArgs 'rekognition_tag_get'))
    [void](Add-HsChild $rek (New-HsSimpleCmd 'has' "Is the inode's rekognition tag value non-empty" ($P.eval + $P.read) $nameArgs 'rekognition_tag_has'))
    [void](Add-HsChild $rek (New-HsSimpleCmd 'delete' 'remove rekognition tag values from inode(s)' $delOpts $nameArgs 'rekognition_tag_del'))
    [void](Add-HsChild $rek (New-HsSimpleCmd 'set' 'Add/Set value of rekognition tag on inode(s)' $setOptsU $nameArgs 'rekognition_tag_set'))
    [void](Add-HsChild $rek (New-HsSimpleCmd 'add' 'Add/Set value of rekognition tag on inode(s)' $setOptsU $nameArgs 'rekognition_tag_set'))
    # objective
    [void](Add-HsChild $objective (New-HsSimpleCmd 'list' 'list all (objective,expression) pairs assigned' ($P.eval + $P.objread) @($script:ArgPaths) 'objective_list'))
    [void](Add-HsChild $objective (New-HsSimpleCmd 'has' 'Get/list objective assignments' ($P.eval + $P.objread + $P.value) $nameArgs 'objective_has'))
    [void](Add-HsChild $objective (New-HsSimpleCmd 'delete' 'remove (objective,expression) pair from inode(s)' ($delOpts + $P.value) $nameArgs 'objective_del'))
    [void](Add-HsChild $objective (New-HsSimpleCmd 'add' 'Add (objective,expression) pair to inode(s)' $setOpts $nameArgs 'objective_add'))

    # --- rm / cp / rsync
    [void](Add-HsChild $root (New-HsCmd 'rm' 'Fast offloaded rm -rf' @(
            (New-HsOpt 'recursive' @('-r', '-R', '--recursive') 'Required for fast mode, remove directories and their contents recursively'),
            (New-HsOpt 'force' @('-f', '--force') 'Required for fast mode, ignore nonexistent files and arguments'),
            (New-HsOpt 'i_lower' @('-i') 'Disables fast mode, passed through to system rm'),
            (New-HsOpt 'I_upper' @('-I') 'Disables fast mode, passed through to system rm'),
            (New-HsOpt 'interactive' @('--interactive') 'Disables fast mode, passed through to system rm' 'value'),
            (New-HsOpt 'one_file_system' @('--one-file-system') 'Disables fast mode, passed through to system rm'),
            (New-HsOpt 'no_preserve_root' @('--no-preserve-root') 'Disables fast mode, passed through to system rm'),
            (New-HsOpt 'preserve_root' @('--preserve-root') 'Disables fast mode, passed through to system rm'),
            (New-HsOpt 'dir' @('-d', '--dir') 'Disables fast mode, passed through to system rm'),
            (New-HsOpt 'verbose' @('-v', '--verbose') 'Disables fast mode, passed through to system rm')
        ) @((New-HsArg 'pathnames' -1 $true $null 'exists')) -Handler { param($kw) Invoke-HsRm $kw }))

    [void](Add-HsChild $root (New-HsCmd 'cp' 'Fast offloaded recursive copy via clone' @(
            (New-HsOpt 'archive' @('-a', '--archive') "Required for fast mode, CoW 'copy' a file or recursivly copy a directory by clone")
        ) @((New-HsArg 'srcs' -1 $true), (New-HsArg 'dest')) -IgnoreUnknown -Handler { param($kw) Invoke-HsCp $kw }))

    [void](Add-HsChild $root (New-HsCmd 'rsync' 'Fast offloaded recursive directory equalizer (Add and Delete)' @(
            (New-HsOpt 'archive' @('-a', '--archive') 'Required, must specify -a --delete'),
            (New-HsOpt 'delete' @('--delete') 'Required, must specify -a --delete')
        ) @((New-HsArg 'src' 1 $true $null 'exists'), (New-HsArg 'dest')) -IgnoreUnknown -Handler { param($kw) Invoke-HsRsync $kw }))

    [void](Add-HsChild $root (New-HsCmd 'collsum' 'Usage details about one/all collections in whole share (fast)' @(
            (New-HsOpt 'collation' @('--collation') '' 'value')
        ) @((New-HsArg 'collection' 1 $true 'all'), $script:ArgSharepaths) -DefaultPaths -Handler {
            param($kw)
            if ($null -eq $kw.collation) { $kw['exp'] = 'collection_sums("' + $kw.collection + '")' }
            else { $kw['exp'] = 'collection_sums("' + $kw.collection + '")[SUMMATION("' + $kw.collation + '")]' }
            Invoke-HsRetcode 'eval' $kw
        }))

    # --- status
    $status = Add-HsChild $root (New-HsGroup 'status' '[sub] System, component, task status')
    $sp = @($script:ArgSharepaths)
    [void](Add-HsChild $status (New-HsSimpleCmd 'assimilation' 'State of current assimilations' @() $sp 'eval' @{ exp = 'assimilation_details' }))
    [void](Add-HsChild $status (New-HsSimpleCmd 'csi' 'Details about the kubernetes CSI' @() $sp 'eval' @{ exp = 'attributes.csi_details' }))
    [void](Add-HsChild $status (New-HsSimpleCmd 'collections' 'Collections present in the share' @() $sp 'eval' @{ exp = 'collections' }))
    [void](Add-HsChild $status (New-HsCmd 'errors' 'Files in the share with errors' @(
            (New-HsOpt 'dump' @('--dump') 'Dump inode details, only on files in dir+dirpath')
        ) $sp -DefaultPaths -Handler {
            param($kw)
            # NOTE: mirrors upstream exactly (--dump selects the summary table, both run as eval)
            if ($kw.dump) { $kw['exp'] = '(IS_FILE AND ERRORS)?SUMS_TABLE{|KEY=ERRORS,|VALUE={1FILE,SPACE_USED,TOP10_TABLE{{space_used,dpath}}}}' }
            else { $kw['exp'] = 'IS_FILE and errors!=0?dump_inode'; $kw['recursive'] = $true }
            Invoke-HsRetcode 'eval' $kw
        }))
    [void](Add-HsChild $status (New-HsSimpleCmd 'open' 'Files open each dir(s)' @() @($script:ArgDirpaths) 'sum' @{ exp = '(IS_FILE AND IS_OPEN)?{1FILE,SPACE_USED,TOP10_TABLE{{space_used,dpath}}}' }))
    [void](Add-HsChild $status (New-HsSimpleCmd 'replication' 'Replication progress for the share(s)' @() $sp 'eval' @{ exp = 'replication_details' }))
    [void](Add-HsChild $status (New-HsSimpleCmd 'sweeper' 'Progress of sweeper (checks file placement) for each share(s)' @() $sp 'eval' @{ exp = 'sweep_details' }))
    [void](Add-HsChild $status (New-HsSimpleCmd 'volume' 'Health of volumes backing the share(s)' @() $sp 'eval' @{ exp = '{|::#A=storage_volumes.name[row],|::#B=storage_volumes.volume_status[row],|::#C=storage_volumes.oper_status[row]}[rows(storage_volumes)]' }))

    # --- usage
    $usage = Add-HsChild $root (New-HsGroup 'usage' $null '[sub] Resource utilization such as capacity or inode')
    $topFiles = { param($help) New-HsOpt 'top_files' @('--top-files') $help }
    [void](Add-HsChild $usage (New-HsCmd 'alignment' 'Alignment state of files each file(s) of files in dir(s)' @(& $topFiles 'include largest files in each alignment state') @($script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            if ($kw.top_files) { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY=OVERALL_ALIGNMENT,|VALUE={1FILE,SPACE_USED,TOP10_TABLE{{space_used,dpath}}}}' }
            else { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY=OVERALL_ALIGNMENT,|VALUE=1}' }
            Invoke-HsRetcode 'sum' $kw
        }))
    [void](Add-HsChild $usage (New-HsCmd 'virus-scan' 'Virus scan state of files each file(s) of files in dir(s)' @(& $topFiles 'include largest files in each virus scan state') @($script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            if ($kw.top_files) { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY=ATTRIBUTES.VIRUS_SCAN,|VALUE={1FILE,SPACE_USED,TOP10_TABLE{{space_used,dpath}}}}' }
            else { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY=ATTRIBUTES.VIRUS_SCAN,|VALUE=1}' }
            Invoke-HsRetcode 'sum' $kw
        }))
    [void](Add-HsChild $usage (New-HsCmd 'owner' 'Owner state of files each file(s) of files in dir(s)' @(& $topFiles 'include largest files of each owner') @($script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            if ($kw.top_files) { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY=OWNER,|VALUE={1FILE,SPACE_USED,TOP10_TABLE{{space_used,dpath}}}}' }
            else { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY=OWNER,|VALUE=1}' }
            Invoke-HsRetcode 'sum' $kw
        }))
    [void](Add-HsChild $usage (New-HsSimpleCmd 'online' 'Summary of files on NAS volumes in the dir' @() @($script:ArgDirpaths) 'sum' @{ exp = 'IS_ONLINE?{1FILE,SPACE_USED,TOP10_TABLE{{space_used,DPATH}}}' }))
    [void](Add-HsChild $usage (New-HsCmd 'volume' 'Usage for each volume backing each dir(s)' @(
            (& $topFiles 'Show largest files on each volume'),
            (New-HsOpt 'deep' @('--deep') 'Might take a long time, XXX')
        ) @($script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            $kw['exp'] = 'IS_FILE?ROWS(INSTANCES)?SUMS_TABLE{|::KEY=INSTANCES[ROW].VOLUME,|::VALUE=1}[ROWS(INSTANCES)]:SUMS_TABLE{|KEY=#EMPTY,|::VALUE=1}'
            if ($kw.top_files) { $kw['exp'] = 'IS_FILE?ROWS(INSTANCES)?SUMS_TABLE{|::KEY=INSTANCES[ROW].VOLUME,|::VALUE={1FILE,INSTANCES[ROW].SPACE_USED,TOP10_TABLE{{space_used,dpath}}}}[ROWS(INSTANCES)]:SUMS_TABLE{|KEY=#EMPTY,|::VALUE={1FILE, SPACE_USED, TOP10_TABLE{{space_used,dpath}}}}' }
            if ($kw.deep) { $kw['exp'] = 'IS_FILE?ROWS(INSTANCES)?SUMS_TABLE{|::KEY=INSTANCES[ROW].VOLUME,|::VALUE={1FILE,INSTANCES[ROW].SPACE_USED,TOP100_TABLE{{space_used,dpath}}}}[ROWS(INSTANCES)]:SUMS_TABLE{|KEY=#EMPTY,|::VALUE={1FILE, SPACE_USED, TOP100_TABLE{{space_used,dpath}}}}' }
            Invoke-HsRetcode 'sum' $kw
        }))
    [void](Add-HsChild $usage (New-HsCmd 'user' 'Users consuming the most capacity in each dir(s)' @(
            (New-HsOpt 'details' @('--details') 'Include details like largest files per user')
        ) @($script:ArgDirpaths) -DefaultPaths -Handler {
            param($kw)
            if ($kw.details) { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY={OWNER,OWNER_GROUP},|VALUE={1FILE,SPACE_USED,TOP10_TABLE{{space_used,dpath}}}}' }
            else { $kw['exp'] = 'IS_FILE?SUMS_TABLE{|KEY={OWNER,OWNER_GROUP},|VALUE=SPACE_USED}' }
            Invoke-HsRetcode 'sum' $kw
        }))
    [void](Add-HsChild $usage (New-HsSimpleCmd 'objectives' 'Objectives applied and capacity managed by dir(s)' @() @($script:ArgDirpaths) 'sum' @{ exp = 'IS_FILE?SUMS_TABLE{|::KEY=LIST_OBJECTIVES_ACTIVE[ROW],|::VALUE={1FILE,SPACE_USED,TOP10_TABLE{{space_used,dpath}}}}[ROWS(LIST_OBJECTIVES_ACTIVE)]' }))
    [void](Add-HsChild $usage (New-HsSimpleCmd 'mime_tags' 'All tags added by mime discovery on dir(s)' @() @($script:ArgDirpaths) 'sum' @{ exp = 'IS_FILE?SUMS_TABLE{attributes.mime.string,{1FILE,SPACE_USED,TOP10_TABLE{{SPACE_USED,DPATH}}}}' }))
    [void](Add-HsChild $usage (New-HsSimpleCmd 'rekognition_tags' 'All tags added by Rekognition on dir(s)' @() @($script:ArgDirpaths) 'sum' @{ exp = 'IS_FILE?ISTABLE(LIST_REKOGNITION_TAGS)?SUMS_TABLE{|::KEY=LIST_REKOGNITION_TAGS()[ROW].NAME,|::VALUE={1FILE,TOP10_TABLE{{LIST_REKOGNITION_TAGS()[ROW].value,dpath}}}}[ROWS(LIST_REKOGNITION_TAGS())]' }))
    # Also an efficient way to follow an assimilation, this will block until it completes
    [void](Add-HsChild $usage (New-HsSimpleCmd 'dirs' 'Number of subdirectories under specified directory(ies), not including that directory' @() @($script:ArgDirpaths) 'sum' @{ exp = '1'; nonfiles = $true }))

    # --- perf
    $perf = Add-HsChild $root (New-HsGroup 'perf' '[sub] Performance and operation stats')
    $shp = @($script:ArgSharepaths)
    [void](Add-HsChild $perf (New-HsSimpleCmd 'clear' 'Clear op/perf counters on share(s)' @() $shp 'tag_set' @{ exp = 'fs_stats.op_stats'; name = 'old_stats' } -Stats))
    [void](Add-HsChild $perf (New-HsSimpleCmd 'top_calls' 'Show filesystem calls consuming the most time on share(s)' @() $shp 'eval' @{ exp = '{(fs_stats.op_stats-get_tag("old_stats")),TOP100_TABLE{|::KEY={#A[PARENT.ROW].op_count,#A[PARENT.ROW].name,#A[PARENT.ROW].op_count,#A[PARENT.ROW].op_time,#A[PARENT.ROW].op_avg}}[ROWS(#A)]}.#B' } -Stats))
    [void](Add-HsChild $perf (New-HsSimpleCmd 'top_funcs' 'Top time consuming functions on share(s)' @(
            (New-HsOpt 'op' @('--op') 'Restrict to reporting to funcs in a specific op' 'value' 'all')
        ) $shp 'eval' -ExtraFn { param($kw) @{ exp = '{(FS_STATS.OP_STATS-get_tag("old_stats"))[|NAME="' + $kw.op + '"].func_stats,TOP100_TABLE{|::KEY={#A[PARENT.ROW].op_time,#A[PARENT.ROW].name,#A[PARENT.ROW].op_count,#A[PARENT.ROW].op_avg}}[ROWS(#A)]}.#B' } } -Stats))
    [void](Add-HsChild $perf (New-HsSimpleCmd 'top_ops' 'Show filesystem ops consuming the most time by share(s)' @() $shp 'eval' @{ exp = '{(fs_stats.op_stats-get_tag("old_stats")),TOP100_TABLE{|::KEY={#A[PARENT.ROW].op_time,#A[PARENT.ROW].name,#A[PARENT.ROW].op_count,#A[PARENT.ROW].op_time,#A[PARENT.ROW].op_avg}}[ROWS(#A)]}.#B' } -Stats))
    [void](Add-HsChild $perf (New-HsSimpleCmd 'flushes' 'Counter for flush transactions by share(s)' @() $shp 'eval' @{ exp = 'sum({|::#A=(fs_stats.op_stats-get_tag("old_stats"))[ROW].flush_count}[ROWS(fs_stats.op_stats)])' } -Stats))

    # --- dump
    $dump = Add-HsChild $root (New-HsGroup 'dump' '[sub] Dump info about various items')
    [void](Add-HsChild $dump (New-HsCmd 'inode' 'inode metadata' @((New-HsOpt 'full' @('--full') 'Include all available details')) @($script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            $kw['exp'] = 'DUMP_INODE'; $kw['recursive'] = $true; $kw['raw'] = $true
            if ($kw.full) { $kw['exp'] = 'THIS' }
            Invoke-HsRetcode 'eval' $kw
        }))
    [void](Add-HsChild $dump (New-HsSimpleCmd 'iinfo' 'Alternative inode details, always in JSON format' @() @($script:ArgPaths) 'inode_info'))
    [void](Add-HsChild $dump (New-HsCmd 'share' 'Full share(s) metadata' @(
            (New-HsOpt 'filter_volume' @('--filter-volume') 'Only report files that have an instance on this volume, provide volume name' 'value')
        ) $sp -DefaultPaths -Handler {
            param($kw)
            $kw['exp'] = 'DUMP_INODE'; $kw['recursive'] = $true; $kw['raw'] = $true
            if ($null -ne $kw.filter_volume) { $kw['exp'] = 'dump_inode_on(storage_volume("' + $kw.filter_volume + '"))' }
            Invoke-HsRetcode 'eval' $kw
        }))
    [void](Add-HsChild $dump (New-HsSimpleCmd 'misaligned' 'Dump details about misaligned files on the share(s)' @() $sp 'eval' @{ exp = 'IS_FILE and overall_alignment!=alignment("aligned")?dump_inode'; recursive = $true }))
    [void](Add-HsChild $dump (New-HsSimpleCmd 'threat' 'Dump details about files that are a virus threat on the share(s)' @() $sp 'eval' @{ exp = 'IS_FILE and attributes.virus_scan==virus_scan_state("THREAT")?dump_inode'; recursive = $true }))
    [void](Add-HsChild $dump (New-HsCmd 'map_file_to_obj' 'For --native object volumes, dump a mapping between file path and object volume path' @() @((New-HsArg 'bucket_name'), $script:ArgSharepaths) -DefaultPaths -Handler {
            param($kw)
            $kw['exp'] = '{instances[|volume=storage_volume("' + $kw.bucket_name + '")],!ISNA(#A)?{PATH,#A.PATH}}.#B'; $kw['recursive'] = $true
            Invoke-HsRetcode 'eval' $kw
        }))
    [void](Add-HsChild $dump (New-HsCmd 'files_on_volume' 'List all files that have data on the specified volume per share(s)' @() @((New-HsArg 'volume_name'), $script:ArgSharepaths) -DefaultPaths -Handler {
            param($kw)
            $kw['exp'] = '{instances[|volume=storage_volume("' + $kw.volume_name + '")],!ISNA(#A)?{PATH}}.#B'; $kw['recursive'] = $true
            Invoke-HsRetcode 'eval' $kw
        }))
    [void](Add-HsChild $dump (New-HsCmd 'volumes' 'List available volumes in the cluster' @() @($script:ArgPath) -DefaultPaths -Handler {
            param($kw)
            $rows = Get-HsTable $kw.path 'STORAGE_VOLUMES' 'STORAGE_VOLUMES_TABLE'
            $volumes = @()
            foreach ($v in $rows) {
                $names = @($v.PSObject.Properties.Name)
                if ($names -notcontains 'VOLUME_STATUS') {
                    if (-not ([string]$v.NAME).Contains('Data Mover')) {
                        ''
                        'ERROR, VOLUME_STATUS not found in'
                        $v | ConvertTo-Json -Depth 20
                    }
                    continue
                }
                if ($v.VOLUME_STATUS.HAMMERSCRIPT -ne "STORAGE_VOLUME_STATUS('REMOVED')") { $volumes += [string]$v.NAME }
            }
            Write-HsNameList $volumes
            Exit-Hs 0
        }))
    [void](Add-HsChild $dump (New-HsCmd 'volume_groups' 'List available volume_groups' @() @($script:ArgPath) -DefaultPaths -Handler {
            param($kw)
            $vgs = @(Get-HsTable $kw.path 'VOLUME_GROUPS.NAME' 'VOLUME_GROUPS_TABLE' | ForEach-Object { [string]$_.NAME })
            Write-HsNameList $vgs
            Exit-Hs 0
        }))
    [void](Add-HsChild $dump (New-HsCmd 'objectives' 'List available objectives' @() @($script:ArgPath) -DefaultPaths -Handler {
            param($kw)
            # names starting with __z_objective are deleted objectives
            $objs = @(Get-HsTable $kw.path 'SMART_OBJECTIVES.NAME' 'SMART_OBJECTIVES_TABLE' | ForEach-Object { [string]$_.NAME } | Where-Object { -not $_.StartsWith('__z_objective') })
            Write-HsNameList $objs
            Exit-Hs 0
        }))

    # --- keep-on-site (GNS replication sites)
    $kos = Add-HsChild $root (New-HsGroup 'keep-on-site' '[sub] sites in the GNS to keep copies of the data on')
    [void](Add-HsChild $kos (New-HsCmd 'available' 'List sites names participating in this share' @() $sp -DefaultPaths -Handler {
            param($kw)
            Write-HsNameList (Get-HsGnsSiteNames @($kw.pathnames))
            Exit-Hs 0
        }))
    [void](Add-HsChild $kos (New-HsSimpleCmd 'list' 'list GNS sites with keep-on rules' ($P.eval + $P.read) @($script:ArgPaths) 'keep_on_site_list'))
    [void](Add-HsChild $kos (New-HsSimpleCmd 'has' 'Is there already a keep-on rule for the specified GNS site?' ($P.eval + $P.read) @($script:ArgSiteName, $script:ArgPaths) 'keep_on_site_has'))
    [void](Add-HsChild $kos (New-HsCmd 'delete' 'remove a GNS site keep-on rule' $delOpts @($script:ArgSiteName, $script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            if (@(Get-HsGnsSiteNames @($kw.pathnames)) -cnotcontains $kw.name) { Stop-HsUsage ("'" + $kw.name + "' is not a valid site name`n") }
            Invoke-HsRetcode 'keep_on_site_del' $kw
        }))
    [void](Add-HsChild $kos (New-HsCmd 'add' 'add a GNS site keep-on rule' @($script:OptRecursive, $script:OptNonfiles) @($script:ArgSiteName, $script:ArgPaths) -DefaultPaths -Handler {
            param($kw)
            if (@(Get-HsGnsSiteNames @($kw.pathnames)) -cnotcontains $kw.name) { Stop-HsUsage ("'" + $kw.name + "' is not a valid site name`n") }
            Invoke-HsRetcode 'keep_on_site_add' $kw
        }))

    # --- aliases
    $aliasMap = @{
        'attribute'       = @('attributes', 'attr', 'attrs')
        'tag'             = @('tags')
        'label'           = @('labels', 'lab')
        'available'       = @('avail')
        'keyword'         = @('keywords')
        'delete'          = @('del')
        'assimilation'    = @('assim')
        'alignment'       = @('align')
        'collsum'         = @('collsums', 'colsum', 'colsums')
        'objective'       = @('objectives', 'obj', 'objs')
        'rekognition-tag' = @('rekognition-tags')
        'keep-on-site'    = @('keep-on-sites')
    }
    $applyAliases = {
        param($g)
        foreach ($n in $g.Order) {
            if ($aliasMap.ContainsKey($n)) { foreach ($a in $aliasMap[$n]) { $g.Aliases[$a] = $n } }
            if ($g.Children[$n].Kind -eq 'group') { & $applyAliases $g.Children[$n] }
        }
    }
    & $applyAliases $root
    $root
}

function Write-HsNameList([string[]]$Names) {
    if ($script:G.output_json) { ConvertTo-PyJsonList @($Names) }
    else { ($Names -join "`n") }
}

# Run an eval with JSON output on one path and return rows of the named table
function Get-HsTable([string]$Path, [string]$Exp, [string]$TableName) {
    $res = Get-HsCaptured 'eval' @{ exp = $Exp; pathnames = @($Path) }
    if ($script:G.dry_run) { return @() }
    $json = (@($res[$Path]) -join '') | ConvertFrom-Json
    @($json.$TableName)
}

# Participating GNS site names for the share (cached, like upstream)
function Get-HsGnsSiteNames([string[]]$Paths) {
    if ($null -ne $script:GnsSiteCache) { return $script:GnsSiteCache }
    $p = '.'
    if ($Paths -and $Paths.Count -gt 0) { $p = $Paths[0] }
    $rows = Get-HsTable $p 'THIS.PARTICIPANTS' 'PARTICIPANTS_TABLE'
    if ($script:G.dry_run) { $script:GnsSiteCache = @('dry_run_test_site1', 'dry_run_test_site2') }
    else { $script:GnsSiteCache = @($rows | ForEach-Object { [string]$_.SITE_NAME }) }
    $script:GnsSiteCache
}

function Initialize-HsStatsFiles([string[]]$Paths) {
    foreach ($p in $Paths) {
        $statsf = Join-PyPath $p '.stats'
        if ($script:G.dry_run) { Write-HsVerbose ('dry run, not creating .stats file ' + $statsf) }
        elseif (-not (Test-HsExists $statsf)) {
            Write-HsVerbose ('creating .stats file ' + $statsf)
            [System.IO.File]::WriteAllBytes((Resolve-HsFullPath $statsf), (New-Object byte[] 0))
        }
    }
}

# --- system tool fallbacks (rm / cp) -------------------------------------------

# Runs the system tool if one exists on PATH; on Windows without one, emulates the common options.
# Output goes to the pipeline, exit code to $script:ToolExit.
function Invoke-HsSystemTool([string]$Tool, [string[]]$ToolArgs) {
    $exe = Get-Command -Name $Tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) {
        & $exe.Source @ToolArgs
        $script:ToolExit = $LASTEXITCODE
        return
    }
    if (-not $script:IsWin) {
        Write-HsErr ("'" + $Tool + "' not found")
        $script:ToolExit = 127
        return
    }
    if ($Tool -eq 'rm') { $script:ToolExit = Invoke-HsEmulatedRm $ToolArgs }
    else { $script:ToolExit = Invoke-HsEmulatedCp $ToolArgs }
}

function Invoke-HsEmulatedRm([string[]]$ToolArgs) {
    $recursive = $false; $force = $false; $confirm = $false; $dirOk = $false; $verbose = $false
    $paths = @(); $endOpts = $false
    for ($i = 0; $i -lt $ToolArgs.Count; $i++) {
        $a = $ToolArgs[$i]
        if (-not $endOpts -and $a -eq '--') { $endOpts = $true; continue }
        if (-not $endOpts -and $a.StartsWith('--')) {
            switch ($a) {
                '--recursive' { $recursive = $true }
                '--force' { $force = $true }
                '--dir' { $dirOk = $true }
                '--verbose' { $verbose = $true }
                { $_ -like '--interactive*' } { if ($_ -notin '--interactive=never', '--interactive=no', '--interactive=none') { $confirm = $true } }
                { $_ -in '--one-file-system', '--no-preserve-root', '--preserve-root' } { }
                default { Write-HsErr ("rm: unsupported option '" + $a + "'"); return 1 }
            }
            continue
        }
        if (-not $endOpts -and $a.StartsWith('-') -and $a.Length -gt 1) {
            foreach ($c in $a.Substring(1).ToCharArray()) {
                switch -CaseSensitive ($c) {
                    'r' { $recursive = $true } 'R' { $recursive = $true } 'f' { $force = $true }
                    'i' { $confirm = $true } 'I' { $confirm = $true } 'd' { $dirOk = $true } 'v' { $verbose = $true }
                    default { Write-HsErr ("rm: invalid option -- '" + $c + "'"); return 1 }
                }
            }
            continue
        }
        $paths += $a
    }
    $rc = 0
    foreach ($p in $paths) {
        $full = Resolve-HsFullPath $p
        $isDir = [System.IO.Directory]::Exists($full)
        if (-not $isDir -and -not [System.IO.File]::Exists($full)) {
            if (-not $force) { Write-HsErr ("rm: cannot remove '" + $p + "': No such file or directory"); $rc = 1 }
            continue
        }
        if ($isDir -and -not $recursive) {
            $empty = -not ([System.IO.Directory]::EnumerateFileSystemEntries($full).GetEnumerator().MoveNext())
            if (-not ($dirOk -and $empty)) { Write-HsErr ("rm: cannot remove '" + $p + "': Is a directory"); $rc = 1; continue }
        }
        try {
            Remove-Item -LiteralPath $full -Recurse:$recursive -Force:$force -Confirm:$confirm -ErrorAction Stop
            if ($verbose) { "removed '" + $p + "'" }
        } catch { Write-HsErr ("rm: cannot remove '" + $p + "': " + $_.Exception.Message); $rc = 1 }
    }
    $rc
}

function Invoke-HsEmulatedCp([string[]]$ToolArgs) {
    $recursive = $false; $force = $false; $verbose = $false
    $operands = @()
    foreach ($a in $ToolArgs) {
        if ($a -in '-a', '--archive', '-r', '-R', '--recursive') { $recursive = $true; continue }
        if ($a -in '-f', '--force') { $force = $true; continue }
        if ($a -in '-v', '--verbose') { $verbose = $true; continue }
        if ($a.StartsWith('-') -and $a.Length -gt 1 -and -not (Test-HsExists $a)) { Write-HsErr ("cp: unsupported option '" + $a + "'"); return 1 }
        $operands += $a
    }
    if ($operands.Count -lt 2) { Write-HsErr 'cp: missing destination file operand'; return 1 }
    $dest = $operands[-1]; $srcs = $operands[0..($operands.Count - 2)]
    $destFull = Resolve-HsFullPath $dest
    $destIsDir = [System.IO.Directory]::Exists($destFull)
    if ($srcs.Count -gt 1 -and -not $destIsDir) { Write-HsErr ("cp: target '" + $dest + "' is not a directory"); return 1 }
    $rc = 0
    foreach ($s in $srcs) {
        $sFull = Resolve-HsFullPath $s
        if (-not (Test-HsExists $s)) { Write-HsErr ("cp: cannot stat '" + $s + "': No such file or directory"); $rc = 1; continue }
        if ([System.IO.Directory]::Exists($sFull) -and -not $recursive) { Write-HsErr ("cp: -r not specified; omitting directory '" + $s + "'"); $rc = 1; continue }
        $target = $destFull
        if ($destIsDir) { $target = [System.IO.Path]::Combine($destFull, [System.IO.Path]::GetFileName($sFull.TrimEnd('\', '/'))) }
        try {
            Copy-Item -LiteralPath $sFull -Destination $target -Recurse:$recursive -Force:$force -ErrorAction Stop
            if ($verbose) { "'" + $s + "' -> '" + $target + "'" }
        } catch { Write-HsErr ('cp: ' + $_.Exception.Message); $rc = 1 }
    }
    $rc
}

# --- rm --------------------------------------------------------------------------
function Invoke-HsRm($kw) {
    $passthrough = @(
        @('i_lower', '-i'), @('I_upper', '-I'), @('one_file_system', '--one-file-system'),
        @('no_preserve_root', '--no-preserve-root'), @('dir', '--dir'), @('verbose', '--verbose')
    )
    $callOut = @()
    foreach ($pt in $passthrough) { if ($kw[$pt[0]]) { $callOut += $pt[1] } }
    # --interactive is documented to disable fast mode; upstream's check for it never fires, here it does
    if ($null -ne $kw.interactive) { $callOut += ('--interactive=' + [string]$kw.interactive) }

    if ($callOut.Count -gt 0 -or -not ($kw.force -and $kw.recursive)) {
        Write-HsVerbose 'Unsupported options supplied, falling back to system rm'
        # upstream drops -r/-f when falling back (so 'hs rm -r dir' could never work); pass them on
        $rf = @()
        if ($kw.recursive) { $rf += '-r' }
        if ($kw.force) { $rf += '-f' }
        $toolArgs = $rf + $callOut + @($kw.pathnames)
        Write-HsVerbose ('Calling: ' + ((@('rm') + $toolArgs) -join ' '))
        if ($script:G.dry_run) { Exit-Hs 0 }
        Invoke-HsSystemTool 'rm' $toolArgs
        Exit-Hs $script:ToolExit
    }

    $others = @(); $dirs = @()
    foreach ($p in @($kw.pathnames)) {
        if (Test-HsDir $p) { $dirs += $p }
        elseif (Test-HsExists $p) { $others += $p }
        else { Write-HsVerbose ('Path not found, ignoring due to --force: ' + $p) }
    }
    $kw['pathnames'] = $dirs
    Write-HsShadResults (Invoke-HsShad 'rm_rf' $kw)

    # unlink any non-dirs
    foreach ($p in $others) {
        Write-HsVerbose ('unlink( ' + $p + ' )')
        if (-not $script:G.dry_run) { [System.IO.File]::Delete((Resolve-HsFullPath $p)) }
    }
    # rmdir the base directories, the shadow command doesn't clean these up
    foreach ($p in $dirs) {
        Write-HsVerbose ('rmdir( ' + $p + ' )')
        if (-not $script:G.dry_run) { [System.IO.Directory]::Delete((Resolve-HsFullPath $p), $false) }
    }
    Exit-Hs 0
}

# --- cp -a -----------------------------------------------------------------------
function Invoke-HsCpFallback($kw, [string[]]$OutArgs, [string[]]$Srcs, [string]$Dest, [string]$Reason) {
    Write-HsVerbose ($Reason + ', falling back to system cp')
    $toolArgs = @($OutArgs)
    if ($kw.archive) { $toolArgs += '-a' }   # upstream passes --archive; -a also works with BSD/macOS cp
    $toolArgs += @($Srcs)
    $toolArgs += $Dest
    Write-HsVerbose ('Calling: ' + ((@('cp') + $toolArgs) -join ' '))
    $res = 0
    if (-not $script:G.dry_run) {
        Invoke-HsSystemTool 'cp' $toolArgs
        $res = $script:ToolExit
    }
    if ($res -ne 0) {
        Write-HsErr ('Error ' + $res + ' processing passthrough cp of path ' + ($Srcs -join ' ') + ': ' + (Get-HsStrError $res))
        Write-HsErr 'Aborting'
        Exit-Hs $res
    }
    Exit-Hs 0
}

function Invoke-HsCp($kw) {
    # anything in srcs that isn't an existing path (unknown options included) triggers a fallback
    $callOut = @(); $srcs = @()
    foreach ($a in @($kw.srcs)) { if (Test-HsExists $a) { $srcs += $a } else { $callOut += $a } }
    $dest = [string]$kw.dest
    $fast = @()

    if ($callOut.Count -gt 0 -or -not $kw.archive) {
        Invoke-HsCpFallback $kw $callOut $srcs $dest 'Unsupported options or non-existant source supplied'
    }
    # NOTE: Trailing /s have no effect on behavior in either single or multi source mode
    if ((Test-HsExists $dest) -and -not (Test-HsDir $dest)) {
        Invoke-HsCpFallback $kw $callOut $srcs $dest 'Destination exists but is not a directory'
    }

    $single = $srcs.Count -eq 1
    if ($single) {
        $src = $srcs[0]
        if (-not (Test-HsDir $src)) {
            Invoke-HsCpFallback $kw $callOut $srcs $dest ('Single source ' + $src + ' is not a directory, use cp --reflink for faster copy')
        }
        $entries = @([System.IO.Directory]::GetFileSystemEntries((Resolve-HsFullPath $src)) | ForEach-Object { [System.IO.Path]::GetFileName($_) })
        if (-not (Test-HsExists $dest)) {
            # dest doesn't exist and src is a directory: cp makes dest and copies only the contents of src in
            Write-HsVerbose ('mkdir ' + $dest)
            if (-not $script:G.dry_run) { New-HsDir $dest }
            foreach ($e in $entries) { $fast += (Join-PyPath $src $e) }
        } else {
            # dest exists and is a directory, cp copies the whole src as a child of dest
            $fast += $src
        }
    }

    if (-not (Test-HsDir $dest)) {
        Invoke-HsCpFallback $kw $callOut $srcs $dest 'Destination directory does not exist'
    }
    $destStat = Get-HsStat $dest

    # In multi source mode, each source is just copied into dest as a child of dest, always
    if (-not $single) { $fast += $srcs }

    foreach ($s in $fast) {
        if (-not (Test-HsExists $s)) {
            Invoke-HsCpFallback $kw $callOut $srcs $dest ('Source ' + $s + ' does not exist')
        }
        if ((Get-HsStat $s).dev -ne $destStat.dev) {
            Invoke-HsCpFallback $kw $callOut $srcs $dest ('Source ' + $s + ' is on different filesystem from destination')
        }
    }
    foreach ($s in $fast) {
        $entry = Get-PyBasename $s
        if ($entry.Length -eq 0) { $entry = $s }
        $tgt = Join-PyPath $dest $entry
        if (Test-HsExists $tgt) {
            Invoke-HsCpFallback $kw $callOut $srcs $dest ('Source item "' + $s + '" collides with existing item "' + $tgt + '" in destination')
        }
    }

    $kw['dest_inode'] = $destStat.ino
    $kw['pathnames'] = $fast
    Write-HsShadResults (Invoke-HsShad 'cp_a' $kw)

    # Walk the tree, following any assimilation to block returning till assims are complete
    Invoke-HsDirsCount @($dest)
    Exit-Hs 0
}

# --- rsync -a --delete -----------------------------------------------------------
function Copy-HsMetadata([string]$Src, [string]$Dest) {
    if ($Src -eq '') { $Src = '.' }
    Write-HsVerbose ('stat ' + $Src)
    if ($script:G.dry_run) {
        Write-HsVerbose ('chown dry_run.dry_run ' + $Dest)
        Write-HsVerbose ('chmod dry_run ' + $Dest)
        return
    }
    if ($script:IsWin) {
        # No uid/gid/mode on Windows: copy the security descriptor (owner if permitted, always the DACL)
        Write-HsVerbose ('copy acl ' + $Src + ' -> ' + $Dest)
        $acl = Get-Acl -LiteralPath (Resolve-HsFullPath $Src)
        try {
            Set-Acl -LiteralPath (Resolve-HsFullPath $Dest) -AclObject $acl
        } catch {
            $d = Get-Acl -LiteralPath (Resolve-HsFullPath $Dest)
            $d.SetSecurityDescriptorSddlForm($acl.Sddl, [System.Security.AccessControl.AccessControlSections]::Access)
            Set-Acl -LiteralPath (Resolve-HsFullPath $Dest) -AclObject $d
        }
        return
    }
    $st = Get-HsStat $Src
    $destFull = Resolve-HsFullPath $Dest
    Write-HsVerbose ('chown ' + $st.uid + '.' + $st.gid + ' ' + $Dest)
    & chown ([string]$st.uid + ':' + [string]$st.gid) -- $destFull
    if ($LASTEXITCODE -ne 0) { throw "chown failed on '$Dest'" }
    Write-HsVerbose ('chmod ' + [Convert]::ToString($st.mode, 8) + ' ' + $Dest)
    & chmod ([Convert]::ToString(($st.mode -band 4095), 8)) -- $destFull
    if ($LASTEXITCODE -ne 0) { throw "chmod failed on '$Dest'" }
    # XXX (upstream) Add copying of acls / HS metadata like tags, objectives, etc
}

function Invoke-HsRsync($kw) {
    $src = [string]$kw.src
    $dest = [string]$kw.dest
    if (-not $kw.archive -or -not $kw.delete) {
        Stop-HsUsage 'Must provide both --delete and --archive options, this is the only supported method for this tool, which may remove data at the destination path'
    }
    $seps = Get-HsSeps
    $dry = $script:G.dry_run

    # NOTE: Trailing /s are important in rsync mode, which is different from cp-a
    $srcIsFile = Test-HsFile $src
    $srcIsDir = Test-HsDir $src
    $srcEndsSlash = $seps -contains $src[$src.Length - 1]
    $srcUndelete = $false
    $destIsDir = Test-HsDir $dest
    $destEndsSlash = $seps -contains $dest[$dest.Length - 1]
    $destExists = Test-HsExists $dest
    $dest = Get-PyAbspath $dest

    if ($srcIsFile) {
        # Dest needs to be a directory and cannot contain a file with the src files name
        if ((-not $srcEndsSlash) -and (-not $destEndsSlash) -and (-not $srcIsDir) -and (-not $destIsDir) -and (Get-PyBasename $src) -eq (Get-PyBasename $dest)) {
            # Assume should be file on both sides
            $destFname = Get-PyBasename $dest; $destParent = Get-PyDirname $dest
        } elseif ((-not $destEndsSlash) -and (-not $destExists)) {
            # rsync would create a file, not a dir, don't support that; snag a rename for future failure
            $destFname = Get-PyBasename $dest; $destParent = Get-PyDirname $dest
        } elseif ($destEndsSlash -or $destIsDir -or (-not $destExists)) {
            # should be directory or already is directory
            $destFname = Get-PyBasename $src; $destParent = $dest
        } else {
            # assume it is a file that was specified
            $destFname = Get-PyBasename $dest; $destParent = Get-PyDirname $dest
        }
        $srcFname = Get-PyBasename $src
        $srcParent = Get-PyDirname $src

        if ($destFname -cne $srcFname) {
            if ($srcFname.StartsWith($destFname + '[#D', [StringComparison]::Ordinal)) {
                # allow restoring from undelete filename, which does have different name from dest
                $srcUndelete = $true
            } else {
                Stop-HsUsage ("This rsync like tool can not handle renaming a file as part of the copy`n" +
                    "please provide a source filename and a target directory/ (include trailing /)`n" +
                    'src filename: ' + (Get-PyBasename $src) + '     dest filename: ' + $destFname)
            }
        } elseif (-not (Test-HsExists $destParent)) {
            Write-HsVerbose ('mkdir ' + $destParent)
            if (-not $dry) { New-HsDir $destParent }
            Copy-HsMetadata $srcParent $destParent
        } elseif ((-not $dry) -and (-not (Test-HsDir $destParent))) {
            Stop-HsUsage ('Source ' + $src + ' is a file but unable to find the destination/parent directory ' + $destParent)
        }
        $destTgt = $destParent
    } elseif ($srcIsDir) {
        # in the following / patterns, must create srcdir name and use as target
        if (-not $srcEndsSlash) {
            $destParent = Join-PyPath $dest (Get-PyBasename $src)
            $destTgt = $destParent
            if (-not (Test-HsExists $dest)) {
                Write-HsVerbose ('mkdir ' + $dest)
                if (-not $dry) { New-HsDir $dest }
            }
        } else {
            $destParent = $dest
            $destTgt = $dest
        }
        $srcParent = $src
        if ((Get-PyBasename $src).StartsWith((Get-PyBasename $dest) + '[#D', [StringComparison]::Ordinal)) { $srcUndelete = $true }

        if (-not (Test-HsExists $destTgt)) {
            Write-HsVerbose ('mkdir ' + $destTgt)
            if (-not $dry) { New-HsDir $destTgt }
            $destIsDir = $true
        }
        if ((-not $dry) -and (-not $destIsDir)) {
            Stop-HsUsage ('Source ' + $src + ' is a directory but dest ' + $dest + ' is not')
        }
    } else {
        Stop-HsUsage ('Source ' + $src + ' is not a file or directory')
    }

    Write-HsVerbose ('stat src ' + $src)
    $srcStat = Get-HsStat $src
    Write-HsVerbose ('src inode ' + $srcStat.ino)
    Write-HsVerbose ('stat dest_tgt ' + $destTgt)
    if ($dry -and -not (Test-HsExists $destTgt)) {
        # dry run never created it; carry on so the rest of the plan can be shown
        $destTgtStat = @{ dev = $srcStat.dev; ino = 0 }
    } else {
        $destTgtStat = Get-HsStat $destTgt
    }
    Write-HsVerbose ('dest_tgt inode ' + $destTgtStat.ino)

    if ($srcStat.dev -ne $destTgtStat.dev) {
        Stop-HsUsage ('Source (stat_dev ' + $srcStat.dev + ') is on different filesystem from destination (stat_dev ' + $destTgtStat.dev + ')')
    }

    # Detect any requests inside .snapshot/current/ that are not undelete files.
    if ($destExists) {
        $destStat = Get-HsStat $dest
        if ($srcStat.ino -eq $destStat.ino) {
            $versions = Get-HsCaptured 'eval' @{ exp = 'VERSION'; pathnames = @($src, $dest) }
            try {
                $vSrc = [int](@($versions[$src])[0])
                $vDest = [int](@($versions[$dest])[0])
            } catch {
                'Error parsing response from VERSION, response was:'
                foreach ($k in $versions.Keys) { $k + ': ' + (@($versions[$k]) -join "`n") }
                throw
            }
            if ($vSrc -eq 2 -and (-not $srcUndelete)) {
                Write-HsVerbose 'Trying to restore from .snapshot/current source and dest are the same file, doing nothing'
                Exit-Hs 0
            } elseif ($vDest -gt 1) {
                Stop-HsUsage ('Dest ' + $dest + ' has version ' + $vDest + ' is in .snapshot/, can not restore TO a snapshot, only FROM')
            }
        }
    }

    $kw['dest_inode'] = $destTgtStat.ino
    $kw['pathnames'] = @($src)
    Write-HsShadResults (Invoke-HsShad 'cp_a' $kw)

    # Walk the tree, following the assimilation to block returning till assim is complete
    Invoke-HsDirsCount @($destTgt)

    if (-not $srcIsFile) {
        # Manually always copy the metadata for all directory sources
        Copy-HsMetadata $srcParent $destParent
    }
    Exit-Hs 0
}

#endregion
#region ---------------------------------------------------------------- entry points

$script:Tree = Build-HsTree

<#
.SYNOPSIS
    Hammerspace hammerscript CLI (PowerShell port of the hstk 'hs' command).
.DESCRIPTION
    Takes exactly the same arguments as the Python 'hs' command, e.g.
        hs eval -e THIS .
        hs -j sum -e 'IS_FILE?SUMS_TABLE{|KEY=OWNER,|VALUE=1}' \\server\share\dir
        hs tag set -e blue color file.txt
        hs rm -rf .\bigdir
    Run 'hs --help' or 'hs --cmd-tree' for the full command list.
    Output lines go to the pipeline; the exit status is left in $LASTEXITCODE.
#>
function Invoke-Hs {
    $script:PipeInput = @($input)
    $script:PipeIdx = 0
    $script:GnsSiteCache = $null
    $script:G = New-HsGlobals
    $script:Ctx = $null
    $argv = [string[]]@($args | ForEach-Object { [string]$_ })
    $code = 0
    try {
        Invoke-HsMain $argv
    } catch {
        $ex = $_.Exception
        while ($null -ne $ex -and -not $ex.Data.Contains('HsExit')) { $ex = $ex.InnerException }
        if ($null -ne $ex) {
            $code = [int]$ex.Data['HsExit']
        } else {
            Write-HsErr ('Error: ' + $_.Exception.Message)
            if ($script:G.debug) { Write-HsErr $_.ScriptStackTrace }
            $code = 1
        }
    }
    $global:LASTEXITCODE = $code
}

function Invoke-HsMain([string[]]$Argv) {
    $root = $script:Tree
    $script:Ctx = @{ Node = $root; Path = 'hs' }
    $r = ConvertFrom-HsArgv $root $Argv
    if ($r.Help) { Show-HsHelp $root 'hs'; Exit-Hs 0 }
    if ($r.Kw.cmd_tree) { Show-HsCmdTree $root; Exit-Hs 0 }
    if ($r.Positional.Count -eq 0) { Show-HsHelp $root 'hs'; Exit-Hs 0 }

    $script:G = @{ verbose = [int]$r.Kw.verbose; dry_run = [bool]$r.Kw.dry_run; debug = [bool]$r.Kw.debug; output_json = [bool]$r.Kw.output_json }
    if ($script:G.verbose -gt 1) {
        Write-Host ('V: verbose: ' + $script:G.verbose)
        Write-Host ('V: dry_run: ' + (ConvertTo-PyBool $script:G.dry_run))
        Write-Host ('V: debug: ' + (ConvertTo-PyBool $script:G.debug))
        Write-Host ('V: output_json: ' + (ConvertTo-PyBool $script:G.output_json))
    }

    $node = $root; $path = 'hs'
    $name = $r.Positional[0]; $rest = [string[]]@($r.Rest)
    while ($true) {
        $node = Resolve-HsChild $node $name
        $path = $path + ' ' + $node.Name
        $script:Ctx = @{ Node = $node; Path = $path }
        $r = ConvertFrom-HsArgv $node $rest
        if ($r.Help) { Show-HsHelp $node $path; Exit-Hs 0 }
        if ($node.Kind -eq 'command') { break }
        if ($r.Positional.Count -eq 0) {
            # click >= 8.2: a group run without a subcommand prints its help to stderr and exits 2
            foreach ($l in (Show-HsHelp $node $path)) { Write-HsErr $l }
            Exit-Hs 2
        }
        $name = $r.Positional[0]; $rest = [string[]]@($r.Rest)
    }

    $kw = $r.Kw
    [void]$kw.Remove('__help')
    Set-HsPositionals $node $kw $r.Positional
    if ($node.DefaultPaths) {
        if ($kw.ContainsKey('path')) { $kw['pathnames'] = @($kw.path) }
        if ($null -eq $kw['pathnames'] -or @($kw['pathnames']).Count -eq 0) {
            Write-HsVerbose 'Setting default pathname to .'
            $kw['pathnames'] = @('.')
        }
    }
    & $node.Handler $kw $node
    Exit-Hs 0
}

<#
.SYNOPSIS
    Run a hammerscript eval expression and return the (JSON) result per path (hstk hs_eval).
#>
function Invoke-HsEval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Expression,
        [Parameter(ValueFromPipeline)][string[]]$Path = @('.'),
        [switch]$Recursive, [switch]$NonFiles, [switch]$Raw, [switch]$Compact
    )
    begin { $all = @() }
    process { $all += $Path }
    end { Invoke-HsLibrary 'eval' $Expression $all @{ recursive = [bool]$Recursive; nonfiles = [bool]$NonFiles; raw = [bool]$Raw; compact = [bool]$Compact } }
}

<#
.SYNOPSIS
    Run a hammerscript sum expression and return the (JSON) result per path (hstk hs_sum).
#>
function Invoke-HsSum {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Expression,
        [Parameter(ValueFromPipeline)][string[]]$Path = @('.'),
        [switch]$NonFiles, [switch]$Raw, [switch]$Compact
    )
    begin { $all = @() }
    process { $all += $Path }
    end { Invoke-HsLibrary 'sum' $Expression $all @{ nonfiles = [bool]$NonFiles; raw = [bool]$Raw; compact = [bool]$Compact } }
}

function Invoke-HsLibrary([string]$Gen, [string]$Expression, [string[]]$Paths, [hashtable]$Extra) {
    $script:G = New-HsGlobals
    $script:Ctx = $null
    $kw = @{ exp = $Expression; pathnames = $Paths }
    foreach ($k in $Extra.Keys) { $kw[$k] = $Extra[$k] }
    try {
        $res = Get-HsCaptured $Gen $kw
    } catch {
        $ex = $_.Exception
        while ($null -ne $ex -and -not $ex.Data.Contains('HsExit')) { $ex = $ex.InnerException }
        if ($null -ne $ex) { throw "hs $Gen failed (exit $($ex.Data['HsExit']))" }
        throw
    }
    foreach ($p in $Paths) {
        $lines = @($res[$p])
        [pscustomobject]@{ Path = $p; Lines = $lines; Text = ($lines -join "`n") }
    }
}

Set-Alias -Name hs -Value Invoke-Hs
Export-ModuleMember -Function Invoke-Hs, Invoke-HsEval, Invoke-HsSum -Alias hs

#endregion
