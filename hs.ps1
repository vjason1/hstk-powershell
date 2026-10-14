#!/usr/bin/env pwsh
# ==============================================================================
#  hs.ps1 — Stand-alone launcher for the Hammerspace hs command (HSTK)
# ==============================================================================
#
#  Author:       Jason Ventresco
#  Version:      1.1.0
#  Last Updated: 2026-10-13
#
#  Loads the HSTK module and runs `hs` with the given arguments, returning the
#  same exit codes as the Python tool.
#    pwsh -File hs.ps1 eval -e THIS .
#    powershell.exe -ExecutionPolicy Bypass -File hs.ps1 -j sum -e "IS_FILE?SUMS_TABLE{|KEY=OWNER,|VALUE=1}" \\server\share
#  On macOS/Linux it can also be made executable (chmod +x) and symlinked as `hs`.
#
#  CHANGELOG:
#    1.1.0  (2026-10-13)  Header block.
#    1.0.2  (2026-10-13)  Finds HSTK.psd1 when run without the .ps1 extension
#                         (empty $PSScriptRoot) or through a symlink; falls back
#                         to an installed HSTK module.
#    1.0.0  (2026-10-13)  Initial release.
#
# ==============================================================================

# Find the folder holding HSTK.psd1.  $PSScriptRoot is empty when pwsh runs an extension-less
# script via its #! line, and points at the link's folder when run through a symlink, so also
# look at the script path on the process command line and follow symlinks.
function Find-HstkModule {
    $candidates = @()
    if ($PSCommandPath) { $candidates += $PSCommandPath }
    $cl = [Environment]::GetCommandLineArgs()
    if ($cl.Count -gt 1) { $candidates += $cl[1] }
    foreach ($c in $candidates) {
        $p = $c
        for ($i = 0; $i -lt 40 -and $p; $i++) {
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $p = $null; break }
            $full = (Resolve-Path -LiteralPath $p).ProviderPath
            $psd = Join-Path (Split-Path -Parent $full) 'HSTK.psd1'
            if (Test-Path -LiteralPath $psd) { return $psd }
            $item = Get-Item -LiteralPath $full -Force
            if (-not $item.LinkType) { break }
            $target = @($item.Target)[0]
            if (-not $target) { break }
            if (-not [System.IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $full) $target }
            $p = $target
        }
    }
    $null
}

$hstkPsd = Find-HstkModule
if ($hstkPsd) {
    Import-Module $hstkPsd -Force
} elseif (Get-Module -ListAvailable -Name HSTK) {
    Import-Module HSTK -Force      # installed in a PSModulePath folder
} else {
    [Console]::Error.WriteLine('hs: cannot find HSTK.psd1 next to this script, and the HSTK module is not installed.')
    exit 1
}
Invoke-Hs @args
exit $LASTEXITCODE
