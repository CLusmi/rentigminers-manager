<#
  Salad-Switch-Log : gestion des groupes et machines SaladCloud.
  Salad-Switch-Log: manage your SaladCloud container groups and machines.
    1. Voir mes groupes                          / View my groups
    2. Voir les machines d'un groupe              / View the machines of a group
    3. Modifier un groupe                         / Edit a group (image tag, replicas, watchdog, priority, miner)
    4. Réallouer / recréer / redémarrer           / Reallocate / recreate / restart machines
    5. Logs en direct                             / Live logs
    6. Démarrer / arrêter un groupe               / Start / stop a group
    7. Cartes : prix et disponibilité             / GPUs: prices and availability
    8. Clés API Salad                             / Salad API keys
    S. Solde Salad (saisi, ou portail), autonomie  / Salad balance (entered, or portal), remaining time
    P. Pool : mon portefeuille HeroMiners / unMineable / Pool: my wallet
    9. Quitter                                    / Quit

  Windows : double-clic sur salad-switch-log.bat (Windows PowerShell 5.1 ou PowerShell 7).
  macOS   : double-clic sur salad-switch-log.command (PowerShell 7, « pwsh », requis).
  Langue  : celle du système (français -> français, sinon anglais) ; -Language fr|en pour forcer.

  Le script parle directement à l'API SaladCloud (https://api.salad.com) :
    lecture des groupes, machines, logs, quotas, classes GPU et disponibilité ;
    modification d'un groupe (image, replicas, variables, priorité) ;
    start / stop d'un groupe ; reallocate / recreate / restart d'une machine.
  Il ne supprime jamais un groupe.  /  It never deletes a group.
  En plus, sans clé : cours du PRL (CoinGecko), réseau PRL (whattomine), rendement des pools
  unMineable et HeroMiners, ton portefeuille sur ces pools (menu P) ; et, si tu le demandes
  (menu S), le solde réel via le portail Salad (e-mail + mot de passe du compte).
#>
param(
    # Intervalle entre deux vérifications pendant le suivi d'un redéploiement ou d'une action.
    [ValidateRange(2, 300)][int]$PollSeconds = 5,
    # Durée maximale d'attente d'un redéploiement.
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600,
    # Intervalle de rafraîchissement des logs en direct (menu 5).
    [ValidateRange(3, 120)][int]$LogRefreshSeconds = 5,
    # Langue de l'affichage : auto (celle du système), fr ou en.
    [ValidateSet('auto', 'fr', 'en')][string]$Language = 'auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Pas de barre de progression pendant les appels HTTP.
$ProgressPreference = 'SilentlyContinue'

# --- Langue ---------------------------------------------------------------------------
$script:Lang = $Language
if ($script:Lang -eq 'auto') {
    $script:Lang = 'en'
    try { if ((Get-Culture).TwoLetterISOLanguageName -eq 'fr') { $script:Lang = 'fr' } } catch { }
}
# Format des nombres selon la langue affichée (et non selon le réglage de Windows) : en
# anglais 1,234.56 et $0.417 ; en français 1 234,56 et 0,417 $. Sinon un Windows réglé en
# allemand ou en néerlandais affiche « $9,795 /h » pour 9,795 $ /h.
try {
    $culture = 'en-US'
    if ($script:Lang -eq 'fr') { $culture = 'fr-FR' }
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
    [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($culture)
}
catch { }
# Texte dans la langue choisie : T 'texte français' 'English text'.
function T([string]$Fr, [string]$En) {
    if ($script:Lang -eq 'fr') { return $Fr }
    return $En
}

# --- Système --------------------------------------------------------------------------
# 'windows', 'mac' ou 'linux'. Windows PowerShell 5.1 ne connaît pas $IsWindows : c'est Windows.
$script:Os = 'windows'
if ($PSVersionTable.PSVersion.Major -ge 6) {
    if ($IsMacOS) { $script:Os = 'mac' }
    elseif ($IsLinux) { $script:Os = 'linux' }
}
# Surcharge réservée aux tests du script.
if ($env:SALAD_SWITCH_OS) { $script:Os = $env:SALAD_SWITCH_OS }

# Adresses de l'API Salad et de Docker Hub (modifiables seulement pour les tests du script).
$script:ApiBase = 'https://api.salad.com/api/public'
if ($env:SALAD_API_BASE) { $script:ApiBase = $env:SALAD_API_BASE.TrimEnd('/') }
$script:HubBase = 'https://hub.docker.com/v2'
if ($env:DOCKERHUB_API_BASE) { $script:HubBase = $env:DOCKERHUB_API_BASE.TrimEnd('/') }
# API interne du portail Salad (solde réel, menu S) ; cours et réseau du PRL.
$script:PortalBase = 'https://portal-api.salad.com/api/portal'
if ($env:SALAD_PORTAL_BASE) { $script:PortalBase = $env:SALAD_PORTAL_BASE.TrimEnd('/') }
$script:CoinGeckoBase = 'https://api.coingecko.com/api/v3'
if ($env:PRL_COINGECKO_BASE) { $script:CoinGeckoBase = $env:PRL_COINGECKO_BASE.TrimEnd('/') }
$script:WhatToMineBase = 'https://whattomine.com'
if ($env:PRL_WHATTOMINE_BASE) { $script:WhatToMineBase = $env:PRL_WHATTOMINE_BASE.TrimEnd('/') }
$script:UnmineableBase = 'https://api.unmineable.com'
if ($env:PRL_UNMINEABLE_BASE) { $script:UnmineableBase = $env:PRL_UNMINEABLE_BASE.TrimEnd('/') }
$script:HeroMinersBase = 'https://pearl.herominers.com'
if ($env:PRL_HEROMINERS_BASE) { $script:HeroMinersBase = $env:PRL_HEROMINERS_BASE.TrimEnd('/') }

# Clé active : { Key, Org, Project, Label }.
$script:Account = $null
# Code de sortie : 1 garde la fenêtre ouverte (voir les lanceurs) pour lire le message.
$script:ExitCode = 0
$script:LogLines = 100
# Classes GPU de l'organisation (id -> nom, prix), chargées une fois par session.
$script:GpuClasses = $null
# Client HTTP partagé pour les appels en parallèle (créé au premier besoin).
$script:HttpClient = $null
# Dernières lignes de logs lues par machine pendant la session (voir Get-MachineLogInfo).
$script:LogCache = $null
# Session ouverte sur le portail Salad (cookie), mot de passe gardé pour la session seulement,
# dernier solde lu { Amount, At }, dernière erreur du portail.
$script:PortalSession = $null
$script:PortalEmail = ''
$script:PortalPassword = ''
$script:PortalBalance = $null
$script:PortalError = ''
# Cours et réseau du PRL, gardés 5 min (voir Get-PearlMarket) ; rapports des pools, gardés 2 min.
$script:Market = $null
$script:Wallets = $null
# Hashrate loué vu au dernier affichage des machines (menu 2) : { Hps, At, Changed, Count } (facteurs des pools).
$script:LastFleet = $null
$script:FleetMenuLabel = 'menu 2'

$script:BorderColor = 'DarkCyan'
$script:AccentColor = 'Cyan'
# Largeur maximale des tableaux, cadres et séparateurs.
$script:MaxWidth = 132

# TLS 1.2 pour l'API (Windows PowerShell 5.1 ne l'active pas toujours de lui-même).
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch { }
# Lectures de logs en parallèle : Windows PowerShell n'ouvre que 2 connexions à la fois vers
# un même serveur par défaut, et attend un « 100-continue » avant d'envoyer chaque requête.
try {
    [Net.ServicePointManager]::DefaultConnectionLimit = 32
    [Net.ServicePointManager]::Expect100Continue = $false
}
catch { }

# === Affichage =====================================================================

function Get-ConsoleWidth {
    try {
        $width = $Host.UI.RawUI.WindowSize.Width
        if ($width -ge 60) { return $width }
    }
    catch { }
    return 120
}

# Largeur utilisable : 2 espaces de marge à gauche, 1 colonne libre à droite.
function Get-AvailableWidth { return [Math]::Min($script:MaxWidth, (Get-ConsoleWidth) - 3) }

function New-Cell([string]$Text, [string]$Fg = '', [string]$Bg = '') {
    if ($null -eq $Text) { $Text = '' }
    return [pscustomobject]@{ Text = $Text; Fg = $Fg; Bg = $Bg }
}

# Ligne "clé   valeur" d'un cadre ; la valeur passe à la ligne si elle est trop longue.
function New-KeyValue([string]$Key, [string]$Value, [int]$KeyWidth, [string]$KeyColor = 'DarkGray', [string]$ValueColor = 'White') {
    if ($null -eq $Value) { $Value = '' }
    return [pscustomobject]@{ Key = $Key; Value = $Value; KeyWidth = $KeyWidth; KeyColor = $KeyColor; ValueColor = $ValueColor }
}

function ConvertTo-Cell($Value) {
    if ($null -eq $Value) { return (New-Cell '') }
    if ($Value -is [string]) { return (New-Cell $Value) }
    return $Value
}

function Write-Segment([string]$Text, [string]$Fg = '', [string]$Bg = '') {
    if ($Text -eq '') { return }
    $params = @{ Object = $Text; NoNewline = $true }
    if ($Fg) { $params.ForegroundColor = $Fg }
    if ($Bg) { $params.BackgroundColor = $Bg }
    Write-Host @params
}

function Limit-Text([string]$Text, [int]$Width) {
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -le 1) { return $Text.Substring(0, [Math]::Max($Width, 0)) }
    return $Text.Substring(0, $Width - 1) + '…'
}

# Coupe un texte en lignes de $Width caractères au plus, entre les mots si possible.
function Split-Text([string]$Text, [int]$Width) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($Width -lt 1) { $Width = 1 }
    foreach ($paragraph in ($Text -split "`n")) {
        $current = ''
        foreach ($word in ($paragraph -split ' ')) {
            while ($word.Length -gt $Width) {
                if ($current -ne '') { $lines.Add($current); $current = '' }
                $lines.Add($word.Substring(0, $Width))
                $word = $word.Substring($Width)
            }
            if ($current -eq '') { $current = $word }
            elseif ($current.Length + 1 + $word.Length -le $Width) { $current += ' ' + $word }
            else { $lines.Add($current); $current = $word }
        }
        $lines.Add($current)
    }
    return , $lines.ToArray()
}

function Write-Ok([string]$Text)   { Write-Host "  $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host "  $Text" -ForegroundColor Red }
function Write-Dim([string]$Text)  { Write-Host "  $Text" -ForegroundColor DarkGray }

function Write-Banner {
    $parts = @(
        (New-Cell 'Salad-Switch-Log' 'White'),
        (New-Cell '  ·  ' $script:BorderColor),
        (New-Cell (T 'Gestion machines SaladCloud' 'SaladCloud machine manager') $script:AccentColor)
    )
    $length = 0
    foreach ($part in $parts) { $length += $part.Text.Length }
    $inner = $length + 6
    Write-Host ''
    Write-Host ('  ╔' + ('═' * $inner) + '╗') -ForegroundColor $script:AccentColor
    Write-Segment '  ║   ' $script:AccentColor
    foreach ($part in $parts) { Write-Segment $part.Text $part.Fg }
    Write-Host '   ║' -ForegroundColor $script:AccentColor
    Write-Host ('  ╚' + ('═' * $inner) + '╝') -ForegroundColor $script:AccentColor
}

# Séparateur avec titre : ── Titre ────────
function Write-Rule([string]$Title) {
    $width = Get-AvailableWidth
    Write-Host ''
    Write-Segment '  ── ' $script:BorderColor
    Write-Segment $Title $script:AccentColor
    Write-Host (' ' + ('─' * [Math]::Max(3, $width - 4 - $Title.Length))) -ForegroundColor $script:BorderColor
}

# Cadre avec titre. $Lines : textes, cellules, tableaux de cellules (plusieurs couleurs
# sur une ligne) ou lignes clé/valeur (New-KeyValue).
function Write-Box([string]$Title, $Lines, [int]$MinWidth = 52) {
    $items = New-Object System.Collections.ArrayList
    foreach ($line in $Lines) {
        if ($null -ne $line -and $line -isnot [array] -and $line.PSObject.Properties['Key']) { [void]$items.Add($line) }
        elseif ($line -is [array]) { [void]$items.Add(@($line | ForEach-Object { ConvertTo-Cell $_ })) }
        else { [void]$items.Add(@(ConvertTo-Cell $line)) }
    }
    $longest = 0
    foreach ($item in $items) {
        if ($item -isnot [array]) { $length = $item.KeyWidth + $item.Value.Length }
        else {
            $length = 0
            foreach ($segment in $item) { $length += $segment.Text.Length }
        }
        if ($length -gt $longest) { $longest = $length }
    }
    $width = [Math]::Max($MinWidth, [Math]::Max($Title.Length + 6, $longest + 5))
    $width = [Math]::Min($width, (Get-AvailableWidth))
    $content = $width - 5

    # Chaque élément devient une ou plusieurs lignes de segments qui tiennent dans le cadre.
    $rows = New-Object System.Collections.ArrayList
    foreach ($item in $items) {
        if ($item -isnot [array]) {
            $keyWidth = [Math]::Min($item.KeyWidth, [Math]::Max(1, $content - 10))
            $pieces = Split-Text $item.Value ($content - $keyWidth)
            for ($p = 0; $p -lt $pieces.Count; $p++) {
                $key = ' ' * $keyWidth
                if ($p -eq 0) { $key = (Limit-Text $item.Key ($keyWidth - 1)).PadRight($keyWidth) }
                [void]$rows.Add(@((New-Cell $key $item.KeyColor), (New-Cell $pieces[$p] $item.ValueColor)))
            }
        }
        elseif ($item.Count -eq 1) {
            foreach ($piece in (Split-Text $item[0].Text $content)) {
                [void]$rows.Add(@(New-Cell $piece $item[0].Fg $item[0].Bg))
            }
        }
        else { [void]$rows.Add($item) }
    }

    Write-Host ''
    Write-Segment '  ┌─ ' $script:BorderColor
    Write-Segment $Title $script:AccentColor
    Write-Host (' ' + ('─' * ($width - 5 - $Title.Length)) + '┐') -ForegroundColor $script:BorderColor
    foreach ($row in $rows) {
        Write-Segment '  │  ' $script:BorderColor
        $used = 0
        foreach ($segment in $row) {
            $text = Limit-Text $segment.Text ($content - $used)
            Write-Segment $text $segment.Fg $segment.Bg
            $used += $text.Length
        }
        Write-Segment (' ' * ($content - $used + 1))
        Write-Host '│' -ForegroundColor $script:BorderColor
    }
    Write-Host ('  └' + ('─' * ($width - 2)) + '┘') -ForegroundColor $script:BorderColor
}

function New-Column([string]$Title, [string]$Align = 'L', [int]$Min = 0, [int]$Max = 0, [bool]$Wrap = $false) {
    if ($Min -le 0) { $Min = $Title.Length }
    return [pscustomobject]@{ Title = $Title; Align = $Align; Min = $Min; Max = $Max; Wrap = $Wrap }
}

function Write-TableBorder($Widths, [string]$Left, [string]$Middle, [string]$Right) {
    $parts = foreach ($width in $Widths) { '─' * ($width + 2) }
    Write-Host ('  ' + $Left + ($parts -join $Middle) + $Right) -ForegroundColor $script:BorderColor
}

function Write-TableRow($Columns, $Widths, $Cells) {
    $cellLines = New-Object System.Collections.ArrayList
    $height = 1
    for ($c = 0; $c -lt $Columns.Count; $c++) {
        $cell = ConvertTo-Cell $Cells[$c]
        if ($Columns[$c].Wrap) { $pieces = Split-Text $cell.Text $Widths[$c] }
        else { $pieces = @(Limit-Text $cell.Text $Widths[$c]) }
        [void]$cellLines.Add($pieces)
        if ($pieces.Count -gt $height) { $height = $pieces.Count }
    }
    for ($l = 0; $l -lt $height; $l++) {
        Write-Segment '  │' $script:BorderColor
        for ($c = 0; $c -lt $Columns.Count; $c++) {
            $cell = ConvertTo-Cell $Cells[$c]
            $pieces = $cellLines[$c]
            $text = ''
            if ($l -lt $pieces.Count) { $text = $pieces[$l] }
            $padding = ' ' * ($Widths[$c] - $text.Length)
            Write-Segment ' '
            if ($Columns[$c].Align -eq 'R') { Write-Segment $padding; Write-Segment $text $cell.Fg $cell.Bg }
            else { Write-Segment $text $cell.Fg $cell.Bg; Write-Segment $padding }
            Write-Segment ' │' $script:BorderColor
        }
        Write-Host ''
    }
}

# Tableau à bordures. Les colonnes s'ajustent au contenu et rétrécissent si la fenêtre est étroite.
function Write-Table($Columns, $Rows) {
    $count = $Columns.Count
    $widths = New-Object int[] $count
    for ($c = 0; $c -lt $count; $c++) {
        $width = $Columns[$c].Title.Length
        foreach ($row in $Rows) {
            $length = (ConvertTo-Cell $row[$c]).Text.Length
            if ($length -gt $width) { $width = $length }
        }
        if ($Columns[$c].Max -gt 0 -and $width -gt $Columns[$c].Max) { $width = $Columns[$c].Max }
        $widths[$c] = $width
    }
    $available = Get-AvailableWidth
    $total = 1 + 3 * $count
    foreach ($width in $widths) { $total += $width }
    while ($total -gt $available) {
        $widest = -1
        for ($c = 0; $c -lt $count; $c++) {
            if ($widths[$c] -gt $Columns[$c].Min -and ($widest -lt 0 -or $widths[$c] -gt $widths[$widest])) { $widest = $c }
        }
        if ($widest -lt 0) { break }
        $widths[$widest]--
        $total--
    }
    $header = @(foreach ($column in $Columns) { New-Cell $column.Title 'White' })
    Write-TableBorder $widths '┌' '┬' '┐'
    Write-TableRow $Columns $widths $header
    Write-TableBorder $widths '├' '┼' '┤'
    foreach ($row in $Rows) { Write-TableRow $Columns $widths $row }
    Write-TableBorder $widths '└' '┴' '┘'
}

function New-Badge([string]$Level) {
    switch ($Level) {
        'ok'    { return (New-Cell '    OK     ' 'White' 'DarkGreen') }
        'warn'  { return (New-Cell (T ' ATTENTION ' '  WARNING  ') 'Black' 'Yellow') }
        default { return (New-Cell (T '  ERREUR   ' '   ERROR   ') 'White' 'DarkRed') }
    }
}

function Write-Step([string]$Text) {
    Write-Segment '  ► ' $script:AccentColor
    Write-Segment $Text
}

# === Saisie ========================================================================

function Read-Answer([string]$Prompt, [string]$Hint = '') {
    Write-Host ''
    if ($Hint) { Write-Dim $Hint }
    Write-Segment '  ► ' $script:AccentColor
    Write-Segment "$Prompt : " 'White'
    $answer = Read-Host
    if ($null -eq $answer) { return '' }
    return $answer.Trim()
}

function Confirm-Action([string]$Prompt) {
    while ($true) {
        $answer = (Read-Answer "$Prompt $(T '(o/n)' '(y/n)')").ToLowerInvariant()
        if (@('o', 'oui', 'y', 'yes') -contains $answer) { return $true }
        if (@('n', 'non', 'no', '') -contains $answer) { return $false }
    }
}

# Réponse du type "1", "1,3", "2-4" ou "T" : renvoie les index choisis (0 = première ligne).
function Read-Selection([int]$Count, [string]$Prompt, [string]$EmptyMeaning) {
    $hint = T "Exemples : 1   1,3   2-4   T = toutes   ·   Entrée sans rien = $EmptyMeaning" "Examples: 1   1,3   2-4   A = all   ·   Enter alone = $EmptyMeaning"
    while ($true) {
        $answer = Read-Answer $Prompt $hint
        if ($answer -eq '') { return , @() }
        if ($answer -match '^(t|tout|toutes|a|all|\*)$') { return , @(0..($Count - 1)) }
        $chosen = New-Object System.Collections.Generic.List[int]
        $valid = $true
        foreach ($part in ($answer -split '[,;\s]+')) {
            if ($part -eq '') { continue }
            if ($part -match '^(\d+)-(\d+)$') { $from = [int]$Matches[1]; $to = [int]$Matches[2] }
            elseif ($part -match '^\d+$') { $from = [int]$part; $to = $from }
            else { $valid = $false; break }
            if ($from -lt 1 -or $to -gt $Count -or $from -gt $to) { $valid = $false; break }
            foreach ($number in $from..$to) { if (-not $chosen.Contains($number - 1)) { $chosen.Add($number - 1) } }
        }
        if ($valid -and $chosen.Count -gt 0) { return , $chosen.ToArray() }
        Write-Warn (T "Réponse non comprise : choisis entre 1 et $Count." "Not understood: pick numbers between 1 and $Count.")
    }
}

# Un seul numéro entre 1 et $Count ; renvoie l'index (0 = premier) ou -1 si Entrée sans rien.
function Read-Index([int]$Count, [string]$Prompt, [string]$Hint) {
    while ($true) {
        $answer = Read-Answer $Prompt $Hint
        if ($answer -eq '') { return -1 }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Count) { return ([int]$answer - 1) }
        Write-Warn (T "Réponse non comprise : tape un numéro entre 1 et $Count." "Not understood: type a number between 1 and $Count.")
    }
}

function Format-Duration([int]$Seconds) {
    if ($Seconds % 60 -eq 0) { return "$($Seconds / 60) min" }
    return "$Seconds s"
}

