@{
    RootModule           = 'HSTK.psm1'
    ModuleVersion        = '4.6.6.1'
    GUID                 = '6f0f6f4e-2b1a-4c55-9b0e-4d1a7f3c9e21'
    Author               = 'PowerShell port of Hammerspace hstk'
    CompanyName          = 'Hammerspace Inc (original Python implementation)'
    Copyright            = 'Copyright 2021 Hammerspace. Apache License 2.0.'
    Description          = 'Hammerspace CLI tool (hs) and toolkit - PowerShell port of https://github.com/hammer-space/hstk'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Invoke-Hs', 'Invoke-HsEval', 'Invoke-HsSum')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('hs')
    PrivateData          = @{
        PSData = @{
            Tags       = @('hammerspace', 'hammerscript', 'metadata', 'nfs', 'smb', 'storage')
            LicenseUri = 'http://www.apache.org/licenses/LICENSE-2.0'
            ProjectUri = 'https://github.com/hammer-space/hstk'
        }
    }
}
