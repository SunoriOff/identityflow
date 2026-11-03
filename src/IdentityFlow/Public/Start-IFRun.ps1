function Start-IFRun {
    <#
    .SYNOPSIS
        Exécution complète en une commande : lecture de l'export RH, plan, application,
        journal d'audit et compte rendu HTML. Conçu pour une tâche planifiée quotidienne.

    .PARAMETER CredentialExportPath
        Sauvegarde les identifiants temporaires des nouveaux comptes avec Export-Clixml,
        chiffrés par DPAPI pour l'utilisateur et la machine courants. Windows uniquement :
        ailleurs, Export-Clixml ne chiffre pas, l'option est donc refusée.

    .EXAMPLE
        # Simulation : rien n'est modifié, le rapport montre ce qui serait fait.
        Start-IFRun -RequestPath .\export-rh.csv -RulesPath .\regles.psd1 -Provider $ad -WhatIf

    .EXAMPLE
        # Tâche planifiée
        $ad = New-IFADProvider -Server dc01.exemple.local -ExchangeAttributes
        Start-IFRun -RequestPath \\rh\exports\mouvements.csv -RulesPath D:\IdentityFlow\regles.psd1 `
            -Provider $ad -AuditFolder D:\IdentityFlow\audit -ReportFolder D:\IdentityFlow\rapports `
            -CredentialExportPath D:\IdentityFlow\remise\comptes.xml
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $RequestPath,
        [Parameter(Mandatory)][string] $RulesPath,
        [Parameter(Mandatory)] $Provider,
        [string] $AuditFolder = 'audit',
        [string] $ReportFolder = 'rapports',
        [string] $CredentialExportPath,
        [datetime] $AsOf = (Get-Date),
        [string] $Delimiter = ';'
    )

    if ($CredentialExportPath -and -not ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows)) {
        throw 'CredentialExportPath n''est disponible que sous Windows (chiffrement DPAPI).'
    }
    $rules = Import-IFRules -Path $RulesPath
    $requests = @(Import-IFRequest -Path $RequestPath -Delimiter $Delimiter)
    Write-Verbose ("{0} ligne(s) lue(s) dans {1}" -f $requests.Count, $RequestPath)

    $plan = @($requests | Get-IFPlan -Rules $rules -Provider $Provider -AsOf $AsOf)
    $stamp = $AsOf.ToString('yyyy-MM-dd')
    $audit = [System.IO.Path]::Combine($AuditFolder, ('audit-{0:yyyy-MM}.jsonl' -f $AsOf))
    $results = @($plan | Invoke-IFPlan -Provider $Provider -AuditPath $audit -PasswordLength $rules.Organisation.PasswordLength)

    $suffix = if ($WhatIfPreference) { '-simulation' } else { '' }
    $runId = if ($results.Count) { $results[0].RunId } else { 'vide' }
    $reportPath = [System.IO.Path]::Combine($ReportFolder, ('identityflow-{0}-{1:HHmmss}-{2}{3}.html' -f $stamp, (Get-Date), $runId, $suffix))
    $report = $results | New-IFReport -Path $reportPath -ProviderName $Provider.Name
    Write-Verbose "Rapport : $($report.FullName)"

    $creds = @($results | Where-Object { $_.TemporaryPassword } | ForEach-Object {
            New-Object System.Management.Automation.PSCredential ($_.Login, $_.TemporaryPassword)
        })
    if ($CredentialExportPath -and $creds.Count -and -not $WhatIfPreference) {
        $creds | Export-Clixml -LiteralPath $CredentialExportPath
        Write-Verbose "$($creds.Count) identifiant(s) temporaire(s) exporté(s) (DPAPI) vers $CredentialExportPath"
    }
    $results
}