function Format-Elapsed([datetime]$Since) {
    $elapsed = (Get-Date) - $Since
    return ('{0}:{1:00}' -f [int][Math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds)
}

function Format-Price($Value, [int]$Decimals = 3) {
    if ($null -eq $Value) { return '?' }
    if ($script:Lang -eq 'fr') { return (('{0:N' + $Decimals + '} $') -f [double]$Value) }
    return (('${0:N' + $Decimals + '}') -f [double]$Value)
}

# "il y a 25 min", "il y a 3 h", "il y a 2 j".
function Format-Ago($Date) {
    if ($null -eq $Date) { return '?' }
    try { $when = [datetime]$Date } catch { return '?' }
    $elapsed = (Get-Date) - $when.ToLocalTime()
    if ($elapsed.TotalSeconds -lt 60) { return (T 'à l''instant' 'just now') }
    if ($elapsed.TotalMinutes -lt 60) { return ((T 'il y a {0} min' '{0} min ago') -f [int][Math]::Floor($elapsed.TotalMinutes)) }
    if ($elapsed.TotalHours -lt 48) { return ((T 'il y a {0} h' '{0} h ago') -f [int][Math]::Floor($elapsed.TotalHours)) }
    return ((T 'il y a {0} j' '{0} d ago') -f [int][Math]::Floor($elapsed.TotalDays))
}

function Format-LocalTime($Date, [string]$Pattern = 'dd/MM HH:mm') {
    if ($null -eq $Date) { return '?' }
    try { return ([datetime]$Date).ToLocalTime().ToString($Pattern) } catch { return '?' }
}
# === Appels à l'API Salad ============================================================

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

# Texte d'erreur d'une exception d'appel HTTP : code + message de l'API s'il y en a un.
function Get-HttpError($ErrorRecord) {
    $exception = $ErrorRecord.Exception
    $status = 0
    $body = ''
    try {
        $response = $exception.Response
        if ($response) {
            $status = [int]$response.StatusCode
            if ($response.PSObject.Methods['GetResponseStream']) {
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
                $body = $reader.ReadToEnd()
                $reader.Close()
            }
        }
    }
    catch { }
    if (-not $body -and $ErrorRecord.ErrorDetails) { $body = [string]$ErrorRecord.ErrorDetails.Message }
    $detail = ''
    if ($body) {
        try {
            $json = ConvertFrom-Json -InputObject $body
            $detail = [string](Get-Prop $json 'detail')
            if (-not $detail) { $detail = [string](Get-Prop $json 'title') }
            if (-not $status -and (Get-Prop $json 'status')) { $status = [int](Get-Prop $json 'status') }
        }
        catch { $detail = $body.Trim() }
    }
    if ($status -eq 401) { return [pscustomobject]@{ Status = 401; Message = (T 'clé API refusée par Salad (401)' 'API key rejected by Salad (401)') } }
    if ($status -eq 403) { return [pscustomobject]@{ Status = 403; Message = (T "accès refusé par Salad (403) : $detail" "access denied by Salad (403): $detail") } }
    if ($status -eq 404) { return [pscustomobject]@{ Status = 404; Message = (T "introuvable (404) : $detail" "not found (404): $detail") } }
    if ($status -eq 429) { return [pscustomobject]@{ Status = 429; Message = (T 'trop de demandes, Salad demande de patienter (429)' 'too many requests, Salad asks to wait (429)') } }
    if ($status) { return [pscustomobject]@{ Status = $status; Message = (T "erreur $status : $detail" "error ${status}: $detail") } }
    return [pscustomobject]@{ Status = 0; Message = (T "pas de réponse de l'API ($($exception.Message))" "no answer from the API ($($exception.Message))") }
}

class SaladApiException : System.Exception {
    [int]$Status
    SaladApiException([string]$Message, [int]$Status) : base($Message) { $this.Status = $Status }
}

# Appel à l'API Salad. $Path commence par / et suit https://api.salad.com/api/public.
# $Body (objet) est envoyé en JSON ; PATCH utilise le type merge-patch demandé par Salad.
function Invoke-Salad([string]$Method, [string]$Path, $Body = $null, [string]$ApiKey = '') {
    if (-not $ApiKey) {
        if (-not $script:Account) { throw (T 'aucune clé API active.' 'no active API key.') }
        $ApiKey = $script:Account.Key
    }
    $headers = @{ 'Salad-Api-Key' = $ApiKey; 'Accept' = 'application/json' }
    $params = @{ Method = $Method; Uri = ($script:ApiBase + $Path); Headers = $headers; TimeoutSec = 60 }
    if ($null -ne $Body) {
        $json = ConvertTo-Json -InputObject $Body -Depth 12 -Compress
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes($json)
        if ($Method -eq 'PATCH') { $params.ContentType = 'application/merge-patch+json' }
        else { $params.ContentType = 'application/json' }
    }
    elseif ($Method -ne 'GET') {
        $params.Body = [System.Text.Encoding]::UTF8.GetBytes('{}')
        $params.ContentType = 'application/json'
    }
    try { return (Invoke-RestMethod @params) }
    catch {
        $error_ = Get-HttpError $_
        throw [SaladApiException]::new($error_.Message, $error_.Status)
    }
}

# Plusieurs appels à l'API en même temps (HttpClient), $MaxParallel au plus en vol :
# dès qu'un appel répond, le suivant part. $Requests : liste de { Method, Path, Body }.
# Renvoie, dans le même ordre, des { Ok, Status, Data, Error, TimedOut }. Un appel sans
# réponse au bout de $TimeoutSeconds est abandonné (TimedOut) ; les erreurs 429 et 5xx
# sont retentées une fois.
function Invoke-SaladMany($Requests, [int]$MaxParallel = 6, [int]$TimeoutSeconds = 12) {
    $results = @()
    if (@($Requests).Count -eq 0) { return , $results }
    if (-not ('System.Net.Http.HttpClient' -as [type])) { Add-Type -AssemblyName System.Net.Http }
    if (-not $script:HttpClient) {
        $script:HttpClient = [System.Net.Http.HttpClient]::new()
        $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(60)
    }
    if ($env:SALAD_LOG_TIMEOUT) { $TimeoutSeconds = [int]$env:SALAD_LOG_TIMEOUT }
    $client = $script:HttpClient
    $pending = @($Requests | ForEach-Object { [pscustomobject]@{ Request = $_; Ok = $false; Status = 0; Data = $null; Error = ''; TimedOut = $false } })
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $queue = New-Object System.Collections.Queue
        foreach ($item in $pending) {
            if (-not $item.Ok -and ($attempt -eq 1 -or (-not $item.TimedOut -and $item.Status -in @(0, 429, 500, 502, 503, 504)))) { $queue.Enqueue($item) }
        }
        if ($queue.Count -eq 0) { break }
        if ($attempt -eq 2) { Start-Sleep -Seconds 2 }
        $inFlight = New-Object System.Collections.ArrayList
        while ($queue.Count -gt 0 -or $inFlight.Count -gt 0) {
            while ($queue.Count -gt 0 -and $inFlight.Count -lt $MaxParallel) {
                $item = $queue.Dequeue()
                $method = [System.Net.Http.HttpMethod]::new($item.Request.Method)
                $message = [System.Net.Http.HttpRequestMessage]::new($method, ($script:ApiBase + $item.Request.Path))
                $message.Headers.TryAddWithoutValidation('Salad-Api-Key', $script:Account.Key) | Out-Null
                $message.Headers.TryAddWithoutValidation('Accept', 'application/json') | Out-Null
                if ($null -ne $item.Request.Body) {
                    $json = ConvertTo-Json -InputObject $item.Request.Body -Depth 12 -Compress
                    $message.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
                }
                $cancel = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
                [void]$inFlight.Add([pscustomobject]@{ Item = $item; Cancel = $cancel; Task = $client.SendAsync($message, $cancel.Token) })
            }
            $tasks = [System.Threading.Tasks.Task[]]@($inFlight | ForEach-Object { $_.Task })
            $index = [System.Threading.Tasks.Task]::WaitAny($tasks, 250)
            if ($index -lt 0) { continue }
            $entry = $inFlight[$index]
            $inFlight.RemoveAt($index)
            $item = $entry.Item
            $item.TimedOut = $false
            try {
                $response = $entry.Task.GetAwaiter().GetResult()
                $item.Status = [int]$response.StatusCode
                # Le corps est déjà reçu (SendAsync attend la réponse complète) ; sans jeton
                # d'annulation, que le .NET de Windows PowerShell ne propose pas ici.
                $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $response.Dispose()
                if ($item.Status -ge 200 -and $item.Status -lt 300) {
                    $item.Data = $null
                    if ($text) { $item.Data = ConvertFrom-Json -InputObject $text }
                    $item.Ok = $true
                    $item.Error = ''
                }
                else {
                    $detail = ''
                    try { $detail = [string](Get-Prop (ConvertFrom-Json -InputObject $text) 'detail') } catch { }
                    if (-not $detail) { $detail = $text.Trim() }
                    $item.Error = (T "erreur $($item.Status) : $detail" "error $($item.Status): $detail")
                }
            }
            catch {
                $item.Status = 0
                if ($entry.Cancel.IsCancellationRequested) {
                    $item.TimedOut = $true
                    $item.Error = (T "pas de réponse en $TimeoutSeconds s" "no answer within $TimeoutSeconds s")
                }
                else {
                    $why = $_.Exception
                    while ($why.InnerException) { $why = $why.InnerException }
                    $item.Error = (T "pas de réponse ($($why.Message))" "no answer ($($why.Message))")
                }
            }
            $entry.Cancel.Dispose()
            # Trace des appels (diagnostic) : SALAD_TRACE=<fichier>.
            if ($env:SALAD_TRACE) {
                $what = ''
                if ($null -ne $item.Request.Body -and $item.Request.Body.ContainsKey('start_time')) { $what = "$($item.Request.Body.start_time) -> $($item.Request.Body.end_time)" }
                $count = ''
                if ($item.Ok -and $item.Data -and ($item.Data.PSObject.Properties['items'])) { $count = "items=$(@($item.Data.items).Count)" }
                Add-Content -Path $env:SALAD_TRACE -Value ("{0:HH:mm:ss.fff} {1} {2} {3} ok={4} status={5} timedout={6} {7} {8}" -f (Get-Date), $attempt, $item.Request.Method, $what, $item.Ok, $item.Status, $item.TimedOut, $count, $item.Error)
            }
        }
    }
    foreach ($item in $pending) { $results += [pscustomobject]@{ Ok = $item.Ok; Status = $item.Status; Data = $item.Data; Error = $item.Error; TimedOut = $item.TimedOut } }
    return , $results
}

function Get-OrgPath { return "/organizations/$($script:Account.Org)" }
function Get-ProjectPath { return "/organizations/$($script:Account.Org)/projects/$($script:Account.Project)" }

# Vérifie une clé sur une organisation et un projet : liste des groupes.
# Renvoie { Ok, Groups, Status, Error }.
function Test-ApiKey([string]$Key, [string]$Org, [string]$Project) {
    try {
        $data = Invoke-Salad 'GET' "/organizations/$Org/projects/$Project/containers" $null $Key
        return [pscustomobject]@{ Ok = $true; Groups = @(Get-Prop $data 'items'); Status = 200; Error = '' }
    }
    catch [SaladApiException] {
        return [pscustomobject]@{ Ok = $false; Groups = @(); Status = $_.Exception.Status; Error = $_.Exception.Message }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Groups = @(); Status = 0; Error = $_.Exception.Message }
    }
}

# Étiquettes d'un dépôt Docker Hub public, de la plus récente à la plus ancienne.
function Get-HubTags([string]$Repository) {
    $repo = $Repository
    if ($repo -notmatch '/') { $repo = "library/$repo" }
    $uri = "$($script:HubBase)/repositories/$repo/tags?page_size=40&ordering=last_updated"
    $data = Invoke-RestMethod -Method GET -Uri $uri -TimeoutSec 30
    $tags = @()
    foreach ($item in @(Get-Prop $data 'results')) {
        $tags += [pscustomobject]@{ Name = [string](Get-Prop $item 'name'); Updated = Get-Prop $item 'last_updated' }
    }
    return , $tags
}

function Get-KeySuffix([string]$Key) {
    if ($Key.Length -ge 4) { return $Key.Substring($Key.Length - 4) }
    return ''
}

function Read-SecretKey([string]$Prompt) {
    Write-Host ''
    Write-Segment '  ► ' $script:AccentColor
    Write-Segment "$Prompt : " 'White'
    $secure = Read-Host -AsSecureString
    $key = (New-Object System.Net.NetworkCredential('', $secure)).Password
    if ($null -eq $key) { return '' }
    return $key.Trim()
}

# === Trousseau de clés =================================================================
# La liste des clés connues est dans keys.json (organisation, projet, date, référence).
#   Windows : la clé elle-même est dans le fichier, chiffrée par la protection Windows
#             (DPAPI) ; seule ta session Windows, sur ce PC, peut la relire.
#   macOS   : la clé est dans le Trousseau d'accès (outil « security » du système) ;
#             le fichier ne contient qu'une référence.
#   Linux   : la clé est dans le fichier, lisible seulement par ton compte (mode 600).

$script:KeychainService = 'Salad-Switch-Log'

function Get-KeyringPath {
    switch ($script:Os) {
        'mac' { return (Join-Path $env:HOME 'Library/Application Support/Salad-Switch-Log/keys.json') }
        'linux' {
            $base = $env:XDG_CONFIG_HOME
            if (-not $base) { $base = Join-Path $env:HOME '.config' }
            return (Join-Path $base 'Salad-Switch-Log/keys.json')
        }
        default {
            $base = $env:APPDATA
            if (-not $base) { $base = Join-Path $env:HOME '.config' }
            return (Join-Path (Join-Path $base 'Salad-Switch-Log') 'keys.json')
        }
    }
}

function Get-KeyringStorageText {
    switch ($script:Os) {
        'mac'   { return (T 'clés dans le Trousseau d''accès macOS' 'keys stored in the macOS Keychain') }
        'linux' { return (T 'clés dans ce fichier, lisible par ton compte seulement' 'keys stored in this file, readable by your account only') }
        default { return (T 'chiffré pour ta session Windows' 'encrypted for your Windows session') }
    }
}

# Appelle l'outil « security » de macOS ; renvoie { ExitCode, Out }.
function Invoke-Security([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'security'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    $process = [System.Diagnostics.Process]::Start($psi)
    $out = $process.StandardOutput.ReadToEnd()
    $err = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $out; Err = $err }
}

# Range une clé ; renvoie la référence à écrire dans keys.json.
function Protect-Key([string]$Key, [string]$Id) {
    if ($script:Os -eq 'mac') {
        $result = Invoke-Security @('add-generic-password', '-a', $Id, '-s', $script:KeychainService, '-l', "Salad-Switch-Log ($Id)", '-w', $Key, '-U')
        if ($result.ExitCode -ne 0) { throw (T "le Trousseau d'accès a refusé d'enregistrer la clé ($($result.Err.Trim()))" "the Keychain refused to store the key ($($result.Err.Trim()))") }
        return "keychain:$Id"
    }
    if ($script:Os -eq 'windows') {
        try {
            $secure = ConvertTo-SecureString -String $Key -AsPlainText -Force
            return 'dpapi:' + (ConvertFrom-SecureString -SecureString $secure)
        }
        catch { }
    }
    return 'plain:' + $Key
}

# Relit une clé à partir de sa référence ; '' si impossible.
function Unprotect-Key([string]$Stored) {
    if ($Stored -like 'plain:*') { return $Stored.Substring(6) }
    if ($Stored -like 'keychain:*') {
        if ($script:Os -ne 'mac') { return '' }
        $result = Invoke-Security @('find-generic-password', '-a', $Stored.Substring(9), '-s', $script:KeychainService, '-w')
        if ($result.ExitCode -ne 0) { return '' }
        return $result.Out.Trim()
    }
    if ($Stored -like 'dpapi:*') {
        try {
            $secure = ConvertTo-SecureString -String $Stored.Substring(6)
            return (New-Object System.Net.NetworkCredential('', $secure)).Password
        }
        catch { return '' }
    }
    return ''
}

# Supprime la clé rangée hors du fichier (Trousseau macOS) quand une entrée est retirée.
function Remove-StoredKey([string]$Stored) {
    if ($Stored -like 'keychain:*' -and $script:Os -eq 'mac') {
        Invoke-Security @('delete-generic-password', '-a', $Stored.Substring(9), '-s', $script:KeychainService) | Out-Null
    }
}

# { Entries = liste de { Id, Org, Project, Suffix, Added, Stored } ; ActiveId }
function Get-Keyring {
    $path = Get-KeyringPath
    $entries = @()
    $activeId = ''
    if (Test-Path -LiteralPath $path) {
        try {
            $data = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
            $activeId = [string](Get-Prop $data 'active')
            foreach ($item in @(Get-Prop $data 'keys')) {
                if ($null -eq $item -or -not (Get-Prop $item 'stored')) { continue }
                $entries += [pscustomobject]@{
                    Id      = [string](Get-Prop $item 'id')
                    Org     = [string](Get-Prop $item 'org')
                    Project = [string](Get-Prop $item 'project')
                    Suffix  = [string](Get-Prop $item 'suffix')
                    Added   = [string](Get-Prop $item 'added')
                    Stored  = [string](Get-Prop $item 'stored')
                }
            }
        }
        catch { Write-Warn (T "Le fichier des clés est illisible ($path) : il sera recréé." "The key file is unreadable ($path): it will be recreated.") }
    }
    return [pscustomobject]@{ Entries = $entries; ActiveId = $activeId }
}

function Save-Keyring($Entries, [string]$ActiveId) {
    $path = Get-KeyringPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $list = @(foreach ($entry in $Entries) {
        @{ id = $entry.Id; org = $entry.Org; project = $entry.Project; suffix = $entry.Suffix; added = $entry.Added; stored = $entry.Stored }
    })
    $json = ConvertTo-Json -InputObject @{ active = $ActiveId; keys = $list } -Depth 4
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    if ($script:Os -ne 'windows') {
        try { & chmod 600 $path 2>$null | Out-Null } catch { }
    }
}

# Ajoute (ou met à jour) une clé dans le trousseau et la rend active. Renvoie le compte actif.
function Set-ActiveKey([string]$Key, [string]$Org, [string]$Project) {
    $ring = Get-Keyring
    $entries = @($ring.Entries)
    $id = ''
    foreach ($entry in $entries) {
        if ($entry.Org -eq $Org -and $entry.Project -eq $Project -and (Unprotect-Key $entry.Stored) -eq $Key) { $id = $entry.Id }
    }
    if (-not $id) {
        $id = [guid]::NewGuid().ToString('N')
        $entries += [pscustomobject]@{
            Id = $id; Org = $Org; Project = $Project
            Suffix = Get-KeySuffix $Key
            Added  = (Get-Date).ToString('dd/MM/yyyy HH:mm')
            Stored = Protect-Key $Key $id
        }
    }
    Save-Keyring $entries $id
    $script:Account = [pscustomobject]@{ Key = $Key; Org = $Org; Project = $Project; Label = "$Org / $Project" }
    $script:GpuClasses = $null
    return $script:Account
}

function Get-ActiveEntry {
    $ring = Get-Keyring
    foreach ($entry in $ring.Entries) { if ($entry.Id -eq $ring.ActiveId) { return $entry } }
    if ($ring.Entries.Count -gt 0) { return $ring.Entries[0] }
    return $null
}

function Write-AccountLine([string]$Lead, [string]$Org, [string]$Project, $Groups) {
    Write-Segment "  $Lead" 'Green'
    Write-Segment (T '   ·   Organisation ' '   ·   Organization ') 'DarkGray'; Write-Segment $Org 'White'
    Write-Segment (T '   ·   Projet ' '   ·   Project ') 'DarkGray'; Write-Segment $Project 'White'
    if ($null -ne $Groups) { Write-Segment '   ·   ' 'DarkGray'; Write-Segment (T "$(@($Groups).Count) groupe(s)" "$(@($Groups).Count) group(s)") 'White' }
    Write-Host ''
}

# Saisie + test d'une nouvelle clé (organisation, projet, clé). Renvoie $null (annulé)
# ou { Key, Org, Project, Groups }.
function Read-NewKey([string]$EmptyMeaning) {
    Write-Dim (T 'Organisation et projet : ce sont les deux noms dans l''adresse du portail,' 'Organization and project: the two names in the portal address,')
    Write-Dim 'portal.salad.com/organizations/ORGANISATION/projects/PROJET/containers'
    $org = Read-Answer (T "Organisation (Entrée sans rien = $EmptyMeaning)" "Organization (Enter alone = $EmptyMeaning)")
    if ($org -eq '') { return $null }
    $org = $org.ToLowerInvariant()
    $project = Read-Answer (T 'Projet' 'Project')
    if ($project -eq '') { return $null }
    $project = $project.ToLowerInvariant()
    while ($true) {
        $key = Read-SecretKey (T "Clé API Salad (Entrée sans rien = $EmptyMeaning)" "Salad API key (Enter alone = $EmptyMeaning)")
        if ($key -eq '') { return $null }
        Write-Step (T 'Test de la clé … ' 'Testing the key … ')
        $check = Test-ApiKey $key $org $project
        if ($check.Ok) {
            Write-Host (T 'acceptée' 'accepted') -ForegroundColor Green
            return [pscustomobject]@{ Key = $key; Org = $org; Project = $project; Groups = $check.Groups }
        }
        if ($check.Status -eq 401) { Write-Host (T 'refusée par Salad' 'rejected by Salad') -ForegroundColor Red }
        elseif ($check.Status -eq 404) { Write-Host (T "organisation ou projet introuvable ($org / $project)" "organization or project not found ($org / $project)") -ForegroundColor Red }
        else { Write-Host (T "impossible de vérifier ($($check.Error))" "could not check ($($check.Error))") -ForegroundColor Red }
        if (-not (Confirm-Action (T 'Réessayer ?' 'Try again?'))) { return $null }
        if ($check.Status -eq 404) {
            $again = (Read-Answer (T 'Organisation' 'Organization') (T "Entrée sans rien = garder $org" "Enter alone = keep $org")).ToLowerInvariant()
            if ($again -ne '') { $org = $again }
            $again = (Read-Answer (T 'Projet' 'Project') (T "Entrée sans rien = garder $project" "Enter alone = keep $project")).ToLowerInvariant()
            if ($again -ne '') { $project = $again }
        }
    }
}

# Au démarrage : clé active du trousseau, testée ; sinon saisie d'une nouvelle clé.
function Initialize-ApiKey {
    $entry = Get-ActiveEntry
    if ($entry) {
        $key = Unprotect-Key $entry.Stored
        if ($key) {
            Write-Step (T "Vérification de la clé …$($entry.Suffix) ($($entry.Org) / $($entry.Project)) … " "Checking key …$($entry.Suffix) ($($entry.Org) / $($entry.Project)) … ")
            $check = Test-ApiKey $key $entry.Org $entry.Project
            if ($check.Ok) {
                Write-Host (T 'acceptée' 'accepted') -ForegroundColor Green
                $script:Account = [pscustomobject]@{ Key = $key; Org = $entry.Org; Project = $entry.Project; Label = "$($entry.Org) / $($entry.Project)" }
                return $check.Groups
            }
            if ($check.Status -eq 401) { Write-Host (T 'refusée par Salad' 'rejected by Salad') -ForegroundColor Red }
            else { Write-Host (T "impossible de vérifier ($($check.Error))" "could not check ($($check.Error))") -ForegroundColor Red }
            if ($check.Status -ne 401 -and $check.Status -ne 404) {
                Write-Warn (T 'Salad ne répond pas pour le moment ; réessaie dans un instant.' 'Salad is not answering right now; try again in a moment.')
                return $null
            }
        }
        else {
            if ($script:Os -eq 'mac') { Write-Warn (T "La clé …$($entry.Suffix) n'est pas dans le Trousseau d'accès de cette session." "Key …$($entry.Suffix) is not in this session's Keychain.") }
            else { Write-Warn (T "La clé …$($entry.Suffix) ne peut pas être déchiffrée sur cette session." "Key …$($entry.Suffix) cannot be decrypted in this session.") }
        }
    }
    else {
        Write-Box (T 'Première utilisation' 'First run') @(
            (T 'Il faut une clé API Salad : portail > ton organisation > API Access, puis « Create key ».' 'You need a Salad API key: portal > your organization > API Access, then "Create key".'),
            (T "Elle sera enregistrée ($(Get-KeyringStorageText)) et testée avant d'être gardée." "It will be stored ($(Get-KeyringStorageText)) and tested before being kept."),
            (New-Cell (T 'Elle ne s''affiche pas pendant la saisie, c''est normal.' 'It is not displayed while you type, that is normal.') 'DarkGray')
        )
    }
    $new = Read-NewKey (T 'quitter' 'quit')
    if (-not $new) { return $null }
    Set-ActiveKey $new.Key $new.Org $new.Project | Out-Null
    return $new.Groups
}

# === Menu 8 : clés API ===============================================================

function Show-Keyring($Entries, [string]$ActiveId) {
    $columns = @((New-Column (T 'N°' '#') 'R'), (New-Column (T 'Organisation' 'Organization') 'L' 8 30), (New-Column (T 'Projet' 'Project') 'L' 8 30), (New-Column (T 'Fin' 'Ends') ), (New-Column (T 'Active' 'Active')), (New-Column (T 'Ajoutée le' 'Added on')))
    $rows = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $Entries.Count; $n++) {
        $entry = $Entries[$n]
        $active = ''
        if ($entry.Id -eq $ActiveId) { $active = '●' }
        [void]$rows.Add(@(
            (New-Cell ([string]($n + 1)) $script:AccentColor),
            (New-Cell $entry.Org 'White'),
            (New-Cell $entry.Project 'White'),
            "…$($entry.Suffix)",
            (New-Cell $active 'Green'),
            $entry.Added
        ))
    }
    Write-Host ''
    Write-Table $columns $rows
}

function Invoke-ApiKeys {
    while ($true) {
        Write-Rule (T 'Clés API Salad' 'Salad API keys')
        $ring = Get-Keyring
        $entries = @($ring.Entries)
        if ($entries.Count -eq 0) { Write-Dim (T 'Aucune clé dans la liste pour le moment.' 'No key in the list yet.') }
        else { Show-Keyring $entries $ring.ActiveId }
        Write-Dim (T "Fichier : $(Get-KeyringPath) ($(Get-KeyringStorageText))" "File: $(Get-KeyringPath) ($(Get-KeyringStorageText))")

        $hint = T 'Un numéro = basculer sur cette clé   ·   A = ajouter   ·   S = retirer de la liste   ·   Entrée sans rien = retour au menu' 'A number = switch to that key   ·   A = add   ·   R = remove from the list   ·   Enter alone = back to the menu'
        $answer = (Read-Answer (T 'Ton choix' 'Your choice') $hint).ToLowerInvariant()
        if ($answer -eq '') { return }

        if ($answer -eq 'a') {
            Write-Box (T 'Ajouter une clé' 'Add a key') @(
                (T 'Crée la clé sur portal.salad.com > ton organisation > API Access, puis colle-la ici.' 'Create the key on portal.salad.com > your organization > API Access, then paste it here.'),
                (T 'Elle est testée avant d''être enregistrée : si Salad la refuse, rien ne change.' 'It is tested before being stored: if Salad rejects it, nothing changes.'),
                (New-Cell (T 'Elle ne s''affiche pas pendant la saisie, c''est normal.' 'It is not displayed while you type, that is normal.') 'DarkGray')
            )
            $new = Read-NewKey (T 'annuler' 'cancel')
            if (-not $new) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); continue }
            Write-AccountLine (T 'Cette clé ouvre' 'This key opens') $new.Org $new.Project $new.Groups
            if (-not (Confirm-Action (T 'L''enregistrer et l''activer ?' 'Store it and make it active?'))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); continue }
            Set-ActiveKey $new.Key $new.Org $new.Project | Out-Null
            Write-Ok (T "Clé …$(Get-KeySuffix $new.Key) enregistrée et active ($($new.Org) / $($new.Project))." "Key …$(Get-KeySuffix $new.Key) stored and active ($($new.Org) / $($new.Project)).")
            continue
        }

        if ($answer -eq 's' -or $answer -eq 'r') {
            if ($entries.Count -eq 0) { Write-Warn (T 'Rien à retirer.' 'Nothing to remove.'); continue }
            $index = Read-Index $entries.Count (T 'Quelle clé retirer de la liste' 'Which key to remove from the list') (T 'Tape son numéro   ·   Entrée sans rien = annuler' 'Type its number   ·   Enter alone = cancel')
            if ($index -lt 0) { continue }
            $entry = $entries[$index]
            if ($entry.Id -eq $ring.ActiveId) {
                Write-Warn (T 'C''est la clé active : elle reste utilisée jusqu''à la fermeture du script, puis il faudra en choisir une autre.' 'This is the active key: it stays in use until the script closes, then you will have to pick another one.')
            }
            if (-not (Confirm-Action (T "Retirer la clé …$($entry.Suffix) ($($entry.Org) / $($entry.Project)) de la liste ?" "Remove key …$($entry.Suffix) ($($entry.Org) / $($entry.Project)) from the list?"))) { continue }
            $kept = @()
            for ($n = 0; $n -lt $entries.Count; $n++) { if ($n -ne $index) { $kept += $entries[$n] } }
            $activeId = $ring.ActiveId
            if ($entry.Id -eq $activeId) { $activeId = '' }
            Save-Keyring $kept $activeId
            Remove-StoredKey $entry.Stored
            Write-Ok (T 'Clé retirée de la liste (elle reste valable sur Salad tant que tu ne la révoques pas sur le portail).' 'Key removed from the list (it stays valid on Salad until you revoke it in the portal).')
            continue
        }

        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $entries.Count) {
            $entry = $entries[[int]$answer - 1]
            $key = Unprotect-Key $entry.Stored
            if (-not $key) {
                Write-Bad (T 'Cette clé ne peut pas être relue sur cette session : retire-la (S) et ressaisis-la (A).' 'This key cannot be read back in this session: remove it (R) and enter it again (A).')
                continue
            }
            if ($entry.Id -eq $ring.ActiveId) { Write-Dim (T 'Cette clé est déjà active.' 'This key is already active.'); continue }
            Write-Step (T "Test de la clé …$($entry.Suffix) … " "Testing key …$($entry.Suffix) … ")
            $check = Test-ApiKey $key $entry.Org $entry.Project
            if (-not $check.Ok) {
                if ($check.Status -eq 401) { Write-Host (T 'refusée par Salad (révoquée ?) : la clé active ne change pas.' 'rejected by Salad (revoked?): the active key does not change.') -ForegroundColor Red }
                else { Write-Host (T "impossible de vérifier ($($check.Error)) : la clé active ne change pas." "could not check ($($check.Error)): the active key does not change.") -ForegroundColor Red }
                continue
            }
            Write-Host (T 'acceptée' 'accepted') -ForegroundColor Green
            Set-ActiveKey $key $entry.Org $entry.Project | Out-Null
            Write-AccountLine (T 'Bascule faite' 'Switched') $entry.Org $entry.Project $check.Groups
            continue
        }

        Write-Warn (T 'Réponse non comprise.' 'Not understood.')
    }
}


