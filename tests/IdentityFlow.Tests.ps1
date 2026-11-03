BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    Import-Module ([System.IO.Path]::Combine($Root, 'src', 'IdentityFlow', 'IdentityFlow.psd1')) -Force
    $script:RulesPath = [System.IO.Path]::Combine($Root, 'examples', 'regles.psd1')
    $script:DemoDir = [System.IO.Path]::Combine($Root, 'examples', 'annuaire-demo.json')
    $script:DemoCsv = [System.IO.Path]::Combine($Root, 'examples', 'export-rh.csv')
    $script:AsOf = [datetime]'2026-11-03'
    $script:Header = 'Action;Matricule;Prénom;Nom;Poste;Service;Site;Manager;Contrat;DateEffet;DateFin'

    function New-TestCsv {
        param([string[]] $Lines, [string] $Header = $script:Header)
        $path = Join-Path $TestDrive ('rh-{0}.csv' -f [guid]::NewGuid().ToString('N'))
        Set-Content -LiteralPath $path -Value (@($Header) + $Lines) -Encoding UTF8
        return $path
    }

    function New-TestDirectory {
        $path = Join-Path $TestDrive ('annuaire-{0}.json' -f [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $script:DemoDir -Destination $path
        return New-IFMemoryProvider -Path $path
    }

    function Invoke-TestRun {
        param([string[]] $Lines, $Provider, [switch] $WhatIf, [datetime] $AsOf = $script:AsOf)
        $rules = Import-IFRules -Path $script:RulesPath
        $audit = Join-Path $TestDrive 'audit.jsonl'
        Import-IFRequest -Path (New-TestCsv $Lines) |
            Get-IFPlan -Rules $rules -Provider $Provider -AsOf $AsOf |
            Invoke-IFPlan -Provider $Provider -AuditPath $audit -WhatIf:$WhatIf
    }
}

Describe 'Calcul des identifiants' {
    It 'retire accents et apostrophes' {
        ConvertTo-IFLogin -FirstName 'Hélène' -LastName "N'Diaye" | Should -Be 'helene.ndiaye'
        ConvertTo-IFLogin -FirstName 'Çağla' -LastName 'Öztürk' | Should -Be 'cagla.ozturk'
    }
    It 'gère ligatures et lettres sans décomposition' {
        ConvertTo-IFLogin -FirstName 'Œdipe' -LastName 'Strauß' | Should -Be 'oedipe.strauss'
    }
    It 'garde les traits d''union, retire les espaces et tronque à 20 caractères' {
        ConvertTo-IFLogin -FirstName 'Jean-Pierre' -LastName 'De La Fontaine' | Should -Be 'jean-pierre.delafont'
    }
    It 'ne finit jamais par un point après troncature' {
        ConvertTo-IFLogin -FirstName 'Bartholomew' -LastName 'Xu' -MaxLength 12 | Should -Be 'bartholomew'
    }
    It 'applique un modèle personnalisé' {
        ConvertTo-IFLogin -FirstName 'Jean-Pierre' -LastName 'De La Fontaine' -Format '{p}{nom}' | Should -Be 'jdelafontaine'
        ConvertTo-IFLogin -FirstName 'Léa' -LastName 'Moreau' -EmployeeId 'E1103' -Format '{matricule}' | Should -Be 'e1103'
    }
    It 'refuse un nom vide après nettoyage' {
        { ConvertTo-IFLogin -FirstName '---' -LastName 'X' } | Should -Throw
    }
    It 'rend l''identifiant unique face à l''annuaire et au lot en cours' {
        InModuleScope IdentityFlow {
            $dir = New-IFMemoryProvider -Groups @()
            $dir.NewUser(@{ Login = 'jean.dupont'; Upn = 'jean.dupont@x.fr'; EmployeeId = 'A' }, $null)
            $reserved = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            Resolve-IFUniqueLogin -BaseLogin 'jean.dupont' -Provider $dir -Reserved $reserved | Should -Be 'jean.dupont2'
            Resolve-IFUniqueLogin -BaseLogin 'jean.dupont' -Provider $dir -Reserved $reserved | Should -Be 'jean.dupont3'
        }
    }
    It 'tronque avant d''ajouter le suffixe' {
        InModuleScope IdentityFlow {
            $dir = New-IFMemoryProvider
            $dir.NewUser(@{ Login = 'jean-pierre.delafont'; Upn = 'x@x.fr'; EmployeeId = 'A' }, $null)
            $reserved = New-Object 'System.Collections.Generic.HashSet[string]'
            Resolve-IFUniqueLogin -BaseLogin 'jean-pierre.delafont' -Provider $dir -Reserved $reserved | Should -Be 'jean-pierre.delafon2'
        }
    }
}

Describe 'Mots de passe temporaires' {
    It 'respecte longueur et complexité, sans caractère ambigu' {
        InModuleScope IdentityFlow {
            foreach ($i in 1..50) {
                $plain = [System.Net.NetworkCredential]::new('', (New-IFPassword -Length 16)).Password
                $plain.Length | Should -Be 16
                $plain | Should -MatchExactly '[A-Z]'
                $plain | Should -MatchExactly '[a-z]'
                $plain | Should -Match '[0-9]'
                $plain | Should -Match '[^A-Za-z0-9]'
                $plain | Should -Not -MatchExactly '[0O1lI]'
            }
        }
    }
    It 'ne se répète pas' {
        InModuleScope IdentityFlow {
            $set = @{}
            foreach ($i in 1..200) { $set[[System.Net.NetworkCredential]::new('', (New-IFPassword)).Password] = 1 }
            $set.Count | Should -Be 200
        }
    }
}

Describe 'Lecture de l''export RH' {
    It 'lit le fichier d''exemple (BOM, accents, deux formats de date)' {
        $r = @(Import-IFRequest -Path $DemoCsv)
        $r.Count | Should -Be 9
        $r[0].Action | Should -Be 'Arrivee'
        $r[0].FirstName | Should -Be 'Hélène'
        $r[1].EffectiveDate | Should -Be ([datetime]'2026-11-03')
        $r[1].EndDate | Should -Be ([datetime]'2027-05-02')
        $r[4].Action | Should -Be 'Mobilite'
        @($r | Where-Object IsValid).Count | Should -Be 9
    }
    It 'signale chaque ligne invalide sans arrêter le lot' {
        $csv = New-TestCsv @(
            'Embauche;E1;A;B;;Informatique;;;CDI;2026-11-01;'
            'Arrivée;E 2;A;B;;Informatique;;;CDI;2026-11-01;'
            'Arrivée;E3;A;B;;Informatique;;;CDI;32/13/2026;'
            'Arrivée;E4;A;B;;Informatique;;;CDD;2026-11-10;2026-11-01'
            'Mobilité;E5;;;;;;;;2026-11-01;'
            'Arrivée;E6;;B;;Informatique;;;CDI;2026-11-01;'
            'Arrivée;E7;A;B;;Informatique;;E7;CDI;2026-11-01;'
            'Départ;e8;;;;;;;;2026-11-01;'
            'Départ;E8;;;;;;;;2026-11-01;'
        )
        $r = @(Import-IFRequest -Path $csv)
        $r.Count | Should -Be 9
        $r[0].Errors | Should -Match 'action inconnue'
        $r[1].Errors | Should -Match 'matricule invalide'
        $r[2].Errors | Should -Match 'DateEffet invalide'
        $r[3].Errors | Should -Match 'antérieure'
        $r[4].Errors | Should -Match 'au moins'
        $r[5].Errors | Should -Match 'Prénom obligatoire'
        $r[6].Errors | Should -Match 'propre manager'
        $r[7].IsValid | Should -BeTrue
        $r[8].Errors | Should -Match 'en double \(déjà présent ligne 9\)'
    }
    It 'met CDI par défaut et normalise le matricule' {
        $r = Import-IFRequest -Path (New-TestCsv 'arrivee;e42;Zoé;Lambert;;Informatique;;;;2026-11-01;')
        $r.Contract | Should -Be 'CDI'
        $r.EmployeeId | Should -Be 'E42'
    }
    It 'refuse un fichier sans colonne obligatoire' {
        $csv = New-TestCsv -Header 'Action;Prénom;Nom' -Lines 'Arrivée;A;B'
        { Import-IFRequest -Path $csv } | Should -Throw '*matricule*'
    }
}

Describe 'Règles' {
    It 'charge l''exemple et complète les valeurs par défaut' {
        $r = Import-IFRules -Path $RulesPath
        $r.Organisation.UpnSuffix | Should -Be 'exemple.fr'
        $r.ManagedGroups | Should -Contain 'GG-*'
    }
    It 'refuse des règles incomplètes avec un message explicite' {
        $p = Join-Path $TestDrive 'mauvaises.psd1'
        Set-Content $p "@{ Organisation = @{ UpnSuffix = 'x'; UsersOU = 'OU=U'; LeaversOU = 'OU=D,DC=x' }; Services = @{} }"
        { Import-IFRules -Path $p } | Should -Throw '*UpnSuffix invalide*'
        { Import-IFRules -Path $p } | Should -Throw '*UsersOU doit être un DN complet*'
    }
}

Describe 'Arrivées' {
    BeforeEach { $dir = New-TestDirectory }

    It 'crée le compte avec OU, groupes, licence, manager et expiration' {
        $res = Invoke-TestRun -Provider $dir -Lines 'Arrivée;E200;Hélène;N''Diaye;Administratrice systèmes;Informatique;Nantes;E1010;CDD;2026-11-03;2027-05-02'
        $res.State | Should -Be 'Done'
        $res.TemporaryPassword | Should -BeOfType [securestring]
        $u = $dir.GetUser('helene.ndiaye')
        $u.DisplayName | Should -Be 'Hélène N''DIAYE'
        $u.Upn | Should -Be 'helene.ndiaye@exemple.fr'
        $u.OU | Should -Be 'OU=Informatique,OU=Utilisateurs,DC=exemple,DC=local'
        $u.Groups | Should -Be @('GG-Admins-Serveurs', 'GG-DSI', 'GG-Tous', 'GG-VPN', 'LIC-M365-E3')
        $u.ManagerLogin | Should -Be 'karim.benali'
        $u.AccountExpires | Should -Be ([datetime]'2027-05-03')
        $u.Enabled | Should -BeTrue
        $dir.Store.Users['helene.ndiaye'].MustChangePassword | Should -BeTrue
        $res.Checklist.Count | Should -Be 2
    }

    It 'attribue jean.dupont2 à un homonyme' {
        $res = Invoke-TestRun -Provider $dir -Lines 'Arrivée;E201;Jean;Dupont;;Commercial;;;CDI;2026-11-03;'
        $res.Login | Should -Be 'jean.dupont2'
    }

    It 'résout un manager qui arrive dans le même lot' {
        $res = @(Invoke-TestRun -Provider $dir -Lines @(
                'Arrivée;E301;Bruno;Collaborateur;;Logistique;;E300;CDI;2026-11-03;'
                'Arrivée;E300;Alice;Cheffe;;Logistique;;;CDI;2026-11-03;'
            ))
        ($res | Where-Object EmployeeId -EQ 'E301').State | Should -Be 'Done'
        $dir.GetUser('bruno.collaborateur').ManagerLogin | Should -Be 'alice.cheffe'
    }

    It 'planifie une arrivée lointaine, mais crée le compte une semaine avant' {
        $res = @(Invoke-TestRun -Provider $dir -Lines @(
                'Arrivée;E400;Loin;Tard;;Logistique;;;CDI;2026-12-01;'
                'Arrivée;E401;Bientot;La;;Logistique;;;CDI;2026-11-09;'
            ))
        $res[0].State | Should -Be 'Scheduled'
        $res[1].State | Should -Be 'Done'
    }

    It 'rejette un service ou un contrat inconnu, et un CDD sans date de fin' {
        $res = @(Invoke-TestRun -Provider $dir -Lines @(
                'Arrivée;E500;A;Un;;Juridique;;;CDI;2026-11-03;'
                'Arrivée;E501;A;Deux;;Logistique;;;Freelance;2026-11-03;'
                'Arrivée;E502;A;Trois;;Logistique;;;CDD;2026-11-03;'
            ))
        $res.State | Should -Be @('Invalid', 'Invalid', 'Invalid')
        $res[0].Errors | Should -Match 'service inconnu'
        $res[1].Errors | Should -Match 'contrat inconnu'
        $res[2].Errors | Should -Match 'date de fin'
        $dir.Store.Users.Count | Should -Be 8
    }

    It 'signale un manager introuvable sans bloquer la création' {
        $res = Invoke-TestRun -Provider $dir -Lines 'Arrivée;E600;Sans;Chef;;Logistique;;E0000;CDI;2026-11-03;'
        $res.State | Should -Be 'Done'
        $res.Messages | Should -Match 'Manager E0000 introuvable'
        $dir.GetUser('sans.chef').ManagerLogin | Should -BeNullOrEmpty
    }

    It 'réembauche un compte désactivé au lieu d''en créer un second' {
        $res = Invoke-TestRun -Provider $dir -Lines 'Arrivée;E1061;Marc;Roux;Magasinier;Logistique;Nantes;E1001;CDI;2026-11-03;'
        $res.State | Should -Be 'Done'
        $res.Login | Should -Be 'marc.roux'
        $res.TemporaryPassword | Should -Not -BeNullOrEmpty
        $u = $dir.GetUser('marc.roux')
        $u.Enabled | Should -BeTrue
        $u.Description | Should -BeNullOrEmpty
        $u.HiddenFromAddressList | Should -BeFalse
        $u.OU | Should -Be 'OU=Logistique,OU=Utilisateurs,DC=exemple,DC=local'
        $u.Groups | Should -Contain 'GG-Logistique'
        $dir.Store.Users.Count | Should -Be 8
    }
}

Describe 'Mobilités' {
    BeforeEach { $dir = New-TestDirectory }

    It 'change service, OU et groupes gérés, en gardant les groupes ajoutés à la main' {
        $res = Invoke-TestRun -Provider $dir -Lines 'Mobilité;E1031;;;Comptable;Comptabilité;;;;2026-11-01;'
        $res.State | Should -Be 'Done'
        $u = $dir.GetUser('julien.dupont')
        $u.Department | Should -Be 'Comptabilité'
        $u.Title | Should -Be 'Comptable'
        $u.Office | Should -Be 'Lille'
        $u.OU | Should -Be 'OU=Finance,OU=Utilisateurs,DC=exemple,DC=local'
        $u.Groups | Should -Be @('GG-Compta', 'GG-Partage-Finance', 'GG-Tous', 'Imprimante-Etage2', 'LIC-M365-E3')
    }

    It 'conserve les groupes liés au contrat' {
        $dir.AddToGroup('julien.dupont', 'GG-Alternants')
        Invoke-TestRun -Provider $dir -Lines 'Mobilité;E1031;;;;Logistique;;;;2026-11-01;' | Out-Null
        $dir.GetUser('julien.dupont').Groups | Should -Contain 'GG-Alternants'
    }

    It 'change seulement le manager' {
        $res = Invoke-TestRun -Provider $dir -Lines 'Mobilité;E1032;;;;;;E1010;;2026-11-01;'
        $res.Steps.Count | Should -Be 1
        $res.Steps[0].Text | Should -Be 'Manager : julien.dupont → karim.benali'
    }

    It 'refuse la mobilité d''un compte inconnu ou désactivé' {
        $res = @(Invoke-TestRun -Provider $dir -Lines @('Mobilité;E7777;;;;Logistique;;;;2026-11-01;', 'Mobilité;E1060;;;;Logistique;;;;2026-11-01;'))
        $res[0].Errors | Should -Match 'introuvable'
        $res[1].Errors | Should -Match 'désactivé'
    }
}

Describe 'Départs' {
    BeforeEach { $dir = New-TestDirectory }

    It 'désactive, retire les groupes, déplace, marque et masque' {
        $res = Invoke-TestRun -Provider $dir -Lines 'Départ;E1045;;;;;;;;2026-10-31;'
        $res.State | Should -Be 'Done'
        $u = $dir.GetUser('thomas.petit')
        $u.Enabled | Should -BeFalse
        $u.Groups | Should -BeNullOrEmpty
        $u.OU | Should -Be 'OU=Departs,DC=exemple,DC=local'
        $u.Description | Should -Be 'Départ le 2026-10-31 (IdentityFlow)'
        $u.HiddenFromAddressList | Should -BeTrue
        $res.TemporaryPassword | Should -BeNullOrEmpty
        $res.Checklist | Should -Contain 'Transférer les fichiers OneDrive au manager'
    }

    It 'attend le lendemain du dernier jour' {
        (Invoke-TestRun -Provider $dir -Lines 'Départ;E1045;;;;;;;;2026-11-03;').State | Should -Be 'Scheduled'
        $dir.GetUser('thomas.petit').Enabled | Should -BeTrue
    }
}

Describe 'Sécurité d''exécution' {
    BeforeEach { $dir = New-TestDirectory }

    It '-WhatIf ne modifie rien et le note dans le journal' {
        $before = $dir.Store.Users.Count
        $res = @(Invoke-TestRun -Provider $dir -WhatIf -Lines @(
                'Arrivée;E700;Nouvelle;Personne;;Logistique;;;CDI;2026-11-03;'
                'Départ;E1045;;;;;;;;2026-10-31;'
            ))
        $res.State | Should -Be @('WhatIf', 'WhatIf')
        $dir.Store.Users.Count | Should -Be $before
        $dir.GetUser('thomas.petit').Enabled | Should -BeTrue
        $audit = @(Get-Content (Join-Path $TestDrive 'audit.jsonl') | ConvertFrom-Json)
        ($audit | Where-Object outcome -NE 'WhatIf').Count | Should -Be 0
    }

    It 'relancer le même fichier ne refait rien (idempotence)' {
        $lines = Get-Content $DemoCsv -Encoding UTF8 | Select-Object -Skip 1
        Invoke-TestRun -Provider $dir -Lines $lines | Out-Null
        $again = @(Invoke-TestRun -Provider $dir -Lines $lines)
        @($again | Where-Object State -In 'Done', 'Pending', 'Failed').Count | Should -Be 0
        @($again | Where-Object State -EQ 'UpToDate').Count | Should -Be 5
    }

    It 'une erreur n''arrête que la personne concernée' {
        [void]$dir.Store.Groups.Remove('GG-VPN')
        $res = @(Invoke-TestRun -Provider $dir -Lines @(
                'Arrivée;E800;Admin;Sys;Administrateur systèmes;Informatique;;;CDI;2026-11-03;'
                'Arrivée;E801;Autre;Personne;;Logistique;;;CDI;2026-11-03;'
            ))
        $res[0].State | Should -Be 'Failed'
        $res[0].Errors | Should -Match 'Groupe introuvable : GG-VPN'
        @($res[0].Steps | Where-Object Outcome -EQ 'Skipped').Count | Should -BeGreaterThan 0
        $res[1].State | Should -Be 'Done'
    }

    It 'le journal ne contient jamais de mot de passe' {
        Invoke-TestRun -Provider $dir -Lines 'Arrivée;E900;Pass;Word;;Logistique;;;CDI;2026-11-03;' | Out-Null
        $raw = Get-Content (Join-Path $TestDrive 'audit.jsonl') -Raw
        $raw | Should -Not -Match '(?i)password"\s*:\s*"'
        $lines = @(Get-Content (Join-Path $TestDrive 'audit.jsonl') | ConvertFrom-Json)
        $lines[0].op | Should -Be 'Create'
        $lines[0].operator | Should -Not -BeNullOrEmpty
        $lines[0].params.OU | Should -Be 'OU=Logistique,OU=Utilisateurs,DC=exemple,DC=local'
    }
}

Describe 'Annulation d''un départ' {
    It 'rétablit groupes, OU, description et visibilité, avec un nouveau mot de passe' {
        $dir = New-TestDirectory
        $before = $dir.GetUser('thomas.petit')
        Invoke-TestRun -Provider $dir -Lines 'Départ;E1045;;;;;;;;2026-10-31;' | Out-Null
        $undo = Undo-IFLeaver -EmployeeId e1045 -AuditPath (Join-Path $TestDrive 'audit.jsonl') -Provider $dir -Confirm:$false
        $undo.State | Should -Be 'Done'
        $undo.TemporaryPassword | Should -Not -BeNullOrEmpty
        $after = $dir.GetUser('thomas.petit')
        $after.Enabled | Should -BeTrue
        $after.Groups | Should -Be $before.Groups
        $after.OU | Should -Be $before.OU
        $after.Description | Should -BeNullOrEmpty
        $after.HiddenFromAddressList | Should -BeFalse
    }
    It 'refuse s''il n''y a aucun départ dans le journal' {
        $dir = New-TestDirectory
        $j = Join-Path $TestDrive 'vide.jsonl'
        Set-Content $j ''
        { Undo-IFLeaver -EmployeeId E1001 -AuditPath $j -Provider $dir -Confirm:$false } | Should -Throw '*Aucun départ*'
    }
}

Describe 'Purge' {
    BeforeEach {
        $dir = New-TestDirectory
        $rules = Import-IFRules -Path $RulesPath
    }
    It 'supprime après la durée de rétention, garde les plus récents' {
        $r = @(Invoke-IFPurge -Rules $rules -Provider $dir -AsOf $AsOf -Confirm:$false)
        ($r | Where-Object Login -EQ 'nadia.haddad').Outcome | Should -Be 'Removed'
        ($r | Where-Object Login -EQ 'marc.roux').Outcome | Should -Be 'Kept'
        $dir.GetUser('nadia.haddad') | Should -BeNullOrEmpty
        $dir.GetUser('marc.roux') | Should -Not -BeNullOrEmpty
    }
    It '-WhatIf ne supprime rien' {
        $r = @(Invoke-IFPurge -Rules $rules -Provider $dir -AsOf $AsOf -WhatIf)
        ($r | Where-Object Login -EQ 'nadia.haddad').Outcome | Should -Be 'WhatIf'
        $dir.GetUser('nadia.haddad') | Should -Not -BeNullOrEmpty
    }
    It 'ne touche jamais un compte réactivé ou sans mention IdentityFlow' {
        $dir.SetEnabled('nadia.haddad', $true)
        $dir.SetAttribute('marc.roux', 'Description', 'déplacé à la main')
        $r = @(Invoke-IFPurge -Rules $rules -Provider $dir -AsOf ([datetime]'2027-06-01') -Confirm:$false)
        @($r | Where-Object Outcome -EQ 'Removed').Count | Should -Be 0
    }
}

Describe 'Compte rendu HTML' {
    It 'échappe les données et liste les actions manuelles' {
        $dir = New-TestDirectory
        $res = @(Invoke-TestRun -Provider $dir -Lines @(
                'Arrivée;E950;<script>alert(1)</script>;Test;;Logistique;;;CDI;2026-11-03;'
                'Départ;E1045;;;;;;;;2026-10-31;'
            ))
        $file = $res | New-IFReport -Path (Join-Path $TestDrive 'r\rapport.html')
        $html = Get-Content $file.FullName -Raw
        $html | Should -Not -Match '<script>alert'
        $html | Should -Match '&lt;script&gt;'
        $html | Should -Match 'À faire à la main'
        $html | Should -Match 'Récupérer le matériel'
        $html | Should -Not -Match 'https?://'
    }
}
