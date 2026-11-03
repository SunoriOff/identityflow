# Connecteurs AD et Entra ID : les cmdlets Microsoft sont remplacées par des simulations
# (Mock), ce qui permet de vérifier les appels sans contrôleur de domaine ni tenant.

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    Import-Module ([System.IO.Path]::Combine($root, 'src', 'IdentityFlow', 'IdentityFlow.psd1')) -Force

    # Fonctions vides si les modules ActiveDirectory / Microsoft.Graph ne sont pas installés.
    $stubs = @(
        'Get-ADUser', 'Get-ADObject', 'New-ADUser', 'Set-ADUser', 'Move-ADObject', 'Add-ADGroupMember', 'Remove-ADGroupMember',
        'Enable-ADAccount', 'Disable-ADAccount', 'Set-ADAccountPassword', 'Remove-ADUser', 'Set-ADAccountExpiration', 'Clear-ADAccountExpiration',
        'Get-MgUser', 'Get-MgGroup', 'Get-MgUserMemberOf', 'Get-MgUserManager', 'New-MgUser', 'Update-MgUser', 'New-MgGroupMember',
        'Remove-MgGroupMemberDirectoryObjectByRef', 'Set-MgUserManagerByRef', 'Remove-MgUserManagerByRef', 'Revoke-MgUserSignInSession', 'Remove-MgUser'
    )
    # Signature commune : les filtres des simulations lisent ces paramètres par leur nom.
    $stubBody = {
        [CmdletBinding(SupportsShouldProcess)]
        param(
            $Filter, $Identity, $Properties, $Property, $Server, $Credential, $SearchBase, $SearchScope,
            $Name, $SamAccountName, $UserPrincipalName, $EmailAddress, $GivenName, $Surname, $DisplayName, $EmployeeID,
            $Path, $AccountPassword, $ChangePasswordAtLogon, $Enabled, $Title, $Department, $Office, $Company,
            $AccountExpirationDate, $Clear, $Replace, $Manager, $TargetPath, $Members, [switch] $Reset, $NewPassword, $DateTime,
            $BodyParameter, $UserId, $GroupId, $DirectoryObjectId, [switch] $AccountEnabled, $PasswordProfile,
            $ConsistencyLevel, $CountVariable, [switch] $All
        )
    }
    foreach ($s in $stubs) {
        if (-not (Get-Command $s -ErrorAction SilentlyContinue)) {
            Set-Item -Path "function:global:$s" -Value $stubBody
        }
    }

    $script:FakeAdUser = [pscustomobject]@{
        SamAccountName    = 'julien.dupont'
        UserPrincipalName = 'julien.dupont@exemple.fr'
        mail              = 'julien.dupont@exemple.fr'
        DisplayName       = 'Julien DUPONT'
        GivenName         = 'Julien'
        Surname           = 'DUPONT'
        EmployeeID        = 'E1031'
        Title             = 'Commercial'
        Department        = 'Commercial'
        Office            = 'Lille'
        Company           = 'Exemple SA'
        Enabled           = $true
        Description       = $null
        AccountExpirationDate = $null
        Manager           = 'CN=Claire MARTIN,OU=Direction,OU=Utilisateurs,DC=exemple,DC=local'
        MemberOf          = @('CN=GG-CRM,OU=Groupes,DC=exemple,DC=local', 'CN=Ventes\, Ouest,OU=Groupes,DC=exemple,DC=local')
        DistinguishedName = 'CN=Julien DUPONT,OU=Commercial,OU=Utilisateurs,DC=exemple,DC=local'
    }
}