# === Portail Salad (facultatif) =======================================================
# L'API publique ne donne pas le solde ; le portail (portal-api.salad.com, API interne,
# non documentée) le donne après connexion par e-mail + mot de passe du compte Salad
# (cookie de session). Réglages dans portal.json, à côté de keys.json :
#   { "<org>": { "email": "...", "stored": "dpapi:..." | "keychain:portal-<org>" | "" } }
# "stored" vide = mot de passe non gardé (demandé via le menu S à chaque lancement).

function Get-PortalPath { return (Join-Path (Split-Path -Parent (Get-KeyringPath)) 'portal.json') }

function Get-PortalSettings {
    $table = @{}
    $path = Get-PortalPath
    if (Test-Path -LiteralPath $path) {
        try {
            $data = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
            foreach ($property in $data.PSObject.Properties) {
                $table[$property.Name] = [pscustomobject]@{ Email = [string](Get-Prop $property.Value 'email'); Stored = [string](Get-Prop $property.Value 'stored') }
            }
        }
        catch { }
    }
    return $table
}

function Save-PortalSettings($Table) {
    $path = Get-PortalPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $out = @{}
    foreach ($key in $Table.Keys) { $out[$key] = @{ email = $Table[$key].Email; stored = $Table[$key].Stored } }
    [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $out -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    if ($script:Os -ne 'windows') {
        try { & chmod 600 $path 2>$null | Out-Null } catch { }
    }
}

# Réglage du portail pour l'organisation active : { Email, Stored } ou $null.
function Get-PortalSetting {
    $table = Get-PortalSettings
    if ($table.ContainsKey($script:Account.Org)) { return $table[$script:Account.Org] }
    return $null
}

function Set-PortalSetting([string]$Email, [string]$Password, [bool]$Keep) {
    $table = Get-PortalSettings
    $stored = ''
    if ($table.ContainsKey($script:Account.Org) -and $table[$script:Account.Org].Stored) { Remove-StoredKey $table[$script:Account.Org].Stored }
    if ($Keep) { $stored = Protect-Key $Password "portal-$($script:Account.Org)" }
    $table[$script:Account.Org] = [pscustomobject]@{ Email = $Email; Stored = $stored }
    Save-PortalSettings $table
    $script:PortalPassword = $Password
}

function Remove-PortalSetting {
    $table = Get-PortalSettings
    if ($table.ContainsKey($script:Account.Org)) {
        if ($table[$script:Account.Org].Stored) { Remove-StoredKey $table[$script:Account.Org].Stored }
        $table.Remove($script:Account.Org)
        Save-PortalSettings $table
    }
    $script:PortalPassword = ''
    $script:PortalSession = $null
    $script:PortalBalance = $null
    $script:PortalError = ''
}

# Mot de passe du portail disponible : celui de la session, sinon celui gardé sur ce PC.
function Get-PortalPassword {
    if ($script:PortalPassword) { return $script:PortalPassword }
    $setting = Get-PortalSetting
    if ($setting -and $setting.Stored) { return (Unprotect-Key $setting.Stored) }
    return ''
}

# Ouvre une session sur le portail ; renvoie '' ou un message d'erreur.
function Connect-Portal([string]$Email, [string]$Password) {
    $script:PortalSession = $null
    $body = ConvertTo-Json -InputObject @{ email = $Email; password = $Password } -Compress
    try {
        $null = Invoke-RestMethod -Method Post -Uri "$($script:PortalBase)/users/login" -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' `
            -Headers @{ Accept = 'application/json'; Origin = 'https://portal.salad.com' } -SessionVariable session -TimeoutSec 20
        $script:PortalSession = $session
        return ''
    }
    catch {
        $failure = Get-HttpError $_
        if ($failure.Status -eq 400 -or $failure.Status -eq 401) { return (T 'e-mail ou mot de passe refusé par le portail Salad' 'e-mail or password rejected by the Salad portal') }
        return $failure.Message
    }
}

function Disconnect-Portal {
    if (-not $script:PortalSession) { return }
    try { $null = Invoke-RestMethod -Method Post -Uri "$($script:PortalBase)/users/logout" -WebSession $script:PortalSession -TimeoutSec 10 } catch { }
    $script:PortalSession = $null
}

# Solde réel de l'organisation active d'après le portail (gardé 60 s) : { Amount, At } ou $null.
# Se connecte au besoin avec l'e-mail et le mot de passe disponibles ; sans eux, $null.
# En cas d'échec, $script:PortalError explique pourquoi.
function Get-PortalBalance([bool]$Force = $false) {
    if (-not $Force -and $script:PortalBalance -and ((Get-Date) - $script:PortalBalance.At).TotalSeconds -lt 60) { return $script:PortalBalance }
    $setting = Get-PortalSetting
    if (-not $setting -or -not $setting.Email) { return $null }
    $password = Get-PortalPassword
    if (-not $password) { $script:PortalError = (T 'mot de passe non gardé : menu S pour te connecter' 'password not kept: menu S to sign in'); return $null }
    $uri = "$($script:PortalBase)/organizations/$($script:Account.Org)/billing-profile/credits-balance"
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (-not $script:PortalSession) {
            $failure = Connect-Portal $setting.Email $password
            if ($failure) { $script:PortalError = $failure; return $null }
        }
        try {
            $data = Invoke-RestMethod -Method Get -Uri $uri -WebSession $script:PortalSession -Headers @{ Accept = 'application/json' } -TimeoutSec 20
            $amount = Get-Prop $data 'amount'
            if ($null -eq $amount) { $script:PortalError = (T 'réponse du portail sans montant' 'portal answer without an amount'); return $null }
            # Le portail renvoie le montant en cents (6705 = 67,05 $), comme l'affiche sa propre page.
            $script:PortalBalance = [pscustomobject]@{ Amount = ([double]$amount / 100); At = (Get-Date) }
            $script:PortalError = ''
            return $script:PortalBalance
        }
        catch {
            $failure = Get-HttpError $_
            # Session expirée : on se reconnecte une fois.
            if ($failure.Status -eq 401 -and $attempt -eq 1) { $script:PortalSession = $null; continue }
            $script:PortalError = $failure.Message
            if ($failure.Status -eq 401) { $script:PortalError = (T 'session du portail refusée (401)' 'portal session rejected (401)') }
            return $null
        }
    }
    return $null
}
# === Classes GPU, prix ===============================================================

$script:PriorityLabels = @{ high = 'High'; medium = 'Medium'; low = 'Low'; batch = 'Lowest' }
$script:PriorityOrder = @('high', 'medium', 'low', 'batch')

function Format-Priority([string]$Priority) {
    $key = ([string]$Priority).ToLowerInvariant()
    if ($script:PriorityLabels.ContainsKey($key)) { return $script:PriorityLabels[$key] }
    if ($key -eq '') { return '?' }
    return $Priority
}

# Classes GPU de l'organisation : liste de { Id, Name, Short, HighDemand, Prices (priorité -> prix) }.
function Get-GpuClasses {
    if ($null -ne $script:GpuClasses) { return $script:GpuClasses }
    $data = Invoke-Salad 'GET' "$(Get-OrgPath)/gpu-classes"
    $classes = @()
    foreach ($item in @(Get-Prop $data 'items')) {
        $prices = @{}
        foreach ($price in @(Get-Prop $item 'prices')) {
            $priority = ([string](Get-Prop $price 'priority')).ToLowerInvariant()
            $value = Get-Prop $price 'price'
            if ($priority -and $null -ne $value) { $prices[$priority] = [double]$value }
        }
        $name = [string](Get-Prop $item 'name')
        $classes += [pscustomobject]@{
            Id         = [string](Get-Prop $item 'id')
            Name       = $name
            Short      = Get-ShortClassName $name
            HighDemand = [bool](Get-Prop $item 'is_high_demand')
            Prices     = $prices
        }
    }
    $script:GpuClasses = @($classes | Sort-Object Name)
    return $script:GpuClasses
}

# "RTX 5090 (32 GB)" -> "RTX 5090" ; "NVIDIA GeForce RTX 5090" -> "RTX 5090".
function Get-ShortClassName([string]$Name) {
    $short = $Name -replace '\s*\(.*\)\s*$', ''
    $short = $short -replace '(?i)^nvidia\s+', '' -replace '(?i)^geforce\s+', ''
    return $short.Trim()
}

function Get-GpuClassById([string]$Id) {
    foreach ($class in (Get-GpuClasses)) { if ($class.Id -eq $Id) { return $class } }
    return $null
}

# Classe correspondant à un modèle lu dans les logs ("RTX 5090"), parmi $Candidates
# (classes du groupe) puis toutes les classes. Nom exact d'abord, puis nom contenu.
function Find-GpuClassByModel([string]$Model, $Candidates) {
    $wanted = (Get-ShortClassName $Model).ToLowerInvariant()
    if (-not $wanted) { return $null }
    foreach ($set in @(@($Candidates), @(Get-GpuClasses))) {
        foreach ($class in $set) { if ($class.Short.ToLowerInvariant() -eq $wanted) { return $class } }
    }
    foreach ($set in @(@($Candidates), @(Get-GpuClasses))) {
        foreach ($class in $set) {
            $short = $class.Short.ToLowerInvariant()
            if ($short -and ($wanted -like "*$short*" -or $short -like "*$wanted*")) { return $class }
        }
    }
    return $null
}

function Get-ClassPrice($Class, [string]$Priority) {
    if ($null -eq $Class) { return $null }
    $key = ([string]$Priority).ToLowerInvariant()
    if ($Class.Prices.ContainsKey($key)) { return $Class.Prices[$key] }
    return $null
}

# === Groupes =======================================================================

# Groupes du projet, avec les champs utiles déjà extraits.
function Get-Groups {
    $data = Invoke-Salad 'GET' "$(Get-ProjectPath)/containers"
    $groups = @()
    foreach ($item in @(Get-Prop $data 'items')) { $groups += ConvertTo-GroupInfo $item }
    return , @($groups | Sort-Object Name)
}

function Get-Group([string]$Name) {
    return (ConvertTo-GroupInfo (Invoke-Salad 'GET' "$(Get-ProjectPath)/containers/$Name"))
}

function ConvertTo-GroupInfo($Raw) {
    $container = Get-Prop $Raw 'container'
    $resources = Get-Prop $container 'resources'
    $state = Get-Prop $Raw 'current_state'
    $counts = Get-Prop $state 'instance_status_counts'
    $classes = @()
    foreach ($id in @(Get-Prop $resources 'gpu_classes')) {
        $class = Get-GpuClassById ([string]$id)
        if ($class) { $classes += $class }
        else { $classes += [pscustomobject]@{ Id = [string]$id; Name = "classe $id"; Short = "classe $(([string]$id).Substring(0, 8))"; HighDemand = $false; Prices = @{} } }
    }
    $priority = [string](Get-Prop $container 'priority')
    if (-not $priority) { $priority = [string](Get-Prop $Raw 'priority') }
    $env_ = @{}
    $envRaw = Get-Prop $container 'environment_variables'
    if ($envRaw) { foreach ($property in $envRaw.PSObject.Properties) { $env_[$property.Name] = [string]$property.Value } }
    $running = 0
    if ($counts) { $running = [int](Get-Prop $counts 'running_count') }
    return [pscustomobject]@{
        Name        = [string](Get-Prop $Raw 'name')
        DisplayName = [string](Get-Prop $Raw 'display_name')
        Status      = ([string](Get-Prop $state 'status')).ToLowerInvariant()
        Description = [string](Get-Prop $state 'description')
        Replicas    = [int](Get-Prop $Raw 'replicas')
        Running     = $running
        Allocating  = $(if ($counts) { [int](Get-Prop $counts 'allocating_count') } else { 0 })
        Creating    = $(if ($counts) { [int](Get-Prop $counts 'creating_count') } else { 0 })
        Stopping    = $(if ($counts) { [int](Get-Prop $counts 'stopping_count') } else { 0 })
        Image       = [string](Get-Prop $container 'image')
        Priority    = $priority.ToLowerInvariant()
        Classes     = $classes
        Env         = $env_
        Version     = Get-Prop $Raw 'version'
        Cpu         = Get-Prop $resources 'cpu'
        Memory      = Get-Prop $resources 'memory'
        Autostart   = Get-Prop $Raw 'autostart_policy'
        Raw         = $Raw
    }
}

# Libellé et couleur d'un état de groupe.
function Get-GroupStatusInfo([string]$Status) {
    switch ($Status) {
        'running'   { return [pscustomobject]@{ Label = (T 'En marche' 'Running');     Color = 'Green' } }
        'deploying' { return [pscustomobject]@{ Label = (T 'Déploiement' 'Deploying'); Color = 'Yellow' } }
        'pending'   { return [pscustomobject]@{ Label = (T 'En attente' 'Pending');     Color = 'Yellow' } }
        'stopped'   { return [pscustomobject]@{ Label = (T 'Arrêté' 'Stopped');         Color = 'DarkGray' } }
        'failed'    { return [pscustomobject]@{ Label = (T 'En échec' 'Failed');        Color = 'Red' } }
        'succeeded' { return [pscustomobject]@{ Label = (T 'Terminé' 'Succeeded');      Color = 'DarkGray' } }
        default     { return [pscustomobject]@{ Label = $Status;       Color = 'Gray' } }
    }
}

# Libellé et couleur d'un état de machine.
function Get-InstanceStateInfo([string]$State, $Ready, $Progress) {
    switch ($State) {
        'running' {
            if ($Ready -eq $false) { return [pscustomobject]@{ Label = (T 'Démarrage' 'Starting'); Color = 'Yellow' } }
            return [pscustomobject]@{ Label = (T 'En marche' 'Running'); Color = 'Green' }
        }
        'downloading' {
            $label = T 'Téléchargement' 'Downloading'
            if ($null -ne $Progress) { $label += (' {0} %' -f [int]$Progress) }
            return [pscustomobject]@{ Label = $label; Color = 'Yellow' }
        }
        'allocating' { return [pscustomobject]@{ Label = (T 'Allocation' 'Allocating'); Color = 'Yellow' } }
        'creating'   { return [pscustomobject]@{ Label = (T 'Création' 'Creating');     Color = 'Yellow' } }
        'stopping'   { return [pscustomobject]@{ Label = (T 'Arrêt' 'Stopping');        Color = 'DarkGray' } }
        default      { return [pscustomobject]@{ Label = $State;       Color = 'Gray' } }
    }
}

function Get-ImageTag([string]$Image) {
    if ($Image -match '^(.*?):([^/:]+)$') { return $Matches[2] }
    return 'latest'
}

function Get-ImageRepository([string]$Image) {
    if ($Image -match '^(.*?):([^/:]+)$') { return $Matches[1] }
    return $Image
}

function Get-ClassesText($Group) {
    if ($Group.Classes.Count -eq 0) { return (T 'aucune (CPU)' 'none (CPU)') }
    return (($Group.Classes | ForEach-Object { $_.Short }) -join ' + ')
}

# Fourchette de prix d'une machine du groupe : { Min, Max } selon les classes et la priorité.
function Get-GroupPriceRange($Group) {
    $min = $null; $max = $null
    foreach ($class in $Group.Classes) {
        $price = Get-ClassPrice $class $Group.Priority
        if ($null -eq $price) { continue }
        if ($null -eq $min -or $price -lt $min) { $min = $price }
        if ($null -eq $max -or $price -gt $max) { $max = $price }
    }
    return [pscustomobject]@{ Min = $min; Max = $max }
}

function Format-PriceRange($Range) {
    if ($null -eq $Range.Min) { return '?' }
    if ($Range.Min -eq $Range.Max) { return (Format-Price $Range.Max) }
    return (T "$(Format-Price $Range.Min) à $(Format-Price $Range.Max)" "$(Format-Price $Range.Min) to $(Format-Price $Range.Max)")
}

# === Machines ======================================================================

# Machines d'un groupe : { Id, MachineId, Short, State, Ready, Started, Progress, Version, Updated, Cpu, Memory }.
function Get-Instances([string]$GroupName) {
    $data = Invoke-Salad 'GET' "$(Get-ProjectPath)/containers/$GroupName/instances"
    $instances = @()
    foreach ($item in @(Get-Prop $data 'instances')) {
        $machine = [string](Get-Prop $item 'machine_id')
        $instances += [pscustomobject]@{
            Id        = [string](Get-Prop $item 'id')
            MachineId = $machine
            Short     = Get-ShortId $machine
            State     = ([string](Get-Prop $item 'state')).ToLowerInvariant()
            Ready     = Get-Prop $item 'ready'
            Started   = Get-Prop $item 'started'
            Progress  = Get-Prop $item 'pulling_progress'
            Version   = Get-Prop $item 'version'
            Updated   = Get-Prop $item 'update_time'
            Cpu       = Get-Prop $item 'cpu_percent'
            Memory    = Get-Prop $item 'memory_usage_percent'
        }
    }
    return , @($instances | Sort-Object Updated)
}

function Get-ShortId([string]$Id) {
    if ($Id.Length -gt 8) { return $Id.Substring(0, 8) }
    return $Id
}

# === Lecture des logs ================================================================

# Corps d'une requête de logs.
function New-LogQueryBody([string]$Query, [datetime]$Start, [datetime]$End, [string]$Order = 'desc', [int]$PageSize = 100) {
    return @{
        query      = $Query
        start_time = $Start.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        end_time   = $End.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        page_size  = $PageSize
        sort_order = $Order
    }
}

# Réponse de l'API -> lignes { Time, Machine, Short, Text, Severity }.
function ConvertTo-LogLines($Data) {
    $lines = @()
    foreach ($item in @(Get-Prop $Data 'items')) {
        $text = [string](Get-Prop $item 'text_log')
        if (-not $text) {
            $json = Get-Prop $item 'json_log'
            if ($json) { try { $text = ConvertTo-Json -InputObject $json -Compress -Depth 5 } catch { $text = [string]$json } }
        }
        $labels = Get-Prop (Get-Prop $item 'resource') 'labels'
        $machine = [string](Get-Prop $labels 'machine_id')
        $lines += [pscustomobject]@{
            Time     = Get-Prop $item 'time'
            Machine  = $machine
            Short    = Get-ShortId $machine
            Text     = ConvertTo-PlainText $text
            Severity = [string](Get-Prop $item 'severity')
        }
    }
    return , $lines
}

# Interroge les logs de l'organisation (un appel). Renvoie des lignes { Time, Machine, Short, Text, Severity }.
function Get-LogEntries([string]$Query, [datetime]$Start, [datetime]$End, [string]$Order = 'desc', [int]$PageSize = 100) {
    $data = Invoke-Salad 'POST' "$(Get-OrgPath)/log-entries" (New-LogQueryBody $Query $Start $End $Order $PageSize)
    return , (ConvertTo-LogLines $data)
}

# Plusieurs requêtes de logs en même temps. $Specs : liste de { Query, Start, End }.
# Renvoie, dans le même ordre, des { Ok, Lines, Error, Full } (Full : 100 lignes, page pleine).
function Get-LogEntriesMany($Specs) {
    $requests = @(foreach ($spec in $Specs) { @{ Method = 'POST'; Path = "$(Get-OrgPath)/log-entries"; Body = (New-LogQueryBody $spec.Query $spec.Start $spec.End 'desc' 100) } })
    $results = Invoke-SaladMany $requests
    $out = @()
    for ($i = 0; $i -lt $results.Count; $i++) {
        $lines = @()
        if ($results[$i].Ok) { $lines = ConvertTo-LogLines $results[$i].Data }
        # 408 : Salad lui-même a renoncé (fenêtre trop lourde), même traitement qu'un délai dépassé.
        $timedOut = $results[$i].TimedOut -or $results[$i].Status -eq 408
        $out += [pscustomobject]@{ Ok = $results[$i].Ok; Lines = $lines; Error = $results[$i].Error; Full = ($lines.Count -ge 100); TimedOut = $timedOut }
    }
    return , $out
}

# Toutes les lignes de plusieurs requêtes, en parallèle. $Specs : liste de { Query, From, To, Slice }.
# Chaque fenêtre est découpée en tranches de Slice secondes (0 : la fenêtre entière) ; une
# tranche qui revient pleine (100 lignes) ou sans réponse dans le délai (Salad est lent sur
# les grandes fenêtres) est coupée en deux et relue, trois tours au plus : la lecture dure
# au maximum trois fois le délai d'un appel. Renvoie { Lines, Errors } ; chaque ligne porte
# Which = index de la requête d'origine.
function Get-LogWindows($Specs) {
    $slices = @()
    for ($q = 0; $q -lt @($Specs).Count; $q++) {
        $spec = @($Specs)[$q]
        $size = [int]$spec.Slice
        if ($size -le 0) { $size = [int][Math]::Ceiling(($spec.To - $spec.From).TotalSeconds) }
        if ($size -le 0) { continue }
        $cursor = $spec.To
        while ($cursor -gt $spec.From) {
            $start = $cursor.AddSeconds(-$size)
            if ($start -lt $spec.From) { $start = $spec.From }
            $slices += [pscustomobject]@{ Which = $q; Query = $spec.Query; Start = $start; End = $cursor }
            $cursor = $start
        }
    }
    $all = @()
    $errors = @()
    for ($round = 0; $round -lt 3 -and $slices.Count -gt 0; $round++) {
        $results = Get-LogEntriesMany $slices
        $next = @()
        for ($i = 0; $i -lt $slices.Count; $i++) {
            $slice = $slices[$i]
            $result = $results[$i]
            $seconds = ($slice.End - $slice.Start).TotalSeconds
            if (($result.Full -or $result.TimedOut) -and $seconds -gt 10 -and $round -lt 2) {
                $middle = $slice.Start.AddSeconds($seconds / 2)
                $next += [pscustomobject]@{ Which = $slice.Which; Query = $slice.Query; Start = $middle; End = $slice.End }
                $next += [pscustomobject]@{ Which = $slice.Which; Query = $slice.Query; Start = $slice.Start; End = $middle }
                continue
            }
            if (-not $result.Ok) { $errors += $result.Error; continue }
            foreach ($line in $result.Lines) {
                $line | Add-Member -NotePropertyName Which -NotePropertyValue $slice.Which -Force
                $all += $line
            }
        }
        $slices = $next
    }
    return [pscustomobject]@{ Lines = $all; Errors = $errors }
}

# Retire les codes couleur et les guillemets autour d'une ligne.
function ConvertTo-PlainText([string]$Text) {
    $esc = [char]27
    $clean = $Text -replace "$esc\[[0-9;?]*[ -/]*[@-~]", '' -replace "$esc[@-_]", ''
    $clean = $clean.TrimEnd("`r", "`n")
    if ($clean.Length -ge 2 -and $clean.StartsWith('"') -and $clean.EndsWith('"')) { $clean = $clean.Substring(1, $clean.Length - 2) }
    return $clean
}

