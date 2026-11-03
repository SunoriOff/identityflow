function New-IFReport {
    <#
    .SYNOPSIS
        Compte rendu HTML d'une exécution : à transmettre au service RH, au manager ou à l'audit.

    .DESCRIPTION
        Fichier autonome (aucune ressource externe). Les mots de passe temporaires n'y
        figurent jamais. La liste « À faire à la main » regroupe les actions qui restent
        humaines (matériel, boîte aux lettres…), par personne.

    .EXAMPLE
        $result | New-IFReport -Path .\rapports\2026-11-03.html
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Result,
        [Parameter(Mandatory)][string] $Path,
        [string] $Title = 'IdentityFlow — compte rendu',
        [string] $ProviderName = ''
    )
    begin { $all = New-Object System.Collections.Generic.List[object] }
    process { foreach ($r in @($Result)) { $all.Add($r) } }
    end {
        $h = { param($t) ConvertTo-IFHtml $t }
        $stateLabel = @{
            Done = 'Appliqué'; Failed = 'Échec'; WhatIf = 'Simulation'; UpToDate = 'Déjà à jour'
            Scheduled = 'Planifié'; Invalid = 'Rejeté'; Pending = 'À appliquer'
        }
        $stepIcon = @{ Done = '✓'; Failed = '✗'; Skipped = '↷'; WhatIf = '○'; Planned = '○' }
        $count = { param($f) @($all | Where-Object $f).Count }
        $isSim = (& $count { $_.State -eq 'WhatIf' }) -gt 0 -and (& $count { $_.State -eq 'Done' }) -eq 0
        $runId = ($all | Where-Object { $_.PSObject.Properties['RunId'] } | Select-Object -First 1).RunId

        $cards = @(
            @('Arrivées', (& $count { $_.Action -eq 'Arrivee' }), 'a'),
            @('Mobilités', (& $count { $_.Action -eq 'Mobilite' }), 'm'),
            @('Départs', (& $count { $_.Action -eq 'Depart' }), 'd'),
            @($(if ($isSim) { 'Simulés' } else { 'Appliqués' }), (& $count { $_.State -in 'Done', 'WhatIf' }), 'ok'),
            @('Planifiés', (& $count { $_.State -eq 'Scheduled' }), 'sch'),
            @('Erreurs', (& $count { $_.State -in 'Failed', 'Invalid' }), 'ko')
        )

        $sb = New-Object System.Text.StringBuilder
        $null = $sb.Append(@"
<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $h $Title)</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--line:#e3e6eb;--tx:#1c2430;--dim:#5d6b7c;--ok:#1a7f37;--ko:#cf222e;--warn:#9a6700;--acc:#0b6bcb}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:14px/1.5 "Segoe UI",system-ui,sans-serif}
header{background:#14213d;color:#fff;padding:24px 32px}header h1{margin:0 0 4px;font-size:22px}header p{margin:0;color:#c8d1e0}
.sim{display:inline-block;margin-top:10px;background:#ffd166;color:#3a2a00;padding:3px 10px;border-radius:99px;font-weight:600;font-size:12px}
main{max-width:1100px;margin:0 auto;padding:24px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:24px}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px}.card b{display:block;font-size:26px}.card span{color:var(--dim)}
.card.ko b{color:var(--ko)}.card.ok b{color:var(--ok)}.card.sch b{color:var(--warn)}
h2{font-size:16px;margin:28px 0 10px}
.todo{background:#fff8e1;border:1px solid #f0d58c;border-radius:10px;padding:12px 18px}.todo ul{margin:6px 0 0;padding-left:18px}
.p{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 18px;margin-bottom:10px}
.p header{all:unset;display:flex;flex-wrap:wrap;gap:10px;align-items:baseline}
.p h3{margin:0;font-size:15px}.meta{color:var(--dim);font-size:13px}
.pill{font-size:12px;font-weight:600;padding:2px 9px;border-radius:99px;background:#eef1f5;color:var(--dim)}
.pill.Arrivee{background:#e6f4ea;color:var(--ok)}.pill.Mobilite{background:#e7f0fb;color:var(--acc)}.pill.Depart{background:#fdecea;color:var(--ko)}
.st{margin-left:auto}.st.Done{color:var(--ok)}.st.Failed,.st.Invalid{color:var(--ko)}.st.Scheduled{color:var(--warn)}
ul.steps{list-style:none;margin:8px 0 0;padding:0}ul.steps li{padding:2px 0}
.i{display:inline-block;width:18px;font-weight:700}.i.Done{color:var(--ok)}.i.Failed{color:var(--ko)}.i.Skipped,.i.WhatIf,.i.Planned{color:var(--dim)}
.err{color:var(--ko);margin:6px 0 0}.msg{color:var(--dim);margin:6px 0 0}
footer{color:var(--dim);font-size:12px;text-align:center;padding:24px}
</style></head><body>
<header><h1>$(& $h $Title)</h1>
<p>$(& $h ((Get-Date).ToString('dddd d MMMM yyyy à HH:mm', [System.Globalization.CultureInfo]::GetCultureInfo('fr-FR')))) · opérateur $(& $h (Get-IFOperator))$(if ($ProviderName) { ' · ' + (& $h $ProviderName) })$(if ($runId) { ' · exécution ' + (& $h $runId) })</p>
$(if ($isSim) { '<span class="sim">SIMULATION : aucune modification n''a été faite</span>' })
</header><main>
<section class="cards">
"@)
        foreach ($c in $cards) { $null = $sb.AppendFormat('<div class="card {2}"><b>{1}</b><span>{0}</span></div>', $c[0], $c[1], $c[2]) }
        $null = $sb.Append('</section>')

        $todo = @($all | Where-Object { $_.Checklist.Count -gt 0 -and $_.State -in 'Done', 'WhatIf' })
        if ($todo.Count) {
            $null = $sb.Append('<h2>À faire à la main</h2><div class="todo">')
            foreach ($r in $todo) {
                $null = $sb.AppendFormat('<p><b>{0}</b> ({1}, {2})</p><ul>', (& $h $r.Name), (& $h $r.ActionLabel), (& $h $r.Login))
                foreach ($c in $r.Checklist) { $null = $sb.AppendFormat('<li>☐ {0}</li>', (& $h $c)) }
                $null = $sb.Append('</ul>')
            }
            $null = $sb.Append('</div>')
        }

        $null = $sb.Append('<h2>Détail par personne</h2>')
        foreach ($r in ($all | Sort-Object Line)) {
            $st = [string]$r.State
            $label = if ($stateLabel.ContainsKey($st)) { $stateLabel[$st] } else { $st }
            $null = $sb.AppendFormat('<article class="p"><header><span class="pill {0}">{1}</span><h3>{2}</h3><span class="meta">matricule {3}{4} · ligne {5}</span><span class="st {6}">{7}</span></header>',
                (& $h $r.Action), (& $h $r.ActionLabel), (& $h $(if ($r.Name) { $r.Name } else { '—' })), (& $h $r.EmployeeId),
                $(if ($r.Login) { ' · ' + (& $h $r.Login) } else { '' }), $r.Line, (& $h $st), (& $h $label))
            if ($r.Steps.Count) {
                $null = $sb.Append('<ul class="steps">')
                foreach ($s in $r.Steps) {
                    $o = [string]$s.Outcome
                    $null = $sb.AppendFormat('<li><span class="i {0}">{1}</span>{2}{3}</li>', $o, $stepIcon[$o], (& $h $s.Text),
                        $(if ($s.Error) { ' — <span class="err">' + (& $h $s.Error) + '</span>' } else { '' }))
                }
                $null = $sb.Append('</ul>')
            }
            foreach ($e in $r.Errors) { $null = $sb.AppendFormat('<p class="err">{0}</p>', (& $h $e)) }
            foreach ($m in $r.Messages) { $null = $sb.AppendFormat('<p class="msg">{0}</p>', (& $h $m)) }
            $null = $sb.Append('</article>')
        }
        $null = $sb.Append('</main><footer>Généré par IdentityFlow. Les mots de passe temporaires ne figurent pas dans ce rapport.</footer></body></html>')

        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $dir = [System.IO.Path]::GetDirectoryName($full)
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force -WhatIf:$false -Confirm:$false) }
        [System.IO.File]::WriteAllText($full, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Get-Item -LiteralPath $full
    }
}
