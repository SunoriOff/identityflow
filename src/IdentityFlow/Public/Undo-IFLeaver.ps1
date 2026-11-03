function Undo-IFLeaver {
    <#
    .SYNOPSIS
        Annule un départ appliqué par erreur (ou reporté), à partir du journal d'audit.

    .DESCRIPTION
        Retrouve, dans le journal, le dernier départ réussi pour ce matricule et rejoue
        les étapes à l'envers : retour dans l'OU d'origine, groupes rendus, description
        et visibilité restaurées, compte réactivé avec un nouveau mot de passe temporaire
        (renvoyé en SecureString, à changer à la première connexion).

    .EXAMPLE
        $r = Undo-IFLeaver -EmployeeId E1042 -AuditPath .\audit -Provider $ad
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $EmployeeId,
        [Parameter(Mandatory)][string] $AuditPath,
        [Parameter(Mandatory)] $Provider,
        [string] $NewAuditPath,
        [ValidateRange(12, 128)][int] $PasswordLength = 16
    )
    $id = $EmployeeId.ToUpperInvariant()
    $entries = @(Read-IFAudit -Path $AuditPath | Where-Object { $_.employeeId -eq $id -and $_.action -eq 'Depart' -and $_.outcome -eq 'Done' })
    if ($entries.Count -eq 0) { throw "Aucun départ appliqué trouvé dans le journal pour le matricule $id." }
    $lastRun = $entries[-1].run
    $steps = @($entries | Where-Object run -EQ $lastRun)
    $login = $steps[0].login

    $current = $Provider.GetUser($login)
    if (-not $current) { throw "Le compte $login n'existe plus (déjà purgé ?) : annulation impossible." }

    $item = [pscustomobject]@{
        Line = 0; Action = 'Annulation'; ActionLabel = 'Annulation de départ'; EmployeeId = $id
        Name = $current.DisplayName; Login = $login; State = 'Pending'
        Steps = New-Object System.Collections.Generic.List[object]
        Checklist = New-Object System.Collections.Generic.List[string]
        Messages = New-Object System.Collections.Generic.List[string]
        Errors = New-Object System.Collections.Generic.List[string]
    }
    $item.Messages.Add("Annulation du départ journalisé le $(([datetime]$steps[0].ts).ToString('dd/MM/yyyy HH:mm')) (exécution $lastRun).")

    [array]::Reverse($steps)
    foreach ($s in $steps) {
        $pp = $s.params
        switch ($s.op) {
            'Move' { Add-IFStep -Item $item -Op 'Move' -Text "Remettre dans $($pp.From)" -Params @{ Login = $login; From = $pp.To; To = $pp.From } }
            'RemoveGroup' { Add-IFStep -Item $item -Op 'AddGroup' -Text "Rendre le groupe $($pp.Group)" -Params @{ Login = $login; Group = $pp.Group } }
            'SetAttribute' {
                Add-IFStep -Item $item -Op 'SetAttribute' -Text ('{0} : {1}' -f $script:AttributeLabels[$pp.Name], (Format-IFValue $pp.Old)) -Params @{ Login = $login; Name = $pp.Name; Old = $pp.New; New = $pp.Old }
            }
        }
    }
    Add-IFStep -Item $item -Op 'ResetPassword' -Text 'Nouveau mot de passe temporaire (à changer à la connexion)' -Params @{ Login = $login; MustChange = $true }
    Add-IFStep -Item $item -Op 'Enable' -Text 'Réactiver le compte' -Params @{ Login = $login }

    $go = $PSCmdlet.ShouldProcess(('{0} [{1}]' -f $current.DisplayName, $login), "Annuler le départ ($($item.Steps.Count) étapes)")
    if (-not $go -and -not $WhatIfPreference) { return }

    $target = if ($NewAuditPath) { $NewAuditPath } elseif (Test-Path -LiteralPath $AuditPath -PathType Container) {
        [System.IO.Path]::Combine((Resolve-Path -LiteralPath $AuditPath).ProviderPath, ('audit-{0:yyyy-MM}.jsonl' -f (Get-Date)))
    } else { $AuditPath }
    $item | Invoke-IFPlan -Provider $Provider -AuditPath $target -PasswordLength $PasswordLength
}
