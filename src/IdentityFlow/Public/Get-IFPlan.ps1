function Get-IFPlan {
    <#
    .SYNOPSIS
        Calcule, sans rien modifier, ce qu'il faut faire pour chaque ligne de l'export RH.

    .DESCRIPTION
        Pour chaque demande, l'état voulu (calculé à partir des règles) est comparé à
        l'état réel de l'annuaire. Le plan ne contient que les écarts : relancer le même
        fichier ne refait rien (idempotence).

        États possibles : Pending (des étapes à appliquer), UpToDate (rien à faire),
        Scheduled (date d'effet pas encore atteinte), Invalid (ligne ou règle en erreur).

        Calendrier :
        - Arrivée : compte créé JoinerLeadDays jours avant la date d'effet (7 par défaut),
          pour préparer le poste ;
        - Mobilité : appliquée à partir de la date d'effet ;
        - Départ : DateEffet est le dernier jour travaillé ; le compte est coupé le lendemain.

    .EXAMPLE
        $plan = Import-IFRequest .\export-rh.csv | Get-IFPlan -Rules $rules -Provider $ad
        $plan | Format-Table Line, ActionLabel, Name, Login, State
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Request,
        [Parameter(Mandatory)][hashtable] $Rules,
        [Parameter(Mandatory)] $Provider,
        [datetime] $AsOf = (Get-Date)
    )
    begin {
        $all = New-Object System.Collections.Generic.List[object]
    }
    process {
        foreach ($r in @($Request)) { $all.Add($r) }
    }
    end {
        $org = $Rules.Organisation
        $today = $AsOf.Date
        $lead = 7
        if ($org.ContainsKey('JoinerLeadDays')) { $lead = [int]$org.JoinerLeadDays }
        $reserved = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $planned = @{}
        $arrivee = @{}
        if ($Rules.ContainsKey('Arrivee')) { $arrivee = $Rules.Arrivee }

        $order = @{ Arrivee = 0; Mobilite = 1; Depart = 2 }
        # Parmi les arrivées, un manager qui arrive dans le même lot passe avant ses collaborateurs.
        $arrivals = @{}
        foreach ($r in $all) { if ($r.IsValid -and $r.Action -eq 'Arrivee') { $arrivals[$r.EmployeeId] = $r } }
        $depth = @{}
        foreach ($id in $arrivals.Keys) {
            $d = 0; $cur = $arrivals[$id]; $seenIds = @{}
            while ($cur.ManagerId -and $arrivals.ContainsKey($cur.ManagerId) -and -not $seenIds.ContainsKey($cur.ManagerId) -and $d -lt 50) {
                $seenIds[$cur.ManagerId] = $true; $d++; $cur = $arrivals[$cur.ManagerId]
            }
            $depth[$id] = $d
        }
        $sorted = $all | Sort-Object @{ Expression = { if ($_.Action -and $order.ContainsKey($_.Action)) { $order[$_.Action] } else { 9 } } },
            @{ Expression = { if ($depth.ContainsKey([string]$_.EmployeeId)) { $depth[[string]$_.EmployeeId] } else { 0 } } }, Line

        # 1er passage : identifiants des nouveaux arrivants, pour que les managers du même lot soient résolus.
        $existingCache = @{}
        foreach ($r in $sorted) {
            if (-not $r.IsValid -or $r.Action -ne 'Arrivee') { continue }
            $existing = $Provider.FindByEmployeeId($r.EmployeeId)
            $existingCache[$r.EmployeeId] = $existing
            if ($existing) { continue }
            if ($r.EffectiveDate.AddDays(-$lead) -gt $today) { continue }
            try {
                $base = ConvertTo-IFLogin -FirstName $r.FirstName -LastName $r.LastName -EmployeeId $r.EmployeeId -Format $org.LoginFormat -MaxLength $org.LoginMaxLength
                $planned[$r.EmployeeId] = Resolve-IFUniqueLogin -BaseLogin $base -Provider $Provider -Reserved $reserved -MaxLength $org.LoginMaxLength
            }
            catch {
                $planned[$r.EmployeeId] = $null
            }
        }

        foreach ($r in $sorted) {
            $item = New-IFPlanItem -Request $r
            if (-not $r.IsValid) {
                foreach ($e in $r.Errors) { $item.Errors.Add($e) }
                $item.State = 'Invalid'
                $item
                continue
            }

            try {
                switch ($r.Action) {
                    'Arrivee' {
                        $current = if ($existingCache.ContainsKey($r.EmployeeId)) { $existingCache[$r.EmployeeId] } else { $Provider.FindByEmployeeId($r.EmployeeId) }
                        if ($r.EffectiveDate.AddDays(-$lead) -gt $today -and -not $current) {
                            $item.State = 'Scheduled'
                            $item.Messages.Add(('Compte créé à partir du {0:dd/MM/yyyy}' -f $r.EffectiveDate.AddDays(-$lead)))
                            break
                        }
                        $role = Get-IFRoleProfile -Request $r -Rules $Rules
                        foreach ($e in $role.Errors) { $item.Errors.Add($e) }
                        if ($item.Errors.Count) { $item.State = 'Invalid'; break }

                        $manager = Resolve-IFManagerLogin -ManagerId $r.ManagerId -Planned $planned -Provider $Provider -Item $item
                        if ($null -eq $manager) { $manager = '<inchangé>' }
                        $attrs = @{
                            Title          = $r.Title
                            Department     = $role.Department
                            Office         = $r.Office
                            Company        = $org.Company
                            AccountExpires = Get-IFAccountExpiry $r.EndDate
                        }

                        if ($current) {
                            $item.Login = $current.Login
                            $item.Name = $current.DisplayName
                            if (-not $current.Enabled) {
                                $item.Messages.Add('Compte existant désactivé : réembauche.')
                                Add-IFStep -Item $item -Op 'Enable' -Text 'Réactiver le compte' -Params @{ Login = $current.Login }
                                Add-IFStep -Item $item -Op 'ResetPassword' -Text 'Nouveau mot de passe temporaire (à changer à la connexion)' -Params @{ Login = $current.Login; MustChange = $true }
                                if ($current.Description) {
                                    Add-IFStep -Item $item -Op 'SetAttribute' -Text 'Effacer la mention de départ' -Params @{ Login = $current.Login; Name = 'Description'; Old = $current.Description; New = $null }
                                }
                                if ($current.HiddenFromAddressList) {
                                    Add-IFStep -Item $item -Op 'SetAttribute' -Text 'Réafficher dans la liste d''adresses' -Params @{ Login = $current.Login; Name = 'HiddenFromAddressList'; Old = $true; New = $false }
                                }
                            }
                            else {
                                $item.Messages.Add('Compte déjà existant : mise en conformité seulement.')
                            }
                            Add-IFReconcileStep -Item $item -Current $current -Attributes $attrs -OU $role.OU -Groups $role.Groups `
                                -ManagedPatterns $Rules.ManagedGroups -Manager $manager -Provider $Provider
                        }
                        else {
                            $login = $planned[$r.EmployeeId]
                            if (-not $login) { throw "identifiant impossible à calculer pour « $($r.FirstName) $($r.LastName) »" }
                            $item.Login = $login
                            $upn = '{0}@{1}' -f $login, $org.UpnSuffix
                            $desired = @{
                                Login          = $login
                                Upn            = $upn
                                Mail           = $upn
                                DisplayName    = Format-IFDisplayName $r.FirstName $r.LastName
                                GivenName      = Format-IFFirstName $r.FirstName
                                Surname        = $r.LastName.Trim().ToUpperInvariant()
                                EmployeeId     = $r.EmployeeId
                                Title          = $attrs.Title
                                Department     = $attrs.Department
                                Office         = $attrs.Office
                                Company        = $attrs.Company
                                OU             = $role.OU
                                AccountExpires = $attrs.AccountExpires
                            }
                            $where = if ($Provider.SupportsOU) { " dans $($role.OU)" } else { '' }
                            Add-IFStep -Item $item -Op 'Create' -Text "Créer le compte $login ($upn)$where" -Params $desired
                            foreach ($g in $role.Groups) {
                                Add-IFStep -Item $item -Op 'AddGroup' -Text "Ajouter au groupe $g" -Params @{ Login = $login; Group = $g }
                            }
                            if ($manager -ne '<inchangé>') {
                                Add-IFStep -Item $item -Op 'SetManager' -Text "Manager : $manager" -Params @{ Login = $login; Old = $null; New = $manager }
                            }
                            if ($arrivee.ContainsKey('Checklist')) { foreach ($c in $arrivee.Checklist) { $item.Checklist.Add($c) } }
                        }
                    }

                    'Mobilite' {
                        $current = $Provider.FindByEmployeeId($r.EmployeeId)
                        if (-not $current) { throw "matricule $($r.EmployeeId) introuvable dans l'annuaire" }
                        if (-not $current.Enabled) { throw "le compte $($current.Login) est désactivé : utilisez une ligne « Arrivée » pour une réembauche" }
                        $item.Login = $current.Login
                        $item.Name = $current.DisplayName
                        if ($r.EffectiveDate -gt $today) {
                            $item.State = 'Scheduled'
                            $item.Messages.Add(('Mobilité appliquée le {0:dd/MM/yyyy}' -f $r.EffectiveDate))
                            break
                        }
                        $merged = [pscustomobject]@{
                            Department = if ($r.Department) { $r.Department } else { $current.Department }
                            Title      = if ($r.Title) { $r.Title } else { $current.Title }
                            Office     = if ($r.Office) { $r.Office } else { $current.Office }
                            Contract   = ''
                            EndDate    = $r.EndDate
                        }
                        $role = Get-IFRoleProfile -Request $merged -Rules $Rules
                        foreach ($e in $role.Errors) { $item.Errors.Add($e) }
                        if ($item.Errors.Count) { $item.State = 'Invalid'; break }

                        $attrs = @{ Title = $merged.Title; Department = $role.Department; Office = $merged.Office }
                        if ($r.EndDate) { $attrs.AccountExpires = Get-IFAccountExpiry $r.EndDate }
                        $manager = '<inchangé>'
                        if ($r.ManagerId) {
                            $manager = Resolve-IFManagerLogin -ManagerId $r.ManagerId -Planned $planned -Provider $Provider -Item $item
                        }
                        Add-IFReconcileStep -Item $item -Current $current -Attributes $attrs -OU $role.OU -Groups $role.Groups `
                            -ManagedPatterns $Rules.ManagedGroups -Preserve (Get-IFContractGroup $Rules) -Manager $manager -Provider $Provider
                    }

                    'Depart' {
                        $current = $Provider.FindByEmployeeId($r.EmployeeId)
                        if (-not $current) { throw "matricule $($r.EmployeeId) introuvable dans l'annuaire" }
                        $item.Login = $current.Login
                        $item.Name = $current.DisplayName
                        if ($r.EffectiveDate -ge $today) {
                            $item.State = 'Scheduled'
                            $item.Messages.Add(('Dernier jour le {0:dd/MM/yyyy} : compte coupé le lendemain' -f $r.EffectiveDate))
                            break
                        }
                        $leaversOU = $org.LeaversOU
                        $mark = 'Départ le {0:yyyy-MM-dd} (IdentityFlow)' -f $r.EffectiveDate
                        $login = $current.Login
                        if ($current.Enabled) {
                            Add-IFStep -Item $item -Op 'Disable' -Text 'Désactiver le compte' -Params @{ Login = $login }
                            Add-IFStep -Item $item -Op 'ResetPassword' -Text 'Remplacer le mot de passe par un mot de passe aléatoire inconnu' -Params @{ Login = $login; MustChange = $false }
                        }
                        if ($Provider.SupportsRevoke -and $current.Enabled) {
                            Add-IFStep -Item $item -Op 'Revoke' -Text 'Révoquer les sessions ouvertes' -Params @{ Login = $login }
                        }
                        foreach ($g in $current.Groups) {
                            Add-IFStep -Item $item -Op 'RemoveGroup' -Text "Retirer du groupe $g" -Params @{ Login = $login; Group = $g }
                        }
                        if ($Provider.SupportsOU -and $current.OU -ne $leaversOU) {
                            Add-IFStep -Item $item -Op 'Move' -Text "Déplacer vers $leaversOU" -Params @{ Login = $login; From = $current.OU; To = $leaversOU }
                        }
                        if ($current.Description -ne $mark) {
                            Add-IFStep -Item $item -Op 'SetAttribute' -Text "Description : $mark" -Params @{ Login = $login; Name = 'Description'; Old = $current.Description; New = $mark }
                        }
                        if ($Rules.Depart.HideFromAddressList) {
                            if ($Provider.SupportsHideFromGal) {
                                if (-not $current.HiddenFromAddressList) {
                                    Add-IFStep -Item $item -Op 'SetAttribute' -Text 'Masquer de la liste d''adresses' -Params @{ Login = $login; Name = 'HiddenFromAddressList'; Old = $false; New = $true }
                                }
                            }
                            elseif ($item.Steps.Count -gt 0) {
                                $item.Checklist.Add('Masquer le compte de la liste d''adresses globale (Exchange)')
                            }
                        }
                        if ($item.Steps.Count -gt 0) { foreach ($c in $Rules.Depart.Checklist) { $item.Checklist.Add($c) } }
                    }
                }
            }
            catch {
                $item.Errors.Add($_.Exception.Message)
                $item.State = 'Invalid'
            }

            if ($item.State -eq 'Pending' -and $item.Steps.Count -eq 0) { $item.State = 'UpToDate' }
            $item
        }
    }
}