function Get-GroupLogQuery([string]$GroupName, [string]$MachineId = '') {
    $query = "resource.type = `"container`" and resource.labels.container_group_name = `"$GroupName`""
    if ($MachineId) { $query += " and resource.labels.machine_id = `"$MachineId`"" }
    return $query
}

# Lignes d'une requête entre $From et $To, complètes même si Salad plafonne une réponse
# à 100 lignes : une tranche qui en renvoie 100 est coupée en deux et relue.
function Get-LogSlice([string]$Query, [datetime]$From, [datetime]$To, [int]$Depth = 0) {
    $lines = Get-LogEntries $Query $From $To 'desc' 100
    if ($lines.Count -lt 100 -or $Depth -ge 6 -or ($To - $From).TotalSeconds -le 10) { return , $lines }
    $middle = $From.AddSeconds(($To - $From).TotalSeconds / 2)
    $both = @()
    $both += Get-LogSlice $Query $middle $To ($Depth + 1)
    $both += Get-LogSlice $Query $From $middle ($Depth + 1)
    return , $both
}

# Les $Count dernières lignes d'une requête, de la plus récente à la plus ancienne : le
# script remonte le temps par tranches de $SliceMinutes, sur $MaxMinutes au plus, et
# trie lui-même, pour ne pas dépendre de l'ordre dans lequel Salad sert une page.
function Get-LatestLogLines([string]$Query, [int]$Count, [int]$MaxMinutes, [int]$SliceMinutes = 2) {
    $collected = @()
    $to = Get-Date
    $limit = $to.AddMinutes(-$MaxMinutes)
    while ($collected.Count -lt $Count -and $to -gt $limit) {
        $from = $to.AddMinutes(-$SliceMinutes)
        if ($from -lt $limit) { $from = $limit }
        $collected += Get-LogSlice $Query $from $to
        $to = $from
    }
    $seen = @{}
    $unique = @(foreach ($line in $collected) {
        $key = "$($line.Time)|$($line.Machine)|$($line.Text)"
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $line }
    })
    $sorted = @($unique | Sort-Object -Property @{ Expression = { [datetime]$_.Time } } -Descending)
    if ($sorted.Count -gt $Count) { $sorted = @($sorted[0..($Count - 1)]) }
    return , $sorted
}

function Set-HashInfo($Info, [string]$Machine, $Line) {
    $reading = ConvertFrom-HashrateLine $Line.Text
    if (-not $reading) { return }
    $entry = $Info[$Machine]
    if ($entry.HashTime -and [datetime]$entry.HashTime -ge [datetime]$Line.Time) { return }
    $entry.Model = $reading.Model
    $entry.Hashrate = $reading.Value
    $entry.Unit = $reading.Unit
    $entry.HashTime = $Line.Time
}

function Set-WatchInfo($Info, [string]$Machine, $Line) {
    $entry = $Info[$Machine]
    if ($entry.WatchTime -and [datetime]$entry.WatchTime -ge [datetime]$Line.Time) { return }
    $entry.Watchdog = Get-WatchdogSummary $Line.Text
    $entry.WatchTime = $Line.Time
}

# Dernière ligne de hashrate SRBMiner et dernière ligne du chien de garde, par machine.
# Renvoie { Info = table machine_id -> { Model, Hashrate, Unit, HashTime, Watchdog, WatchTime } ; Errors }.
# 1. Une lecture groupée, en parallèle, sur de petites fenêtres (Salad répond lentement aux
#    grandes) : hashrate sur 2 min, chien de garde sur 12 min (en mode reallocate il n'écrit
#    une ligne OK que toutes les 10 min), en tranches d'autant plus courtes que le groupe est
#    grand (environ 60 lignes par tranche).
# 2. Pour les machines en marche à qui il manque encore quelque chose, une requête chacune
#    sur une fenêtre plus longue (hashrate 6 min, chien de garde 25 min).
# Ce qui a déjà été lu pendant la session est gardé en mémoire : les lectures suivantes ne
# cherchent que ce qui est plus récent que la dernière lecture complète du groupe.
function Get-MachineLogInfo([string]$GroupName, $Instances) {
    if ($null -eq $script:LogCache) { $script:LogCache = @{} }
    $info = @{}
    foreach ($instance in $Instances) {
        if ($script:LogCache.ContainsKey($instance.MachineId)) { $info[$instance.MachineId] = $script:LogCache[$instance.MachineId] }
        else {
            $info[$instance.MachineId] = [pscustomobject]@{ Model = ''; Hashrate = $null; Unit = ''; HashTime = $null; Watchdog = ''; WatchTime = $null }
            $script:LogCache[$instance.MachineId] = $info[$instance.MachineId]
        }
    }
    $running = @($Instances | Where-Object { $_.State -eq 'running' })
    $hashFilter = ' and log contains "GPU0" and log contains "H/s"'
    $watchFilter = ' and log contains "[salad]"'
    $errors = @()
    $now = Get-Date
    $base = Get-GroupLogQuery $GroupName
    $hashFrom = $now.AddMinutes(-2)
    $watchFrom = $now.AddMinutes(-12)
    $readKey = "group:$GroupName"
    if ($script:LogCache.ContainsKey($readKey)) {
        # Déjà lu pendant la session : on repart de la dernière lecture (avec une marge,
        # Salad met quelques secondes à indexer une ligne).
        $since = ([datetime]$script:LogCache[$readKey]).AddSeconds(-60)
        if ($since -gt $hashFrom) { $hashFrom = $since }
        if ($since -gt $watchFrom) { $watchFrom = $since }
    }
    # SRBMiner écrit son hashrate toutes les 30 à 90 s, le chien de garde une ligne par 10 min.
    $count = [Math]::Max(1, $running.Count)
    $hashSlice = [Math]::Max(10, [Math]::Min(40, [int](2700 / $count)))
    $watchSlice = [Math]::Max(30, [Math]::Min(120, [int](36000 / $count)))
    try {
        $specs = @(
            [pscustomobject]@{ Kind = 'hash'; Machine = ''; Query = ($base + $hashFilter); From = $hashFrom; To = $now; Slice = $hashSlice },
            [pscustomobject]@{ Kind = 'watch'; Machine = ''; Query = ($base + $watchFilter); From = $watchFrom; To = $now; Slice = $watchSlice }
        )
        $read = Get-LogWindows $specs
        $errors += $read.Errors
        if (@($read.Errors).Count -eq 0) { $script:LogCache[$readKey] = $now }
        foreach ($line in $read.Lines) {
            if (-not $info.ContainsKey($line.Machine)) { continue }
            if ($specs[$line.Which].Kind -eq 'hash') { Set-HashInfo $info $line.Machine $line } else { Set-WatchInfo $info $line.Machine $line }
        }
        $specs = @()
        foreach ($instance in $running) {
            $own = Get-GroupLogQuery $GroupName $instance.MachineId
            $entry = $info[$instance.MachineId]
            if (-not $entry.Model -or (Get-LogAge $entry.HashTime) -gt 2) {
                $specs += [pscustomobject]@{ Kind = 'hash'; Machine = $instance.MachineId; Query = ($own + $hashFilter); From = $now.AddMinutes(-6); To = $now; Slice = 0 }
            }
            if (-not $entry.Watchdog -or (Get-LogAge $entry.WatchTime) -gt 12) {
                $specs += [pscustomobject]@{ Kind = 'watch'; Machine = $instance.MachineId; Query = ($own + $watchFilter); From = $now.AddMinutes(-25); To = $now; Slice = 0 }
            }
        }
        if ($specs.Count -gt 0) {
            $more = Get-LogWindows $specs
            $errors += $more.Errors
            foreach ($line in $more.Lines) {
                $spec = $specs[$line.Which]
                if ($spec.Kind -eq 'hash') { Set-HashInfo $info $spec.Machine $line } else { Set-WatchInfo $info $spec.Machine $line }
            }
        }
    }
    catch { $errors += $_.Exception.Message }
    return [pscustomobject]@{ Info = $info; Errors = $errors }
}

# "GPU0 RTX 5090: 342.10 TH/s [T:71C ...]" -> { Model, Value, Unit }.
function ConvertFrom-HashrateLine([string]$Text) {
    if ($Text -match 'GPU\d+\s+([^:\[]+?):\s+([0-9]+(?:\.[0-9]+)?)\s*([KkMmGgTt]?)[Hh]/s') {
        return [pscustomobject]@{ Model = $Matches[1].Trim(); Value = [double]$Matches[2]; Unit = $Matches[3].ToUpperInvariant() }
    }
    return $null
}

# Résumé court d'une ligne [salad].
function Get-WatchdogSummary([string]$Text) {
    if ($Text -match 'Reallocation acceptee') { return (T 'réallocation demandée' 'reallocation requested') }
    if ($Text -match 'VERDICT \(mode observe') { return 'VERDICT (observe)' }
    if ($Text -match 'VERDICT') { return 'VERDICT' }
    if ($Text -match '<\s*seuil\s+(\S+).*:\s*(\d+)/(\d+)') { return (T "sous seuil $($Matches[1]) ($($Matches[2])/$($Matches[3]))" "below $($Matches[1]) ($($Matches[2])/$($Matches[3]))") }
    if ($Text -match '>=\s*seuil\s+(\S+)') { return (T "OK (seuil $($Matches[1]))" "OK (threshold $($Matches[1]))") }
    if ($Text -match 'revenu') { return (T 'revenu au-dessus du seuil' 'back above threshold') }
    if ($Text -match 'Pas de seuil') { return (T 'carte non surveillée' 'GPU not monitored') }
    if ($Text -match 'Hashrate a 0.*:\s*(\d+)/(\d+)') { return (T "à 0 H/s ($($Matches[1])/$($Matches[2]))" "at 0 H/s ($($Matches[1])/$($Matches[2]))") }
    if ($Text -match 'Hashrate a 0') { return (T 'à 0 H/s (ignoré)' 'at 0 H/s (ignored)') }
    if ($Text -match 'revenu a .* apres') { return (T 'revenu après un 0' 'back after a 0') }
    if ($Text -match 'refusee ou sans reponse') { return (T 'réallocation refusée' 'reallocation refused') }
    return (Limit-Text ($Text -replace '^\[salad\]\s*', '') 30)
}

function Get-WatchdogColor([string]$Summary) {
    if ($Summary -match '^VERDICT|réallocation|reallocation') { return 'Red' }
    if ($Summary -match '^sous seuil|^below|à 0|at 0') { return 'Yellow' }
    if ($Summary -match '^revenu|^back') { return 'Green' }
    if ($Summary -match '^OK|revenu|back above') { return 'Green' }
    if ($Summary -eq '') { return 'DarkGray' }
    return 'Gray'
}

# Âge d'une ligne de log en minutes.
function Get-LogAge($Time) {
    if ($null -eq $Time) { return 0 }
    try { return ((Get-Date) - ([datetime]$Time).ToLocalTime()).TotalMinutes } catch { return 0 }
}

# "3 min", "1 h", "2 j", "à l'instant".
function Format-ShortAgo($Time) {
    $minutes = Get-LogAge $Time
    if ($minutes -lt 1) { return '< 1 min' }
    if ($minutes -lt 60) { return ('{0} min' -f [int][Math]::Floor($minutes)) }
    if ($minutes -lt 2880) { return ('{0} h' -f [int][Math]::Floor($minutes / 60)) }
    return ((T '{0} j' '{0} d') -f [int][Math]::Floor($minutes / 1440))
}

function Format-Hashrate($Value, [string]$Unit) {
    if ($null -eq $Value) { return '–' }
    return ('{0:N2} {1}H/s' -f [double]$Value, $Unit)
}

# Hashrate en H/s, quelle que soit l'unité lue (K, M, G, T).
function ConvertTo-HashesPerSecond($Value, [string]$Unit) {
    $factor = 1.0
    switch ($Unit.ToUpperInvariant()) {
        'K' { $factor = 1e3 }
        'M' { $factor = 1e6 }
        'G' { $factor = 1e9 }
        'T' { $factor = 1e12 }
    }
    return [double]$Value * $factor
}

# Un total en H/s, dans l'unité la plus lisible : "3 412,8 TH/s".
function Format-HashrateTotal([double]$HashesPerSecond) {
    $units = @(@('T', 1e12), @('G', 1e9), @('M', 1e6), @('K', 1e3))
    foreach ($unit in $units) {
        if ($HashesPerSecond -ge $unit[1]) { return ('{0:N1} {1}H/s' -f ($HashesPerSecond / $unit[1]), $unit[0]) }
    }
    return ('{0:N1} H/s' -f $HashesPerSecond)
}

# === Solde Salad ===================================================================
# L'API Salad ne donne pas le solde : il est saisi à la main (menu S) et gardé dans
# balances.json, à côté de keys.json : { "<org>": { "amount": 42.5, "at": "...Z" } }.

function Get-BalancePath { return (Join-Path (Split-Path -Parent (Get-KeyringPath)) 'balances.json') }

function Get-Balances {
    $table = @{}
    $path = Get-BalancePath
    if (Test-Path -LiteralPath $path) {
        try {
            $data = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
            foreach ($property in $data.PSObject.Properties) {
                $amount = Get-Prop $property.Value 'amount'
                $at = Get-Prop $property.Value 'at'
                if ($null -ne $amount -and $at) { $table[$property.Name] = [pscustomobject]@{ Amount = [double]$amount; At = ([datetime]$at).ToLocalTime() } }
            }
        }
        catch { }
    }
    return $table
}

function Save-Balances($Table) {
    $path = Get-BalancePath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $out = @{}
    foreach ($key in $Table.Keys) { $out[$key] = @{ amount = $Table[$key].Amount; at = $Table[$key].At.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") } }
    [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $out -Depth 4))
}

# Solde saisi pour l'organisation active : { Amount, At } ou $null.
function Get-Balance {
    $table = Get-Balances
    if ($table.ContainsKey($script:Account.Org)) { return $table[$script:Account.Org] }
    return $null
}

function Set-Balance([double]$Amount) {
    $table = Get-Balances
    $table[$script:Account.Org] = [pscustomobject]@{ Amount = $Amount; At = (Get-Date) }
    Save-Balances $table
}

function Remove-Balance {
    $table = Get-Balances
    if ($table.ContainsKey($script:Account.Org)) { $table.Remove($script:Account.Org); Save-Balances $table }
}

# "45 min", "23 h", "2 j 3 h".
function Format-Duration([double]$Hours) {
    if ($Hours -lt 1) { return ('{0} min' -f [int][Math]::Floor($Hours * 60)) }
    if ($Hours -lt 24) { return ('{0} h' -f [int][Math]::Floor($Hours)) }
    $days = [int][Math]::Floor($Hours / 24)
    $rest = [int][Math]::Floor($Hours - $days * 24)
    if ($rest -eq 0) { return ((T '{0} j' '{0} d') -f $days) }
    return ((T '{0} j {1} h' '{0} d {1} h') -f $days, $rest)
}

# Dépense horaire de tous les groupes : { Min, Max, Machines, Unknown } (fourchette si
# plusieurs cartes sont cochées ; Unknown = prix inconnu pour certaines cartes).
function Get-GroupsRate($Groups) {
    $min = 0.0; $max = 0.0; $machines = 0; $unknown = $false
    foreach ($group in $Groups) {
        if ($group.Running -le 0) { continue }
        $machines += $group.Running
        $range = Get-GroupPriceRange $group
        if ($null -eq $range.Min) { $unknown = $true; continue }
        $min += $range.Min * $group.Running
        $max += $range.Max * $group.Running
    }
    return [pscustomobject]@{ Min = $min; Max = $max; Machines = $machines; Unknown = $unknown }
}

# Ligne « Solde » du menu 1. Solde réel du portail si le menu S l'a connecté ; sinon
# solde saisi, estimation du solde actuel (solde moins la dépense au rythme actuel
# depuis la saisie) ; puis autonomie au rythme actuel (le plus élevé de la fourchette,
# par prudence).
function Write-BalanceLine($Spend) {
    $live = Get-PortalBalance
    $balance = Get-Balance
    if ($null -eq $live -and $null -eq $balance) {
        if ($script:PortalError) { Write-Dim (T "Solde : portail Salad injoignable ($($script:PortalError)) et aucun solde saisi (menu S)." "Balance: Salad portal unreachable ($($script:PortalError)) and no balance entered (menu S).") }
        else { Write-Dim (T 'Solde : non saisi — menu S pour le saisir ou connecter le portail ; l''autonomie s''affichera ici.' 'Balance: not entered — menu S to enter it or connect the portal; the remaining time will show here.') }
        return
    }
    $rate = $Spend.Max
    Write-Segment (T '  Solde : ' '  Balance: ') 'DarkGray'
    if ($null -ne $live) {
        $estimate = $live.Amount
        Write-Segment (T "$(Format-Price $live.Amount 2) (portail Salad, $(Format-Ago $live.At))" "$(Format-Price $live.Amount 2) (Salad portal, $(Format-Ago $live.At))") 'White'
    }
    else {
        $elapsed = ((Get-Date) - $balance.At).TotalHours
        if ($elapsed -lt 0) { $elapsed = 0 }
        $estimate = $balance.Amount - $rate * $elapsed
        Write-Segment (T "$(Format-Price $balance.Amount 2) saisi $(Format-Ago $balance.At)" "$(Format-Price $balance.Amount 2) entered $(Format-Ago $balance.At)") 'White'
    }
    if ($Spend.Machines -eq 0) {
        Write-Segment (T '   ·   aucune machine en marche, pas de dépense en cours' '   ·   no running machine, nothing being spent') 'DarkGray'
        Write-Host ''
    }
    elseif ($rate -le 0) {
        Write-Segment (T '   ·   prix des cartes inconnu, autonomie impossible à estimer' '   ·   unknown GPU prices, remaining time cannot be estimated') 'Yellow'
        Write-Host ''
    }
    elseif ($estimate -le 0) {
        if ($null -ne $live) { Write-Segment (T '   ·   solde épuisé : Salad arrête les machines, recharge dans le portail.' '   ·   balance used up: Salad stops the machines, top up in the portal.') 'Red' }
        else { Write-Segment (T '   →   ≈ 0 $ maintenant : probablement épuisé, vérifie le portail et ressaisis le solde.' '   →   ≈ $0 now: probably used up, check the portal and enter the balance again.') 'Red' }
        Write-Host ''
    }
    else {
        $hours = $estimate / $rate
        $color = 'Green'
        if ($hours -lt 24) { $color = 'Yellow' }
        if ($hours -lt 6) { $color = 'Red' }
        $rateText = Format-Price $rate
        if ($Spend.Min -ne $Spend.Max) { $rateText = (T "au plus $rateText" "at most $rateText") }
        if ($Spend.Unknown) { $rateText += (T ', cartes sans prix non comptées' ', GPUs without a price not counted') }
        if ($null -eq $live) { Write-Segment (T "   →   ≈ $(Format-Price $estimate 2) maintenant" "   →   ≈ $(Format-Price $estimate 2) now") 'White' }
        Write-Segment '   ·   ' 'DarkGray'
        Write-Segment (T "autonomie ≈ $(Format-Duration $hours)" "remaining ≈ $(Format-Duration $hours)") $color
        Write-Segment (T " au rythme actuel ($rateText /h)" " at the current rate ($rateText /h)") 'DarkGray'
        Write-Host ''
    }
    if ($null -eq $live -and $script:PortalError) {
        Write-Dim (T "Portail Salad injoignable ($($script:PortalError)) : solde saisi affiché." "Salad portal unreachable ($($script:PortalError)): entered balance shown.")
    }
}

# === Tableaux ======================================================================

# Tableau des groupes avec prix/h estimé et totaux.
function Show-Groups($Groups) {
    $columns = @(
        (New-Column (T 'N°' '#') 'R'), (New-Column (T 'Groupe' 'Group') 'L' 6 24), (New-Column (T 'État' 'State')), (New-Column 'Machines' 'R'),
        (New-Column (T 'Cartes' 'GPUs') 'L' 8 24 $true), (New-Column (T 'Priorité' 'Priority')), (New-Column 'Image' 'L' 20 40), (New-Column 'Version' 'R'), (New-Column (T 'Prix/h' 'Price/h') 'R' 18)
    )
    $rows = New-Object System.Collections.ArrayList
    $totalMin = 0.0; $totalMax = 0.0; $machines = 0; $unknown = $false
    for ($n = 0; $n -lt $Groups.Count; $n++) {
        $group = $Groups[$n]
        $status = Get-GroupStatusInfo $group.Status
        $range = Get-GroupPriceRange $group
        $priceText = '–'
        if ($group.Running -gt 0) {
            if ($null -eq $range.Min) { $priceText = '?'; $unknown = $true }
            else {
                $totalMin += $range.Min * $group.Running
                $totalMax += $range.Max * $group.Running
                $priceText = Format-PriceRange ([pscustomobject]@{ Min = $range.Min * $group.Running; Max = $range.Max * $group.Running })
            }
            $machines += $group.Running
        }
        # Sans le compte Docker Hub (toujours le même) : l'étiquette reste lisible.
        $image = $group.Image -replace '^[^/:]+/', ''
        [void]$rows.Add(@(
            (New-Cell ([string]($n + 1)) $script:AccentColor),
            (New-Cell $group.Name 'White'),
            (New-Cell $status.Label $status.Color),
            "$($group.Running) / $($group.Replicas)",
            (Get-ClassesText $group),
            (Format-Priority $group.Priority),
            (New-Cell $image 'Gray'),
            [string]$group.Version,
            $priceText
        ))
    }
    Write-Host ''
    Write-Table $columns $rows
    $hour = Format-PriceRange ([pscustomobject]@{ Min = $totalMin; Max = $totalMax })
    $day = Format-PriceRange ([pscustomobject]@{ Min = $totalMin * 24; Max = $totalMax * 24 })
    Write-Segment (T '  Total : ' '  Total: ') 'DarkGray'
    Write-Segment (T "$machines machine(s) en marche" "$machines running machine(s)") 'White'
    Write-Segment '   ·   ' 'DarkGray'; Write-Segment "$hour /h" 'White'
    Write-Segment '   ·   ' 'DarkGray'; Write-Segment (T "$day /jour" "$day /day") 'White'
    if ($unknown) { Write-Segment (T '   (prix inconnu pour certaines cartes)' '   (unknown price for some GPUs)') 'Yellow' }
    Write-Host ''
    Write-BalanceLine (Get-GroupsRate $Groups)
    Write-MarketLine
}

# Tableau des machines d'un groupe, enrichi avec les logs. Renvoie les machines (pour la sélection).
function Show-Instances($Group, $Instances, [bool]$WithLogs = $true) {
    if ($Instances.Count -eq 0) { Write-Warn (T 'Aucune machine dans ce groupe pour le moment.' 'No machine in this group yet.'); return }
    $info = @{}
    if ($WithLogs) {
        Write-Step (T 'Lecture des logs des machines … ' 'Reading machine logs … ')
        $started = Get-Date
        $read = Get-MachineLogInfo $Group.Name $Instances
        $info = $read.Info
        $took = ('{0:N1} s' -f ((Get-Date) - $started).TotalSeconds)
        if (@($read.Errors).Count -eq 0) { Write-Host (T "ok ($took)" "ok ($took)") -ForegroundColor Green }
        else {
            $first = @($read.Errors)[0]
            Write-Host (T "partiel ($took) : $(@($read.Errors).Count) requête(s) sans réponse ($first)" "partial ($took): $(@($read.Errors).Count) request(s) failed ($first)") -ForegroundColor Yellow
        }
    }
    $columns = @(
        (New-Column (T 'N°' '#') 'R'), (New-Column 'Machine'), (New-Column (T 'État' 'State') 'L' 9 22), (New-Column 'Version' 'R'), (New-Column (T 'Depuis' 'Since') 'R' 6 12),
        (New-Column (T 'Carte' 'GPU') 'L' 5 22), (New-Column 'Hashrate' 'R'), (New-Column (T 'Prix/h' 'Price/h') 'R'), (New-Column (T 'Chien de garde' 'Watchdog') 'L' 24 40)
    )
    $rows = New-Object System.Collections.ArrayList
    $total = 0.0; $approx = $false; $running = 0
    # Hashrate total des machines en marche (somme des dernières lectures) et nombre de lectures.
    $hashTotal = 0.0; $hashRead = 0
    for ($n = 0; $n -lt $Instances.Count; $n++) {
        $instance = $Instances[$n]
        $state = Get-InstanceStateInfo $instance.State $instance.Ready $instance.Progress
        $model = ''; $hashText = '–'; $hashColor = 'Green'; $priceText = '–'; $watch = ''; $watchColor = 'DarkGray'
        if ($info.ContainsKey($instance.MachineId)) {
            $detail = $info[$instance.MachineId]
            $model = $detail.Model
            if ($null -ne $detail.Hashrate) {
                $hashText = Format-Hashrate $detail.Hashrate $detail.Unit
                if ([double]$detail.Hashrate -eq 0) { $hashColor = 'Red' }
                # Lecture de plus de 5 min : la machine ne produit peut-être plus de stats.
                if ((Get-LogAge $detail.HashTime) -gt 5) { $hashColor = 'Yellow'; $hashText += " ($(Format-ShortAgo $detail.HashTime))" }
                if ($instance.State -eq 'running') { $hashTotal += ConvertTo-HashesPerSecond $detail.Hashrate $detail.Unit; $hashRead++ }
            }
            if ($detail.Watchdog) {
                $watch = "$($detail.Watchdog) · $(Format-ShortAgo $detail.WatchTime)"
                $watchColor = Get-WatchdogColor $detail.Watchdog
            }
        }
        if ($instance.State -eq 'running') {
            $running++
            $price = $null
            if ($model) { $price = Get-ClassPrice (Find-GpuClassByModel $model $Group.Classes) $Group.Priority }
            if ($null -eq $price) {
                $range = Get-GroupPriceRange $Group
                if ($null -ne $range.Max) { $price = $range.Max; $approx = $true; $priceText = '≈ ' + (Format-Price $price) }
                else { $priceText = '?' }
            }
            else { $priceText = Format-Price $price }
            if ($null -ne $price) { $total += $price }
        }
        $modelText = $model
        if (-not $modelText) { $modelText = '–' }
        [void]$rows.Add(@(
            (New-Cell ([string]($n + 1)) $script:AccentColor),
            (New-Cell $instance.Short 'White'),
            (New-Cell $state.Label $state.Color),
            [string]$instance.Version,
            (Format-ShortAgo $instance.Updated),
            $modelText,
            (New-Cell $hashText $hashColor),
            $priceText,
            (New-Cell $watch $watchColor)
        ))
    }
    Write-Host ''
    Write-Table $columns $rows
    Write-Segment (T '  Total : ' '  Total: ') 'DarkGray'
    Write-Segment (T "$running machine(s) en marche" "$running running machine(s)") 'White'
    Write-Segment '   ·   ' 'DarkGray'; Write-Segment "$(if ($approx) { '≈ ' })$(Format-Price $total) /h" 'White'
    Write-Segment '   ·   ' 'DarkGray'; Write-Segment (T "$(if ($approx) { '≈ ' })$(Format-Price ($total * 24) 2) /jour" "$(if ($approx) { '≈ ' })$(Format-Price ($total * 24) 2) /day") 'White'
    if ($hashRead -gt 0) {
        Write-Segment '   ·   ' 'DarkGray'; Write-Segment (Format-HashrateTotal $hashTotal) 'White'
        if ($hashRead -lt $running) { Write-Segment (T " ($hashRead machine(s) sur $running lue(s))" " ($hashRead of $running machines read)") 'Yellow' }
    }
    Write-Host ''
    if ($WithLogs -and $hashRead -gt 0) {
        # Flotte louée, pour les facteurs des pools : hashrate total et « changée dans les 24 h »
        # (une machine en marche depuis moins d'un jour, ou des machines en marche non lues).
        $changed = ($hashRead -lt $running)
        foreach ($instance in $Instances) {
            if ($instance.State -eq 'running' -and (Get-LogAge $instance.Updated) -lt 1440) { $changed = $true }
        }
        $script:LastFleet = [pscustomobject]@{ Hps = $hashTotal; At = (Get-Date); Changed = $changed; Count = $running }
        $cost = $null
        if ($total -gt 0) { $cost = $total * 24 }
        Write-RevenueTable $hashTotal $cost $approx
        Write-WalletLines
    }
}

# === Logs : affichage ===============================================================

# Couleur d'une ligne de logs selon son contenu.
function Get-LogLineColor([string]$Line) {
    if ($Line -match '^\[salad\].*(VERDICT|refusee)') { return 'Red' }
    if ($Line -match '^\[salad\].*<\s*seuil') { return 'Yellow' }
    if ($Line -match '^\[salad\]') { return 'Magenta' }
    if ($Line -match '(?i)erreur|error|failed|rejected|warning|attention') { return 'Red' }
    if ($Line -match '^\[rentingminers\]') { return 'Cyan' }
    if ($Line -match '(?i)accepted|H/s') { return 'Green' }
    if ($Line -match '^\[cpu\]') { return 'Gray' }
    return ''
}

function Write-LogLine($Line, [bool]$ShowMachine) {
    Write-Segment ('  ' + (Format-LocalTime $Line.Time 'HH:mm:ss') + ' ') 'DarkGray'
    if ($ShowMachine) { Write-Segment ('[' + $Line.Short + '] ') 'DarkCyan' }
    $color = Get-LogLineColor $Line.Text
    if ($color) { Write-Host $Line.Text -ForegroundColor $color } else { Write-Host $Line.Text }
}

# Dernières lignes d'un groupe (ou d'une machine), les plus anciennes d'abord.
function Get-RecentLogLines([string]$GroupName, [string]$MachineId, [int]$Count, [int]$MaxMinutes = 120) {
    $lines = Get-LatestLogLines (Get-GroupLogQuery $GroupName $MachineId) $Count $MaxMinutes
    [array]::Reverse($lines)
    return , $lines
}

function Show-Logs([string]$GroupName, [string]$MachineId = '', [string]$Title = '') {
    if (-not $Title) { $Title = T "Logs  ·  Groupe $GroupName" "Logs  ·  Group $GroupName" }
    Write-Rule (T "$Title  ·  $($script:LogLines) dernières lignes" "$Title  ·  last $($script:LogLines) lines")
    try { $lines = Get-RecentLogLines $GroupName $MachineId $script:LogLines }
    catch { Write-Warn (T "Logs indisponibles ($($_.Exception.Message))." "Logs unavailable ($($_.Exception.Message))."); return }
    if ($lines.Count -eq 0) {
        Write-Segment '  │ ' $script:BorderColor
        Write-Host (T '(pas encore de logs)' '(no logs yet)') -ForegroundColor Yellow
    }
    else {
        foreach ($line in $lines) { Write-LogLine $line (-not $MachineId) }
    }
    Write-Host ('  ' + ('─' * (Get-AvailableWidth))) -ForegroundColor $script:BorderColor
}

# === Logs en direct ===================================================================

# Filtres proposés : libellé, expression régulière (vide = tout).
function Get-LogFilters {
    return @(
        @{ Label = (T 'Tout' 'Everything');                                  Pattern = '' },
        @{ Label = 'Hashrates';                                              Pattern = 'H/s' },
        @{ Label = (T 'Shares, erreurs et alertes' 'Shares, errors and warnings'); Pattern = '(?i)accepted|rejected|error|erreur|failed|warning|attention' },
        @{ Label = (T 'Chien de garde [salad]' 'Watchdog [salad]');          Pattern = '^\[salad\]' },
        @{ Label = (T 'Messages de l''image' 'Image messages');              Pattern = '^\[rentingminers\]' }
    )
}

# Choix du filtre : un des filtres proposés, ou un texte libre.
function Read-LogFilter {
    $filters = Get-LogFilters
    $lines = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $filters.Count; $n++) {
        [void]$lines.Add(@((New-Cell ('{0}   ' -f ($n + 1)) 'Yellow'), $filters[$n].Label))
    }
    [void]$lines.Add(@((New-Cell ('{0}   ' -f ($filters.Count + 1)) 'Yellow'), (T 'Texte libre (un mot, ou une expression régulière)' 'Free text (a word, or a regular expression)')))
    Write-Box (T 'Filtre' 'Filter') $lines
    while ($true) {
        $answer = Read-Answer (T 'Quel filtre' 'Which filter') (T 'Entrée sans rien = tout' 'Enter alone = everything')
        if ($answer -eq '' -or $answer -eq '1') { return [pscustomobject]@{ Label = $filters[0].Label; Pattern = '' } }
        if ($answer -match '^\d+$' -and [int]$answer -ge 2 -and [int]$answer -le $filters.Count) {
            $chosen = $filters[[int]$answer - 1]
            return [pscustomobject]@{ Label = $chosen.Label; Pattern = $chosen.Pattern }
        }
        if ($answer -eq [string]($filters.Count + 1)) {
            $text = Read-Answer (T 'Texte à chercher' 'Text to look for') (T 'Exemples : VERDICT   share   GPU0   ·   Entrée sans rien = tout' 'Examples: VERDICT   share   GPU0   ·   Enter alone = everything')
            if ($text -eq '') { return [pscustomobject]@{ Label = $filters[0].Label; Pattern = '' } }
            try { [void][regex]::new($text) } catch { $text = [regex]::Escape($text) }
            return [pscustomobject]@{ Label = (T "« $text »" "`"$text`""); Pattern = "(?i)$text" }
        }
        Write-Warn (T "Réponse non comprise : tape un numéro entre 1 et $($filters.Count + 1)." "Not understood: type a number between 1 and $($filters.Count + 1).")
    }
}