Describe 'Connecteur Active Directory' {
    BeforeEach {
        $ad = New-IFADProvider -Server 'dc01.exemple.local'
    }

    It 'traduit un compte AD (OU, groupes avec virgule échappée, manager)' {
        Mock -ModuleName IdentityFlow Get-ADUser { $script:FakeAdUser } -ParameterFilter { $Filter }
        Mock -ModuleName IdentityFlow Get-ADUser { [pscustomobject]@{ SamAccountName = 'claire.martin' } } -ParameterFilter { $Identity }
        $u = $ad.FindByEmployeeId('E1031')
        $u.Login | Should -Be 'julien.dupont'
        $u.OU | Should -Be 'OU=Commercial,OU=Utilisateurs,DC=exemple,DC=local'
        $u.Groups | Should -Be @('GG-CRM', 'Ventes, Ouest')
        $u.ManagerLogin | Should -Be 'claire.martin'
        Should -Invoke -ModuleName IdentityFlow Get-ADUser -ParameterFilter { $Filter -eq "EmployeeID -eq 'E1031'" -and $Server -eq 'dc01.exemple.local' } -Times 1 -Exactly
    }

    It 'échappe les apostrophes dans les filtres' {
        Mock -ModuleName IdentityFlow Get-ADObject { $null }
        $ad.LoginExists("o'neil") | Should -BeFalse
        Should -Invoke -ModuleName IdentityFlow Get-ADObject -ParameterFilter { $Filter -like "*SamAccountName -eq 'o''neil'*" }
    }

    It 'signale un matricule porté par plusieurs comptes' {
        Mock -ModuleName IdentityFlow Get-ADUser { $script:FakeAdUser; $script:FakeAdUser }
        { $ad.FindByEmployeeId('E1031') } | Should -Throw '*porté par 2 comptes*'
    }

    It 'crée le compte avec mot de passe à changer, dans la bonne OU' {
        Mock -ModuleName IdentityFlow New-ADUser { }
        $pw = ConvertTo-SecureString 'Xy7!secretTest99' -AsPlainText -Force
        $ad.NewUser(@{
                Login = 'lea.moreau'; Upn = 'lea.moreau@exemple.fr'; Mail = 'lea.moreau@exemple.fr'; DisplayName = 'Léa MOREAU'
                GivenName = 'Léa'; Surname = 'MOREAU'; EmployeeId = 'E1103'; Title = 'Assistante RH'; Department = 'Ressources humaines'
                Office = 'Nantes'; Company = 'Exemple SA'; OU = 'OU=RH,OU=Utilisateurs,DC=exemple,DC=local'; AccountExpires = [datetime]'2028-09-01'
            }, $pw)
        Should -Invoke -ModuleName IdentityFlow New-ADUser -Times 1 -Exactly -ParameterFilter {
            $SamAccountName -eq 'lea.moreau' -and $Path -eq 'OU=RH,OU=Utilisateurs,DC=exemple,DC=local' -and
            $ChangePasswordAtLogon -eq $true -and $Enabled -eq $true -and $EmployeeID -eq 'E1103' -and
            $AccountExpirationDate -eq [datetime]'2028-09-01' -and $AccountPassword -is [securestring]
        }
    }

    It 'vide un attribut au lieu d''écrire une chaîne vide' {
        Mock -ModuleName IdentityFlow Set-ADUser { }
        $ad.SetAttribute('thomas.petit', 'Description', $null)
        Should -Invoke -ModuleName IdentityFlow Set-ADUser -ParameterFilter { $Clear -eq 'Description' }
        $ad.SetAttribute('thomas.petit', 'Title', 'Chef d''équipe')
        Should -Invoke -ModuleName IdentityFlow Set-ADUser -ParameterFilter { $Title -eq 'Chef d''équipe' }
    }

    It 'gère l''expiration du compte avec les cmdlets dédiées' {
        Mock -ModuleName IdentityFlow Set-ADAccountExpiration { }
        Mock -ModuleName IdentityFlow Clear-ADAccountExpiration { }
        $ad.SetAttribute('x', 'AccountExpires', [datetime]'2027-01-01')
        $ad.SetAttribute('x', 'AccountExpires', $null)
        Should -Invoke -ModuleName IdentityFlow Set-ADAccountExpiration -Times 1 -Exactly
        Should -Invoke -ModuleName IdentityFlow Clear-ADAccountExpiration -Times 1 -Exactly
    }

    It 'désactive, retire des groupes sans confirmation et réinitialise le mot de passe' {
        Mock -ModuleName IdentityFlow Disable-ADAccount { }
        Mock -ModuleName IdentityFlow Remove-ADGroupMember { }
        Mock -ModuleName IdentityFlow Set-ADAccountPassword { }
        Mock -ModuleName IdentityFlow Set-ADUser { }
        $ad.SetEnabled('thomas.petit', $false)
        $ad.RemoveFromGroup('thomas.petit', 'GG-Tous')
        $ad.ResetPassword('thomas.petit', (ConvertTo-SecureString 'Xy7!secretTest99' -AsPlainText -Force), $false)
        Should -Invoke -ModuleName IdentityFlow Disable-ADAccount -ParameterFilter { $Identity -eq 'thomas.petit' }
        Should -Invoke -ModuleName IdentityFlow Remove-ADGroupMember -ParameterFilter { $Identity -eq 'GG-Tous' -and $Members -eq 'thomas.petit' }
        Should -Invoke -ModuleName IdentityFlow Set-ADAccountPassword -ParameterFilter { $Reset }
        Should -Invoke -ModuleName IdentityFlow Set-ADUser -ParameterFilter { $ChangePasswordAtLogon -eq $false }
    }

    It 'ne déclare le masquage Exchange que si demandé' {
        $ad.SupportsHideFromGal | Should -BeFalse
        (New-IFADProvider -ExchangeAttributes).SupportsHideFromGal | Should -BeTrue
    }
}

