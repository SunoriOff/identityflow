function Import-IFRequest {
    <#
    .SYNOPSIS
        Lit l'export RH (CSV) et le valide ligne par ligne.

    .DESCRIPTION
        Colonnes reconnues (casse et accents indifférents) :
        Action (Arrivée | Mobilité | Départ), Matricule, Prénom, Nom, Poste, Service, Site,
        Manager (matricule du manager), Contrat, DateEffet, DateFin.

        Chaque ligne devient une demande ; une ligne invalide n'arrête pas le lot :
        elle porte ses erreurs (propriété Errors) et sera signalée dans le plan.
        Dates acceptées : AAAA-MM-JJ ou JJ/MM/AAAA.

    .EXAMPLE
        Import-IFRequest -Path .\export-rh.csv | Where-Object { -not $_.IsValid }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Delimiter = ';',
        [string] $Encoding = 'UTF8'
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Fichier introuvable : $Path" }
    $rows = @(Import-Csv -LiteralPath $Path -Delimiter $Delimiter -Encoding $Encoding)
    if ($rows.Count -eq 0) { return }

    $aliases = @{
        'action' = 'Action'; 'matricule' = 'EmployeeId'; 'prenom' = 'FirstName'; 'nom' = 'LastName'
        'poste' = 'Title'; 'service' = 'Department'; 'site' = 'Office'; 'manager' = 'ManagerId'
        'contrat' = 'Contract'; 'dateeffet' = 'EffectiveDate'; 'datefin' = 'EndDate'
    }
    $headerMap = @{}
    foreach ($h in $rows[0].PSObject.Properties.Name) {
        $k = (ConvertTo-IFKey $h) -replace '[\s_-]', ''
        if ($aliases.ContainsKey($k)) { $headerMap[$aliases[$k]] = $h }
    }
    foreach ($required in @('Action', 'EmployeeId', 'EffectiveDate')) {
        if (-not $headerMap.ContainsKey($required)) {
            $fr = ($aliases.GetEnumerator() | Where-Object Value -EQ $required | Select-Object -First 1).Key
            throw "Colonne obligatoire absente du fichier : « $fr »."
        }
    }

    $seen = @{}
    $line = 1
    foreach ($row in $rows) {
        $line++
        $get = {
            param($field)
            if ($headerMap.ContainsKey($field)) {
                $v = $row.($headerMap[$field])
                if ($null -ne $v) { return ([string]$v).Trim() }
            }
            return ''
        }
        $errors = New-Object System.Collections.Generic.List[string]

        $actionRaw = & $get 'Action'
        $action = switch (ConvertTo-IFKey $actionRaw) {
            'arrivee' { 'Arrivee' }
            'mobilite' { 'Mobilite' }
            'depart' { 'Depart' }
            default { $null }
        }
        if (-not $action) { $errors.Add("action inconnue « $actionRaw » (attendu : Arrivée, Mobilité ou Départ)") }

        $id = & $get 'EmployeeId'
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$') {
            $errors.Add("matricule invalide « $id » (lettres, chiffres, - et _ uniquement)")
        }
        elseif ($seen.ContainsKey($id.ToUpperInvariant())) {
            $errors.Add("matricule en double (déjà présent ligne $($seen[$id.ToUpperInvariant()]))")
        }
        else {
            $seen[$id.ToUpperInvariant()] = $line
        }

        $effective = ConvertTo-IFDate (& $get 'EffectiveDate')
        if (-not $effective) { $errors.Add("DateEffet invalide ou absente « $(& $get 'EffectiveDate') »") }
        $endRaw = & $get 'EndDate'
        $end = $null
        if ($endRaw) {
            $end = ConvertTo-IFDate $endRaw
            if (-not $end) { $errors.Add("DateFin invalide « $endRaw »") }
            elseif ($effective -and $end -lt $effective) { $errors.Add('DateFin antérieure à DateEffet') }
        }

        $req = [pscustomobject]@{
            PSTypeName    = 'IdentityFlow.Request'
            Line          = $line
            Action        = $action
            EmployeeId    = $id.ToUpperInvariant()
            FirstName     = & $get 'FirstName'
            LastName      = & $get 'LastName'
            Title         = & $get 'Title'
            Department    = & $get 'Department'
            Office        = & $get 'Office'
            ManagerId     = (& $get 'ManagerId').ToUpperInvariant()
            Contract      = & $get 'Contract'
            EffectiveDate = $effective
            EndDate       = $end
            Errors        = $null
            IsValid       = $false
        }

        switch ($action) {
            'Arrivee' {
                foreach ($f in @(@('FirstName', 'Prénom'), @('LastName', 'Nom'), @('Department', 'Service'))) {
                    if (-not $req.($f[0])) { $errors.Add("$($f[1]) obligatoire pour une arrivée") }
                }
                if (-not $req.Contract) { $req.Contract = 'CDI' }
            }
            'Mobilite' {
                if (-not ($req.Department -or $req.Title -or $req.Office -or $req.ManagerId)) {
                    $errors.Add('une mobilité doit changer au moins le service, le poste, le site ou le manager')
                }
            }
        }
        if ($req.ManagerId -and $req.ManagerId -eq $req.EmployeeId) { $errors.Add('un collaborateur ne peut pas être son propre manager') }

        $req.Errors = @($errors)
        $req.IsValid = ($errors.Count -eq 0)
        $req
    }
}