function Test-QuitKey {
    try {
        while ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.Character -eq 'q' -or $key.Character -eq 'Q' -or $key.VirtualKeyCode -eq 27) { return $true }
        }
    }
    catch { }
    return $false
}

# Choix d'un groupe dans la liste ; renvoie le groupe ou $null.
function Select-Group([string]$Prompt, $Groups = $null) {
    if ($null -eq $Groups) { $Groups = Get-Groups }
    if ($Groups.Count -eq 0) { Write-Warn (T 'Aucun groupe dans ce projet.' 'No group in this project.'); return $null }
    Show-Groups $Groups
    $index = Read-Index $Groups.Count $Prompt (T 'Tape son numéro   ·   Entrée sans rien = retour au menu' 'Type its number   ·   Enter alone = back to the menu')
    if ($index -lt 0) { return $null }
    return $Groups[$index]
}

function Invoke-LiveLogs {
    Write-Rule (T 'Logs en direct' 'Live logs')
    $group = Select-Group (T 'Quel groupe' 'Which group')
    if (-not $group) { return }
    $instances = Get-Instances $group.Name
    $machineId = ''
    $where = T "groupe $($group.Name), toutes les machines" "group $($group.Name), all machines"
    if ($instances.Count -gt 0) {
        Show-Instances $group $instances $false
        $index = Read-Index $instances.Count (T 'Quelle machine' 'Which machine') (T 'Tape son numéro   ·   Entrée sans rien = toutes les machines du groupe' 'Type its number   ·   Enter alone = all machines of the group')
        if ($index -ge 0) { $machineId = $instances[$index].MachineId; $where = "machine $($instances[$index].Short)" }
    }
    $filter = Read-LogFilter

    try { [Console]::Clear() } catch { }
    Write-Rule (T "Logs en direct  ·  $where  ·  filtre : $($filter.Label)  ·  rafraîchi toutes les $LogRefreshSeconds s  ·  Q = retour au menu" "Live logs  ·  $where  ·  filter: $($filter.Label)  ·  refreshed every $LogRefreshSeconds s  ·  Q = back to the menu")
    $query = Get-GroupLogQuery $group.Name $machineId
    # Les lignes arrivent chez Salad avec un peu de retard : chaque tour relit les
    # 3 dernières minutes et n'affiche que les lignes jamais vues.
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $order = New-Object System.Collections.Generic.Queue[string]
    $first = $true
    $lastNew = Get-Date
    $silentNotice = $false
    while ($true) {
        $now = Get-Date
        $start = $now.AddMinutes(-3)
        if ($first) { $start = $now.AddMinutes(-15) }
        $batch = @()
        try {
            $cursor = $start
            for ($page = 0; $page -lt 5; $page++) {
                $lines = Get-LogEntries $query $cursor $now 'asc' 100
                $batch += $lines
                if ($lines.Count -lt 100) { break }
                try { $cursor = ([datetime]$lines[-1].Time).ToLocalTime() } catch { break }
            }
        }
        catch { Write-Warn (T "Salad ne répond pas ($($_.Exception.Message)), nouvel essai…" "Salad is not answering ($($_.Exception.Message)), retrying…") }
        if ($first) {
            if ($batch.Count -gt $script:LogLines) { $batch = @($batch | Select-Object -Last $script:LogLines) }
            if ($batch.Count -eq 0) { Write-Dim (T '(pas encore de logs)' '(no logs yet)') }
            $first = $false
        }
        $shown = 0
        foreach ($line in $batch) {
            $key = "$($line.Time)|$($line.Machine)|$($line.Text)"
            if ($seen.Contains($key)) { continue }
            [void]$seen.Add($key); $order.Enqueue($key)
            while ($order.Count -gt 3000) { [void]$seen.Remove($order.Dequeue()) }
            if ($filter.Pattern -and $line.Text -notmatch $filter.Pattern) { continue }
            Write-LogLine $line (-not $machineId)
            $shown++
        }
        $stamp = (Get-Date).ToString('HH:mm:ss')
        try { $Host.UI.RawUI.WindowTitle = "Salad-Switch-Log  ·  logs $($group.Name)  ·  $stamp" } catch { }
        if ($shown -gt 0) { $lastNew = Get-Date; $silentNotice = $false }
        elseif (-not $silentNotice -and ((Get-Date) - $lastNew).TotalSeconds -ge 60) {
            Write-Dim (T "· rien de nouveau depuis 1 min (dernier rafraîchissement $stamp) ·" "· nothing new for 1 min (last refresh $stamp) ·")
            $silentNotice = $true
        }

        # Attente, en guettant la touche Q.
        $deadline = (Get-Date).AddSeconds($LogRefreshSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-QuitKey) {
                try { $Host.UI.RawUI.WindowTitle = 'Salad-Switch-Log' } catch { }
                Write-Host ''
                Write-Dim (T 'Retour au menu.' 'Back to the menu.')
                return
            }
            Start-Sleep -Milliseconds 150
        }
    }
}

# === Pearl (PRL) : cours, réseau, rentabilité ========================================
# Sources, toutes publiques et sans clé, gardées 5 min :
#   - CoinGecko (id pearl-2)        : cours en $, variation 24 h ;
#   - whattomine (coin 469)         : hashrate réseau, récompense, temps de bloc ;
#   - unMineable (pool pearlpow)    : rendement réel de la pool par hash (simulateur) ;
#   - HeroMiners (pearl.herominers) : stats réseau et prix vus par la pool, frais.

function Get-PearlError($ErrorRecord) {
    $status = 0
    try { if ($ErrorRecord.Exception.Response) { $status = [int]$ErrorRecord.Exception.Response.StatusCode } } catch { }
    if ($status -eq 429) { return (T 'trop de demandes (429), réessaie dans une minute' 'too many requests (429), try again in a minute') }
    if ($status) { return (T "erreur $status" "error $status") }
    return (T "pas de réponse ($($ErrorRecord.Exception.Message))" "no answer ($($ErrorRecord.Exception.Message))")
}

function Invoke-PearlGet([string]$Uri) {
    return Invoke-RestMethod -Uri $Uri -Headers @{ Accept = 'application/json' } -TimeoutSec 12
}

# { At, Usd, Change24, NetHash, BlockReward, BlockTime, Difficulty,
#   UmYield (PRL par H/s et par jour, brut), UmFee (0.01), UmUsd,
#   HmNetHash, HmReward, HmBlockTime, HmFee (%), HmUsd, HmScale (hash de la pool -> H/s), HmEffort7d,
#   Errors }.
function Get-PearlMarket {
    if ($script:Market -and ((Get-Date) - $script:Market.At).TotalMinutes -lt 5) { return $script:Market }
    $market = [pscustomobject]@{
        At = (Get-Date); Usd = $null; Change24 = $null
        NetHash = $null; BlockReward = $null; BlockTime = $null; Difficulty = $null
        UmYield = $null; UmFee = $null; UmUsd = $null
        HmNetHash = $null; HmReward = $null; HmBlockTime = $null; HmFee = $null; HmUsd = $null; HmScale = $null; HmEffort7d = $null
        Errors = @()
    }
    try {
        $data = Invoke-PearlGet "$($script:CoinGeckoBase)/simple/price?ids=pearl-2&vs_currencies=usd&include_24hr_change=true"
        $coin = Get-Prop $data 'pearl-2'
        if ($null -ne (Get-Prop $coin 'usd')) { $market.Usd = [double](Get-Prop $coin 'usd') }
        if ($null -ne (Get-Prop $coin 'usd_24h_change')) { $market.Change24 = [double](Get-Prop $coin 'usd_24h_change') }
        if ($null -eq $market.Usd) { $market.Errors += (T 'CoinGecko : cours absent de la réponse' 'CoinGecko: price missing from the answer') }
    }
    catch { $market.Errors += "CoinGecko : $(Get-PearlError $_)" }
    try {
        $data = Invoke-PearlGet "$($script:WhatToMineBase)/coins/469.json"
        if ($null -ne (Get-Prop $data 'nethash')) { $market.NetHash = [double](Get-Prop $data 'nethash') }
        if ($null -ne (Get-Prop $data 'block_reward')) { $market.BlockReward = [double](Get-Prop $data 'block_reward') }
        if ($null -ne (Get-Prop $data 'block_time')) { $market.BlockTime = [double](Get-Prop $data 'block_time') }
        if ($null -ne (Get-Prop $data 'difficulty')) { $market.Difficulty = [double](Get-Prop $data 'difficulty') }
        if ($null -eq $market.NetHash) { $market.Errors += (T 'whattomine : hashrate réseau absent de la réponse' 'whattomine: network hashrate missing from the answer') }
    }
    catch { $market.Errors += "whattomine : $(Get-PearlError $_)" }
    try {
        # Simulateur unMineable pour 1 PH/s : la réponse donne le rendement par hash et par jour.
        $body = @{
            mode = 'advanced'; coin = 'PRL'; algorithm = 'pearlpow'; hashrate_hs = '1000000000000000'
            scenario_set = 'default'; referral_discount = $false
            shock_profile = @{
                yield = @{ down_percentage = 0; up_percentage = 0 }
                algorithm_coin_price = @{ down_percentage = 0; up_percentage = 0 }
                payout_coin_price = @{ down_percentage = 0; up_percentage = 0 }
            }
        }
        $json = ConvertTo-Json -InputObject $body -Depth 6 -Compress
        $data = Invoke-RestMethod -Method Post -Uri "$($script:UnmineableBase)/v5/calculator/simulate" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json' -Headers @{ Accept = 'application/json' } -TimeoutSec 15
        $algo = @(Get-Prop (Get-Prop $data 'data') 'algorithms')
        if ($algo.Count -gt 0) {
            $assumptions = Get-Prop $algo[0] 'assumptions'
            if ($null -ne (Get-Prop $assumptions 'current_yield_coin_per_hash_per_day')) { $market.UmYield = [double](Get-Prop $assumptions 'current_yield_coin_per_hash_per_day') }
            if ($null -ne (Get-Prop $assumptions 'fee_ratio')) { $market.UmFee = [double](Get-Prop $assumptions 'fee_ratio') }
            if ($null -ne (Get-Prop $assumptions 'algorithm_coin_price_usdt')) { $market.UmUsd = [double](Get-Prop $assumptions 'algorithm_coin_price_usdt') }
        }
        if ($null -eq $market.UmYield) { $market.Errors += (T 'unMineable : rendement absent de la réponse' 'unMineable: yield missing from the answer') }
    }
    catch { $market.Errors += "unMineable : $(Get-PearlError $_)" }
    try {
        $data = Invoke-PearlGet "$($script:HeroMinersBase)/api/stats"
        $network = Get-Prop $data 'network'
        $pool = Get-Prop $data 'pool'
        $config = Get-Prop $data 'config'
        $last = Get-Prop $data 'lastblock'
        $units = 1e8
        if ($null -ne (Get-Prop $config 'coinUnits')) { $units = [double](Get-Prop $config 'coinUnits') }
        if ($null -ne (Get-Prop $network 'networkHashps')) { $market.HmNetHash = [double](Get-Prop $network 'networkHashps') }
        if ($null -ne (Get-Prop $last 'reward')) { $market.HmReward = [double](Get-Prop $last 'reward') / $units }
        if ($null -ne (Get-Prop $network 'difficultyTarget')) { $market.HmBlockTime = [double](Get-Prop $network 'difficultyTarget') }
        elseif ($null -ne (Get-Prop $config 'coinDifficultyTarget')) { $market.HmBlockTime = [double](Get-Prop $config 'coinDifficultyTarget') }
        if ($null -ne (Get-Prop $config 'fee')) { $market.HmFee = [double](Get-Prop $config 'fee') }
        $price = Get-Prop $pool 'price'
        if ($null -ne (Get-Prop $price 'usd')) { $market.HmUsd = [double](Get-Prop $price 'usd') }
        $real = Get-Prop $pool 'realHashrate'
        $scaled = Get-Prop $pool 'hashrate'
        if ($null -ne $real -and $null -ne $scaled -and [double]$scaled -gt 0) { $market.HmScale = [double]$real / [double]$scaled }
        if ($null -ne (Get-Prop $pool 'effort_7d')) { $market.HmEffort7d = [double](Get-Prop $pool 'effort_7d') }
        if ($null -eq $market.HmNetHash -or $null -eq $market.HmReward -or $null -eq $market.HmBlockTime) { $market.Errors += (T 'HeroMiners : stats réseau incomplètes' 'HeroMiners: incomplete network stats') }
    }
    catch { $market.Errors += "HeroMiners : $(Get-PearlError $_)" }
    $script:Market = $market
    return $market
}

# "49,5 EH/s", "3 412,8 TH/s". $MaxUnit = 'T' pour rester en TH/s comme les tableaux de machines.
function Format-NetworkHashrate([double]$HashesPerSecond, [int]$Decimals = 1, [string]$MaxUnit = 'E') {
    $units = @(@('E', 1e18), @('P', 1e15), @('T', 1e12), @('G', 1e9), @('M', 1e6), @('K', 1e3))
    $pattern = '{0:N' + $Decimals + '} {1}H/s'
    $allowed = $false
    foreach ($unit in $units) {
        if ($unit[0] -eq $MaxUnit) { $allowed = $true }
        if ($allowed -and $HashesPerSecond -ge $unit[1]) { return ($pattern -f ($HashesPerSecond / $unit[1]), $unit[0]) }
    }
    return (('{0:N' + $Decimals + '} H/s') -f $HashesPerSecond)
}

# "3 min 11 s"
function Format-BlockTime([double]$Seconds) {
    $minutes = [int][Math]::Floor($Seconds / 60)
    $rest = [int][Math]::Round($Seconds - $minutes * 60)
    if ($minutes -eq 0) { return "$rest s" }
    if ($rest -eq 0) { return "$minutes min" }
    return "$minutes min $rest s"
}

# Ligne « PRL : 1,01 $ (−5,3 % / 24 h) · réseau 49,5 EH/s · bloc 2 283 PRL / 3 min 11 s ».
function Write-MarketLine {
    $market = Get-PearlMarket
    if ($null -eq $market.Usd -and $null -eq $market.NetHash) {
        Write-Dim (T "PRL : cours et réseau indisponibles ($($market.Errors -join ' ; '))." "PRL: price and network unavailable ($($market.Errors -join '; ')).")
        return
    }
    Write-Segment '  PRL : ' 'DarkGray'
    if ($null -ne $market.Usd) {
        Write-Segment (Format-Price $market.Usd 3) 'White'
        if ($null -ne $market.Change24) {
            $color = 'Green'
            if ($market.Change24 -lt 0) { $color = 'Red' }
            Write-Segment ' (' 'DarkGray'
            Write-Segment (('{0}{1:N1} %' -f $(if ($market.Change24 -ge 0) { '+' } else { '' }), $market.Change24) + (T ' / 24 h' ' / 24 h')) $color
            Write-Segment ')' 'DarkGray'
        }
    }
    else { Write-Segment (T 'cours indisponible' 'price unavailable') 'Yellow' }
    if ($null -ne $market.NetHash) {
        Write-Segment (T '   ·   réseau ' '   ·   network ') 'DarkGray'
        Write-Segment (Format-NetworkHashrate $market.NetHash) 'White'
        if ($null -ne $market.BlockReward -and $null -ne $market.BlockTime) {
            Write-Segment (T '   ·   bloc ' '   ·   block ') 'DarkGray'
            Write-Segment (('{0:N0} PRL / ' -f $market.BlockReward) + (Format-BlockTime $market.BlockTime)) 'White'
        }
    }
    else { Write-Segment (T '   ·   réseau indisponible' '   ·   network unavailable') 'Yellow' }
    Write-Host ''
    $lineErrors = @($market.Errors | Where-Object { $_ -match '^(CoinGecko|whattomine)' })
    if ($lineErrors.Count -gt 0) { Write-Dim (T "PRL : $($lineErrors -join ' ; ')." "PRL: $($lineErrors -join '; ').") }
}

# PRL théoriques par jour d'un hashrate (H/s), d'après le réseau (whattomine), sans frais ; $null sans données.
function Get-TheoreticalPrlPerDay([double]$HashesPerSecond) {
    $market = Get-PearlMarket
    if ($null -eq $market.NetHash -or $null -eq $market.BlockReward -or $null -eq $market.BlockTime -or $market.NetHash -le 0 -or $market.BlockTime -le 0) { return $null }
    return ($HashesPerSecond / $market.NetHash) * (86400 / $market.BlockTime) * $market.BlockReward
}

# Les estimations de revenu d'un hashrate (H/s), en PRL/jour et $/jour : { Source, Prl, Usd, Note } ;
# une source sans données est absente. S'y ajoute la pool à facteur saisi à la main (menu P).
function Get-RevenueEstimates([double]$HashesPerSecond) {
    $market = Get-PearlMarket
    $rows = @()
    if ($null -ne $market.NetHash -and $null -ne $market.BlockReward -and $null -ne $market.BlockTime -and $market.NetHash -gt 0 -and $market.BlockTime -gt 0) {
        $prl = ($HashesPerSecond / $market.NetHash) * (86400 / $market.BlockTime) * $market.BlockReward
        $usd = $null
        if ($null -ne $market.Usd) { $usd = $prl * $market.Usd }
        $rows += [pscustomobject]@{ Source = 'whattomine'; Prl = $prl; Usd = $usd; Note = (T 'théorique : part du réseau × blocs par jour × récompense' 'theoretical: network share × blocks per day × reward') }
    }
    if ($null -ne $market.UmYield -and $market.UmYield -gt 0) {
        $fee = 0.0
        if ($null -ne $market.UmFee) { $fee = $market.UmFee }
        $prl = $HashesPerSecond * $market.UmYield * (1 - $fee)
        $price = $market.UmUsd
        if ($null -eq $price) { $price = $market.Usd }
        $usd = $null
        if ($null -ne $price) { $usd = $prl * $price }
        $rows += [pscustomobject]@{ Source = 'unMineable'; Prl = $prl; Usd = $usd; Note = ((T 'rendement réel de la pool, net de {0:N0} % de frais' 'real pool yield, net of {0:N0} % fee') -f ($fee * 100)) }
    }
    if ($null -ne $market.HmNetHash -and $null -ne $market.HmReward -and $null -ne $market.HmBlockTime -and $market.HmNetHash -gt 0 -and $market.HmBlockTime -gt 0) {
        $fee = 0.0
        if ($null -ne $market.HmFee) { $fee = $market.HmFee / 100 }
        $prl = ($HashesPerSecond / $market.HmNetHash) * (86400 / $market.HmBlockTime) * $market.HmReward * (1 - $fee)
        $price = $market.HmUsd
        if ($null -eq $price) { $price = $market.Usd }
        $usd = $null
        if ($null -ne $price) { $usd = $prl * $price }
        $note = ((T 'stats réseau et cours de la pool, net de {0:N0} % de frais' 'pool network stats and price, net of {0:N0} % fee') -f ($fee * 100))
        if ($null -ne $market.HmEffort7d) { $note += ((T ' ; effort 7 j {0:N0} %' '; 7-day effort {0:N0} %') -f ($market.HmEffort7d * 100)) }
        $rows += [pscustomobject]@{ Source = 'HeroMiners'; Prl = $prl; Usd = $usd; Note = $note }
    }
    $manual = Get-ManualPool
    if ($manual -and $null -ne $market.NetHash) {
        $prl = (Get-TheoreticalPrlPerDay $HashesPerSecond) * $manual.Factor
        $usd = $null
        if ($null -ne $market.Usd) { $usd = $prl * $market.Usd }
        $rows += [pscustomobject]@{ Source = ('{0} (×{1:N2})' -f $manual.Name, $manual.Factor); Prl = $prl; Usd = $usd; Note = (T 'théorique × ton ratio saisi (menu P)' 'theoretical × your entered ratio (menu P)') }
    }
    return , $rows
}

