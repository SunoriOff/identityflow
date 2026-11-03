function Write-IFAudit {
    <#
    .SYNOPSIS
        Ajoute une ligne JSON au journal d'audit (une ligne par étape, jamais de mot de passe).
    #>
    [CmdletBinding()]
    param(
        [string] $Path,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Record
    )
    if (-not $Path) { return }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false) }
    $clean = [ordered]@{}
    foreach ($k in $Record.Keys) {
        $v = $Record[$k]
        if ($v -is [securestring]) { continue }
        if ($v -is [System.Collections.IDictionary]) {
            $h = [ordered]@{}
            foreach ($kk in $v.Keys) {
                $vv = $v[$kk]
                if ($vv -is [securestring]) { continue }
                if ($vv -is [datetime]) { $vv = $vv.ToString('s') }
                $h[$kk] = $vv
            }
            $v = $h
        }
        elseif ($v -is [datetime]) { $v = $v.ToString('s') }
        $clean[$k] = $v
    }
    $line = (ConvertTo-Json -InputObject ([pscustomobject]$clean) -Depth 5 -Compress) + [Environment]::NewLine
    [System.IO.File]::AppendAllText($Path, $line, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-IFAudit {
    <# Relit un journal (fichier .jsonl) ou tous les journaux d'un dossier. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    $files = if (Test-Path -LiteralPath $Path -PathType Container) {
        Get-ChildItem -LiteralPath $Path -Filter '*.jsonl' -File | Sort-Object Name
    }
    elseif (Test-Path -LiteralPath $Path) { Get-Item -LiteralPath $Path }
    else { throw "Journal introuvable : $Path" }
    foreach ($f in $files) {
        foreach ($l in [System.IO.File]::ReadAllLines($f.FullName)) {
            if ($l.Trim()) { $l | ConvertFrom-Json }
        }
    }
}

function Get-IFOperator {
    if ($env:USERDOMAIN -and $env:USERNAME) { return "$env:USERDOMAIN\$env:USERNAME" }
    if ($env:USERNAME) { return $env:USERNAME }
    if ($env:USER) { return $env:USER }
    return [System.Environment]::UserName
}

function Invoke-IFStep {
    <# Exécute une étape sur le connecteur. Renvoie le mot de passe temporaire éventuel. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Step, [Parameter(Mandatory)] $Provider, [int] $PasswordLength = 16)
    $p = $Step.Params
    switch ($Step.Op) {
        'Create' {
            $pw = New-IFPassword -Length $PasswordLength
            $Provider.NewUser($p, $pw)
            return $pw
        }
        'AddGroup' { $Provider.AddToGroup($p.Login, $p.Group) }
        'RemoveGroup' { $Provider.RemoveFromGroup($p.Login, $p.Group) }
        'SetAttribute' { $Provider.SetAttribute($p.Login, $p.Name, $p.New) }
        'Move' { $Provider.MoveUser($p.Login, $p.To) }
        'SetManager' { $Provider.SetManager($p.Login, $p.New) }
        'Enable' { $Provider.SetEnabled($p.Login, $true) }
        'Disable' { $Provider.SetEnabled($p.Login, $false) }
        'Revoke' { $Provider.RevokeSessions($p.Login) }
        'ResetPassword' {
            $pw = New-IFPassword -Length $PasswordLength
            $Provider.ResetPassword($p.Login, $pw, [bool]$p.MustChange)
            if ($p.MustChange) { return $pw }
        }
        'Remove' { $Provider.RemoveUser($p.Login) }
        default { throw "Opération inconnue : $($Step.Op)" }
    }
    return $null
}
