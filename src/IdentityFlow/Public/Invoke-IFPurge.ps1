function Invoke-IFPurge {
    <#
    .SYNOPSIS
        Supprime les comptes partis depuis plus de RetentionDays jours (90 par défaut).

    .DESCRIPTION
        Ne considère que les comptes de l'OU des départs qui sont désactivés ET portent
        la mention « Départ le AAAA-MM-JJ (IdentityFlow) » : un compte déplacé à la main
        ou réactivé entre-temps n'est jamais supprimé. Confirmation demandée par défaut
        (ConfirmImpact High) ; utilisez -WhatIf pour voir la liste.

    .EXAMPLE
        Invoke-IFPurge -Rules $rules -Provider $ad -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable] $Rules,
        [Parameter(Mandatory)] $Provider,
        [datetime] $AsOf = (Get-Date),
        [string] $AuditPath
    )
    $days = [int]$Rules.Organisation.RetentionDays
    $ou = $Rules.Organisation.LeaversOU
    $operator = Get-IFOperator
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    foreach ($u in @($Provider.GetUsersInOU($ou))) {
        $left = $null
        if ($u.Description -match 'Départ le (\d{4}-\d{2}-\d{2}) \(IdentityFlow\)') {
            $left = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        $out = [pscustomobject]@{ Login = $u.Login; Name = $u.DisplayName; EmployeeId = $u.EmployeeId; LeftOn = $left; Outcome = $null; Reason = $null }
        if ($u.Enabled) { $out.Outcome = 'Kept'; $out.Reason = 'compte actif'; $out; continue }
        if (-not $left) { $out.Outcome = 'Kept'; $out.Reason = 'pas de mention de départ IdentityFlow'; $out; continue }
        $age = ($AsOf.Date - $left.Date).Days
        if ($age -lt $days) { $out.Outcome = 'Kept'; $out.Reason = "parti depuis $age jour(s) sur $days"; $out; continue }

        if ($PSCmdlet.ShouldProcess(('{0} [{1}]' -f $u.DisplayName, $u.Login), "Supprimer définitivement (parti depuis $age jours)")) {
            try {
                $Provider.RemoveUser($u.Login)
                $out.Outcome = 'Removed'
            }
            catch { $out.Outcome = 'Failed'; $out.Reason = $_.Exception.Message }
        }
        else { $out.Outcome = 'WhatIf' }
        Write-IFAudit -Path $AuditPath -Record ([ordered]@{
                ts = (Get-Date).ToString('o'); run = $runId; operator = $operator; provider = $Provider.Name
                action = 'Purge'; employeeId = $u.EmployeeId; login = $u.Login; op = 'Remove'
                text = "Suppression après $age jours"; outcome = $out.Outcome; error = $out.Reason
            })
        $out
    }
    if (-not $WhatIfPreference) { $Provider.Save() }
}
