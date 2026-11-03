<#
.SYNOPSIS
    Démonstration complète d'IdentityFlow, sans Active Directory : un annuaire fictif
    en mémoire, l'export RH d'exemple, une simulation puis l'application réelle.

    pwsh ./examples/demo.ps1
#>
param([string] $Workspace = (Join-Path ([System.IO.Path]::GetTempPath()) 'identityflow-demo'))

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\src\IdentityFlow\IdentityFlow.psd1') -Force

Remove-Item $Workspace -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Workspace | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'annuaire-demo.json') (Join-Path $Workspace 'annuaire.json')
Push-Location $Workspace
try {
    $asOf = [datetime]'2026-11-03'   # date fixe : la démo donne toujours le même résultat
    $run = @{
        RequestPath = Join-Path $PSScriptRoot 'export-rh.csv'
        RulesPath   = Join-Path $PSScriptRoot 'regles.psd1'
        Provider    = New-IFMemoryProvider -Path (Join-Path $Workspace 'annuaire.json')
        AsOf        = $asOf
    }

    Write-Host "`n1) Simulation (-WhatIf) : rien n'est modifié`n" -ForegroundColor Cyan
    $sim = Start-IFRun @run -WhatIf 6>$null
    $sim | Select-Object Line, ActionLabel, Name, Login, State, @{ n = 'Étapes'; e = { $_.Steps.Count } } |
        Format-Table -AutoSize | Out-String -Width 160 | Write-Host

    Write-Host "2) Application`n" -ForegroundColor Cyan
    $res = Start-IFRun @run
    $res | Select-Object Line, ActionLabel, Name, Login, State, @{ n = 'Erreur'; e = { $_.Errors -join ' ; ' } } |
        Format-Table -AutoSize | Out-String -Width 200 | Write-Host

    Write-Host "3) Relance du même fichier : rien à refaire`n" -ForegroundColor Cyan
    $again = Start-IFRun @run
    $again | Group-Object State | Select-Object Name, Count | Format-Table -AutoSize | Out-String -Width 80 | Write-Host

    Write-Host "4) Annulation du départ de Thomas PETIT`n" -ForegroundColor Cyan
    $undo = Undo-IFLeaver -EmployeeId E1045 -AuditPath (Join-Path $Workspace 'audit') -Provider $run.Provider -Confirm:$false
    $undo.Steps | Select-Object Text, Outcome | Format-Table -AutoSize | Out-String -Width 160 | Write-Host

    Write-Host "5) Purge des comptes partis depuis plus de 90 jours (simulation)`n" -ForegroundColor Cyan
    Invoke-IFPurge -Rules (Import-IFRules $run.RulesPath) -Provider $run.Provider -AsOf $asOf -WhatIf 6>$null |
        Format-Table Login, Name, LeftOn, Outcome, Reason -AutoSize | Out-String -Width 160 | Write-Host

    $report = Get-ChildItem (Join-Path $Workspace 'rapports') -Filter "*-$($res[0].RunId).html"
    Write-Host "Compte rendu de l'application : $($report.FullName)"
    Write-Host "Journal d'audit : $(Join-Path $Workspace 'audit')"
}
finally {
    Pop-Location
}
