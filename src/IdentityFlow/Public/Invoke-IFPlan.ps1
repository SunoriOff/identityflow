function Invoke-IFPlan {
    <#
    .SYNOPSIS
        Applique un plan calculé par Get-IFPlan, étape par étape, avec journal d'audit.

    .DESCRIPTION
        - -WhatIf affiche chaque étape sans rien modifier (et le note dans le journal) ;
        - une étape en erreur arrête les étapes suivantes de CETTE personne seulement :
          le reste du lot continue ;
        - chaque étape est écrite dans le journal JSONL (qui, quand, quoi, ancienne et
          nouvelle valeur, résultat) : c'est ce qui permet Undo-IFLeaver ;
        - les mots de passe temporaires ne sont jamais journalisés : ils sont renvoyés
          en SecureString dans la propriété TemporaryPassword du résultat.

    .EXAMPLE
        $result = $plan | Invoke-IFPlan -Provider $ad -AuditPath .\audit\2026-11.jsonl -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Plan,
        [Parameter(Mandatory)] $Provider,
        [string] $AuditPath,
        [ValidateRange(12, 128)][int] $PasswordLength = 16
    )
    begin {
        $runId = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $operator = Get-IFOperator
        if ($AuditPath) { $AuditPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($AuditPath) }
        $whatIf = [bool]$WhatIfPreference
    }
    process {
        foreach ($item in @($Plan)) {
            $result = [pscustomobject]@{
                PSTypeName        = 'IdentityFlow.Result'
                RunId             = $runId
                Line              = $item.Line
                Action            = $item.Action
                ActionLabel       = $item.ActionLabel
                EmployeeId        = $item.EmployeeId
                Name              = $item.Name
                Login             = $item.Login
                State             = $item.State
                Steps             = $item.Steps
                Checklist         = $item.Checklist
                Messages          = $item.Messages
                Errors            = New-Object System.Collections.Generic.List[string]
                TemporaryPassword = $null
            }
            foreach ($e in $item.Errors) { $result.Errors.Add($e) }

            if ($item.State -ne 'Pending') {
                $result
                continue
            }

            $failed = $false
            $done = 0
            foreach ($step in $item.Steps) {
                if ($failed) { $step.Outcome = 'Skipped'; continue }
                $record = [ordered]@{
                    ts = (Get-Date).ToString('o'); run = $runId; operator = $operator; provider = $Provider.Name
                    line = $item.Line; action = $item.Action; employeeId = $item.EmployeeId; login = $item.Login
                    op = $step.Op; text = $step.Text; params = $step.Params; outcome = $null; error = $null
                }
                if ($PSCmdlet.ShouldProcess(('{0} [{1}]' -f $item.Name, $item.Login), $step.Text)) {
                    try {
                        $pw = Invoke-IFStep -Step $step -Provider $Provider -PasswordLength $PasswordLength
                        if ($pw) { $result.TemporaryPassword = $pw }
                        $step.Outcome = 'Done'
                        $done++
                    }
                    catch {
                        $failed = $true
                        $step.Outcome = 'Failed'
                        $step.Error = $_.Exception.Message
                        $result.Errors.Add(('{0} : {1}' -f $step.Text, $_.Exception.Message))
                    }
                }
                else {
                    $step.Outcome = 'WhatIf'
                }
                $record.outcome = $step.Outcome
                $record.error = $step.Error
                Write-IFAudit -Path $AuditPath -Record $record
            }
            $result.State = if ($failed) { 'Failed' } elseif ($whatIf -or $done -eq 0) { 'WhatIf' } else { 'Done' }
            $result
        }
    }
    end {
        if (-not $whatIf) { $Provider.Save() }
    }
}
