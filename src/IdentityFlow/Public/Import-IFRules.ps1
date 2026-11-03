function Import-IFRules {
    <#
    .SYNOPSIS
        Charge et valide le fichier de règles (.psd1) : OU, groupes et licences par service,
        par poste et par type de contrat.

    .EXAMPLE
        $rules = Import-IFRules -Path .\regles.psd1
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Fichier de règles introuvable : $Path" }
    $r = Import-PowerShellDataFile -LiteralPath $Path

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($section in @('Organisation', 'Services')) {
        if (-not $r.ContainsKey($section)) { $errors.Add("section « $section » manquante") }
    }
    if ($errors.Count -eq 0) {
        $org = $r.Organisation
        foreach ($k in @('UpnSuffix', 'UsersOU', 'LeaversOU')) {
            if (-not $org.ContainsKey($k) -or [string]::IsNullOrWhiteSpace($org[$k])) { $errors.Add("Organisation.$k manquant") }
        }
        if ($org.ContainsKey('UpnSuffix') -and $org.UpnSuffix -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {
            $errors.Add("Organisation.UpnSuffix invalide : $($org.UpnSuffix)")
        }
        foreach ($k in @('UsersOU', 'LeaversOU')) {
            if ($org.ContainsKey($k) -and $org[$k] -notmatch '(^|,)DC=') { $errors.Add("Organisation.$k doit être un DN complet (…,DC=exemple,DC=local)") }
        }
        if ($r.Services.Count -eq 0) { $errors.Add('au moins un service est requis') }
        foreach ($name in $r.Services.Keys) {
            $s = $r.Services[$name]
            if (-not ($s -is [hashtable])) { $errors.Add("Services.$name doit être une table @{ }"); continue }
            if (-not $s.ContainsKey('OU')) { $errors.Add("Services.$name : OU manquante") }
        }
    }
    if ($errors.Count -gt 0) {
        throw ("Règles invalides ({0}) :`n - {1}" -f $Path, ($errors -join "`n - "))
    }

    # Valeurs par défaut
    $defaults = @{ LoginFormat = '{prenom}.{nom}'; LoginMaxLength = 20; RetentionDays = 90; Company = ''; PasswordLength = 16 }
    foreach ($k in $defaults.Keys) { if (-not $r.Organisation.ContainsKey($k)) { $r.Organisation[$k] = $defaults[$k] } }
    foreach ($k in @('Postes', 'Contrats', 'Depart')) { if (-not $r.ContainsKey($k)) { $r[$k] = @{} } }
    if (-not $r.ContainsKey('CommonGroups')) { $r.CommonGroups = @() }
    if (-not $r.ContainsKey('ManagedGroups')) { $r.ManagedGroups = @('GG-*', 'LIC-*') }
    if (-not $r.Depart.ContainsKey('Checklist')) { $r.Depart.Checklist = @() }
    if (-not $r.Depart.ContainsKey('HideFromAddressList')) { $r.Depart.HideFromAddressList = $true }
    return $r
}
