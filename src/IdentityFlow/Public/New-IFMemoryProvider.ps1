function New-IFMemoryProvider {
    <#
    .SYNOPSIS
        Annuaire de démonstration et de test, en mémoire (et éventuellement sauvegardé en JSON).

    .DESCRIPTION
        Se comporte comme un petit Active Directory : OU, groupes, managers, comptes
        activés ou non. Sert à tester un fichier RH et des règles sans toucher à la
        production, et à faire tourner les tests automatisés.

    .PARAMETER Path
        Fichier JSON de l'annuaire : chargé s'il existe, réécrit après chaque exécution.

    .PARAMETER Groups
        Groupes existants (si l'annuaire est vide).

    .EXAMPLE
        $dir = New-IFMemoryProvider -Path .\annuaire-demo.json
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [string[]] $Groups = @()
    )

    if ($Path) { $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path) }
    $store = @{
        Users  = New-Object 'System.Collections.Generic.Dictionary[string,hashtable]' ([System.StringComparer]::OrdinalIgnoreCase)
        Groups = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    }
    foreach ($g in $Groups) { [void]$store.Groups.Add($g) }

    if ($Path -and (Test-Path -LiteralPath $Path)) {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($g in @($json.groups)) { if ($g) { [void]$store.Groups.Add([string]$g) } }
        foreach ($u in @($json.users)) {
            if (-not $u) { continue }
            $h = @{}
            foreach ($p in $u.PSObject.Properties) { $h[$p.Name] = $p.Value }
            $h.Groups = New-Object 'System.Collections.Generic.List[string]'
            foreach ($g in @($u.Groups)) { if ($g) { $h.Groups.Add([string]$g) } }
            foreach ($k in @('Enabled', 'HiddenFromAddressList', 'MustChangePassword')) { $h[$k] = [bool]$h[$k] }
            $store.Users[[string]$h.Login] = $h
        }
    }

    $p = [pscustomobject]@{
        PSTypeName          = 'IdentityFlow.Provider'
        Name                = 'Démonstration (en mémoire)'
        SupportsOU          = $true
        SupportsHideFromGal = $true
        SupportsRevoke      = $false
        Store               = $store
        Path                = $Path
    }

    $need = {
        param($self, [string] $login)
        if (-not $self.Store.Users.ContainsKey($login)) { throw "Compte introuvable : $login" }
        return $self.Store.Users[$login]
    }
    $p | Add-Member -MemberType NoteProperty -Name Need -Value $need

    $p | Add-Member ScriptMethod ToUser {
        param([hashtable] $h)
        if ($null -eq $h) { return $null }
        [pscustomobject]@{
            Login                 = $h.Login
            Upn                   = $h.Upn
            Mail                  = $h.Mail
            DisplayName           = $h.DisplayName
            GivenName             = $h.GivenName
            Surname               = $h.Surname
            EmployeeId            = $h.EmployeeId
            Title                 = $h.Title
            Department            = $h.Department
            Office                = $h.Office
            Company               = $h.Company
            OU                    = $h.OU
            Enabled               = [bool]$h.Enabled
            ManagerLogin          = $h.ManagerLogin
            Groups                = @($h.Groups | Sort-Object)
            Description           = $h.Description
            AccountExpires        = if ($h.AccountExpires) { [datetime]$h.AccountExpires } else { $null }
            HiddenFromAddressList = [bool]$h.HiddenFromAddressList
        }
    }
    $p | Add-Member ScriptMethod FindByEmployeeId {
        param([string] $id)
        foreach ($u in $this.Store.Users.Values) {
            if ([string]$u.EmployeeId -eq $id) { return $this.ToUser($u) }
        }
        return $null
    }
    $p | Add-Member ScriptMethod GetUser {
        param([string] $login)
        if ($this.Store.Users.ContainsKey($login)) { return $this.ToUser($this.Store.Users[$login]) }
        return $null
    }
    $p | Add-Member ScriptMethod LoginExists {
        param([string] $login)
        if ($this.Store.Users.ContainsKey($login)) { return $true }
        foreach ($u in $this.Store.Users.Values) {
            if (([string]$u.Upn).Split('@')[0] -eq $login) { return $true }
        }
        return $false
    }
    $p | Add-Member ScriptMethod NewUser {
        param([hashtable] $d, [securestring] $password)
        if ($this.LoginExists($d['Login'])) { throw "Le compte $($d['Login']) existe déjà." }
        $u = @{
            Login = $d['Login']; Upn = $d['Upn']; Mail = $d['Mail']; DisplayName = $d['DisplayName']
            GivenName = $d['GivenName']; Surname = $d['Surname']; EmployeeId = $d['EmployeeId']
            Title = $d['Title']; Department = $d['Department']; Office = $d['Office']; Company = $d['Company']
            OU = $d['OU']; Enabled = $true; ManagerLogin = $null; Description = $null
            AccountExpires = if ($d['AccountExpires']) { ([datetime]$d['AccountExpires']).ToString('s') } else { $null }
            HiddenFromAddressList = $false; MustChangePassword = $true
            PasswordSetAt = (Get-Date).ToString('s')
            Groups = New-Object 'System.Collections.Generic.List[string]'
        }
        $this.Store.Users[$d['Login']] = $u
    }
    $p | Add-Member ScriptMethod SetAttribute {
        param([string] $login, [string] $name, $value)
        $u = & $this.Need $this $login
        if ($name -eq 'AccountExpires' -and $value) { $value = ([datetime]$value).ToString('s') }
        $u[$name] = $value
    }
    $p | Add-Member ScriptMethod MoveUser {
        param([string] $login, [string] $ou)
        $u = & $this.Need $this $login
        $u.OU = $ou
    }
    $p | Add-Member ScriptMethod AddToGroup {
        param([string] $login, [string] $group)
        $u = & $this.Need $this $login
        if (-not $this.Store.Groups.Contains($group)) { throw "Groupe introuvable : $group" }
        if (-not ($u.Groups -contains $group)) { $u.Groups.Add($group) }
    }
    $p | Add-Member ScriptMethod RemoveFromGroup {
        param([string] $login, [string] $group)
        $u = & $this.Need $this $login
        [void]$u.Groups.Remove($group)
    }
    $p | Add-Member ScriptMethod SetManager {
        param([string] $login, [string] $managerLogin)
        $u = & $this.Need $this $login
        if ($managerLogin) { [void](& $this.Need $this $managerLogin) }
        $u.ManagerLogin = $managerLogin
    }
    $p | Add-Member ScriptMethod SetEnabled {
        param([string] $login, [bool] $enabled)
        $u = & $this.Need $this $login
        $u.Enabled = $enabled
    }
    $p | Add-Member ScriptMethod ResetPassword {
        param([string] $login, [securestring] $password, [bool] $mustChange)
        $u = & $this.Need $this $login
        if ($null -eq $password -or $password.Length -lt 12) { throw 'Mot de passe refusé par la politique (12 caractères minimum).' }
        $u.PasswordSetAt = (Get-Date).ToString('s')
        $u.MustChangePassword = $mustChange
    }
    $p | Add-Member ScriptMethod RevokeSessions { param([string] $login) [void](& $this.Need $this $login) }
    $p | Add-Member ScriptMethod RemoveUser {
        param([string] $login)
        [void](& $this.Need $this $login)
        foreach ($u in $this.Store.Users.Values) { if ($u.ManagerLogin -eq $login) { $u.ManagerLogin = $null } }
        [void]$this.Store.Users.Remove($login)
    }
    $p | Add-Member ScriptMethod GetUsersInOU {
        param([string] $ou)
        foreach ($u in @($this.Store.Users.Values)) { if ($u.OU -eq $ou) { $this.ToUser($u) } }
    }
    $p | Add-Member ScriptMethod Save {
        if (-not $this.Path) { return }
        $users = foreach ($u in $this.Store.Users.Values) {
            $copy = [ordered]@{}
            foreach ($k in ($u.Keys | Sort-Object)) {
                if ($k -eq 'Groups') { $copy[$k] = @($u.Groups | Sort-Object) } else { $copy[$k] = $u[$k] }
            }
            [pscustomobject]$copy
        }
        $doc = [pscustomobject]@{ groups = @($this.Store.Groups | Sort-Object); users = @($users | Sort-Object Login) }
        $json = ConvertTo-Json -InputObject $doc -Depth 6
        [System.IO.File]::WriteAllText($this.Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $p
}
