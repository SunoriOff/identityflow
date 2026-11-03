function Resolve-IFOU {
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $OU, [string] $UsersOU)
    if ([string]::IsNullOrWhiteSpace($OU)) { return $UsersOU }
    if ($OU -match '(^|,)DC=') { return $OU }
    return '{0},{1}' -f $OU.TrimEnd(','), $UsersOU
}

function Get-IFRoleProfile {
    <#
    .SYNOPSIS
        Ce que le poste implique : OU, groupes (communs + service + poste + contrat) et licence.
        Renvoie aussi les erreurs (service inconnu, date de fin manquante…).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Request, [Parameter(Mandatory)][hashtable] $Rules)

    $errors = New-Object System.Collections.Generic.List[string]
    $groups = New-Object System.Collections.Generic.List[string]
    foreach ($g in $Rules.CommonGroups) { $groups.Add($g) }

    $service = Find-IFRuleEntry -Table $Rules.Services -Name $Request.Department
    $license = $null
    $ou = $null
    if (-not $service) {
        $errors.Add("service inconnu dans les règles : « $($Request.Department) »")
    }
    else {
        $ou = Resolve-IFOU -OU $service.Value.OU -UsersOU $Rules.Organisation.UsersOU
        if ($service.Value.ContainsKey('Groups')) { foreach ($g in $service.Value.Groups) { $groups.Add($g) } }
        if ($service.Value.ContainsKey('License')) { $license = $service.Value.License }
    }

    $poste = Find-IFRuleEntry -Table $Rules.Postes -Name $Request.Title
    if ($poste -and $poste.Value.ContainsKey('Groups')) { foreach ($g in $poste.Value.Groups) { $groups.Add($g) } }
    if ($poste -and $poste.Value.ContainsKey('License')) { $license = $poste.Value.License }

    $contract = Find-IFRuleEntry -Table $Rules.Contrats -Name $Request.Contract
    if ($Request.Contract -and $Rules.Contrats.Count -gt 0 -and -not $contract) {
        $errors.Add("type de contrat inconnu : « $($Request.Contract) »")
    }
    if ($contract) {
        if ($contract.Value.ContainsKey('Groups')) { foreach ($g in $contract.Value.Groups) { $groups.Add($g) } }
        if ($contract.Value.ContainsKey('License')) { $license = $contract.Value.License }
        if ($contract.Value.ContainsKey('RequireEndDate') -and $contract.Value.RequireEndDate -and -not $Request.EndDate) {
            $errors.Add("le contrat « $($contract.Name) » exige une date de fin (colonne DateFin)")
        }
    }
    if ($license) { $groups.Add($license) }

    [pscustomobject]@{
        OU         = $ou
        Department = if ($service) { $service.Name } else { $Request.Department }
        Groups     = @($groups | Where-Object { $_ } | Sort-Object -Unique)
        License    = $license
        Errors     = @($errors)
    }
}

function Get-IFAccountExpiry {
    <# Le compte expire à la fin du dernier jour du contrat (le lendemain à 00:00). #>
    [CmdletBinding()]
    param($EndDate)
    if ($null -eq $EndDate) { return $null }
    return ([datetime]$EndDate).Date.AddDays(1)
}
