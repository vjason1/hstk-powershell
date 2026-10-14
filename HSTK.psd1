# ==============================================================================
#  HSTK.psd1 — Module manifest for the Hammerspace Toolkit (hs) for PowerShell
# ==============================================================================
#
#  Author:       Jason Ventresco
#  Version:      1.1.0
#  Last Updated: 2026-10-13
#
#  CHANGELOG:
#    1.1.0  (2026-10-13)  Header block; ModuleVersion now tracks this port's own
#                         version (1.1.0) instead of upstream hstk (4.6.6.1).
#                         Release notes added.
#    1.0.0  (2026-10-13)  Initial release.
#
#  Full history: CHANGELOG.md
# ==============================================================================
@{
    RootModule           = 'HSTK.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = '6f0f6f4e-2b1a-4c55-9b0e-4d1a7f3c9e21'
    Author               = 'Jason Ventresco'
    CompanyName          = 'Unknown'
    Copyright            = 'Port: Jason Ventresco. Original hstk: Copyright 2021 Hammerspace. Apache License 2.0.'
    Description          = 'Hammerspace CLI tool (hs) and toolkit for PowerShell. Port of hammer-space/hstk 4.6.6.1.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Invoke-Hs', 'Invoke-HsEval', 'Invoke-HsSum')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('hs')
    PrivateData          = @{
        PSData = @{
            Tags         = @('hammerspace', 'hammerscript', 'metadata', 'nfs', 'smb', 'storage')
            LicenseUri   = 'http://www.apache.org/licenses/LICENSE-2.0'
            ProjectUri   = 'https://github.com/hammer-space/hstk'
            ReleaseNotes = '1.1.0: on macOS SMB mounts, a gateway I/O error now explains the SMB limitation and prints the NFS mount command. See CHANGELOG.md.'
        }
    }
}