Describe 'Connecteur Entra ID' {
    BeforeEach { $g = New-IFGraphProvider }

    It 'crée l''utilisateur avec changement de mot de passe forcé et pays d''utilisation' {
        Mock -ModuleName IdentityFlow New-MgUser { }
        $g.NewUser(@{ Login = 'lea.moreau'; Upn = 'lea.moreau@exemple.fr'; DisplayName = 'Léa MOREAU'; GivenName = 'Léa'; Surname = 'MOREAU'; EmployeeId = 'E1103'; Department = 'RH' },
            (ConvertTo-SecureString 'Xy7!secretTest99' -AsPlainText -Force))
        Should -Invoke -ModuleName IdentityFlow New-MgUser -ParameterFilter {
            $BodyParameter.mailNickname -eq 'lea.moreau' -and $BodyParameter.passwordProfile.forceChangePasswordNextSignIn -and
            $BodyParameter.usageLocation -eq 'FR' -and $BodyParameter.department -eq 'RH' -and $BodyParameter.passwordProfile.password -eq 'Xy7!secretTest99'
        }
    }

    It 'révoque les sessions au départ et n''a pas d''OU' {
        Mock -ModuleName IdentityFlow Get-MgUser { [pscustomobject]@{ Id = 'abc-123' } }
        Mock -ModuleName IdentityFlow Revoke-MgUserSignInSession { }
        $g.SupportsOU | Should -BeFalse
        $g.SupportsRevoke | Should -BeTrue
        $g.RevokeSessions('thomas.petit')
        Should -Invoke -ModuleName IdentityFlow Revoke-MgUserSignInSession -ParameterFilter { $UserId -eq 'abc-123' }
    }

    It 'refuse un groupe ambigu' {
        Mock -ModuleName IdentityFlow Get-MgGroup { [pscustomobject]@{ Id = '1' }; [pscustomobject]@{ Id = '2' } }
        Mock -ModuleName IdentityFlow Get-MgUser { [pscustomobject]@{ Id = 'abc' } }
        { $g.AddToGroup('x', 'GG-Tous') } | Should -Throw '*ambigu*'
    }

    It 'refuse la purge, inutile dans Entra ID' {
        { $g.GetUsersInOU('x') } | Should -Throw '*corbeille*'
    }
}

Describe 'Plan avec un connecteur sans OU' {
    It 'ne propose pas de déplacement et reporte le masquage dans la liste manuelle' {
        $root = Split-Path -Parent $PSScriptRoot
        $rules = Import-IFRules -Path ([System.IO.Path]::Combine($root, 'examples', 'regles.psd1'))
        $dir = New-IFMemoryProvider -Path ([System.IO.Path]::Combine($root, 'examples', 'annuaire-demo.json'))
        $dir.SupportsOU = $false
        $dir.SupportsHideFromGal = $false
        $dir.Path = $null
        $csv = Join-Path $TestDrive 'd.csv'
        Set-Content $csv @('Action;Matricule;DateEffet', 'Départ;E1045;2026-10-31') -Encoding UTF8
        $plan = Import-IFRequest $csv | Get-IFPlan -Rules $rules -Provider $dir -AsOf ([datetime]'2026-11-03')
        $plan.Steps.Op | Should -Not -Contain 'Move'
        $plan.Checklist | Should -Contain 'Masquer le compte de la liste d''adresses globale (Exchange)'
    }
}
