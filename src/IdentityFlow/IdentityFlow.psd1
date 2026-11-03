@{
    RootModule        = 'IdentityFlow.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7c0f3a52-4d7e-4b8f-9a61-2f5d8e1c9b30'
    Author            = 'Joris Pelaud'
    Copyright         = '(c) 2026 Joris Pelaud. Licence MIT.'
    Description       = 'Arrivées, mobilités et départs des collaborateurs à partir de l''export RH : comptes Active Directory ou Entra ID, groupes, licences, plan vérifiable avant application, journal d''audit et annulation.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @(
        'Import-IFRequest'
        'Import-IFRules'
        'Get-IFPlan'
        'Invoke-IFPlan'
        'Start-IFRun'
        'Undo-IFLeaver'
        'Invoke-IFPurge'
        'New-IFReport'
        'New-IFMemoryProvider'
        'New-IFADProvider'
        'New-IFGraphProvider'
        'ConvertTo-IFLogin'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags         = @('ActiveDirectory', 'EntraID', 'Onboarding', 'Offboarding', 'JML', 'IAM', 'RH')
            LicenseUri   = 'https://github.com/SunoriOff/identityflow/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/SunoriOff/identityflow'
        }
    }
}