# Tableau de rentabilité d'un hashrate (H/s), source par source, comparé au coût par jour
# si connu. $CostApprox : le coût est approximatif.
function Write-RevenueTable([double]$HashesPerSecond, $CostPerDay = $null, [bool]$CostApprox = $false) {
    if ($HashesPerSecond -le 0) { return }
    $market = Get-PearlMarket
    $estimates = Get-RevenueEstimates $HashesPerSecond
    if ($estimates.Count -eq 0) {
        Write-Dim (T "Rentabilité : aucune source ne répond ($($market.Errors -join ' ; '))." "Profitability: no source answers ($($market.Errors -join '; ')).")
        return
    }
    Write-Host ''
    Write-Segment (T "  Rentabilité pour $(Format-NetworkHashrate $HashesPerSecond 1 'T')" "  Profitability for $(Format-NetworkHashrate $HashesPerSecond 1 'T')") 'White'
    if ($null -ne $CostPerDay) {
        $prefix = ''
        if ($CostApprox) { $prefix = '≈ ' }
        Write-Segment (T "   ·   coût $prefix$(Format-Price $CostPerDay 2) /jour" "   ·   cost $prefix$(Format-Price $CostPerDay 2) /day") 'DarkGray'
    }
    Write-Host ''
    $columns = @((New-Column 'Source'), (New-Column (T 'PRL/jour' 'PRL/day') 'R'), (New-Column (T '$/jour' '$/day') 'R'))
    if ($null -ne $CostPerDay) { $columns += (New-Column (T 'Résultat/jour' 'Result/day') 'R') }
    $rows = New-Object System.Collections.ArrayList
    foreach ($estimate in $estimates) {
        $cells = @((New-Cell $estimate.Source 'White'), ('{0:N1}' -f $estimate.Prl))
        if ($null -ne $estimate.Usd) { $cells += (Format-Price $estimate.Usd 2) } else { $cells += '–' }
        if ($null -ne $CostPerDay) {
            if ($null -ne $estimate.Usd) {
                $diff = $estimate.Usd - [double]$CostPerDay
                $color = 'Green'
                if ($diff -lt 0) { $color = 'Red' }
                $cells += (New-Cell (('{0}{1}' -f $(if ($diff -ge 0) { '+' } else { '' }), (Format-Price $diff 2))) $color)
            }
            else { $cells += '–' }
        }
        [void]$rows.Add($cells)
    }
    Write-Table $columns $rows
    $tableErrors = @($market.Errors | Where-Object { $_ -match '^(whattomine|unMineable|HeroMiners)' })
    if ($tableErrors.Count -gt 0) { Write-Dim (T "Sources sans réponse : $($tableErrors -join ' ; ')." "Sources without answer: $($tableErrors -join '; ').") }
}
# === Portefeuille sur les pools (HeroMiners, unMineable) =============================
# Adresses PRL gardées dans pools.json, à côté de keys.json (une adresse est publique), et
# la pool à facteur saisi à la main (pool sans API) :
#   { "herominers": "prl1p...", "unmineable": "prl1p...", "manual_name": "Kryptex", "manual_factor": 0.8 }
# Tableau « Puissance » (sous la rentabilité et en tête du menu P) : par pool, puissance
# matériel (hashrate total des logs du dernier affichage des machines) / puissance vue par
# la pool à l'instant / ratio ; puis le total des pools.

$script:PrlAddressPattern = '^prl1p[023456789acdefghjklmnpqrstuvwxyz]{58}$'

function Get-PoolsPath { return (Join-Path (Split-Path -Parent (Get-KeyringPath)) 'pools.json') }

# Table pool -> adresse.
function Get-PoolWallets {
    $table = @{}
    $path = Get-PoolsPath
    if (Test-Path -LiteralPath $path) {
        try {
            $data = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
            foreach ($property in $data.PSObject.Properties) {
                if ($property.Value) { $table[$property.Name] = [string]$property.Value }
            }
        }
        catch { }
    }
    return $table
}

