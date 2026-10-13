#!/usr/bin/env pwsh
#
# Stand-alone entry point for the PowerShell port of the Hammerspace 'hs' tool.
#   pwsh -File hs.ps1 eval -e THIS .
#   powershell.exe -ExecutionPolicy Bypass -File hs.ps1 -j sum -e "IS_FILE?SUMS_TABLE{|KEY=OWNER,|VALUE=1}" \\server\share
# Returns the same exit codes as the Python tool.
#
Import-Module (Join-Path $PSScriptRoot 'HSTK.psd1') -Force
Invoke-Hs @args
exit $LASTEXITCODE