function Save-PoolWallets($Table) {
    $path = Get-PoolsPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $out = @{}
    foreach ($key in $Table.Keys) { $out[$key] = $Table[$key] }
    [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $out -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
}

function Set-PoolWallet([string]$Pool, [string]$Address) {
    $table = Get-PoolWallets
    if ($Address) { $table[$Pool] = $Address } else { $table.Remove($Pool) }
    Save-PoolWallets $table
    $script:Wallets = $null
}

# Pool à facteur saisi à la main : { Name, Factor } ou $null.
function Get-ManualPool {
    $table = Get-PoolWallets
    if ($table.ContainsKey('manual_name') -and $table.ContainsKey('manual_factor')) {
        $factor = 0.0
        if ([double]::TryParse([string]$table['manual_factor'], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$factor) -and $factor -gt 0) {
            return [pscustomobject]@{ Name = [string]$table['manual_name']; Factor = $factor }
        }
    }
    return $null
}

function Set-ManualPool([string]$Name, $Factor) {
    $table = Get-PoolWallets
    if ($Name -and $null -ne $Factor) {
        $table['manual_name'] = $Name
        $table['manual_factor'] = ([double]$Factor).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    else { $table.Remove('manual_name'); $table.Remove('manual_factor') }
    Save-PoolWallets $table
}

# Hashrate loué connu de la session (dernier affichage des machines) : { Hps, At, Changed, Count } ou $null.
function Get-RentedFleet {
    if ($null -eq $script:LastFleet -or $script:LastFleet.Hps -le 0) { return $null }
    return $script:LastFleet
}

# Puissance vue par la pool à l'instant (H/s) d'un rapport, ou $null.
function Get-PoolPower($Report) {
    if ($Report.Error) { return $null }
    return $Report.Hashrate
}

function Format-Ratio($Ratio) {
    if ($null -eq $Ratio) { return '–' }
    return ('×{0:N2}' -f [double]$Ratio)
}

function Get-RatioColor($Ratio) {
    if ($null -eq $Ratio) { return 'DarkGray' }
    if ($Ratio -ge 0.95) { return 'Green' }
    if ($Ratio -ge 0.85) { return 'Yellow' }
    return 'Red'
}

# "prl1p…hgwx"
function Format-ShortAddress([string]$Address) {
    if ($Address.Length -le 12) { return $Address }
    return $Address.Substring(0, 5) + '…' + $Address.Substring($Address.Length - 4)
}

function Format-Prl($Value, [int]$Decimals = 1) {
    if ($null -eq $Value) { return '–' }
    return (('{0:N' + $Decimals + '} PRL') -f [double]$Value)
}

# Rapport HeroMiners d'une adresse : { Pool, Address, Hashrate, Hashrate1h, Hashrate24h, Workers,
# WorkersOnline, Balance, Paid, Paid24h, Paid7d, Today, Yesterday, Avg7, LastShare, Error }.
function Get-HeroMinersWallet([string]$Address) {
    $report = [pscustomobject]@{ Pool = 'HeroMiners'; Address = $Address; Hashrate = $null; Hashrate1h = $null; Hashrate24h = $null; Workers = 0; WorkersOnline = 0
        Balance = $null; Paid = $null; Paid24h = $null; Paid7d = $null; Today = $null; Yesterday = $null; Avg7 = $null; LastShare = $null; Error = '' }
    try {
        $data = Invoke-PearlGet "$($script:HeroMinersBase)/api/stats_address?address=$([uri]::EscapeDataString($Address))&longpoll=false"
        if (Get-Prop $data 'error') { $report.Error = [string](Get-Prop $data 'error'); return $report }
        $stats = Get-Prop $data 'stats'
        if ($null -eq $stats) { $report.Error = (T 'adresse inconnue de la pool' 'address unknown to the pool'); return $report }
        $market = Get-PearlMarket
        $scale = $market.HmScale
        if ($null -eq $scale -or $scale -le 0) { $scale = [Math]::Pow(2, 32) }
        $units = 1e8
        foreach ($pair in @(@('hashrate', 'Hashrate'), @('hashrate_1h', 'Hashrate1h'), @('hashrate_24h', 'Hashrate24h'))) {
            $value = Get-Prop $stats $pair[0]
            if ($null -ne $value) { $report.($pair[1]) = [double]$value * $scale }
        }
        foreach ($pair in @(@('balance', 'Balance'), @('paid', 'Paid'), @('payments_24h', 'Paid24h'), @('payments_7d', 'Paid7d'))) {
            $value = Get-Prop $stats $pair[0]
            if ($null -ne $value) { $report.($pair[1]) = [double]$value / $units }
        }
        if ($null -ne (Get-Prop $stats 'lastShare')) { $report.LastShare = [double](Get-Prop $stats 'lastShare') }
        $workers = @(Get-Prop $data 'workers')
        $report.Workers = $workers.Count
        $report.WorkersOnline = @($workers | Where-Object { $null -ne $_ -and [double](Get-Prop $_ 'hashrate') -gt 0 }).Count
        $daily = @(Get-Prop $data 'unlocked_daily')
        if ($daily.Count -gt 0) { $report.Today = [double]$daily[0] / $units }
        if ($daily.Count -gt 1) { $report.Yesterday = [double]$daily[1] / $units }
        if ($daily.Count -gt 1) {
            $week = @($daily | Select-Object -Skip 1 -First 7)
            $sum = 0.0
            foreach ($value in $week) { $sum += [double]$value }
            $report.Avg7 = $sum / $units / $week.Count
        }
    }
    catch { $report.Error = Get-PearlError $_ }
    return $report
}

# unMineable marque un worker en ligne par true, 1 ou "online" selon les versions de son API.
function Test-UnmineableOnline($Value) {
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return (@('true', '1', 'online', 'yes') -contains $text)
}

# Rapport unMineable d'une adresse : { Pool, Address, Hashrate (calculé), Reported, Workers, WorkersOnline,
# Balance, Payable, Threshold, Paid, Rewarded24h, Rewarded7d, Rewarded30d, LastPayment, Error }.
function Get-UnmineableWallet([string]$Address) {
    $report = [pscustomobject]@{ Pool = 'unMineable'; Address = $Address; Hashrate = $null; Reported = $null; Workers = 0; WorkersOnline = 0
        Balance = $null; Payable = $null; Threshold = $null; Paid = $null; Rewarded24h = $null; Rewarded7d = $null; Rewarded30d = $null; LastPayment = $null; Error = '' }
    try {
        $data = Invoke-PearlGet "$($script:UnmineableBase)/v5/address/$([uri]::EscapeDataString($Address))?coin=PRL"
        $account = Get-Prop $data 'data'
        $uuid = [string](Get-Prop $account 'uuid')
        if (-not $uuid) { $report.Error = [string](Get-Prop $data 'msg'); if (-not $report.Error) { $report.Error = (T 'adresse inconnue de la pool' 'address unknown to the pool') }; return $report }
        if ($null -ne (Get-Prop $account 'balance')) { $report.Balance = [double](Get-Prop $account 'balance') }
        if ($null -ne (Get-Prop $account 'balance_payable')) { $report.Payable = [double](Get-Prop $account 'balance_payable') }
        if ($null -ne (Get-Prop $account 'payment_threshold')) { $report.Threshold = [double](Get-Prop $account 'payment_threshold') }
        $stats = Get-Prop (Invoke-PearlGet "$($script:UnmineableBase)/v5/account/$uuid/stats") 'data'
        $rewarded = Get-Prop $stats 'rewarded'
        if ($null -ne (Get-Prop $rewarded 'past_24h')) { $report.Rewarded24h = [double](Get-Prop $rewarded 'past_24h') }
        if ($null -ne (Get-Prop $rewarded 'past_7d')) { $report.Rewarded7d = [double](Get-Prop $rewarded 'past_7d') }
        if ($null -ne (Get-Prop $rewarded 'past_30d')) { $report.Rewarded30d = [double](Get-Prop $rewarded 'past_30d') }
        if ($null -ne (Get-Prop $stats 'paid')) { $report.Paid = [double](Get-Prop $stats 'paid') }
        if ($null -ne (Get-Prop $stats 'last_payment')) { $report.LastPayment = Get-Prop $stats 'last_payment' }
        $workers = Get-Prop (Get-Prop (Invoke-PearlGet "$($script:UnmineableBase)/v5/account/$uuid/workers") 'data') 'pearlpow'
        $list = @(Get-Prop $workers 'workers')
        $report.Workers = $list.Count
        # Seuls les workers en ligne comptent : la pool garde le dernier hashrate connu des
        # workers partis (une machine réallouée ou éteinte resterait comptée).
        $calculated = 0.0; $reported = 0.0; $online = 0
        foreach ($worker in $list) {
            if ($null -eq $worker -or -not (Test-UnmineableOnline (Get-Prop $worker 'online'))) { continue }
            $online++
            if ($null -ne (Get-Prop $worker 'chr')) { $calculated += [double](Get-Prop $worker 'chr') }
            if ($null -ne (Get-Prop $worker 'rhr')) { $reported += [double](Get-Prop $worker 'rhr') }
        }
        $report.WorkersOnline = $online
        if ($list.Count -gt 0) { $report.Hashrate = $calculated; $report.Reported = $reported }
    }
    catch { $report.Error = Get-PearlError $_ }
    return $report
}

# Rapports des pools configurées, gardés 2 min : liste de rapports.
function Get-WalletReports([bool]$Force = $false) {
    if (-not $Force -and $script:Wallets -and ((Get-Date) - $script:Wallets.At).TotalMinutes -lt 2) { return , $script:Wallets.Reports }
    $wallets = Get-PoolWallets
    $reports = @()
    if ($wallets.ContainsKey('herominers')) { $reports += Get-HeroMinersWallet $wallets['herominers'] }
    if ($wallets.ContainsKey('unmineable')) { $reports += Get-UnmineableWallet $wallets['unmineable'] }
    $script:Wallets = [pscustomobject]@{ At = (Get-Date); Reports = $reports }
    return , $reports
}

# Tableau « Puissance » : matériel (logs) / à la pool (instant) / ratio, par pool puis total.
function Write-PowerTable($Reports) {
    if (@($Reports).Count -eq 0) { return }
    $fleet = Get-RentedFleet
    if ($null -eq $fleet) {
        Write-Dim (T "Puissance : ouvre d'abord le $($script:FleetMenuLabel) pour connaître la puissance matériel (hashrate des logs)." "Power: open the $($script:FleetMenuLabel) first to know the hardware power (hashrate from the logs).")
        return
    }
    $hardware = Format-NetworkHashrate $fleet.Hps 1 'T'
    $columns = @((New-Column (T 'Puissance' 'Power') 'L' 10 24), (New-Column (T 'Matériel' 'Hardware') 'R'), (New-Column (T 'À la pool' 'At the pool') 'R'), (New-Column 'Ratio' 'R'))
    $rows = New-Object System.Collections.ArrayList
    $sum = 0.0; $counted = 0
    foreach ($report in $Reports) {
        $power = Get-PoolPower $report
        if ($null -eq $power) {
            $why = $report.Error
            if (-not $why) { $why = (T 'pas de hashrate' 'no hashrate') }
            [void]$rows.Add(@((New-Cell $report.Pool 'White'), $hardware, (New-Cell $why 'Yellow'), '–'))
            continue
        }
        $ratio = $power / $fleet.Hps
        $sum += $power; $counted++
        [void]$rows.Add(@((New-Cell $report.Pool 'White'), $hardware, (Format-NetworkHashrate $power 1 'T'), (New-Cell (Format-Ratio $ratio) (Get-RatioColor $ratio))))
    }
    if ($counted -gt 1) {
        [void]$rows.Add(@((New-Cell (T 'Total cumulé' 'Combined total') 'White'), $hardware, (Format-NetworkHashrate $sum 1 'T'), (New-Cell (Format-Ratio ($sum / $fleet.Hps)) 'White')))
    }
    Write-Host ''
    Write-Table $columns $rows
}

# Sous le tableau de rentabilité : le tableau « Puissance » des pools configurées.
function Write-WalletLines {
    $reports = Get-WalletReports
    Write-PowerTable $reports
}

# Cadre d'un rapport (menu P) : l'essentiel, en peu de lignes.
function Show-WalletReport($Report) {
    $market = Get-PearlMarket
    $lines = New-Object System.Collections.ArrayList
    $width = 20
    [void]$lines.Add((New-KeyValue (T 'Adresse' 'Address') $Report.Address $width))
    if ($Report.Error) {
        [void]$lines.Add((New-KeyValue (T 'Erreur' 'Error') $Report.Error $width 'DarkGray' 'Yellow'))
        Write-Box $Report.Pool $lines
        return
    }
    $usd = { param($prl) if ($null -ne $prl -and $null -ne $market.Usd) { return " ≈ $(Format-Price ($prl * $market.Usd) 2)" }; return '' }
    $power = '–'
    if ($null -ne $Report.Hashrate) { $power = Format-NetworkHashrate $Report.Hashrate 1 'T' }
    if ($Report.Pool -eq 'HeroMiners') {
        if ($null -ne $Report.Hashrate1h) { $power += "   ·   1 h $(Format-NetworkHashrate $Report.Hashrate1h 1 'T')" }
        if ($null -ne $Report.Hashrate24h) { $power += "   ·   24 h $(Format-NetworkHashrate $Report.Hashrate24h 1 'T')" }
        [void]$lines.Add((New-KeyValue (T 'Puissance à la pool' 'Power at the pool') $power $width))
        [void]$lines.Add((New-KeyValue 'Workers' (T "$($Report.WorkersOnline) actifs sur $($Report.Workers)" "$($Report.WorkersOnline) active out of $($Report.Workers)") $width))
        [void]$lines.Add((New-KeyValue (T 'Gains hier' 'Earned yesterday') ((Format-Prl $Report.Yesterday) + (& $usd $Report.Yesterday)) $width))
        if ($null -ne $Report.Avg7) { [void]$lines.Add((New-KeyValue (T 'Moyenne 7 jours' '7-day average') ((Format-Prl $Report.Avg7) + (& $usd $Report.Avg7) + (T ' par jour' ' per day')) $width)) }
        [void]$lines.Add((New-KeyValue (T 'Payé 24 h / 7 j' 'Paid 24 h / 7 d') "$(Format-Prl $Report.Paid24h)   ·   $(Format-Prl $Report.Paid7d)" $width))
        [void]$lines.Add((New-KeyValue (T 'En attente' 'Pending') ((Format-Prl $Report.Balance 2) + (& $usd $Report.Balance)) $width))
    }
    else {
        if ($null -ne $Report.Reported) { $power += (T "   ·   déclaré par les mineurs $(Format-NetworkHashrate $Report.Reported 1 'T')" "   ·   reported by the miners $(Format-NetworkHashrate $Report.Reported 1 'T')") }
        [void]$lines.Add((New-KeyValue (T 'Puissance à la pool' 'Power at the pool') $power $width))
        [void]$lines.Add((New-KeyValue 'Workers' (T "$($Report.WorkersOnline) en ligne sur $($Report.Workers)" "$($Report.WorkersOnline) online out of $($Report.Workers)") $width))
        [void]$lines.Add((New-KeyValue (T 'Gains 24 h' 'Earned 24 h') ((Format-Prl $Report.Rewarded24h) + (& $usd $Report.Rewarded24h)) $width))
        [void]$lines.Add((New-KeyValue (T 'Gains 7 j / 30 j' 'Earned 7 d / 30 d') "$(Format-Prl $Report.Rewarded7d)   ·   $(Format-Prl $Report.Rewarded30d)" $width))
        $balance = (Format-Prl $Report.Balance 2) + (& $usd $Report.Balance)
        if ($null -ne $Report.Threshold) { $balance += (T " (payé à partir de $(Format-Prl $Report.Threshold 0))" " (paid from $(Format-Prl $Report.Threshold 0))") }
        [void]$lines.Add((New-KeyValue (T 'Solde' 'Balance') $balance $width))
    }
    Write-Box $Report.Pool $lines
}

# Menu P : portefeuille sur les pools.
function Invoke-PoolMenu {
    Write-Rule (T 'Pool : mon portefeuille' 'Pool: my wallet')
    $wallets = Get-PoolWallets
    if ($wallets.Count -eq 0) {
        Write-Dim (T 'Aucune adresse PRL enregistrée. Donne celle que tu mines sur HeroMiners et/ou unMineable.' 'No PRL address saved. Give the one you mine with on HeroMiners and/or unMineable.')
    }
    else {
        Write-Step (T 'Lecture des pools … ' 'Reading the pools … ')
        $started = Get-Date
        $reports = Get-WalletReports $true
        Write-Host ('ok ({0:N1} s)' -f ((Get-Date) - $started).TotalSeconds) -ForegroundColor Green
        Write-PowerTable $reports
        foreach ($report in $reports) { Show-WalletReport $report }
    }
    $hero = (T 'aucune' 'none'); $um = (T 'aucune' 'none'); $manualText = (T 'aucun' 'none')
    if ($wallets.ContainsKey('herominers')) { $hero = Format-ShortAddress $wallets['herominers'] }
    if ($wallets.ContainsKey('unmineable')) { $um = Format-ShortAddress $wallets['unmineable'] }
    $manual = Get-ManualPool
    if ($manual) { $manualText = ('{0} ×{1:N2}' -f $manual.Name, $manual.Factor) }
    Write-Box (T 'Adresses et facteur' 'Addresses and factor') @(
        @((New-Cell '1   ' 'Yellow'), (T "HeroMiners : $hero — saisir / changer" "HeroMiners: $hero — enter / change")),
        @((New-Cell '2   ' 'Yellow'), (T "unMineable : $um — saisir / changer" "unMineable: $um — enter / change")),
        @((New-Cell '3   ' 'Yellow'), (T 'Retirer une adresse' 'Remove an address')),
        @((New-Cell '4   ' 'Yellow'), (T "Autre pool, ratio saisi à la main : $manualText" "Other pool, ratio entered by hand: $manualText"))
    )
    $choice = Read-Answer (T 'Ton choix' 'Your choice') (T 'Entrée sans rien = retour.' 'Enter alone = back.')
    if ($choice -eq '1' -or $choice -eq '2') {
        $pool = 'herominers'; $label = 'HeroMiners'
        if ($choice -eq '2') { $pool = 'unmineable'; $label = 'unMineable' }
        $address = Read-Answer (T "Adresse PRL utilisée sur $label (prl1p…)" "PRL address used on $label (prl1p…)") (T 'Entrée sans rien = annuler.' 'Enter alone = cancel.')
        if ($address -eq '') { return }
        $address = $address.Trim().ToLowerInvariant()
        if ($address -notmatch $script:PrlAddressPattern) { Write-Warn (T 'Adresse non comprise : une adresse PRL commence par prl1p et compte 63 caractères.' 'Address not understood: a PRL address starts with prl1p and has 63 characters.'); return }
        Set-PoolWallet $pool $address
        Write-Ok (T "Adresse enregistrée pour $label ($(Get-PoolsPath))." "Address saved for $label ($(Get-PoolsPath)).")
        Write-Step (T "Lecture de $label … " "Reading $label … ")
        $report = $null
        if ($pool -eq 'herominers') { $report = Get-HeroMinersWallet $address } else { $report = Get-UnmineableWallet $address }
        if ($report.Error) { Write-Host $report.Error -ForegroundColor Yellow } else { Write-Host 'ok' -ForegroundColor Green }
        Show-WalletReport $report
    }
    elseif ($choice -eq '3') {
        $which = Read-Answer (T 'Retirer quelle adresse ? (1 = HeroMiners, 2 = unMineable)' 'Remove which address? (1 = HeroMiners, 2 = unMineable)') (T 'Entrée sans rien = annuler.' 'Enter alone = cancel.')
        if ($which -eq '1') { Set-PoolWallet 'herominers' ''; Write-Ok (T 'Adresse HeroMiners retirée.' 'HeroMiners address removed.') }
        elseif ($which -eq '2') { Set-PoolWallet 'unmineable' ''; Write-Ok (T 'Adresse unMineable retirée.' 'unMineable address removed.') }
    }
    elseif ($choice -eq '4') {
        Write-Dim (T 'Pour une pool sans API : son ratio (puissance à la pool ÷ matériel), ex. 0,8 ou 1,2. Elle apparaît alors dans le tableau de rentabilité avec ce ratio.' 'For a pool without API: its ratio (power at the pool ÷ hardware), e.g. 0.8 or 1.2. It then appears in the profitability table with that ratio.')
        $name = Read-Answer (T 'Nom de la pool (ex. Kryptex)' 'Pool name (e.g. Kryptex)') (T 'Entrée sans rien = annuler ; « effacer » = retirer.' 'Enter alone = cancel; "clear" = remove.')
        if ($name -eq '') { return }
        if (@('effacer', 'clear', 'x') -contains $name.ToLowerInvariant()) { Set-ManualPool '' $null; Write-Ok (T 'Pool retirée.' 'Pool removed.'); return }
        $answer = Read-Answer (T 'Ratio (ex. 0,8 ou 1,2)' 'Ratio (e.g. 0.8 or 1.2)') (T 'Entrée sans rien = annuler.' 'Enter alone = cancel.')
        if ($answer -eq '') { return }
        $factor = 0.0
        if (-not [double]::TryParse(($answer.Trim() -replace ',', '.'), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$factor) -or $factor -le 0 -or $factor -gt 5) {
            Write-Warn (T 'Ratio non compris : un nombre entre 0 et 5, par exemple 0,8.' 'Ratio not understood: a number between 0 and 5, for example 0.8.')
            return
        }
        Set-ManualPool $name.Trim() $factor
        Write-Ok ((T 'Pool {0} enregistrée avec le ratio ×{1:N2}.' 'Pool {0} saved with ratio ×{1:N2}.') -f $name.Trim(), $factor)
    }
}
# === Modifications et suivi ==========================================================

# PATCH (merge-patch) d'un groupe ; renvoie le groupe mis à jour.
function Update-Group([string]$Name, $Patch) {
    return (ConvertTo-GroupInfo (Invoke-Salad 'PATCH' "$(Get-ProjectPath)/containers/$Name" $Patch))
}

function Write-InstanceChange([datetime]$Start, $Instance) {
    $info = Get-InstanceStateInfo $Instance.State $Instance.Ready $Instance.Progress
    Write-Segment ('  {0,6}  ' -f (Format-Elapsed $Start)) 'DarkGray'
    Write-Segment '● ' $info.Color
    Write-Segment $Instance.Short 'White'
    Write-Segment ('  {0,-18}' -f $info.Label) $info.Color
    Write-Host ("  version $($Instance.Version)") -ForegroundColor DarkGray
}

# Suit les machines d'un groupe jusqu'à ce qu'elles tournent toutes (avec la version
# $Version si elle est donnée), ou jusqu'au délai. Affiche chaque changement d'état.
function Wait-Group([string]$Name, $Version = $null, [string]$Title = '') {
    if (-not $Title) { $Title = T 'Suivi du redéploiement' 'Redeployment progress' }
    Write-Rule (T "$Title  ·  vérification toutes les $PollSeconds s  ·  $(Format-Duration $TimeoutSeconds) maximum" "$Title  ·  checked every $PollSeconds s  ·  $(Format-Duration $TimeoutSeconds) at most")
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $signatures = @{}
    $lastBeat = $start
    $result = 'timeout'
    # Salad peut annoncer une version dans sa réponse puis en créer une de plus en
    # déployant : la cible suit la version la plus haute vue sur le groupe.
    $target = $Version
    $seen = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $PollSeconds
        try {
            $group = Get-Group $Name
            $instances = Get-Instances $Name
        }
        catch { Write-Warn (T "$(Format-Elapsed $start)  Salad ne répond pas ($($_.Exception.Message)), nouvel essai…" "$(Format-Elapsed $start)  Salad is not answering ($($_.Exception.Message)), retrying…"); continue }
        if ($null -ne $target -and $null -ne $group.Version -and [int]$group.Version -gt [int]$target) {
            Write-Dim ((T '{0,6}  Salad est passé à la version {1}' '{0,6}  Salad moved on to version {1}') -f (Format-Elapsed $start), $group.Version)
            $target = [int]$group.Version
        }
        $printed = $false
        foreach ($instance in $instances) {
            if ($null -ne $instance.Version -and ($null -eq $seen -or [int]$instance.Version -gt $seen)) { $seen = [int]$instance.Version }
            $signature = "$($instance.State)|$($instance.Ready)|$($instance.Version)|$([int]$instance.Progress)"
            if (-not $signatures.ContainsKey($instance.MachineId) -or $signatures[$instance.MachineId] -ne $signature) {
                Write-InstanceChange $start $instance
                $signatures[$instance.MachineId] = $signature
                $printed = $true
            }
        }
        if ($group.Status -eq 'stopped' -or $group.Replicas -eq 0) { $result = 'stopped'; break }
        if ($group.Status -eq 'failed') { $result = 'failed'; break }
        $allGood = $instances.Count -ge $group.Replicas
        foreach ($instance in $instances) {
            if ($instance.State -ne 'running' -or $instance.Ready -eq $false) { $allGood = $false }
            if ($null -ne $target -and [int]$instance.Version -lt [int]$target) { $allGood = $false }
        }
        if ($allGood -and $instances.Count -gt 0) { $result = 'ok'; break }
        if (-not $printed -and ((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
            Write-Dim ((T '{0,6}  … en attente ({1} machine(s) en marche sur {2})' '{0,6}  … waiting ({1} running machine(s) out of {2})') -f (Format-Elapsed $start), $group.Running, $group.Replicas)
            $lastBeat = Get-Date
        }
        elseif ($printed) { $lastBeat = Get-Date }
    }
    Write-Host ''
    $withVersion = ''
    if ($null -ne $target) {
        $shown = $target
        if ($null -ne $seen -and $seen -gt $shown) { $shown = $seen }
        $withVersion = T " avec la version $shown" " with version $shown"
    }
    switch ($result) {
        'ok'      { Write-Ok (T "Toutes les machines du groupe $Name tournent$withVersion." "All machines of group $Name are running$withVersion.") }
        'stopped' { Write-Warn (T "Le groupe $Name est arrêté (ou à 0 replica) : rien à suivre." "Group $Name is stopped (or at 0 replica): nothing to follow.") }
        'failed'  { Write-Bad (T "Le groupe $Name est en échec : regarde ses logs et les System Events dans le portail." "Group $Name has failed: check its logs and the System Events in the portal.") }
        default   { Write-Warn (T "Pas terminé au bout de $(Format-Duration $TimeoutSeconds) : des machines attendent encore (Allocation = pas de carte libre pour le moment)." "Not finished after $(Format-Duration $TimeoutSeconds): some machines are still waiting (Allocating = no free GPU right now).") }
    }
    return $result
}

# === Menu 1 : voir mes groupes =======================================================

function Invoke-View {
    Write-Rule (T 'Mes groupes' 'My groups')
    $groups = Get-Groups
    if ($groups.Count -eq 0) { Write-Warn (T 'Aucun groupe dans ce projet.' 'No group in this project.'); return }
    Show-Groups $groups
    try {
        $quotas = Invoke-Salad 'GET' "$(Get-OrgPath)/quotas"
        $cg = Get-Prop $quotas 'container_groups_quotas'
        $max = Get-Prop $cg 'container_replicas_quota'
        $used = Get-Prop $cg 'container_replicas_used'
        if ($null -ne $max) { Write-Dim (T "Quota de l'organisation : $used replica(s) utilisé(s) sur $max (tous groupes confondus, arrêtés compris)." "Organization quota: $used replica(s) used out of $max (all groups, stopped ones included).") }
    }
    catch { }
}

# === Menu S : solde Salad =============================================================

function Invoke-Balance {
    Write-Rule (T 'Solde Salad' 'Salad balance')
    $setting = Get-PortalSetting
    $balance = Get-Balance
    if ($setting -and $setting.Email) {
        $kept = (T 'mot de passe gardé sur ce PC' 'password kept on this computer')
        if (-not $setting.Stored) { $kept = (T 'mot de passe non gardé' 'password not kept') }
        if ($script:PortalPassword -or $setting.Stored) { $kept += (T ', connexion prête' ', ready to sign in') }
        Write-Dim (T "Portail Salad : $($setting.Email) ($kept)." "Salad portal: $($setting.Email) ($kept).")
    }
    else { Write-Dim (T 'Portail Salad : non connecté.' 'Salad portal: not connected.') }
    if ($null -eq $balance) { Write-Dim (T "Solde saisi à la main pour $($script:Account.Org) : aucun." "Balance entered by hand for $($script:Account.Org): none.") }
    else { Write-Dim (T "Solde saisi à la main pour $($script:Account.Org) : $(Format-Price $balance.Amount 2), $(Format-Ago $balance.At)." "Balance entered by hand for $($script:Account.Org): $(Format-Price $balance.Amount 2), $(Format-Ago $balance.At).") }
    Write-Host ''
    Write-Dim (T "L'API Salad (clé API) ne donne pas le solde. Deux façons de l'avoir dans le menu 1 :" "The Salad API (API key) does not expose the balance. Two ways to get it in menu 1:")
    Write-Box (T 'Solde' 'Balance') @(
        @((New-Cell '1   ' 'Yellow'), (T 'Saisir le solde à la main (lu dans le portail, Billing & Usage) ; estimation ensuite' 'Enter the balance by hand (read in the portal, Billing & Usage); estimated afterwards')),
        @((New-Cell '2   ' 'Yellow'), (T 'Connecter le portail Salad (e-mail + mot de passe du compte) : solde réel à chaque affichage' 'Connect the Salad portal (account e-mail + password): real balance on every view')),
        @((New-Cell '3   ' 'Yellow'), (T 'Oublier le portail (e-mail et mot de passe gardés)' 'Forget the portal (kept e-mail and password)')),
        @((New-Cell '4   ' 'Yellow'), (T 'Effacer le solde saisi à la main' 'Clear the balance entered by hand'))
    )
    $choice = Read-Answer (T 'Ton choix' 'Your choice') (T 'Entrée sans rien = retour.' 'Enter alone = back.')
    switch ($choice) {
        '1' { Invoke-BalanceEntry }
        '2' { Invoke-PortalConnect }
        '3' {
            Remove-PortalSetting
            Write-Ok (T 'Portail oublié : le menu 1 utilisera le solde saisi à la main, s''il y en a un.' 'Portal forgotten: menu 1 will use the balance entered by hand, if any.')
        }
        '4' {
            Remove-Balance
            Write-Ok (T 'Solde saisi effacé.' 'Entered balance cleared.')
        }
    }
}

function Invoke-BalanceEntry {
    $answer = Read-Answer (T 'Solde actuel en $ (ex. 42,50)' 'Current balance in $ (e.g. 42.50)') (T 'Entrée sans rien = ne rien changer. Ressaisis-le après une recharge ou un changement de cartes.' 'Enter alone = keep as is. Enter it again after a top-up or a change of GPUs.')
    if ($answer -eq '') { return }
    $text = ($answer -replace '[\s$€]', '') -replace ',', '.'
    $amount = 0.0
    if (-not [double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$amount) -or $amount -lt 0) {
        Write-Warn (T 'Montant non compris : tape un nombre, par exemple 42,50.' 'Amount not understood: type a number, for example 42.50.')
        return
    }
    Set-Balance $amount
    Write-Ok (T "Solde enregistré : $(Format-Price $amount 2) ($(Get-BalancePath))." "Balance saved: $(Format-Price $amount 2) ($(Get-BalancePath)).")
    try { Write-BalanceLine (Get-GroupsRate (Get-Groups)) } catch { }
}

function Invoke-PortalConnect {
    Write-Dim (T 'Le portail (portal-api.salad.com) est une API interne, non documentée : Salad peut la changer. En cas de panne, le menu 1 retombe sur le solde saisi à la main.' 'The portal (portal-api.salad.com) is an internal, undocumented API: Salad may change it. If it breaks, menu 1 falls back to the balance entered by hand.')
    Write-Dim (T 'Le mot de passe est celui de ton compte Salad (pas la clé API). Il n''est jamais affiché ; gardé sur ce PC seulement si tu le demandes, chiffré comme les clés.' 'The password is your Salad account password (not the API key). It is never shown; kept on this computer only if you ask, encrypted like the keys.')
    $setting = Get-PortalSetting
    $default = $script:PortalEmail
    if (-not $default -and $setting) { $default = $setting.Email }
    $hint = (T 'Entrée sans rien = annuler.' 'Enter alone = cancel.')
    if ($default) { $hint = (T "Entrée sans rien = garder $default." "Enter alone = keep $default.") }
    $email = Read-Answer (T 'E-mail du compte Salad' 'Salad account e-mail') $hint
    if ($email -eq '') { $email = $default }
    if ($email -eq '') { return }
    $script:PortalEmail = $email
    $password = Read-SecretKey (T 'Mot de passe du compte Salad (saisie masquée)' 'Salad account password (hidden input)')
    if ($password -eq '') { Write-Warn (T 'Annulé, rien n''a été modifié.' 'Cancelled, nothing was changed.'); return }
    Write-Step (T 'Connexion au portail Salad … ' 'Signing in to the Salad portal … ')
    $failure = Connect-Portal $email $password
    if ($failure) { Write-Host (T "échec : $failure" "failed: $failure") -ForegroundColor Red; return }
    Write-Host 'ok' -ForegroundColor Green
    $keep = Confirm-Action (T 'Garder le mot de passe sur ce PC (chiffré) pour les prochains lancements ?' 'Keep the password on this computer (encrypted) for the next launches?')
    Set-PortalSetting $email $password $keep
    $script:PortalBalance = $null
    if ($keep) { Write-Ok (T "Portail connecté, mot de passe gardé ($(Get-PortalPath))." "Portal connected, password kept ($(Get-PortalPath)).") }
    else { Write-Ok (T 'Portail connecté pour cette session ; au prochain lancement, menu S pour ressaisir le mot de passe.' 'Portal connected for this session; next launch, menu S to enter the password again.') }
    try { Write-BalanceLine (Get-GroupsRate (Get-Groups)) } catch { Write-Warn $_.Exception.Message }
}

# === Menu 2 : voir les machines d'un groupe ==========================================

function Invoke-ViewInstances {
    Write-Rule (T 'Machines d''un groupe' 'Machines of a group')
    $group = Select-Group (T 'Quel groupe' 'Which group')
    if (-not $group) { return }
    Write-Rule (T "Machines  ·  Groupe $($group.Name)  ·  $(Get-ClassesText $group)  ·  priorité $(Format-Priority $group.Priority)" "Machines  ·  Group $($group.Name)  ·  $(Get-ClassesText $group)  ·  priority $(Format-Priority $group.Priority)")
    $instances = Get-Instances $group.Name
    Show-Instances $group $instances $true
}

# === Menu 3 : modifier un groupe =====================================================

function Show-GroupConfig($Group) {
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((New-KeyValue 'Image' $Group.Image 14 'DarkGray' 'White'))
    [void]$lines.Add((New-KeyValue 'Replicas' (T "$($Group.Running) en marche / $($Group.Replicas) demandés" "$($Group.Running) running / $($Group.Replicas) requested") 14))
    [void]$lines.Add((New-KeyValue (T 'Priorité' 'Priority') (Format-Priority $Group.Priority) 14))
    [void]$lines.Add((New-KeyValue (T 'Cartes' 'GPUs') (Get-ClassesText $Group) 14))
    [void]$lines.Add((New-KeyValue (T 'Ressources' 'Resources') "$($Group.Cpu) vCPU · $($Group.Memory) MB" 14))
    [void]$lines.Add((New-KeyValue 'Version' ([string]$Group.Version) 14))
    $names = @($Group.Env.Keys | Sort-Object)
    if ($names.Count -eq 0) { [void]$lines.Add((New-KeyValue (T 'Variables' 'Variables') (T '(aucune)' '(none)') 14)) }
    foreach ($name in $names) {
        $color = 'Gray'
        if ($name -like 'SALAD_*') { $color = 'Yellow' }
        [void]$lines.Add((New-KeyValue $name $Group.Env[$name] 20 $color 'White'))
    }
    Write-Box (T "Groupe $($Group.Name)" "Group $($Group.Name)") $lines
}

function Invoke-ChangeImage($Group) {
    $repository = Get-ImageRepository $Group.Image
    $currentTag = Get-ImageTag $Group.Image
    Write-Step (T "Étiquettes du dépôt $repository sur Docker Hub … " "Tags of repository $repository on Docker Hub … ")
    try { $tags = Get-HubTags $repository }
    catch { Write-Host (T "introuvables ($($_.Exception.Message))" "not found ($($_.Exception.Message))") -ForegroundColor Red; $tags = @() }
    if ($tags.Count -gt 0) {
        Write-Host (T "$($tags.Count) trouvée(s)" "$($tags.Count) found") -ForegroundColor Green
        $columns = @((New-Column (T 'N°' '#') 'R'), (New-Column (T 'Étiquette' 'Tag') 'L' 8 40), (New-Column (T 'Publiée le' 'Published on')), (New-Column (T 'Actuelle' 'Current')))
        $rows = New-Object System.Collections.ArrayList
        for ($n = 0; $n -lt $tags.Count; $n++) {
            $mark = ''
            if ($tags[$n].Name -eq $currentTag) { $mark = '●' }
            [void]$rows.Add(@((New-Cell ([string]($n + 1)) $script:AccentColor), (New-Cell $tags[$n].Name 'White'), (Format-LocalTime $tags[$n].Updated 'dd/MM/yyyy HH:mm'), (New-Cell $mark 'Green')))
        }
        Write-Host ''
        Write-Table $columns $rows
        $hint = T 'Tape son numéro   ·   ou tape directement une étiquette   ·   Entrée sans rien = annuler' 'Type its number   ·   or type a tag directly   ·   Enter alone = cancel'
    }
    else { $hint = T 'Tape l''étiquette (ex. 2026-10-04-1830)   ·   Entrée sans rien = annuler' 'Type the tag (e.g. 2026-10-04-1830)   ·   Enter alone = cancel' }
    $answer = Read-Answer (T 'Quelle étiquette' 'Which tag') $hint
    if ($answer -eq '') { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    $tag = $answer
    if ($tags.Count -gt 0 -and $answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $tags.Count) { $tag = $tags[[int]$answer - 1].Name }
    if ($tag -eq $currentTag) { Write-Dim (T "Le groupe est déjà sur l'étiquette $tag." "The group is already on tag $tag."); return }
    $image = "${repository}:$tag"
    Write-Box (T 'Changement d''image' 'Image change') @(
        (New-KeyValue (T 'Groupe' 'Group') $Group.Name 12),
        (New-KeyValue (T 'Avant' 'Before') $Group.Image 12 'DarkGray' 'Gray'),
        (New-KeyValue (T 'Après' 'After') $image 12 'DarkGray' 'White'),
        (New-Cell (T 'Salad télécharge la nouvelle image et redéploie toutes les machines du groupe.' 'Salad pulls the new image and redeploys every machine of the group.') 'Yellow')
    )
    if (-not (Confirm-Action (T 'Appliquer ?' 'Apply?'))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    Write-Step (T 'Envoi à Salad … ' 'Sending to Salad … ')
    $updated = Update-Group $Group.Name @{ container = @{ image = $image } }
    Write-Host (T "version $($updated.Version) annoncée" "version $($updated.Version) announced") -ForegroundColor Green
    Wait-Group $Group.Name $updated.Version | Out-Null
    Show-Logs $Group.Name
}

function Invoke-ChangeReplicas($Group) {
    $answer = Read-Answer (T "Nombre de replicas (actuellement $($Group.Replicas))" "Number of replicas (currently $($Group.Replicas))") (T 'Un nombre   ·   Entrée sans rien = annuler' 'A number   ·   Enter alone = cancel')
    if ($answer -eq '') { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    if ($answer -notmatch '^\d+$' -or [int]$answer -gt 500) { Write-Warn (T 'Il faut un nombre entre 0 et 500.' 'A number between 0 and 500 is expected.'); return }
    $count = [int]$answer
    if ($count -eq $Group.Replicas) { Write-Dim (T 'C''est déjà le nombre demandé.' 'That is already the requested number.'); return }
    if ($count -eq 0) { Write-Warn (T '0 replica = plus aucune machine, le groupe reste créé.' '0 replica = no machine at all, the group itself remains.') }
    if (-not (Confirm-Action (T "Passer le groupe $($Group.Name) de $($Group.Replicas) à $count replica(s) ?" "Change group $($Group.Name) from $($Group.Replicas) to $count replica(s)?"))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    Write-Step (T 'Envoi à Salad … ' 'Sending to Salad … ')
    $updated = Update-Group $Group.Name @{ replicas = $count }
    Write-Host (T 'fait' 'done') -ForegroundColor Green
    Write-Ok (T "Groupe $($Group.Name) : $($updated.Replicas) replica(s) demandés. Les machines en marche ne redémarrent pas ; les nouvelles arrivent dès qu'une carte est libre (menu 2 pour suivre)." "Group $($Group.Name): $($updated.Replicas) replica(s) requested. Running machines do not restart; new ones arrive as soon as a GPU is free (menu 2 to follow).")
}

function Test-ThresholdList([string]$Text) {
    foreach ($entry in ($Text -split '[,;\s]+')) {
        if ($entry -eq '') { continue }
        if ($entry -notmatch '^[^=]+=\d+(\.\d+)?\s*[KkMmGgTt]?([Hh](/[Ss])?)?$') { return $false }
    }
    return $true
}

# Formulaire du chien de garde : chaque champ, Entrée = garder la valeur en place.
function Invoke-ChangeWatchdog($Group) {
    $env_ = $Group.Env
    $current = @{}
    foreach ($name in @('SALAD_WATCHDOG', 'SALAD_MIN_HASHRATE', 'SALAD_GRACE', 'SALAD_BAD_READINGS', 'SALAD_MAX_RESTARTS', 'SALAD_ZERO_READINGS', 'SALAD_STALE_MINUTES')) {
        $current[$name] = ''
        if ($env_.ContainsKey($name)) { $current[$name] = $env_[$name] }
    }
    $patch = @{}
    Write-Box (T 'Chien de garde' 'Watchdog') @(
        (T 'Pour chaque réglage : Entrée sans rien = garder la valeur en place.' 'For each setting: Enter alone = keep the current value.'),
        (New-Cell (T 'Un changement crée une nouvelle version du groupe et redéploie toutes les machines.' 'A change creates a new version of the group and redeploys every machine.') 'Yellow')
    )

    $modeNow = $current['SALAD_WATCHDOG']
    if (-not $modeNow) { $modeNow = T 'désactivé' 'disabled' }
    $answer = (Read-Answer (T "Mode (actuellement : $modeNow)" "Mode (currently: $modeNow)") (T '1 = observe (surveille, n''agit pas)   ·   2 = reallocate (demande une autre machine)   ·   3 = désactivé' '1 = observe (monitors, does nothing)   ·   2 = reallocate (asks for another machine)   ·   3 = disabled')).ToLowerInvariant()
    if ($answer -eq '1' -or $answer -eq 'observe') { $patch['SALAD_WATCHDOG'] = 'observe' }
    elseif ($answer -eq '2' -or $answer -eq 'reallocate') { $patch['SALAD_WATCHDOG'] = 'reallocate' }
    elseif ($answer -eq '3' -or $answer -match '^d') { if ($current['SALAD_WATCHDOG']) { $patch['SALAD_WATCHDOG'] = $null } }
    elseif ($answer -ne '') { Write-Warn (T 'Réponse non comprise, mode inchangé.' 'Not understood, mode unchanged.') }

    $now = $current['SALAD_MIN_HASHRATE']
    if (-not $now) { $now = T '(aucun)' '(none)' }
    while ($true) {
        $answer = Read-Answer (T "Seuils par carte (actuellement : $now)" "Thresholds per GPU (currently: $now)") (T 'Exemple : 5090=300T,4090=250T,3090=100T   ·   aucun = retirer' 'Example: 5090=300T,4090=250T,3090=100T   ·   none = remove')
        if ($answer -eq '') { break }
        if ($answer -match '^(aucun|none|-)$') { if ($current['SALAD_MIN_HASHRATE']) { $patch['SALAD_MIN_HASHRATE'] = $null }; break }
        if (Test-ThresholdList $answer) { $patch['SALAD_MIN_HASHRATE'] = ($answer -replace '\s+', ''); break }
        Write-Warn (T 'Forme attendue : MODELE=SEUIL séparés par des virgules, seuil en K, M, G ou T (ex. 5090=300T).' 'Expected form: MODEL=THRESHOLD separated by commas, threshold in K, M, G or T (e.g. 5090=300T).')
    }

    foreach ($field in @(
        @{ Name = 'SALAD_GRACE';        Label = (T 'Répit après démarrage (secondes)' 'Grace period after start (seconds)'); Default = (T '300 par défaut' '300 by default') },
        @{ Name = 'SALAD_BAD_READINGS'; Label = (T 'Lectures sous le seuil avant verdict' 'Readings below threshold before a verdict'); Default = (T '3 par défaut' '3 by default') },
        @{ Name = 'SALAD_MAX_RESTARTS'; Label = (T 'Redémarrages du mineur en 10 min avant verdict' 'Miner restarts within 10 min before a verdict'); Default = (T 'inactif par défaut' 'inactive by default') },
        @{ Name = 'SALAD_ZERO_READINGS'; Label = (T 'Lectures à 0 H/s avant verdict (0 = règle désactivée)' 'Readings at 0 H/s before a verdict (0 = rule disabled)'); Default = (T '2 par défaut' '2 by default') },
        @{ Name = 'SALAD_STALE_MINUTES'; Label = (T 'Minutes sans statistiques avant verdict (0 = règle désactivée)' 'Minutes without statistics before a verdict (0 = rule disabled)'); Default = (T '2 par défaut' '2 by default') }
    )) {
        $now = $current[$field.Name]
        if (-not $now) { $now = T "non renseigné, $($field.Default)" "not set, $($field.Default)" }
        while ($true) {
            $answer = (Read-Answer "$($field.Label)$(T " (actuellement : $now)" " (currently: $now)")" (T 'Un nombre   ·   aucun = retirer la variable' 'A number   ·   none = remove the variable')).ToLowerInvariant()
            if ($answer -eq '') { break }
            if ($answer -match '^(aucun|none|-)$') { if ($current[$field.Name]) { $patch[$field.Name] = $null }; break }
            if ($answer -match '^\d+$') { $patch[$field.Name] = $answer; break }
            Write-Warn (T 'Il faut un nombre entier.' 'A whole number is expected.')
        }
    }

    if ($patch.Count -eq 0) { Write-Dim (T 'Rien à changer.' 'Nothing to change.'); return }
    $lines = New-Object System.Collections.ArrayList
    foreach ($name in @($patch.Keys | Sort-Object)) {
        $value = $patch[$name]
        if ($null -eq $value) { $value = T '(retirée)' '(removed)' }
        [void]$lines.Add((New-KeyValue $name $value 22 'Yellow' 'White'))
    }
    Write-Box (T 'Changements' 'Changes') $lines
    if (-not (Confirm-Action (T 'Appliquer ?' 'Apply?'))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    Write-Step (T 'Envoi à Salad … ' 'Sending to Salad … ')
    $updated = Update-Group $Group.Name @{ container = @{ environment_variables = $patch } }
    Write-Host (T "version $($updated.Version) annoncée" "version $($updated.Version) announced") -ForegroundColor Green
    # Vérification par relecture : ce que Salad a vraiment retenu.
    $check = Get-Group $Group.Name
    $lines = New-Object System.Collections.ArrayList
    foreach ($name in @($check.Env.Keys | Where-Object { $_ -like 'SALAD_*' } | Sort-Object)) { [void]$lines.Add((New-KeyValue $name $check.Env[$name] 22 'Yellow' 'White')) }
    if ($lines.Count -eq 0) { [void]$lines.Add((T '(aucune variable SALAD_* : chien de garde désactivé)' '(no SALAD_* variable: watchdog disabled)')) }
    Write-Box (T 'Variables en place après modification' 'Variables in place after the change') $lines
    Wait-Group $Group.Name $updated.Version | Out-Null
    Show-Logs $Group.Name
}

# Mineurs GPU connus de l'image rentingminers : valeur de GPU_MINER, nom affiché, forme
# des arguments (chaque mineur a sa syntaxe).
$script:GpuMiners = @(
    @{ Value = 'srbminer';   Name = 'SRBMiner-MULTI';   Shape = '--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE --worker NOM' },
    @{ Value = 'forgeminer'; Name = 'ForgeMiner';       Shape = '--algorithm pearlhash --pool POOL:PORT --wallet ADRESSE --worker NOM' },
    @{ Value = 'krigminer';  Name = 'krig (Kryptex)';   Shape = '--url POOL:PORT --user ADRESSE.NOM' },
    @{ Value = 'peakminer';  Name = 'PeakMiner';        Shape = '--coin pearl -o POOL:PORT -u ADRESSE -w NOM' },
    @{ Value = 'rgminer';    Name = 'RGminer';          Shape = '--algo pearl --proto herominers --stratum POOL:PORT --wallet ADRESSE --worker NOM' }
)

# Formulaire mineur GPU + arguments (GPU_MINER, GPU_ARGS) : Entrée = garder la valeur en place.
function Invoke-ChangeMiner($Group) {
    $env_ = $Group.Env
    $minerNow = ''
    $argsNow = ''
    if ($env_.ContainsKey('GPU_MINER')) { $minerNow = $env_['GPU_MINER'] }
    if ($env_.ContainsKey('GPU_ARGS')) { $argsNow = $env_['GPU_ARGS'] }
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((New-KeyValue 'GPU_MINER' $(if ($minerNow) { $minerNow } else { T '(absent)' '(not set)' }) 12 'Cyan' 'White'))
    [void]$lines.Add((New-KeyValue 'GPU_ARGS' $(if ($argsNow) { $argsNow } else { T '(absent)' '(not set)' }) 12 'Cyan' 'White'))
    [void]$lines.Add('')
    [void]$lines.Add((T 'Mineurs de l''image rentingminers, et la forme de leurs arguments :' 'Miners of the rentingminers image, and the shape of their arguments:'))
    for ($n = 0; $n -lt $script:GpuMiners.Count; $n++) {
        $miner = $script:GpuMiners[$n]
        $mark = ''
        if ($miner.Value -eq $minerNow.ToLowerInvariant()) { $mark = T '   (actuel)' '   (current)' }
        [void]$lines.Add(@((New-Cell ('{0}   ' -f ($n + 1)) 'Yellow'), (New-Cell ('{0,-11}' -f $miner.Value) 'White'), (New-Cell ('{0,-16}' -f $miner.Name) 'Gray'), (New-Cell "$($miner.Shape)$mark" 'DarkGray')))
    }
    [void]$lines.Add('')
    [void]$lines.Add((New-Cell (T 'Un changement crée une nouvelle version du groupe et redéploie toutes les machines.' 'A change creates a new version of the group and redeploys every machine.') 'Yellow'))
    Write-Box (T 'Mineur GPU et ses arguments' 'GPU miner and its arguments') $lines

    $patch = @{}
    $minerNew = $minerNow
    while ($true) {
        $answer = (Read-Answer (T 'Mineur' 'Miner') (T 'Tape son numéro ou sa valeur   ·   Entrée sans rien = garder le mineur en place' 'Type its number or its value   ·   Enter alone = keep the current miner')).Trim().ToLowerInvariant()
        if ($answer -eq '') { break }
        $found = $null
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $script:GpuMiners.Count) { $found = $script:GpuMiners[[int]$answer - 1] }
        else { $found = $script:GpuMiners | Where-Object { $_.Value -eq $answer } | Select-Object -First 1 }
        if (-not $found) { Write-Warn (T 'Mineur inconnu : tape un numéro de la liste ou une valeur (srbminer, forgeminer, krigminer, peakminer, rgminer).' 'Unknown miner: type a number from the list or a value (srbminer, forgeminer, krigminer, peakminer, rgminer).'); continue }
        $minerNew = $found.Value
        if ($minerNew -ne $minerNow) { $patch['GPU_MINER'] = $minerNew }
        break
    }
    if (-not $minerNew) { Write-Warn (T 'Pas de mineur GPU dans ce groupe : choisis-en un d''abord.' 'No GPU miner in this group: pick one first.'); return }

    $shape = ($script:GpuMiners | Where-Object { $_.Value -eq $minerNew } | Select-Object -First 1).Shape
    if ($minerNew -ne $minerNow -and $argsNow) {
        Write-Warn (T "Le mineur change : les arguments en place sont ceux de $minerNow, $minerNew a sa propre syntaxe." "The miner changes: the current arguments are those of $minerNow, $minerNew has its own syntax.")
    }
    $hint = T "Forme pour $minerNew : $shape   ·   Entrée sans rien = garder les arguments en place" "Shape for ${minerNew}: $shape   ·   Enter alone = keep the current arguments"
    while ($true) {
        $answer = (Read-Answer 'GPU_ARGS' $hint).Trim()
        if ($answer -eq '') { break }
        if ($answer -notmatch '^-') { Write-Warn (T 'Les arguments commencent par une option (--algorithm, --url, --coin, --algo…).' 'Arguments start with an option (--algorithm, --url, --coin, --algo…).'); continue }
        if ($answer -ne $argsNow) { $patch['GPU_ARGS'] = $answer }
        break
    }
    if ($patch.ContainsKey('GPU_MINER') -and -not $patch.ContainsKey('GPU_ARGS') -and $argsNow -and $minerNew -ne $minerNow) {
        Write-Warn (T "Mineur $minerNew avec des arguments écrits pour $minerNow : vérifie qu'ils ont la même syntaxe." "Miner $minerNew with arguments written for ${minerNow}: check that both use the same syntax.")
    }
    if ($patch.Count -eq 0) { Write-Dim (T 'Rien à changer.' 'Nothing to change.'); return }

    $lines = New-Object System.Collections.ArrayList
    foreach ($name in @('GPU_MINER', 'GPU_ARGS')) {
        if (-not $patch.ContainsKey($name)) { continue }
        $before = $(if ($name -eq 'GPU_MINER') { $minerNow } else { $argsNow })
        if (-not $before) { $before = T '(absent)' '(not set)' }
        [void]$lines.Add((New-KeyValue "$name $(T 'avant' 'before')" $before 18 'DarkGray' 'Gray'))
        [void]$lines.Add((New-KeyValue "$name $(T 'après' 'after')" $patch[$name] 18 'Cyan' 'White'))
    }
    [void]$lines.Add((New-Cell (T 'Salad redéploie toutes les machines du groupe (le minage s''interrompt le temps du redéploiement).' 'Salad redeploys every machine of the group (mining stops during the redeployment).') 'Yellow'))
    Write-Box (T 'Changements' 'Changes') $lines
    if (-not (Confirm-Action (T 'Appliquer ?' 'Apply?'))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    Write-Step (T 'Envoi à Salad … ' 'Sending to Salad … ')
    $updated = Update-Group $Group.Name @{ container = @{ environment_variables = $patch } }
    Write-Host (T "version $($updated.Version) annoncée" "version $($updated.Version) announced") -ForegroundColor Green
    # Vérification par relecture : ce que Salad a vraiment retenu.
    $check = Get-Group $Group.Name
    $lines = New-Object System.Collections.ArrayList
    foreach ($name in @('GPU_MINER', 'GPU_ARGS')) {
        $value = T '(absent)' '(not set)'
        if ($check.Env.ContainsKey($name)) { $value = $check.Env[$name] }
        [void]$lines.Add((New-KeyValue $name $value 12 'Cyan' 'White'))
    }
    Write-Box (T 'Variables en place après modification' 'Variables in place after the change') $lines
    Wait-Group $Group.Name $updated.Version | Out-Null
    Show-Logs $Group.Name
}

function Invoke-ChangePriority($Group) {
    $lines = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $script:PriorityOrder.Count; $n++) {
        $priority = $script:PriorityOrder[$n]
        $prices = @(foreach ($class in $Group.Classes) { $price = Get-ClassPrice $class $priority; if ($null -ne $price) { "$($class.Short) $(Format-Price $price)/h" } })
        $text = Format-Priority $priority
        if ($prices.Count -gt 0) { $text += '   ' + ($prices -join '  ·  ') }
        if ($priority -eq $Group.Priority) { $text += (T '   (actuelle)' '   (current)') }
        [void]$lines.Add(@((New-Cell ('{0}   ' -f ($n + 1)) 'Yellow'), $text))
    }
    Write-Box (T 'Priorité' 'Priority') $lines
    $index = Read-Index $script:PriorityOrder.Count (T 'Quelle priorité' 'Which priority') (T 'Tape son numéro   ·   Entrée sans rien = annuler' 'Type its number   ·   Enter alone = cancel')
    if ($index -lt 0) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    $priority = $script:PriorityOrder[$index]
    if ($priority -eq $Group.Priority) { Write-Dim (T 'C''est déjà la priorité du groupe.' 'That is already the group priority.'); return }
    Write-Warn (T 'Changer la priorité redéploie toutes les machines du groupe.' 'Changing the priority redeploys every machine of the group.')
    if (-not (Confirm-Action (T "Passer le groupe $($Group.Name) en priorité $(Format-Priority $priority) ?" "Switch group $($Group.Name) to priority $(Format-Priority $priority)?"))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    Write-Step (T 'Envoi à Salad … ' 'Sending to Salad … ')
    $updated = Update-Group $Group.Name @{ container = @{ priority = $priority } }
    Write-Host (T "version $($updated.Version) annoncée" "version $($updated.Version) announced") -ForegroundColor Green
    Wait-Group $Group.Name $updated.Version | Out-Null
}

function Invoke-ModifyGroup {
    Write-Rule (T 'Modifier un groupe' 'Edit a group')
    $group = Select-Group (T 'Quel groupe modifier' 'Which group to edit')
    if (-not $group) { return }
    while ($true) {
        $group = Get-Group $group.Name
        Show-GroupConfig $group
        Write-Box (T 'Que modifier ?' 'What to change?') @(
            @((New-Cell '1   ' 'Yellow'), (T 'Étiquette de l''image (liste des étiquettes Docker Hub)' 'Image tag (list of Docker Hub tags)')),
            @((New-Cell '2   ' 'Yellow'), (T 'Nombre de replicas (sans redémarrage des machines)' 'Number of replicas (no machine restart)')),
            @((New-Cell '3   ' 'Yellow'), (T 'Chien de garde (mode, seuils, répit, lectures, redémarrages, 0 H/s, silence)' 'Watchdog (mode, thresholds, grace, readings, restarts, 0 H/s, silence)')),
            @((New-Cell '4   ' 'Yellow'), (T 'Priorité' 'Priority')),
            @((New-Cell '5   ' 'Yellow'), (T 'Mineur GPU et ses arguments (GPU_MINER, GPU_ARGS)' 'GPU miner and its arguments (GPU_MINER, GPU_ARGS)'))
        )
        $choice = Read-Answer (T 'Ton choix' 'Your choice') (T 'Entrée sans rien = retour au menu' 'Enter alone = back to the menu')
        if ($choice -eq '') { return }
        try {
            if ($choice -eq '1') { Invoke-ChangeImage $group }
            elseif ($choice -eq '2') { Invoke-ChangeReplicas $group }
            elseif ($choice -eq '3') { Invoke-ChangeWatchdog $group }
            elseif ($choice -eq '4') { Invoke-ChangePriority $group }
            elseif ($choice -eq '5') { Invoke-ChangeMiner $group }
            else { Write-Warn (T 'Réponse non comprise.' 'Not understood.') }
        }
        catch { Write-Bad (T "Erreur : $($_.Exception.Message)" "Error: $($_.Exception.Message)") }
    }
}

# === Menu 4 : réallouer / recréer / redémarrer des machines ==========================

function Get-InstanceActions {
    return @(
        @{ Key = 'reallocate'; Label = (T 'Réallouer : abandonner ce PC, en prendre un autre (carte lente, machine douteuse)' 'Reallocate: drop this PC and take another one (slow GPU, dubious machine)') },
        @{ Key = 'recreate';   Label = (T 'Recréer : nouveau conteneur sur le même PC, image déjà en place' 'Recreate: new container on the same PC, image already there') },
        @{ Key = 'restart';    Label = (T 'Redémarrer : relance le conteneur sur le même PC' 'Restart: restart the container on the same PC') }
    )
}

function Invoke-InstanceActions {
    Write-Rule (T 'Réallouer / recréer / redémarrer des machines' 'Reallocate / recreate / restart machines')
    $group = Select-Group (T 'Quel groupe' 'Which group')
    if (-not $group) { return }
    $instances = Get-Instances $group.Name
    if ($instances.Count -eq 0) { Write-Warn (T 'Aucune machine dans ce groupe.' 'No machine in this group.'); return }
    Write-Rule (T "Machines  ·  Groupe $($group.Name)" "Machines  ·  Group $($group.Name)")
    Show-Instances $group $instances $true
    $chosen = Read-Selection $instances.Count (T 'Quelles machines' 'Which machines') (T 'retour au menu' 'back to the menu')
    if ($chosen.Count -eq 0) { return }
    $actions = Get-InstanceActions
    $lines = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $actions.Count; $n++) {
        [void]$lines.Add(@((New-Cell ('{0}   ' -f ($n + 1)) 'Yellow'), $actions[$n].Label))
    }
    Write-Box (T 'Quelle action ?' 'Which action?') $lines
    $index = Read-Index $actions.Count (T 'Ton choix' 'Your choice') (T 'Tape son numéro   ·   Entrée sans rien = annuler' 'Type its number   ·   Enter alone = cancel')
    if ($index -lt 0) { return }
    $action = $actions[$index]
    $names = @(foreach ($i in $chosen) { $instances[$i].Short })
    if (-not (Confirm-Action (T "$($action.Key) sur $($chosen.Count) machine(s) : $($names -join ', ') ?" "$($action.Key) on $($chosen.Count) machine(s): $($names -join ', ')?"))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    $results = @()
    foreach ($i in $chosen) {
        $instance = $instances[$i]
        Write-Step "$($action.Key) $($instance.Short) … "
        try {
            Invoke-Salad 'POST' "$(Get-ProjectPath)/containers/$($group.Name)/instances/$($instance.Id)/$($action.Key)" | Out-Null
            Write-Host (T 'demandé' 'requested') -ForegroundColor Green
            $results += [pscustomobject]@{ Short = $instance.Short; Level = 'ok'; Text = (T "Demande de $($action.Key) acceptée." "$($action.Key) request accepted.") }
        }
        catch {
            Write-Host (T "refusé ($($_.Exception.Message))" "refused ($($_.Exception.Message))") -ForegroundColor Red
            $results += [pscustomobject]@{ Short = $instance.Short; Level = 'error'; Text = $_.Exception.Message }
        }
    }
    if (@($results | Where-Object { $_.Level -eq 'ok' }).Count -gt 0) {
        Wait-Group $group.Name $null (T 'Suivi des machines' 'Machine progress') | Out-Null
    }
    Write-Rule (T 'Résumé' 'Summary')
    Write-Host ''
    $columns = @((New-Column 'Machine'), (New-Column (T 'Statut' 'Status')), (New-Column (T 'Détail' 'Detail') 'L' 20 80 $true))
    $rows = @(foreach ($result in $results) { , @((New-Cell $result.Short 'White'), (New-Badge $result.Level), $result.Text) })
    Write-Table $columns $rows
    Write-Dim (T 'Les limites Salad : quelques réallocations, recréations et redémarrages par minute et par groupe ; au-delà, l''API refuse (429).' 'Salad limits: a few reallocations, recreations and restarts per minute and per group; beyond that the API refuses (429).')
}

# === Menu 6 : démarrer / arrêter un groupe ===========================================

function Invoke-StartStop {
    Write-Rule (T 'Démarrer / arrêter un groupe' 'Start / stop a group')
    $group = Select-Group (T 'Quel groupe' 'Which group')
    if (-not $group) { return }
    $status = Get-GroupStatusInfo $group.Status
    if ($group.Status -eq 'stopped' -or $group.Status -eq 'failed' -or $group.Status -eq 'succeeded') {
        Write-Box (T "Groupe $($group.Name)" "Group $($group.Name)") @(
            (New-KeyValue (T 'État' 'State') $status.Label 10 'DarkGray' $status.Color),
            (New-KeyValue 'Replicas' ([string]$group.Replicas) 10),
            (New-KeyValue (T 'Cartes' 'GPUs') (Get-ClassesText $group) 10),
            (New-Cell (T 'Démarrer relance les replicas : facturation dès qu''une machine tourne.' 'Start relaunches the replicas: billing starts as soon as a machine runs.') 'Yellow')
        )
        if (-not (Confirm-Action (T "Démarrer le groupe $($group.Name) ?" "Start group $($group.Name)?"))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
        Write-Step (T 'Envoi à Salad … ' 'Sending to Salad … ')
        Invoke-Salad 'POST' "$(Get-ProjectPath)/containers/$($group.Name)/start" | Out-Null
        Write-Host (T 'fait' 'done') -ForegroundColor Green
        Wait-Group $group.Name $null (T 'Suivi du démarrage' 'Start-up progress') | Out-Null
        return
    }
    Write-Box (T "Groupe $($group.Name)" "Group $($group.Name)") @(
        (New-KeyValue (T 'État' 'State') $status.Label 10 'DarkGray' $status.Color),
        (New-KeyValue 'Machines' (T "$($group.Running) en marche / $($group.Replicas) demandés" "$($group.Running) running / $($group.Replicas) requested") 10),
        (New-Cell (T 'Arrêter coupe toutes les machines ; le groupe et sa configuration restent, tu pourras le redémarrer.' 'Stop cuts every machine; the group and its configuration remain, you can start it again later.') 'Yellow'),
        (New-Cell (T 'Les replicas d''un groupe arrêté comptent toujours dans ton quota.' 'The replicas of a stopped group still count against your quota.') 'DarkGray')
    )
    if (-not (Confirm-Action (T "Arrêter le groupe $($group.Name) ?" "Stop group $($group.Name)?"))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); return }
    Write-Step (T 'Envoi à Salad … ' 'Sending to Salad … ')
    Invoke-Salad 'POST' "$(Get-ProjectPath)/containers/$($group.Name)/stop" | Out-Null
    Write-Host (T 'fait' 'done') -ForegroundColor Green
    $start = Get-Date
    while (((Get-Date) - $start).TotalSeconds -lt 120) {
        Start-Sleep -Seconds $PollSeconds
        try { $check = Get-Group $group.Name } catch { continue }
        if ($check.Status -eq 'stopped') { Write-Ok (T "Groupe $($group.Name) arrêté." "Group $($group.Name) stopped."); return }
        Write-Dim (T "$(Format-Elapsed $start)  $((Get-GroupStatusInfo $check.Status).Label) · $($check.Running) machine(s) encore en marche" "$(Format-Elapsed $start)  $((Get-GroupStatusInfo $check.Status).Label) · $($check.Running) machine(s) still running")
    }
    Write-Warn (T 'L''arrêt prend plus de 2 min ; vérifie dans un moment (menu 1).' 'Stopping takes more than 2 min; check again in a moment (menu 1).')
}

# === Menu 7 : cartes, prix et disponibilité ==========================================

function Invoke-GpuMarket {
    Write-Rule (T 'Cartes : prix et disponibilité' 'GPUs: prices and availability')
    $classes = Get-GpuClasses
    if ($classes.Count -eq 0) { Write-Warn (T 'Aucune classe GPU renvoyée par Salad.' 'Salad returned no GPU class.'); return }
    $columns = @((New-Column (T 'N°' '#') 'R'), (New-Column (T 'Carte' 'GPU') 'L' 8 34))
    foreach ($priority in $script:PriorityOrder) { $columns += New-Column "$(Format-Priority $priority) $/h" 'R' }
    $columns += New-Column (T 'Forte demande' 'High demand')
    $rows = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $classes.Count; $n++) {
        $class = $classes[$n]
        $cells = @((New-Cell ([string]($n + 1)) $script:AccentColor), (New-Cell $class.Name 'White'))
        foreach ($priority in $script:PriorityOrder) {
            $price = Get-ClassPrice $class $priority
            if ($null -eq $price) { $cells += '–' } else { $cells += (Format-Price $price) }
        }
        $demand = ''
        if ($class.HighDemand) { $demand = T 'oui' 'yes' }
        $cells += (New-Cell $demand 'Yellow')
        [void]$rows.Add($cells)
    }
    Write-Host ''
    Write-Table $columns $rows
    Write-Dim (T 'Prix par carte et par heure, vCPU et RAM compris. Lowest = « batch » dans l''API.' 'Price per GPU and per hour, vCPU and RAM included. Lowest = "batch" in the API.')
    $chosen = Read-Selection $classes.Count (T 'Disponibilité de quelles cartes' 'Availability of which GPUs') (T 'retour au menu' 'back to the menu')
    if ($chosen.Count -eq 0) { return }
    $columns = @((New-Column (T 'Carte' 'GPU') 'L' 8 34))
    foreach ($priority in $script:PriorityOrder) { $columns += New-Column (Format-Priority $priority) 'R' }
    $rows = New-Object System.Collections.ArrayList
    foreach ($i in $chosen) {
        $class = $classes[$i]
        Write-Step (T "Disponibilité $($class.Short) … " "Availability $($class.Short) … ")
        try {
            $data = Invoke-Salad 'POST' "$(Get-OrgPath)/availability/sce-gpu-availability" @{ gpu_classes = @($class.Id) }
            Write-Host 'ok' -ForegroundColor Green
            $cells = @((New-Cell $class.Name 'White'))
            foreach ($priority in $script:PriorityOrder) {
                $count = Get-Prop $data "available_gpu_$priority"
                if ($null -eq $count) { $cells += '?' }
                elseif ([int]$count -eq 0) { $cells += (New-Cell '0' 'Red') }
                else { $cells += (New-Cell ([string]$count) 'Green') }
            }
            [void]$rows.Add($cells)
        }
        catch {
            Write-Host (T "échec ($($_.Exception.Message))" "failed ($($_.Exception.Message))") -ForegroundColor Red
            [void]$rows.Add(@((New-Cell $class.Name 'White'), '?', '?', '?', '?'))
        }
    }
    Write-Host ''
    Write-Table $columns $rows
    Write-Dim (T 'Machines libres à cet instant pour un replica de cette carte, par priorité (même chiffre que le formulaire de création du portail).' 'Machines free right now for one replica of this GPU, per priority (same figure as the portal creation form).')
}

# === Programme principal ===========================================================

function Main {
    try { $Host.UI.RawUI.WindowTitle = 'Salad-Switch-Log' } catch { }
    Write-Banner

    $groups = Initialize-ApiKey
    if (-not $script:Account) {
        Write-Bad (T 'Sans clé API valide, je ne peux rien faire.' 'Without a valid API key, nothing can be done.')
        $script:ExitCode = 1
        return
    }
    Write-Host ''
    Write-AccountLine (T 'Connecté à Salad' 'Connected to Salad') $script:Account.Org $script:Account.Project $groups

    while ($true) {
        Write-Box "Menu  ·  $($script:Account.Label)" @(
            @((New-Cell '1   ' 'Yellow'), (T 'Voir mes groupes' 'View my groups')),
            @((New-Cell '2   ' 'Yellow'), (T 'Voir les machines d''un groupe (carte, hashrate, chien de garde, prix)' 'View the machines of a group (GPU, hashrate, watchdog, price)')),
            @((New-Cell '3   ' 'Yellow'), (T 'Modifier un groupe (étiquette d''image, replicas, chien de garde, priorité, mineur)' 'Edit a group (image tag, replicas, watchdog, priority, miner)')),
            @((New-Cell '4   ' 'Yellow'), (T 'Réallouer / recréer / redémarrer des machines' 'Reallocate / recreate / restart machines')),
            @((New-Cell '5   ' 'Yellow'), (T 'Logs en direct' 'Live logs')),
            @((New-Cell '6   ' 'Yellow'), (T 'Démarrer / arrêter un groupe' 'Start / stop a group')),
            @((New-Cell '7   ' 'Yellow'), (T 'Cartes : prix et disponibilité' 'GPUs: prices and availability')),
            @((New-Cell '8   ' 'Yellow'), (T 'Clés API Salad (basculer, ajouter, retirer)' 'Salad API keys (switch, add, remove)')),
            @((New-Cell 'S   ' 'Yellow'), (T 'Solde Salad : saisir, ou connecter le portail (autonomie dans le menu 1)' 'Salad balance: enter, or connect the portal (remaining time in menu 1)')),
            @((New-Cell 'P   ' 'Yellow'), (T 'Pool : mon portefeuille HeroMiners / unMineable (hashrate vu par la pool, gains réels)' 'Pool: my HeroMiners / unMineable wallet (hashrate seen by the pool, real earnings)')),
            @((New-Cell '9   ' 'Yellow'), (T 'Quitter' 'Quit'))
        )
        $choice = (Read-Answer (T 'Ton choix' 'Your choice')).ToLowerInvariant()
        try {
            if ($choice -eq '1') { Invoke-View }
            elseif ($choice -eq '2') { Invoke-ViewInstances }
            elseif ($choice -eq '3') { Invoke-ModifyGroup }
            elseif ($choice -eq '4') { Invoke-InstanceActions }
            elseif ($choice -eq '5') { Invoke-LiveLogs }
            elseif ($choice -eq '6') { Invoke-StartStop }
            elseif ($choice -eq '7') { Invoke-GpuMarket }
            elseif ($choice -eq '8') { Invoke-ApiKeys }
            elseif (@('s', 'solde', 'balance') -contains $choice) { Invoke-Balance }
            elseif (@('p', 'pool', 'wallet', 'portefeuille') -contains $choice) { Invoke-PoolMenu }
            elseif (@('9', 'q', 'quit', 'quitter') -contains $choice) { Disconnect-Portal; return }
        }
        catch { Write-Bad (T "Erreur : $($_.Exception.Message)" "Error: $($_.Exception.Message)") }
    }
}

try {
    Main
    exit $script:ExitCode
}
catch {
    Write-Bad (T "Erreur inattendue : $($_.Exception.Message)" "Unexpected error: $($_.Exception.Message)")
    exit 1
}
