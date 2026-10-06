<#
  Vast-Switch-Log : gestion des locations Vast.ai.
  Vast-Switch-Log: manage your Vast.ai rentals.
    1. Voir mes locations (hashrate, prix, crédit, autonomie) / View my rentals
    2. Changer le template (update + recycle)      / Change the template
    3. Redémarrer (reboot)                         / Reboot
    4. Logs en direct                              / Live logs
    5. Clés API Vast.ai                            / Vast.ai API keys
    6. Cartes : prix et offres (search offers)     / GPUs: prices and offers
    P. Pool : mon portefeuille HeroMiners / unMineable / Pool: my wallet
    7. Quitter                                     / Quit

  Windows : double-clic sur vast-switch-log.bat (Windows PowerShell 5.1 ou PowerShell 7).
  macOS   : double-clic sur vast-switch-log.command (PowerShell 7, « pwsh », requis).
  Langue  : celle du système (français -> français, sinon anglais) ; -Language fr|en pour forcer.

  Le script n'utilise que ces commandes vastai :
    show user, set api-key, show instances, search templates, search offers,
    update instance, recycle instance, reboot instance, logs
  Il ne détruit jamais une location.  /  It never destroys a rental.
  En plus, sans clé : cours du PRL (CoinGecko), réseau PRL (whattomine), rendement des pools
  unMineable et HeroMiners, et ton portefeuille sur ces pools (menu P).
#>
param(
    # Intervalle entre deux vérifications pendant l'attente du redémarrage.
    [ValidateRange(2, 300)][int]$PollSeconds = 15,
    # Durée maximale d'attente du redémarrage.
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 600,
    # Intervalle de rafraîchissement des logs en direct (menu 4).
    [ValidateRange(3, 120)][int]$LogRefreshSeconds = 5,
    # Langue de l'affichage : auto (celle du système), fr ou en.
    [ValidateSet('auto', 'fr', 'en')][string]$Language = 'auto'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

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
if ($env:VAST_SWITCH_OS) { $script:Os = $env:VAST_SWITCH_OS }

# vastai est un programme Python : sortie en UTF-8, sans message de mise à jour.
$env:PYTHONIOENCODING = 'utf-8'
$env:PYTHONUTF8 = '1'
$env:VASTAI_NO_UPDATE_CHECK = '1'

$script:VastExe = $null
# Cours (CoinGecko) et réseau (whattomine) du PRL, gardés 5 min (voir Get-PearlMarket).
$script:CoinGeckoBase = 'https://api.coingecko.com/api/v3'
if ($env:PRL_COINGECKO_BASE) { $script:CoinGeckoBase = $env:PRL_COINGECKO_BASE.TrimEnd('/') }
$script:WhatToMineBase = 'https://whattomine.com'
if ($env:PRL_WHATTOMINE_BASE) { $script:WhatToMineBase = $env:PRL_WHATTOMINE_BASE.TrimEnd('/') }
$script:UnmineableBase = 'https://api.unmineable.com'
if ($env:PRL_UNMINEABLE_BASE) { $script:UnmineableBase = $env:PRL_UNMINEABLE_BASE.TrimEnd('/') }
$script:HeroMinersBase = 'https://pearl.herominers.com'
if ($env:PRL_HEROMINERS_BASE) { $script:HeroMinersBase = $env:PRL_HEROMINERS_BASE.TrimEnd('/') }
$script:Market = $null
# Rapports des pools (menu P), gardés 2 min ; hashrate loué vu au dernier menu 1 (facteurs des pools).
$script:Wallets = $null
$script:LastFleet = $null
$script:FleetMenuLabel = 'menu 1'
# Compte Vast.ai ouvert par la clé active (réponse de show user), pour le bandeau du menu.
$script:User = $null
# Code de sortie : 1 garde la fenêtre ouverte (voir les lanceurs) pour lire le message.
$script:ExitCode = 0
$script:LogLines = 100
# Lignes de logs relues par location pour trouver le dernier hashrate (menu 1).
$script:HashTail = 400
# Si le script ne voit pas le redémarrage (même image, redémarrage très rapide),
# il accepte la location après ce délai, à condition qu'elle tourne.
$script:UnseenRecycleSeconds = [Math]::Min(180, [int]($TimeoutSeconds / 2))
$script:UnseenRebootSeconds = [Math]::Min(60, [int]($TimeoutSeconds / 2))
# Un reboot est rapide : vérification plus fréquente pour le voir passer.
$script:RebootPollSeconds = [Math]::Min(5, $PollSeconds)

$script:BorderColor = 'DarkCyan'
$script:AccentColor = 'Cyan'
# Largeur maximale des tableaux, cadres et séparateurs.
$script:MaxWidth = 132

# TLS 1.2 pour CoinGecko et whattomine (Windows PowerShell 5.1 ne l'active pas toujours de lui-même).
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
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
        (New-Cell 'Vast-Switch-Log' 'White'),
        (New-Cell '  ·  ' $script:BorderColor),
        (New-Cell (T 'Gestion locations Vast.ai' 'Vast.ai rental manager') $script:AccentColor)
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

function Format-Price($Value, [int]$Decimals = 2) {
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

# Date Vast.ai (secondes depuis 1970, UTC) en heure locale.
function Format-Epoch($Seconds) {
    if ($null -eq $Seconds) { return '?' }
    try {
        $origin = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
        return $origin.AddSeconds([double]$Seconds).ToLocalTime().ToString('dd/MM/yyyy HH:mm')
    }
    catch { return '?' }
}
# === Appels à vastai ===============================================================

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function ConvertTo-ArgumentString([string[]]$Arguments) {
    $parts = foreach ($argument in $Arguments) {
        if ($argument -eq '') { '""' }
        elseif ($argument -match '[\s"]') { '"' + ($argument -replace '"', '\"') + '"' }
        else { $argument }
    }
    return ($parts -join ' ')
}

# Lance vastai et récupère séparément sa sortie normale et sa sortie d'erreur.
function Invoke-Vast([string[]]$Arguments, [string]$ApiKey = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:VastExe
    $psi.Arguments = ConvertTo-ArgumentString $Arguments
    # Une clé passée ici n'est utilisée que pour cet appel (variable VAST_API_KEY de vastai),
    # sans toucher à la clé enregistrée.
    if ($ApiKey) { $psi.EnvironmentVariables['VAST_API_KEY'] = $ApiKey }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($psi)
    $errTask = $process.StandardError.ReadToEndAsync()
    $out = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Out = $out; Err = $errTask.Result }
}

# Plusieurs appels vastai en même temps, $MaxParallel au plus en vol : dès qu'un appel se
# termine, le suivant part. $ArgumentLists : liste de listes d'arguments. Renvoie, dans
# le même ordre, des { ExitCode, Out, Err, TimedOut } ; un appel qui dépasse
# $TimeoutSeconds est arrêté (TimedOut).
function Invoke-VastMany($ArgumentLists, [int]$MaxParallel = 6, [int]$TimeoutSeconds = 45) {
    $results = @()
    if (@($ArgumentLists).Count -eq 0) { return , $results }
    if ($env:VAST_LOG_TIMEOUT) { $TimeoutSeconds = [int]$env:VAST_LOG_TIMEOUT }
    $pending = @(foreach ($arguments in $ArgumentLists) { [pscustomobject]@{ Arguments = $arguments; ExitCode = -1; Out = ''; Err = ''; TimedOut = $false } })
    $queue = New-Object System.Collections.Queue
    foreach ($item in $pending) { $queue.Enqueue($item) }
    $inFlight = New-Object System.Collections.ArrayList
    while ($queue.Count -gt 0 -or $inFlight.Count -gt 0) {
        while ($queue.Count -gt 0 -and $inFlight.Count -lt $MaxParallel) {
            $item = $queue.Dequeue()
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $script:VastExe
            $psi.Arguments = ConvertTo-ArgumentString $item.Arguments
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
            try {
                $process = [System.Diagnostics.Process]::Start($psi)
                [void]$inFlight.Add([pscustomobject]@{
                    Item = $item; Process = $process; Started = (Get-Date)
                    OutTask = $process.StandardOutput.ReadToEndAsync(); ErrTask = $process.StandardError.ReadToEndAsync()
                })
            }
            catch { $item.Err = $_.Exception.Message; $item.ExitCode = -1 }
        }
        Start-Sleep -Milliseconds 150
        for ($i = $inFlight.Count - 1; $i -ge 0; $i--) {
            $entry = $inFlight[$i]
            $done = $entry.Process.HasExited
            if (-not $done -and ((Get-Date) - $entry.Started).TotalSeconds -gt $TimeoutSeconds) {
                try { $entry.Process.Kill() } catch { }
                $entry.Item.TimedOut = $true
                $done = $true
            }
            if (-not $done) { continue }
            $entry.Process.WaitForExit()
            $entry.Item.Out = $entry.OutTask.Result
            $entry.Item.Err = $entry.ErrTask.Result
            $entry.Item.ExitCode = $entry.Process.ExitCode
            $entry.Process.Dispose()
            $inFlight.RemoveAt($i)
        }
    }
    foreach ($item in $pending) { $results += [pscustomobject]@{ ExitCode = $item.ExitCode; Out = $item.Out; Err = $item.Err; TimedOut = $item.TimedOut } }
    return , $results
}

function ConvertFrom-VastJson([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $start = $Text.IndexOfAny([char[]]'[{')
    if ($start -lt 0) { return $null }
    try { return (ConvertFrom-Json -InputObject $Text.Substring($start)) } catch { return $null }
}

# Message d'erreur lisible à partir d'une réponse de vastai.
function Get-VastError($Result) {
    $json = ConvertFrom-VastJson $Result.Err
    if ($json -and (Get-Prop $json 'msg')) {
        $code = Get-Prop $json 'status_code'
        if ($code) { return (T "erreur $code : $(Get-Prop $json 'msg')" "error ${code}: $(Get-Prop $json 'msg')") }
        return [string](Get-Prop $json 'msg')
    }
    foreach ($text in @($Result.Err, $Result.Out)) {
        $lines = @($text -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
        if ($lines.Count -gt 0) { return $lines[-1].Trim() }
    }
    return (T 'pas de réponse de vastai' 'no answer from vastai')
}

function Test-Unauthorized($Result) {
    $json = ConvertFrom-VastJson $Result.Err
    $code = Get-Prop $json 'status_code'
    if ($code -eq 401 -or $code -eq 403) { return $true }
    return (("$($Result.Err) $($Result.Out)") -match '\b401\b|Invalid user key|log in or sign up')
}

# === Trouver vastai et vérifier la clé =============================================

# vastai sur le PATH, sinon là où pip l'installe (Windows : dossiers Scripts de Python ;
# macOS : Homebrew, pipx, ~/Library/Python/3.x/bin).
function Find-VastExe {
    $command = Get-Command vastai -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Path }
    $patterns = @()
    if ($script:Os -eq 'windows') {
        if ($env:LOCALAPPDATA) {
            $patterns += Join-Path $env:LOCALAPPDATA 'Python\*\Scripts\vastai.exe'
            $patterns += Join-Path $env:LOCALAPPDATA 'Programs\Python\*\Scripts\vastai.exe'
        }
        if ($env:APPDATA) { $patterns += Join-Path $env:APPDATA 'Python\*\Scripts\vastai.exe' }
    }
    else {
        $patterns += '/opt/homebrew/bin/vastai'
        $patterns += '/usr/local/bin/vastai'
        if ($env:HOME) {
            $patterns += Join-Path $env:HOME '.local/bin/vastai'
            $patterns += Join-Path $env:HOME 'Library/Python/*/bin/vastai'
        }
    }
    foreach ($pattern in $patterns) {
        $hit = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Find-Python {
    $names = @('py', 'python')
    if ($script:Os -ne 'windows') { $names = @('python3', 'python') }
    foreach ($name in $names) {
        $found = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -notmatch '\\WindowsApps\\' } | Select-Object -First 1
        if ($found) { return $found.Path }
    }
    return $null
}

function Install-Vast {
    $python = Find-Python
    if (-not $python) {
        if ($script:Os -eq 'mac') { Write-Bad (T 'Python est introuvable. Installe-le avec « brew install python » (ou depuis python.org), puis relance ce script.' 'Python is missing. Install it with "brew install python" (or from python.org), then run this script again.') }
        else { Write-Bad (T 'Python est introuvable. Installe-le depuis python.org, puis relance ce script.' 'Python is missing. Install it from python.org, then run this script again.') }
        return $false
    }
    Write-Step (T "Installation de vastai avec $python" "Installing vastai with $python")
    Write-Host ''
    if ($script:Os -eq 'windows') { & $python -m pip install --upgrade vastai }
    else { & $python -m pip install --user --upgrade vastai }
    return ($LASTEXITCODE -eq 0)
}

function Test-ApiKey([string]$ApiKey = '') {
    $result = Invoke-Vast @('show', 'user', '--raw') $ApiKey
    $user = ConvertFrom-VastJson $result.Out
    if ($user -and (Get-Prop $user 'id')) {
        return [pscustomobject]@{ User = $user; Unauthorized = $false; Error = '' }
    }
    # Réponse valide mais illisible pour ce PowerShell : la clé marche quand même.
    if ($result.Out -match '"id"\s*:') {
        return [pscustomobject]@{ User = [pscustomobject]@{ id = 1 }; Unauthorized = $false; Error = '' }
    }
    return [pscustomobject]@{ User = $null; Unauthorized = (Test-Unauthorized $result); Error = (Get-VastError $result) }
}

function Initialize-ApiKey {
    while ($true) {
        $check = Test-ApiKey
        if ($check.User) { return $check.User }
        if (-not $check.Unauthorized) {
            Write-Bad (T "Impossible de joindre Vast.ai : $($check.Error)" "Cannot reach Vast.ai: $($check.Error)")
            if (Confirm-Action (T 'Réessayer ?' 'Try again?')) { continue }
            return $null
        }
        Write-Box (T 'Clé API' 'API key') @(
            (New-Cell (T 'Vast.ai refuse ta clé API (supprimée, expirée ou absente).' 'Vast.ai rejects your API key (deleted, expired or missing).') 'Red'),
            '',
            (T 'Crée une nouvelle clé sur cloud.vast.ai > Account > Keys, puis colle-la ici.' 'Create a new key on cloud.vast.ai > Account > Keys, then paste it here.'),
            (New-Cell (T 'Elle ne s''affiche pas pendant la saisie, c''est normal.' 'It is not displayed while you type, that is normal.') 'DarkGray')
        )
        $new = Read-NewKey (T 'quitter' 'quit')
        if (-not $new) { return $null }
        if (Set-ActiveKey $new.Key $new.User) { return $new.User }
    }
}

# Clé enregistrée par vastai (chaîne vide si aucune). vastai la range dans le dossier
# de configuration XDG : ~/.config/vastai/vast_api_key (sur Windows aussi :
# C:\Users\<toi>\.config\vastai\vast_api_key).
function Get-SavedKey {
    $candidates = @()
    if ($env:XDG_CONFIG_HOME) { $candidates += Join-Path $env:XDG_CONFIG_HOME 'vastai/vast_api_key' }
    if ($env:USERPROFILE) { $candidates += Join-Path $env:USERPROFILE '.config\vastai\vast_api_key' }
    if ($env:HOME) { $candidates += Join-Path $env:HOME '.config/vastai/vast_api_key' }
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            try { return ([System.IO.File]::ReadAllText($path)).Trim() } catch { }
        }
    }
    return ''
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
# La clé active est celle de vastai (son fichier, en clair : c'est son fonctionnement).
# La liste des clés connues est dans keys.json (compte, date, référence) :
#   Windows : la clé elle-même est dans le fichier, chiffrée par la protection Windows
#             (DPAPI) ; seule ta session Windows, sur ce PC, peut la relire.
#   macOS   : la clé est dans le Trousseau d'accès (outil « security » du système).
#   Linux   : la clé est dans le fichier, lisible seulement par ton compte (mode 600).

$script:KeychainService = 'Vast-Switch-Log'

function Get-KeyringPath {
    switch ($script:Os) {
        'mac' { return (Join-Path $env:HOME 'Library/Application Support/Vast-Switch-Log/keys.json') }
        'linux' {
            $base = $env:XDG_CONFIG_HOME
            if (-not $base) { $base = Join-Path $env:HOME '.config' }
            return (Join-Path $base 'Vast-Switch-Log/keys.json')
        }
        default {
            $base = $env:APPDATA
            if (-not $base) { $base = Join-Path $env:HOME '.config' }
            return (Join-Path (Join-Path $base 'Vast-Switch-Log') 'keys.json')
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

# Appelle l'outil « security » de macOS ; renvoie { ExitCode, Out, Err }.
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
        $result = Invoke-Security @('add-generic-password', '-a', $Id, '-s', $script:KeychainService, '-l', "Vast-Switch-Log ($Id)", '-w', $Key, '-U')
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

# Liste des entrées { Id, Account, Suffix, Added, Stored }.
function Get-Keyring {
    $path = Get-KeyringPath
    $entries = @()
    if (Test-Path -LiteralPath $path) {
        try {
            $data = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($path))
            foreach ($item in @(Get-Prop $data 'keys')) {
                if ($null -eq $item -or -not (Get-Prop $item 'stored')) { continue }
                $id = [string](Get-Prop $item 'id')
                if (-not $id) { $id = [guid]::NewGuid().ToString('N') }
                $entries += [pscustomobject]@{
                    Id      = $id
                    Account = [string](Get-Prop $item 'account')
                    Suffix  = [string](Get-Prop $item 'suffix')
                    Added   = [string](Get-Prop $item 'added')
                    Stored  = [string](Get-Prop $item 'stored')
                }
            }
        }
        catch { Write-Warn (T "Le fichier des clés est illisible ($path) : il sera recréé." "The key file is unreadable ($path): it will be recreated.") }
    }
    return , $entries
}

function Save-Keyring($Entries) {
    $path = Get-KeyringPath
    $folder = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $list = @(foreach ($entry in $Entries) {
        @{ id = $entry.Id; account = $entry.Account; suffix = $entry.Suffix; added = $entry.Added; stored = $entry.Stored }
    })
    $json = ConvertTo-Json -InputObject @{ keys = $list } -Depth 4
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    if ($script:Os -ne 'windows') {
        try { & chmod 600 $path 2>$null | Out-Null } catch { }
    }
}

# Ajoute une clé dans le trousseau ; une clé déjà présente garde sa place et sa date.
function Add-KeyringEntry([string]$Key, [string]$Account) {
    $entries = Get-Keyring
    $found = $false
    foreach ($entry in $entries) {
        if ((Unprotect-Key $entry.Stored) -eq $Key) { $entry.Account = $Account; $found = $true }
    }
    if (-not $found) {
        $id = [guid]::NewGuid().ToString('N')
        $entries += [pscustomobject]@{
            Id      = $id
            Account = $Account
            Suffix  = Get-KeySuffix $Key
            Added   = (Get-Date).ToString('dd/MM/yyyy HH:mm')
            Stored  = Protect-Key $Key $id
        }
    }
    Save-Keyring $entries
}

# Enregistre la clé comme clé active de vastai et dans le trousseau. $User : réponse de show user.
function Set-ActiveKey([string]$Key, $User) {
    $result = Invoke-Vast @('set', 'api-key', $Key)
    if ($result.ExitCode -ne 0 -or $result.Out -notmatch 'saved') {
        Write-Bad (T "Enregistrement refusé : $(Get-VastError $result)" "Could not save the key: $(Get-VastError $result)")
        return $false
    }
    $account = [string](Get-Prop $User 'email')
    if (-not $account) { $account = T 'compte Vast.ai' 'Vast.ai account' }
    Add-KeyringEntry $Key $account
    return $true
}

function Write-AccountLine([string]$Lead, $User) {
    $email = Get-Prop $User 'email'
    $credit = Get-Prop $User 'credit'
    Write-Segment "  $Lead" 'Green'
    if ($email) { Write-Segment (T '   ·   Compte ' '   ·   Account ') 'DarkGray'; Write-Segment $email 'White' }
    if ($null -ne $credit) { Write-Segment (T '   ·   Crédit ' '   ·   Credit ') 'DarkGray'; Write-Segment (Format-Price $credit) 'White' }
    Write-Host ''
}

# Saisie + test d'une nouvelle clé. Renvoie $null (annulé) ou { Key, User }.
function Read-NewKey([string]$EmptyMeaning) {
    while ($true) {
        $key = Read-SecretKey (T "Nouvelle clé API (Entrée sans rien = $EmptyMeaning)" "New API key (Enter alone = $EmptyMeaning)")
        if ($key -eq '') { return $null }
        Write-Step (T 'Test de la clé … ' 'Testing the key … ')
        $check = Test-ApiKey $key
        if ($check.User) {
            Write-Host (T 'acceptée' 'accepted') -ForegroundColor Green
            return [pscustomobject]@{ Key = $key; User = $check.User }
        }
        if ($check.Unauthorized) { Write-Host (T 'refusée par Vast.ai' 'rejected by Vast.ai') -ForegroundColor Red }
        else { Write-Host (T "impossible de vérifier ($($check.Error))" "could not check ($($check.Error))") -ForegroundColor Red }
        if (-not (Confirm-Action (T 'Réessayer avec une autre clé ?' 'Try another key?'))) { return $null }
    }
}

# === Menu 5 : clés API ===============================================================

function Show-Keyring($Entries, [string]$ActiveKey) {
    $columns = @((New-Column (T 'N°' '#') 'R'), (New-Column (T 'Compte' 'Account') 'L' 10 40), (New-Column (T 'Fin' 'Ends')), (New-Column 'Active'), (New-Column (T 'Ajoutée le' 'Added on')))
    $rows = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $Entries.Count; $n++) {
        $entry = $Entries[$n]
        $active = ''
        if ($ActiveKey -and (Unprotect-Key $entry.Stored) -eq $ActiveKey) { $active = '●' }
        [void]$rows.Add(@(
            (New-Cell ([string]($n + 1)) $script:AccentColor),
            (New-Cell $entry.Account 'White'),
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
        Write-Rule (T 'Clés API Vast.ai' 'Vast.ai API keys')
        $entries = Get-Keyring
        $activeKey = Get-SavedKey
        $knownActive = $false
        foreach ($entry in $entries) { if ($activeKey -and (Unprotect-Key $entry.Stored) -eq $activeKey) { $knownActive = $true } }
        if ($activeKey -and -not $knownActive) {
            Write-Dim (T "La clé active de vastai (…$(Get-KeySuffix $activeKey)) n'est pas dans la liste : elle y sera ajoutée si tu la confirmes." "The active vastai key (…$(Get-KeySuffix $activeKey)) is not in the list: it will be added if you confirm it.")
        }
        if ($entries.Count -eq 0) { Write-Dim (T 'Aucune clé dans la liste pour le moment.' 'No key in the list yet.') }
        else { Show-Keyring $entries $activeKey }
        Write-Dim (T "Fichier : $(Get-KeyringPath) ($(Get-KeyringStorageText))" "File: $(Get-KeyringPath) ($(Get-KeyringStorageText))")

        $hint = T 'Un numéro = basculer sur cette clé   ·   A = ajouter   ·   S = retirer de la liste   ·   Entrée sans rien = retour au menu' 'A number = switch to that key   ·   A = add   ·   R = remove from the list   ·   Enter alone = back to the menu'
        if ($activeKey -and -not $knownActive) { $hint = T 'Un numéro = basculer   ·   A = ajouter   ·   C = garder la clé active actuelle dans la liste   ·   S = retirer   ·   Entrée = retour' 'A number = switch   ·   A = add   ·   K = keep the current active key in the list   ·   R = remove   ·   Enter = back' }
        $answer = (Read-Answer (T 'Ton choix' 'Your choice') $hint).ToLowerInvariant()

        if ($answer -eq '') { return }

        if (($answer -eq 'c' -or $answer -eq 'k') -and $activeKey -and -not $knownActive) {
            Write-Step (T 'Test de la clé active … ' 'Testing the active key … ')
            $check = Test-ApiKey
            if ($check.User) {
                Write-Host (T 'acceptée' 'accepted') -ForegroundColor Green
                $account = [string](Get-Prop $check.User 'email')
                if (-not $account) { $account = T 'compte Vast.ai' 'Vast.ai account' }
                Add-KeyringEntry $activeKey $account
                Write-Ok (T 'Clé ajoutée à la liste.' 'Key added to the list.')
            }
            else { Write-Host (T 'refusée par Vast.ai, elle n''est pas ajoutée.' 'rejected by Vast.ai, not added.') -ForegroundColor Red }
            continue
        }

        if ($answer -eq 'a') {
            Write-Box (T 'Ajouter une clé' 'Add a key') @(
                (T 'Crée la clé sur cloud.vast.ai > Account > Keys, puis colle-la ici.' 'Create the key on cloud.vast.ai > Account > Keys, then paste it here.'),
                (T 'Elle est testée avant d''être enregistrée : si Vast.ai la refuse, rien ne change.' 'It is tested before being stored: if Vast.ai rejects it, nothing changes.'),
                (New-Cell (T 'Elle ne s''affiche pas pendant la saisie, c''est normal.' 'It is not displayed while you type, that is normal.') 'DarkGray')
            )
            $new = Read-NewKey (T 'annuler' 'cancel')
            if (-not $new) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); continue }
            Write-AccountLine (T 'Cette clé ouvre' 'This key opens') $new.User
            if (-not (Confirm-Action (T 'L''enregistrer et l''activer ?' 'Store it and make it active?'))) { Write-Dim (T 'Annulé, rien n''a changé.' 'Cancelled, nothing changed.'); continue }
            if (Set-ActiveKey $new.Key $new.User) {
                $script:User = $new.User
                Write-Ok (T "Clé …$(Get-KeySuffix $new.Key) enregistrée et active." "Key …$(Get-KeySuffix $new.Key) stored and active.")
            }
            continue
        }

        if ($answer -eq 's' -or $answer -eq 'r') {
            if ($entries.Count -eq 0) { Write-Warn (T 'Rien à retirer.' 'Nothing to remove.'); continue }
            $index = Read-Index $entries.Count (T 'Quelle clé retirer de la liste' 'Which key to remove from the list') (T 'Tape son numéro   ·   Entrée sans rien = annuler' 'Type its number   ·   Enter alone = cancel')
            if ($index -lt 0) { continue }
            $entry = $entries[$index]
            if ($activeKey -and (Unprotect-Key $entry.Stored) -eq $activeKey) {
                Write-Warn (T 'C''est la clé active : elle reste utilisée par vastai, elle disparaît seulement de la liste.' 'This is the active key: vastai keeps using it, it only disappears from the list.')
            }
            if (-not (Confirm-Action (T "Retirer la clé …$($entry.Suffix) ($($entry.Account)) de la liste ?" "Remove key …$($entry.Suffix) ($($entry.Account)) from the list?"))) { continue }
            $kept = @()
            for ($n = 0; $n -lt $entries.Count; $n++) { if ($n -ne $index) { $kept += $entries[$n] } }
            Save-Keyring $kept
            Remove-StoredKey $entry.Stored
            Write-Ok (T 'Clé retirée de la liste (elle reste valable sur Vast.ai tant que tu ne la révoques pas sur le site).' 'Key removed from the list (it stays valid on Vast.ai until you revoke it on the site).')
            continue
        }

        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $entries.Count) {
            $entry = $entries[[int]$answer - 1]
            $key = Unprotect-Key $entry.Stored
            if (-not $key) {
                Write-Bad (T 'Cette clé ne peut pas être relue sur cette session : retire-la (S) et ressaisis-la (A).' 'This key cannot be read back in this session: remove it (R) and enter it again (A).')
                continue
            }
            if ($key -eq $activeKey) { Write-Dim (T 'Cette clé est déjà active.' 'This key is already active.'); continue }
            Write-Step (T "Test de la clé …$($entry.Suffix) … " "Testing key …$($entry.Suffix) … ")
            $check = Test-ApiKey $key
            if (-not $check.User) {
                if ($check.Unauthorized) { Write-Host (T 'refusée par Vast.ai (révoquée ?) : la clé active ne change pas.' 'rejected by Vast.ai (revoked?): the active key does not change.') -ForegroundColor Red }
                else { Write-Host (T "impossible de vérifier ($($check.Error)) : la clé active ne change pas." "could not check ($($check.Error)): the active key does not change.") -ForegroundColor Red }
                continue
            }
            Write-Host (T 'acceptée' 'accepted') -ForegroundColor Green
            if (Set-ActiveKey $key $check.User) {
                $script:User = $check.User
                Write-AccountLine (T 'Bascule faite' 'Switched') $check.User
            }
            continue
        }

        Write-Warn (T 'Réponse non comprise.' 'Not understood.')
    }
}

# === Locations =====================================================================

function Get-Instances {
    $result = Invoke-Vast @('show', 'instances', '--raw')
    $data = ConvertFrom-VastJson $result.Out
    if ($null -eq $data -and $result.Out.Trim() -ne '[]') {
        throw (T "impossible de lire la liste des locations ($(Get-VastError $result))" "cannot read the rental list ($(Get-VastError $result))")
    }
    $list = @()
    foreach ($instance in @($data)) { if ($null -ne $instance) { $list += $instance } }
    return , $list
}

# Image qui tourne vraiment, d'après le message d'état de Vast.ai
# (ex. "success, running clusmi/rentingminers:latest").
function Get-RunningImage([string]$StatusMsg) {
    if ($StatusMsg -and $StatusMsg -match 'running\s+(\S+)') { return $Matches[1].TrimEnd('.', ',') }
    return $null
}

function Get-NormalizedImage([string]$Image) {
    if ([string]::IsNullOrWhiteSpace($Image)) { return '' }
    $image = $Image.Trim().ToLowerInvariant() -replace '^docker\.io/', '' -replace '^library/', ''
    $lastPart = $image.Split('/')[-1]
    if ($lastPart -notmatch ':' -and $image -notmatch '@') { $image += ':latest' }
    return $image
}

function Test-StatusError([string]$StatusMsg) {
    if (-not $StatusMsg) { return $false }
    return ($StatusMsg -match '(?i)^\s*error|pull access denied|manifest .*not found|unauthorized: authentication required|OCI runtime')
}

# État Vast.ai traduit, avec sa couleur.
function Get-StatusInfo([string]$Status, [string]$StatusMsg) {
    if (Test-StatusError $StatusMsg) { return [pscustomobject]@{ Label = (T 'Erreur' 'Error'); Color = 'Red' } }
    switch ($Status) {
        'running'    { return [pscustomobject]@{ Label = (T 'En marche' 'Running');    Color = 'Green' } }
        'loading'    { return [pscustomobject]@{ Label = (T 'Démarrage' 'Starting');   Color = 'Yellow' } }
        'scheduling' { return [pscustomobject]@{ Label = (T 'En attente' 'Pending');   Color = 'Yellow' } }
        'created'    { return [pscustomobject]@{ Label = (T 'Créée' 'Created');        Color = 'Yellow' } }
        'exited'     { return [pscustomobject]@{ Label = (T 'Arrêtée' 'Stopped');      Color = 'Red' } }
        'stopped'    { return [pscustomobject]@{ Label = (T 'Arrêtée' 'Stopped');      Color = 'Red' } }
        'offline'    { return [pscustomobject]@{ Label = (T 'Hors ligne' 'Offline');   Color = 'Red' } }
    }
    if (-not $Status) { $Status = '?' }
    return [pscustomobject]@{ Label = $Status; Color = 'Yellow' }
}

function Get-GpuText($Instance) {
    return "$(Get-Prop $Instance 'num_gpus')x $(Get-Prop $Instance 'gpu_name')"
}

# === Hashrate lu dans les logs =====================================================

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

# Un hashrate en H/s, dans l'unité la plus lisible : "342.10 TH/s", "5.00 MH/s".
function Format-Hashrate([double]$HashesPerSecond, [int]$Decimals = 2) {
    $units = @(@('T', 1e12), @('G', 1e9), @('M', 1e6), @('K', 1e3))
    $pattern = '{0:N' + $Decimals + '} {1}H/s'
    foreach ($unit in $units) {
        if ($HashesPerSecond -ge $unit[1]) { return ($pattern -f ($HashesPerSecond / $unit[1]), $unit[0]) }
    }
    return (('{0:N' + $Decimals + '} H/s') -f $HashesPerSecond)
}

# Dernière lecture de hashrate de chaque GPU dans des lignes de logs (SRBMiner :
# "GPU0 RTX 5090: 342.10 TH/s [...]", ou "GPU0: 2.51 MH/s  GPU1: 2.49 MH/s").
# Renvoie { HashesPerSecond (somme des GPU), Gpus (nombre de GPU lus) } ou $null.
function ConvertFrom-HashrateLines($Lines) {
    $latest = @{}
    foreach ($line in $Lines) {
        foreach ($match in [regex]::Matches([string]$line, 'GPU(\d+)[^:\r\n]*:\s*([0-9]+(?:\.[0-9]+)?)\s*([KkMmGgTt]?)[Hh]/s')) {
            $latest[[int]$match.Groups[1].Value] = ConvertTo-HashesPerSecond $match.Groups[2].Value $match.Groups[3].Value
        }
    }
    if ($latest.Count -eq 0) { return $null }
    $sum = 0.0
    foreach ($value in $latest.Values) { $sum += $value }
    return [pscustomobject]@{ HashesPerSecond = $sum; Gpus = $latest.Count }
}

# Hashrate des locations en marche, lu dans les dernières lignes de logs de chacune
# (vastai logs, lancés en parallèle). Renvoie { Info = table id -> { HashesPerSecond, Gpus } ; Errors }.
function Get-InstanceHashrates($Instances) {
    $info = @{}
    $errors = @()
    $targets = @($Instances | Where-Object { [string](Get-Prop $_ 'actual_status') -eq 'running' })
    if ($targets.Count -eq 0) { return [pscustomobject]@{ Info = $info; Errors = $errors } }
    $lists = @(foreach ($instance in $targets) { , @('logs', [string]$instance.id, '--tail', [string]$script:HashTail, '--filter', 'H/s') })
    $results = Invoke-VastMany $lists
    for ($i = 0; $i -lt $targets.Count; $i++) {
        $result = $results[$i]
        $id = [string]$targets[$i].id
        if ($result.TimedOut) { $errors += (T "location $id : pas de réponse à temps" "rental ${id}: no answer in time"); continue }
        if ($result.ExitCode -ne 0 -and -not $result.Out.Trim()) { $errors += (T "location $id : $(Get-VastError $result)" "rental ${id}: $(Get-VastError $result)"); continue }
        $esc = [char]27
        $text = $result.Out -replace "$esc\[[0-9;?]*[ -/]*[@-~]", '' -replace "$esc[@-_]", ''
        $reading = ConvertFrom-HashrateLines @($text -split "`r?`n")
        if ($reading) { $info[$id] = $reading }
    }
    return [pscustomobject]@{ Info = $info; Errors = $errors }
}

# "3 min", "5 h", "2 j" depuis un instant Unix (start_date de Vast.ai).
function Format-ShortSince($EpochSeconds) {
    if ($null -eq $EpochSeconds) { return '–' }
    try {
        $origin = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
        $minutes = ((Get-Date).ToUniversalTime() - $origin.AddSeconds([double]$EpochSeconds)).TotalMinutes
    }
    catch { return '–' }
    if ($minutes -lt 1) { return '< 1 min' }
    if ($minutes -lt 60) { return ('{0} min' -f [int][Math]::Floor($minutes)) }
    if ($minutes -lt 2880) { return ('{0} h' -f [int][Math]::Floor($minutes / 60)) }
    return ((T '{0} j' '{0} d') -f [int][Math]::Floor($minutes / 1440))
}

# "45 min", "23 h", "2 j 3 h".
function Format-HoursLeft([double]$Hours) {
    if ($Hours -lt 1) { return ('{0} min' -f [int][Math]::Floor($Hours * 60)) }
    if ($Hours -lt 24) { return ('{0} h' -f [int][Math]::Floor($Hours)) }
    $days = [int][Math]::Floor($Hours / 24)
    $rest = [int][Math]::Floor($Hours - $days * 24)
    if ($rest -eq 0) { return ((T '{0} j' '{0} d') -f $days) }
    return ((T '{0} j {1} h' '{0} d {1} h') -f $days, $rest)
}

# === Tableau des locations =========================================================

# $Hashrates : résultat de Get-InstanceHashrates (ou $null : colonne Hashrate absente).
function Show-Instances($Instances, $Credit = $null, $Hashrates = $null) {
    $columns = @(
        (New-Column (T 'N°' '#') 'R'),
        (New-Column 'ID'),
        (New-Column 'GPU' 'L' 5),
        (New-Column (T 'État' 'State')),
        (New-Column (T 'Depuis' 'Since') 'R' 6 12),
        (New-Column (T 'Prix/h' 'Price/h') 'R')
    )
    if ($null -ne $Hashrates) { $columns += (New-Column 'Hashrate' 'R') }
    $columns += (New-Column 'Template' 'L' 10 30)
    $columns += (New-Column (T 'Image en cours' 'Running image') 'L' 12 34)
    $rows = New-Object System.Collections.ArrayList
    $mismatch = 0
    $totalPrice = 0.0; $running = 0
    $hashTotal = 0.0; $hashRead = 0
    for ($n = 0; $n -lt $Instances.Count; $n++) {
        $instance = $Instances[$n]
        $status = [string](Get-Prop $instance 'actual_status')
        $statusMsg = [string](Get-Prop $instance 'status_msg')
        $wanted = [string](Get-Prop $instance 'image_uuid')
        $templateName = [string](Get-Prop $instance 'template_name')
        if (-not $templateName) { $templateName = '—' }
        $price = Get-Prop $instance 'dph_total'
        if ($null -ne $price) { $totalPrice += [double]$price }
        if ($status -eq 'running') { $running++ }
        $info = Get-StatusInfo $status $statusMsg
        $runningImage = Get-RunningImage $statusMsg
        if (-not $runningImage) {
            $runningCell = New-Cell "? $statusMsg" 'DarkGray'
        }
        elseif ((Get-NormalizedImage $runningImage) -ne (Get-NormalizedImage $wanted)) {
            $mismatch++
            $runningCell = New-Cell $runningImage 'Yellow'
        }
        else { $runningCell = New-Cell $runningImage 'Green' }
        $cells = @(
            (New-Cell ([string]($n + 1)) $script:AccentColor),
            (New-Cell ([string]$instance.id) 'White'),
            (Get-GpuText $instance),
            (New-Cell $info.Label $info.Color),
            (Format-ShortSince (Get-Prop $instance 'start_date')),
            (Format-Price $price)
        )
        if ($null -ne $Hashrates) {
            $hashCell = New-Cell '–' 'DarkGray'
            if ($Hashrates.Info.ContainsKey([string]$instance.id)) {
                $reading = $Hashrates.Info[[string]$instance.id]
                $color = 'Green'
                if ($reading.HashesPerSecond -le 0) { $color = 'Red' }
                $hashCell = New-Cell (Format-Hashrate $reading.HashesPerSecond) $color
                if ($status -eq 'running') { $hashTotal += $reading.HashesPerSecond; $hashRead++ }
            }
            $cells += $hashCell
        }
        $cells += $templateName
        $cells += $runningCell
        [void]$rows.Add($cells)
    }
    Write-Host ''
    Write-Table $columns $rows
    Write-Segment (T '  Total : ' '  Total: ') 'DarkGray'
    Write-Segment (T "$running location(s) en marche sur $($Instances.Count)" "$running running rental(s) out of $($Instances.Count)") 'White'
    Write-Segment '   ·   ' 'DarkGray'; Write-Segment "$(Format-Price $totalPrice) /h" 'White'
    Write-Segment '   ·   ' 'DarkGray'; Write-Segment (T "$(Format-Price ($totalPrice * 24)) /jour" "$(Format-Price ($totalPrice * 24)) /day") 'White'
    if ($hashRead -gt 0) {
        Write-Segment '   ·   ' 'DarkGray'; Write-Segment (Format-Hashrate $hashTotal 1) 'White'
        if ($hashRead -lt $running) { Write-Segment (T " ($hashRead location(s) sur $running lue(s))" " ($hashRead of $running rentals read)") 'Yellow' }
    }
    Write-Host ''
    if ($null -ne $Credit) {
        Write-Segment (T '  Crédit : ' '  Credit: ') 'DarkGray'
        Write-Segment (Format-Price $Credit) 'White'
        if ($totalPrice -gt 0) {
            $hours = [double]$Credit / $totalPrice
            $color = 'Green'
            if ($hours -lt 24) { $color = 'Yellow' }
            if ($hours -lt 6) { $color = 'Red' }
            Write-Segment '   ·   ' 'DarkGray'
            if ([double]$Credit -le 0) { Write-Segment (T 'crédit épuisé' 'credit used up') 'Red' }
            else { Write-Segment (T "autonomie ≈ $(Format-HoursLeft $hours)" "remaining ≈ $(Format-HoursLeft $hours)") $color }
            Write-Segment (T " au rythme actuel ($(Format-Price $totalPrice) /h)" " at the current rate ($(Format-Price $totalPrice) /h)") 'DarkGray'
        }
        else { Write-Segment (T '   ·   aucune dépense en cours' '   ·   nothing being spent') 'DarkGray' }
        Write-Host ''
    }
    if ($null -ne $Hashrates) {
        Write-MarketLine
        if ($hashRead -gt 0) {
            # Flotte louée, pour les facteurs des pools : « changée dans les 24 h » si une location en
            # marche a démarré il y a moins d'un jour, ou si des locations en marche n'ont pas été lues.
            $changed = ($hashRead -lt $running)
            $origin = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)
            foreach ($instance in $Instances) {
                if ([string](Get-Prop $instance 'actual_status') -ne 'running') { continue }
                $start = Get-Prop $instance 'start_date'
                if ($null -eq $start) { continue }
                try { if (((Get-Date).ToUniversalTime() - $origin.AddSeconds([double]$start)).TotalHours -lt 24) { $changed = $true } } catch { }
            }
            $script:LastFleet = [pscustomobject]@{ Hps = $hashTotal; At = (Get-Date); Changed = $changed; Count = $running }
            $cost = $null
            if ($totalPrice -gt 0) { $cost = $totalPrice * 24 }
            Write-RevenueTable $hashTotal $cost
            Write-WalletLines
        }
    }
    if ($mismatch -gt 0) {
        Write-Host ''
        Write-Segment '  '
        Write-Segment (New-Badge 'warn').Text 'Black' 'Yellow'
        Write-Host (T "  $mismatch location(s) ne tournent pas avec l'image de leur template : il leur manque un recycle." "  $mismatch rental(s) are not running their template image: they need a recycle.") -ForegroundColor Yellow
    }
}

# Dernières lignes de logs d'une location, nettoyées des codes de couleur des mineurs.
function Get-LogLines([string]$Id, [int]$Count) {
    $result = Invoke-Vast @('logs', $Id, '--tail', [string]$Count)
    $esc = [char]27
    $text = $result.Out -replace "$esc\[[0-9;?]*[ -/]*[@-~]", '' -replace "$esc[@-_]", ''
    $lines = @($text -split "`r?`n" | ForEach-Object { ($_ -split "`r")[-1] } | Where-Object { $_.Trim() -ne '' })
    return [pscustomobject]@{ Lines = $lines; Result = $result }
}

# Couleur d'une ligne de logs selon son contenu.
function Get-LogLineColor([string]$Line) {
    if ($Line -match '(?i)erreur|error|failed|rejected|warning|attention') { return 'Red' }
    if ($Line -match '^\[rentingminers\]') { return 'Cyan' }
    if ($Line -match '(?i)accepted|H/s') { return 'Green' }
    if ($Line -match '^\[cpu\]') { return 'Gray' }
    return ''
}

function Show-Logs([string]$Id) {
    Write-Rule (T "Logs  ·  Location $Id  ·  $($script:LogLines) dernières lignes" "Logs  ·  Rental $Id  ·  last $($script:LogLines) lines")
    $fetched = Get-LogLines $Id $script:LogLines
    $lines = $fetched.Lines
    $result = $fetched.Result
    if ($lines.Count -eq 0) {
        Write-Segment '  │ ' $script:BorderColor
        Write-Host (T '(pas encore de logs)' '(no logs yet)') -ForegroundColor Yellow
        if ($result.Err.Trim()) {
            Write-Segment '  │ ' $script:BorderColor
            Write-Host (Get-VastError $result) -ForegroundColor Yellow
        }
    }
    else {
        foreach ($line in ($lines | Select-Object -Last $script:LogLines)) {
            Write-Segment '  │ ' $script:BorderColor
            $color = Get-LogLineColor $line
            if ($color) { Write-Host $line -ForegroundColor $color } else { Write-Host $line }
        }
    }
    Write-Host ('  ' + ('─' * (Get-AvailableWidth))) -ForegroundColor $script:BorderColor
}

# === Logs en direct ===================================================================

# Filtres proposés : libellé, expression régulière (vide = tout).
function Get-LogFilters {
    return @(
        @{ Label = (T 'Tout' 'Everything');                                        Pattern = '' },
        @{ Label = (T 'Hashrates (GPU et CPU)' 'Hashrates (GPU and CPU)');         Pattern = 'H/s' },
        @{ Label = (T 'GPU seulement' 'GPU only');                                 Pattern = '^(?!\[cpu\])' },
        @{ Label = (T 'CPU seulement' 'CPU only');                                 Pattern = '^\[cpu\]' },
        @{ Label = (T 'Shares, erreurs et alertes' 'Shares, errors and warnings'); Pattern = '(?i)accepted|rejected|error|erreur|failed|warning|attention' },
        @{ Label = (T 'Messages de l''image' 'Image messages');                    Pattern = '^\[rentingminers\]' }
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
            $text = Read-Answer (T 'Texte à chercher' 'Text to look for') (T 'Exemples : speed   GPU3   accepted   ·   Entrée sans rien = tout' 'Examples: speed   GPU3   accepted   ·   Enter alone = everything')
            if ($text -eq '') { return [pscustomobject]@{ Label = $filters[0].Label; Pattern = '' } }
            try { [void][regex]::new($text) } catch { $text = [regex]::Escape($text) }
            return [pscustomobject]@{ Label = (T "« $text »" "`"$text`""); Pattern = "(?i)$text" }
        }
        Write-Warn (T "Réponse non comprise : tape un numéro entre 1 et $($filters.Count + 1)." "Not understood: type a number between 1 and $($filters.Count + 1).")
    }
}

# Lignes de $Current qui suivent la fin de $Previous (les logs ne font que s'allonger).
# Renvoie $null si aucun recouvrement n'est trouvé (logs remis à zéro, ou trop de nouvelles lignes).
function Get-NewLogLines($Previous, $Current) {
    if ($Previous.Count -eq 0) { return , @($Current) }
    $max = [Math]::Min(20, $Previous.Count)
    for ($k = $max; $k -ge 2; $k--) {
        $suffix = @($Previous | Select-Object -Last $k)
        for ($i = $Current.Count - $k; $i -ge 0; $i--) {
            $match = $true
            for ($j = 0; $j -lt $k; $j++) {
                if ($Current[$i + $j] -ne $suffix[$j]) { $match = $false; break }
            }
            if ($match) {
                if ($i + $k -ge $Current.Count) { return , @() }
                return , @($Current[($i + $k)..($Current.Count - 1)])
            }
        }
    }
    return $null
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

function Invoke-LiveLogs {
    Write-Rule (T 'Logs en direct' 'Live logs')
    $all = Get-Instances
    if ($all.Count -eq 0) { Write-Warn (T 'Aucune location sur ton compte.' 'No rental on your account.'); return }
    Show-Instances $all
    $index = Read-Index $all.Count (T 'Quelle location' 'Which rental') (T 'Tape son numéro   ·   Entrée sans rien = retour au menu' 'Type its number   ·   Enter alone = back to the menu')
    if ($index -lt 0) { return }
    $id = [string]$all[$index].id
    $filter = Read-LogFilter

    try { [Console]::Clear() } catch { }
    Write-Rule (T "Logs en direct  ·  Location $id  ·  filtre : $($filter.Label)  ·  rafraîchi toutes les $LogRefreshSeconds s  ·  Q = retour au menu" "Live logs  ·  Rental $id  ·  filter: $($filter.Label)  ·  refreshed every $LogRefreshSeconds s  ·  Q = back to the menu")
    $previous = @()
    $lastNew = Get-Date
    $silentNotice = $false
    $fetch = 300
    while ($true) {
        $fetched = Get-LogLines $id $fetch
        $current = $fetched.Lines
        if ($current.Count -eq 0 -and $previous.Count -eq 0) {
            Write-Dim (T '(pas encore de logs)' '(no logs yet)')
            if ($fetched.Result.Err.Trim()) { Write-Warn (Get-VastError $fetched.Result) }
            $new = @()
        }
        else {
            $new = Get-NewLogLines $previous $current
            if ($null -eq $new) {
                if ($previous.Count -gt 0) { Write-Dim (T '… (coupure : logs remis à zéro ou trop de nouvelles lignes) …' '… (gap: logs reset or too many new lines) …') }
                $new = @($current | Select-Object -Last $script:LogLines)
            }
        }
        $shown = 0
        foreach ($line in $new) {
            if ($filter.Pattern -and $line -notmatch $filter.Pattern) { continue }
            $color = Get-LogLineColor $line
            if ($color) { Write-Host $line -ForegroundColor $color } else { Write-Host $line }
            $shown++
        }
        if ($current.Count -gt 0) { $previous = $current }
        $stamp = (Get-Date).ToString('HH:mm:ss')
        try { $Host.UI.RawUI.WindowTitle = "Vast-Switch-Log  ·  logs $id  ·  $stamp" } catch { }
        if ($shown -gt 0) { $lastNew = Get-Date; $silentNotice = $false }
        elseif (-not $silentNotice -and ((Get-Date) - $lastNew).TotalSeconds -ge 60) {
            Write-Dim (T "· rien de nouveau depuis 1 min (dernier rafraîchissement $stamp) ·" "· nothing new for 1 min (last refresh $stamp) ·")
            $silentNotice = $true
        }

        # Attente, en guettant la touche Q.
        $deadline = (Get-Date).AddSeconds($LogRefreshSeconds)
        while ((Get-Date) -lt $deadline) {
            if (Test-QuitKey) {
                try { $Host.UI.RawUI.WindowTitle = 'Vast-Switch-Log' } catch { }
                Write-Host ''
                Write-Dim (T 'Retour au menu.' 'Back to the menu.')
                return
            }
            Start-Sleep -Milliseconds 150
        }
    }
}

# === Templates privés ==============================================================

# Tes templates privés, une entrée par nom : Vast.ai crée un nouveau hash à chaque
# enregistrement et garde les anciennes versions, on ne garde que la plus récente.
function Get-Templates {
    $result = Invoke-Vast @('search', 'templates', 'private=True')
    $data = ConvertFrom-VastJson $result.Out
    if ($null -eq $data -and $result.Out.Trim() -ne '[]') {
        throw (T "impossible de lire tes templates ($(Get-VastError $result))" "cannot read your templates ($(Get-VastError $result))")
    }
    $latest = @{}
    foreach ($template in @($data)) {
        if ($null -eq $template -or -not (Get-Prop $template 'hash_id')) { continue }
        $name = [string](Get-Prop $template 'name')
        $created = [double](Get-Prop $template 'created_at')
        if (-not $latest.ContainsKey($name) -or $created -gt [double](Get-Prop $latest[$name] 'created_at')) {
            $latest[$name] = $template
        }
    }
    $list = @($latest.Values | Sort-Object { ([string](Get-Prop $_ 'name')).ToLowerInvariant() })
    return , $list
}

function Get-TemplateImage($Template) {
    $image = [string](Get-Prop $Template 'image')
    $tag = [string](Get-Prop $Template 'tag')
    if ($tag -and $image.Split('/')[-1] -notmatch ':') { $image += ":$tag" }
    return $image
}

# Mode de lancement : seul "Docker ENTRYPOINT" lance le programme prévu par l'image.
function Get-LaunchInfo($Template) {
    $runtype = [string](Get-Prop $Template 'runtype')
    if ($runtype -eq 'args') { return [pscustomobject]@{ Label = 'Docker ENTRYPOINT'; Color = 'Green'; Warning = '' } }
    $warning = T 'ce mode remplace l''ENTRYPOINT de l''image : le mineur ne démarre que si le script de démarrage le lance.' 'this mode replaces the image ENTRYPOINT: the miner only starts if the start-up script launches it.'
    if ($runtype -match '(?i)jupyter') { return [pscustomobject]@{ Label = 'Jupyter'; Color = 'Yellow'; Warning = (T "Mode Jupyter : $warning" "Jupyter mode: $warning") } }
    if ($runtype -match '(?i)ssh') { return [pscustomobject]@{ Label = 'SSH'; Color = 'Yellow'; Warning = (T "Mode SSH : $warning" "SSH mode: $warning") } }
    if (-not $runtype) { $runtype = '?' }
    return [pscustomobject]@{ Label = $runtype; Color = 'Yellow'; Warning = '' }
}

# Variables (-e CLE=VALEUR), ports (-p) et autres options Docker d'un template.
function Get-TemplateOptions($Template) {
    $vars = New-Object System.Collections.ArrayList
    $ports = New-Object System.Collections.Generic.List[string]
    $other = New-Object System.Collections.Generic.List[string]
    $property = $Template.PSObject.Properties['env']
    $env = $null
    if ($property) { $env = $property.Value }

    if ($env -is [string]) {
        # Découpe en mots en respectant les guillemets ("a b" ou 'a b').
        $tokens = @([regex]::Matches($env, '(?:[^\s"'']+|"[^"]*"|''[^'']*'')+') |
            ForEach-Object { $_.Value -replace '"([^"]*)"', '$1' -replace "'([^']*)'", '$1' })
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $token = $tokens[$i]
            $assignment = $null
            if (($token -eq '-e' -or $token -eq '--env') -and $i + 1 -lt $tokens.Count) { $i++; $assignment = $tokens[$i] }
            elseif ($token -like '--env=*') { $assignment = $token.Substring(6) }
            elseif ($token -eq '-p' -and $i + 1 -lt $tokens.Count) { $i++; $ports.Add($tokens[$i]); continue }
            else { $other.Add($token); continue }
            $equal = $assignment.IndexOf('=')
            if ($equal -gt 0) { [void]$vars.Add(@($assignment.Substring(0, $equal), $assignment.Substring($equal + 1))) }
            else { [void]$vars.Add(@($assignment, '')) }
        }
    }
    elseif ($env -is [array]) {
        foreach ($item in $env) {
            if ($item -is [array] -and $item.Count -ge 2) { [void]$vars.Add(@([string]$item[0], [string]$item[1])) }
            elseif ($item -is [string] -and $item.IndexOf('=') -gt 0) {
                [void]$vars.Add(@($item.Substring(0, $item.IndexOf('=')), $item.Substring($item.IndexOf('=') + 1)))
            }
        }
    }
    elseif ($null -ne $env) {
        foreach ($entry in $env.PSObject.Properties) { [void]$vars.Add(@($entry.Name, [string]$entry.Value)) }
    }
    return [pscustomobject]@{ Vars = $vars; Ports = $ports; Other = $other }
}

function Show-Templates($Templates) {
    $columns = @(
        (New-Column (T 'N°' '#') 'R'),
        (New-Column (T 'Nom' 'Name') 'L' 10 40),
        (New-Column 'Image' 'L' 12 40),
        (New-Column (T 'Modifié le' 'Modified on'))
    )
    $rows = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $Templates.Count; $n++) {
        $template = $Templates[$n]
        [void]$rows.Add(@(
            (New-Cell ([string]($n + 1)) $script:AccentColor),
            (New-Cell ([string](Get-Prop $template 'name')) 'White'),
            (Get-TemplateImage $template),
            (Format-Epoch (Get-Prop $template 'created_at'))
        ))
    }
    Write-Host ''
    Write-Table $columns $rows
}

# Cadre avec la configuration complète du template, et les locations concernées.
function Show-TemplateConfig($Template, $Targets) {
    $options = Get-TemplateOptions $Template
    $launch = Get-LaunchInfo $Template
    $onstart = [string](Get-Prop $Template 'onstart')
    $arguments = [string](Get-Prop $Template 'args_str')
    $hash = [string](Get-Prop $Template 'hash_id')

    $keyWidth = 14
    foreach ($var in $options.Vars) { if ($var[0].Length + 2 -gt $keyWidth) { $keyWidth = $var[0].Length + 2 } }
    $keyWidth = [Math]::Min($keyWidth, 30)

    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add((New-KeyValue 'Image' (Get-TemplateImage $Template) $keyWidth))
    [void]$lines.Add((New-KeyValue (T 'Lancement' 'Launch mode') $launch.Label $keyWidth 'DarkGray' $launch.Color))
    [void]$lines.Add((New-KeyValue 'Version' (T "du $(Format-Epoch (Get-Prop $Template 'created_at'))  ·  hash $hash" "from $(Format-Epoch (Get-Prop $Template 'created_at'))  ·  hash $hash") $keyWidth))
    [void]$lines.Add('')
    if ($options.Vars.Count -eq 0) { [void]$lines.Add((New-Cell (T '(aucune variable)' '(no variable)') 'DarkGray')) }
    foreach ($var in $options.Vars) { [void]$lines.Add((New-KeyValue $var[0] $var[1] $keyWidth 'Yellow' 'White')) }
    if ($options.Ports.Count -gt 0) { [void]$lines.Add((New-KeyValue 'Ports' ($options.Ports -join '  ') $keyWidth)) }
    if ($options.Other.Count -gt 0) { [void]$lines.Add((New-KeyValue (T 'Autres options' 'Other options') ($options.Other -join ' ') $keyWidth)) }
    if ($arguments.Trim()) { [void]$lines.Add((New-KeyValue 'Arguments' $arguments.Trim() $keyWidth)) }
    if ($onstart.Trim()) {
        $startup = (@($onstart -split "`r?`n" | Where-Object { $_.Trim() -ne '' }) -join ' ; ')
        [void]$lines.Add((New-KeyValue (T 'Au démarrage' 'On start') (Limit-Text $startup 300) $keyWidth))
    }
    [void]$lines.Add('')
    [void]$lines.Add((New-KeyValue (T 'Locations' 'Rentals') ((@($Targets | ForEach-Object { [string]$_.id })) -join '  ·  ') $keyWidth))
    if ($launch.Warning) { [void]$lines.Add((New-Cell $launch.Warning 'Yellow')) }
    [void]$lines.Add((New-Cell (T 'Les locations vont redémarrer : quelques minutes sans minage. Elles sont conservées.' 'The rentals will restart: a few minutes without mining. They are kept.') 'Yellow'))
    Write-Box "Template  ·  $(Get-Prop $Template 'name')" $lines
}

# === Cartes : prix et offres (search offers) ========================================

# "5090" -> "RTX_5090", "3090 ti" -> "RTX_3090_Ti", "A100 PCIE" -> "A100_PCIE" (le format
# attendu par vastai : les espaces du nom deviennent des tirets bas).
function ConvertTo-GpuQueryName([string]$Text) {
    $clean = $Text.Trim() -replace '\s+', ' '
    if ($clean -match '^(?i)(rtx\s*)?(\d{4})\s*(ti|d|super)?$') {
        $name = "RTX_$($Matches[2])"
        if ($Matches[3]) { $name += '_' + $Matches[3].Substring(0, 1).ToUpperInvariant() + $Matches[3].Substring(1).ToLowerInvariant() }
        return $name
    }
    return ($clean -replace ' ', '_')
}

function Get-MedianValue($Values) {
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2 -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

# Résumé des offres d'une carte : { Count, MinPerGpu, MedianPerGpu, Cheapest } ($null si aucune).
function Get-OfferSummary($Offers) {
    $perGpu = @()
    $cheapest = $null
    $cheapestPrice = $null
    foreach ($offer in @($Offers)) {
        if ($null -eq $offer) { continue }
        $gpus = [double](Get-Prop $offer 'num_gpus')
        $price = Get-Prop $offer 'dph_total'
        if ($gpus -le 0 -or $null -eq $price) { continue }
        $unit = [double]$price / $gpus
        $perGpu += $unit
        if ($null -eq $cheapestPrice -or $unit -lt $cheapestPrice) { $cheapestPrice = $unit; $cheapest = $offer }
    }
    if ($perGpu.Count -eq 0) { return $null }
    return [pscustomobject]@{
        Count        = $perGpu.Count
        MinPerGpu    = ($perGpu | Measure-Object -Minimum).Minimum
        MedianPerGpu = Get-MedianValue $perGpu
        Cheapest     = $cheapest
    }
}

# "8x · US · fiabilité 99,6 % · 950 Mb/s"
function Format-CheapestOffer($Offer) {
    $parts = @("$([int](Get-Prop $Offer 'num_gpus'))x")
    $country = [string](Get-Prop $Offer 'geolocation')
    if ($country) { $parts += $country }
    $reliability = Get-Prop $Offer 'reliability2'
    if ($null -ne $reliability) { $parts += ((T 'fiabilité {0:N1} %' 'reliability {0:N1}%') -f ([double]$reliability * 100)) }
    $down = Get-Prop $Offer 'inet_down'
    if ($null -ne $down) { $parts += ('{0:N0} Mb/s' -f [double]$down) }
    return ($parts -join ' · ')
}

function Invoke-Market {
    Write-Rule (T 'Cartes : prix et offres' 'GPUs: prices and offers')
    Write-Dim (T 'Offres louables maintenant à la demande (on-demand), machines vérifiées ; prix Vast.ai total par carte et par heure (stockage de base compris).' 'Offers rentable now on demand, verified machines; Vast.ai total price per GPU and per hour (base storage included).')
    $answer = Read-Answer (T 'Quelles cartes ? (ex. 5090, 4090, 3090 Ti)' 'Which GPUs? (e.g. 5090, 4090, 3090 Ti)') (T 'Entrée sans rien = 5090, 4090, 3090 ; q = retour.' 'Enter alone = 5090, 4090, 3090; q = back.')
    if (@('q', 'r', 'retour', 'back') -contains $answer.ToLowerInvariant()) { return }
    if ($answer -eq '') { $answer = '5090, 4090, 3090' }
    $names = @($answer -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { ConvertTo-GpuQueryName $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return }

    Write-Step (T 'Recherche des offres … ' 'Searching offers … ')
    $started = Get-Date
    $lists = @(foreach ($name in $names) { , @('search', 'offers', "gpu_name=$name rentable=true verified=true", '--order', 'dph_total', '--limit', '500', '--raw') })
    $results = Invoke-VastMany $lists 4 60
    $took = ('{0:N1} s' -f ((Get-Date) - $started).TotalSeconds)
    $errors = @()
    $rows = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $names.Count; $i++) {
        $label = $names[$i] -replace '_', ' '
        $result = $results[$i]
        $offers = $null
        if ($result.TimedOut) { $errors += (T "$label : pas de réponse à temps" "${label}: no answer in time") }
        else {
            $offers = ConvertFrom-VastJson $result.Out
            if ($null -eq $offers -and $result.Out.Trim() -ne '[]') { $errors += "$label : $(Get-VastError $result)" }
        }
        $summary = Get-OfferSummary $offers
        if ($null -eq $summary) {
            [void]$rows.Add(@((New-Cell ([string]($i + 1)) $script:AccentColor), (New-Cell $label 'White'), (New-Cell '0' 'Red'), '–', '–', (New-Cell (T 'aucune offre louable en ce moment' 'no rentable offer right now') 'DarkGray')))
            continue
        }
        [void]$rows.Add(@(
            (New-Cell ([string]($i + 1)) $script:AccentColor),
            (New-Cell $label 'White'),
            [string]$summary.Count,
            (New-Cell (Format-Price $summary.MinPerGpu 3) 'Green'),
            (Format-Price $summary.MedianPerGpu 3),
            (Format-CheapestOffer $summary.Cheapest)
        ))
    }
    if ($errors.Count -eq 0) { Write-Host "ok ($took)" -ForegroundColor Green }
    else { Write-Host (T "partiel ($took) : $($errors[0])" "partial ($took): $($errors[0])") -ForegroundColor Yellow }
    $columns = @(
        (New-Column (T 'N°' '#') 'R'), (New-Column (T 'Carte' 'GPU') 'L' 8 24), (New-Column (T 'Offres' 'Offers') 'R'),
        (New-Column (T 'Mini $/carte/h' 'Min $/GPU/h') 'R'), (New-Column (T 'Médian $/carte/h' 'Median $/GPU/h') 'R'),
        (New-Column (T 'Offre la moins chère' 'Cheapest offer') 'L' 16 48)
    )
    Write-Host ''
    Write-Table $columns $rows
    Write-Dim (T 'Offre la moins chère : nombre de cartes de la machine, pays, fiabilité et débit descendant. Même recherche que « vastai search offers ».' 'Cheapest offer: number of GPUs on the machine, country, reliability and download speed. Same search as "vastai search offers".')
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
# === Actions sur les locations : suivi commun =======================================

function New-Job([string]$Id) {
    return [pscustomobject]@{
        Id = $Id; Level = 'error'; Done = $false; Result = ''; Started = $false
        Wanted = ''; Before = $null; LastSig = ''; RestartSeen = $false; ActedAt = $null
    }
}

# Mémorise l'état de chaque location juste avant l'action, pour repérer le redémarrage.
function Save-JobState($Jobs) {
    $snapshot = Get-Instances
    foreach ($job in $Jobs) {
        $instance = $snapshot | Where-Object { [string]$_.id -eq $job.Id } | Select-Object -First 1
        $job.Wanted = [string](Get-Prop $instance 'image_uuid')
        $job.Before = [pscustomobject]@{
            Status = [string](Get-Prop $instance 'actual_status')
            Msg    = [string](Get-Prop $instance 'status_msg')
            Uptime = Get-Prop $instance 'uptime_mins'
        }
        $job.LastSig = "$($job.Before.Status)|$($job.Before.Msg)"
    }
}

# Attend que les locations redémarrent. Mode 'recycle' : il faut aussi la bonne image.
function Wait-Jobs($Jobs, [string]$Mode) {
    $waiting = @($Jobs | Where-Object { -not $_.Done })
    if ($waiting.Count -eq 0) { return }
    $poll = $PollSeconds
    $unseen = $script:UnseenRecycleSeconds
    if ($Mode -eq 'reboot') { $poll = $script:RebootPollSeconds; $unseen = $script:UnseenRebootSeconds }

    Write-Rule (T "Attente du redémarrage  ·  vérification toutes les $poll s  ·  $(Format-Duration $TimeoutSeconds) maximum" "Waiting for the restart  ·  checked every $poll s  ·  $(Format-Duration $TimeoutSeconds) at most")
    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $lastBeat = $start
    while (@($Jobs | Where-Object { -not $_.Done }).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $poll
        try { $current = Get-Instances }
        catch { Write-Warn (T "$(Format-Elapsed $start)  Vast.ai ne répond pas, nouvel essai…" "$(Format-Elapsed $start)  Vast.ai is not answering, retrying…"); continue }
        $printed = $false
        foreach ($job in @($Jobs | Where-Object { -not $_.Done })) {
            $instance = $current | Where-Object { [string]$_.id -eq $job.Id } | Select-Object -First 1
            if (-not $instance) {
                $job.Done = $true
                $job.Result = T 'La location n''apparaît plus sur ton compte.' 'The rental no longer appears on your account.'
                continue
            }
            $status = [string](Get-Prop $instance 'actual_status')
            $statusMsg = [string](Get-Prop $instance 'status_msg')
            $uptime = Get-Prop $instance 'uptime_mins'
            $signature = "$status|$statusMsg"
            if ($signature -ne $job.LastSig) {
                $info = Get-StatusInfo $status $statusMsg
                Write-Segment ('  {0,6}  ' -f (Format-Elapsed $start)) 'DarkGray'
                Write-Segment '● ' $info.Color
                Write-Segment $job.Id 'White'
                Write-Segment ('  {0,-10}  ' -f $info.Label) $info.Color
                Write-Host $statusMsg -ForegroundColor DarkGray
                $job.LastSig = $signature
                $printed = $true
            }
            if ($status -ne $job.Before.Status -or $statusMsg -ne $job.Before.Msg) { $job.RestartSeen = $true }
            if ($null -ne $uptime -and $null -ne $job.Before.Uptime -and [double]$uptime -lt [double]$job.Before.Uptime) {
                $job.RestartSeen = $true
            }
            if ($job.RestartSeen -and (Test-StatusError $statusMsg)) {
                $job.Done = $true
                $job.Result = T "Erreur au démarrage : $statusMsg" "Start-up error: $statusMsg"
                continue
            }
            if ($status -ne 'running') { continue }
            $running = Get-RunningImage $statusMsg
            $runningText = $running
            if (-not $runningText) { $runningText = T '(image non indiquée par Vast.ai)' '(image not reported by Vast.ai)' }
            $goodImage = $running -and (Get-NormalizedImage $running) -eq (Get-NormalizedImage $job.Wanted)
            if ($Mode -eq 'recycle' -and -not $goodImage) { continue }
            $sinceAction = ((Get-Date) - $job.ActedAt).TotalSeconds
            if ($job.RestartSeen) {
                $job.Done = $true; $job.Level = 'ok'
                if ($Mode -eq 'reboot') { $job.Result = T "Redémarrée, tourne avec $runningText" "Rebooted, running $runningText" }
                else { $job.Result = T "Tourne avec $runningText" "Running $runningText" }
            }
            elseif ($sinceAction -ge $unseen) {
                $job.Done = $true; $job.Level = 'warn'
                $job.Result = T "Tourne avec $runningText, mais le redémarrage a été trop rapide pour être vu : vérifie les logs." "Running $runningText, but the restart was too quick to be seen: check the logs."
            }
        }
        if (-not $printed -and ((Get-Date) - $lastBeat).TotalSeconds -ge 60) {
            $left = @($Jobs | Where-Object { -not $_.Done }).Count
            if ($left -gt 0) { Write-Dim ((T '{0,6}  … toujours en attente de {1} location(s)' '{0,6}  … still waiting for {1} rental(s)') -f (Format-Elapsed $start), $left) }
            $lastBeat = Get-Date
        }
        elseif ($printed) { $lastBeat = Get-Date }
    }

    # Locations toujours pas prêtes à la fin du délai.
    foreach ($job in @($Jobs | Where-Object { -not $_.Done })) {
        $job.Done = $true
        $status, $statusMsg = ($job.LastSig -split '\|', 2)
        $running = Get-RunningImage $statusMsg
        if ($Mode -eq 'recycle' -and $status -eq 'running' -and $running -and (Get-NormalizedImage $running) -ne (Get-NormalizedImage $job.Wanted)) {
            $job.Level = 'warn'
            $job.Result = T "Tourne encore l'ancienne image ($running) au lieu de $($job.Wanted) : refais un changement de template." "Still running the old image ($running) instead of $($job.Wanted): change the template again."
        }
        else {
            $info = Get-StatusInfo $status $statusMsg
            $job.Result = T "Pas redémarrée au bout de $(Format-Duration $TimeoutSeconds) (état : $($info.Label), $statusMsg)." "Not restarted after $(Format-Duration $TimeoutSeconds) (state: $($info.Label), $statusMsg)."
        }
    }
}

# Logs des locations relancées, puis tableau de résumé.
function Show-JobsReport($Jobs) {
    foreach ($job in $Jobs) { if ($job.Started) { Show-Logs $job.Id } }
    Write-Rule (T 'Résumé' 'Summary')
    Write-Host ''
    $columns = @((New-Column (T 'Location' 'Rental')), (New-Column (T 'Statut' 'Status')), (New-Column (T 'Détail' 'Detail') 'L' 20 80 $true))
    $rows = @(foreach ($job in $Jobs) { , @((New-Cell $job.Id 'White'), (New-Badge $job.Level), $job.Result) })
    Write-Table $columns $rows
}

# === Menu 1 : voir mes locations ===================================================

function Invoke-View {
    Write-Rule (T 'Mes locations' 'My rentals')
    $all = Get-Instances
    if ($all.Count -eq 0) { Write-Warn (T 'Aucune location sur ton compte.' 'No rental on your account.'); return }
    $check = Test-ApiKey
    if ($check.User) { $script:User = $check.User }
    Write-Step (T 'Lecture des logs des locations … ' 'Reading rental logs … ')
    $started = Get-Date
    $hashrates = Get-InstanceHashrates $all
    $took = ('{0:N1} s' -f ((Get-Date) - $started).TotalSeconds)
    if (@($hashrates.Errors).Count -eq 0) { Write-Host "ok ($took)" -ForegroundColor Green }
    else { Write-Host (T "partiel ($took) : $(@($hashrates.Errors)[0])" "partial ($took): $(@($hashrates.Errors)[0])") -ForegroundColor Yellow }
    Show-Instances $all (Get-Prop $check.User 'credit') $hashrates
}

# === Menu 2 : changer le template ==================================================

function Invoke-ChangeTemplate {
    Write-Rule (T 'Changer le template' 'Change the template')
    $all = Get-Instances
    if ($all.Count -eq 0) { Write-Warn (T 'Aucune location sur ton compte.' 'No rental on your account.'); return }
    Show-Instances $all
    $selection = Read-Selection $all.Count (T 'Quelles locations' 'Which rentals') (T 'annuler' 'cancel')
    if ($selection.Count -eq 0) { Write-Dim (T 'Annulé, rien n''a été modifié.' 'Cancelled, nothing was changed.'); return }
    $targets = @(foreach ($n in $selection) { $all[$n] })

    $templates = Get-Templates
    if ($templates.Count -eq 0) {
        Write-Warn (T 'Aucun template privé sur ton compte : crée-en un sur cloud.vast.ai > Templates.' 'No private template on your account: create one on cloud.vast.ai > Templates.')
        return
    }
    Write-Rule (T 'Mes templates privés' 'My private templates')
    Show-Templates $templates

    # Choix du template : sa configuration s'affiche, tu valides ou tu en choisis un autre.
    $template = $null
    while (-not $template) {
        $index = Read-Index $templates.Count (T 'Quel template' 'Which template') (T 'Tape son numéro   ·   Entrée sans rien = annuler' 'Type its number   ·   Enter alone = cancel')
        if ($index -lt 0) { Write-Dim (T 'Annulé, rien n''a été modifié.' 'Cancelled, nothing was changed.'); return }
        Show-TemplateConfig $templates[$index] $targets
        while ($true) {
            $answer = (Read-Answer (T 'On y va ? (o = oui, n = choisir un autre template, Entrée sans rien = annuler)' 'Go ahead? (y = yes, n = pick another template, Enter alone = cancel)')).ToLowerInvariant()
            if (@('o', 'oui', 'y', 'yes') -contains $answer) { $template = $templates[$index]; break }
            if (@('n', 'non', 'no') -contains $answer) { Show-Templates $templates; break }
            if ($answer -eq '') { Write-Dim (T 'Annulé, rien n''a été modifié.' 'Cancelled, nothing was changed.'); return }
        }
    }
    $hash = [string](Get-Prop $template 'hash_id')

    # 1. Mise à jour du template de chaque location.
    $jobs = New-Object System.Collections.ArrayList
    Write-Host ''
    foreach ($target in $targets) {
        $job = New-Job ([string]$target.id)
        [void]$jobs.Add($job)
        Write-Step (T "Location $($job.Id)  ·  changement de template … " "Rental $($job.Id)  ·  template change … ")
        $result = Invoke-Vast @('update', 'instance', $job.Id, '--template_hash_id', $hash, '--raw')
        $answer = ConvertFrom-VastJson $result.Out
        if ($answer -and (Get-Prop $answer 'success') -eq $true) {
            Write-Host 'OK' -ForegroundColor Green
            continue
        }
        $message = Get-Prop $answer 'msg'
        if (-not $message) { $message = Get-VastError $result }
        Write-Host (T "refusé ($message)" "refused ($message)") -ForegroundColor Red
        $job.Done = $true
        $job.Result = T "Changement de template refusé : $message" "Template change refused: $message"
    }

    # 2. Recycle : recrée le conteneur avec la configuration du template.
    $pending = @($jobs | Where-Object { -not $_.Done })
    if ($pending.Count -gt 0) {
        Save-JobState $pending
        foreach ($job in $pending) {
            Write-Step (T "Location $($job.Id)  ·  redémarrage (recycle) vers $($job.Wanted) … " "Rental $($job.Id)  ·  restart (recycle) to $($job.Wanted) … ")
            $result = Invoke-Vast @('recycle', 'instance', $job.Id)
            if ($result.Out -match 'Recycling instance') {
                Write-Host 'OK' -ForegroundColor Green
                $job.ActedAt = Get-Date
                $job.Started = $true
            }
            else {
                $message = Get-VastError $result
                Write-Host (T "refusé ($message)" "refused ($message)") -ForegroundColor Red
                $job.Done = $true
                $job.Result = T "Template changé, mais recycle refusé : $message" "Template changed, but recycle refused: $message"
            }
        }
    }

    Wait-Jobs $jobs 'recycle'
    Show-JobsReport $jobs
}

# === Menu 3 : redémarrer (reboot) ==================================================

function Invoke-Reboot {
    Write-Rule (T 'Redémarrer (reboot)' 'Reboot')
    $all = Get-Instances
    if ($all.Count -eq 0) { Write-Warn (T 'Aucune location sur ton compte.' 'No rental on your account.'); return }
    Show-Instances $all
    $selection = Read-Selection $all.Count (T 'Quelles locations redémarrer' 'Which rentals to reboot') (T 'annuler' 'cancel')
    if ($selection.Count -eq 0) { Write-Dim (T 'Annulé, rien n''a été modifié.' 'Cancelled, nothing was changed.'); return }
    $targets = @(foreach ($n in $selection) { $all[$n] })

    $lines = New-Object System.Collections.ArrayList
    $label = T 'Locations' 'Rentals'
    foreach ($target in $targets) {
        [void]$lines.Add((New-KeyValue $label "$($target.id)  ·  $(Get-GpuText $target)  ·  $(Format-Price (Get-Prop $target 'dph_total'))/h" 12))
        $label = ''
    }
    [void]$lines.Add('')
    [void]$lines.Add((T 'Le conteneur est arrêté puis relancé : le template et l''image ne changent pas.' 'The container is stopped then started again: template and image do not change.'))
    [void]$lines.Add((New-Cell (T 'Quelques secondes à une minute sans minage. Les locations sont conservées.' 'A few seconds to a minute without mining. The rentals are kept.') 'Yellow'))
    Write-Box (T 'Redémarrage' 'Reboot') $lines
    if (-not (Confirm-Action (T 'On y va ?' 'Go ahead?'))) { Write-Dim (T 'Annulé, rien n''a été modifié.' 'Cancelled, nothing was changed.'); return }

    $jobs = New-Object System.Collections.ArrayList
    foreach ($target in $targets) { [void]$jobs.Add((New-Job ([string]$target.id))) }
    Save-JobState $jobs
    Write-Host ''
    foreach ($job in $jobs) {
        Write-Step (T "Location $($job.Id)  ·  redémarrage (reboot) … " "Rental $($job.Id)  ·  reboot … ")
        $result = Invoke-Vast @('reboot', 'instance', $job.Id)
        if ($result.Out -match 'Rebooting instance') {
            Write-Host 'OK' -ForegroundColor Green
            $job.ActedAt = Get-Date
            $job.Started = $true
        }
        else {
            $message = Get-VastError $result
            Write-Host (T "refusé ($message)" "refused ($message)") -ForegroundColor Red
            $job.Done = $true
            $job.Result = T "Reboot refusé : $message" "Reboot refused: $message"
        }
    }

    Wait-Jobs $jobs 'reboot'
    Show-JobsReport $jobs
}

# === Programme principal ===========================================================

function Main {
    try { $Host.UI.RawUI.WindowTitle = 'Vast-Switch-Log' } catch { }
    Write-Banner

    $script:VastExe = Find-VastExe
    if (-not $script:VastExe) {
        Write-Warn (T 'Je ne trouve pas vastai (l''outil en ligne de commande de Vast.ai) sur ce PC.' 'vastai (the Vast.ai command-line tool) was not found on this computer.')
        if ((Confirm-Action (T 'L''installer maintenant ?' 'Install it now?')) -and (Install-Vast)) { $script:VastExe = Find-VastExe }
        if (-not $script:VastExe) {
            if ($script:Os -eq 'windows') { Write-Bad (T 'vastai est introuvable. Installe-le avec : pip install vastai' 'vastai is missing. Install it with: pip install vastai') }
            else { Write-Bad (T 'vastai est introuvable. Installe-le avec : python3 -m pip install --user vastai' 'vastai is missing. Install it with: python3 -m pip install --user vastai') }
            $script:ExitCode = 1
            return
        }
    }

    $user = Initialize-ApiKey
    if (-not $user) {
        Write-Bad (T 'Sans clé API valide, je ne peux rien faire.' 'Without a valid API key, nothing can be done.')
        $script:ExitCode = 1
        return
    }
    $script:User = $user
    Write-Host ''
    Write-AccountLine (T 'Connecté à Vast.ai' 'Connected to Vast.ai') $user
    Write-Dim "vastai : $($script:VastExe)"

    while ($true) {
        $account = Get-Prop $script:User 'email'
        $title = 'Menu'
        if ($account) { $title = "Menu  ·  $account" }
        Write-Box $title @(
            @((New-Cell '1   ' 'Yellow'), (T 'Voir mes locations (hashrate, prix, crédit, autonomie)' 'View my rentals (hashrate, price, credit, remaining time)')),
            @((New-Cell '2   ' 'Yellow'), (T 'Changer le template' 'Change the template')),
            @((New-Cell '3   ' 'Yellow'), (T 'Redémarrer (reboot)' 'Reboot')),
            @((New-Cell '4   ' 'Yellow'), (T 'Logs en direct' 'Live logs')),
            @((New-Cell '5   ' 'Yellow'), (T 'Clés API Vast.ai (basculer, ajouter, retirer)' 'Vast.ai API keys (switch, add, remove)')),
            @((New-Cell '6   ' 'Yellow'), (T 'Cartes : prix et offres (search offers)' 'GPUs: prices and offers (search offers)')),
            @((New-Cell 'P   ' 'Yellow'), (T 'Pool : mon portefeuille HeroMiners / unMineable (hashrate vu par la pool, gains réels)' 'Pool: my HeroMiners / unMineable wallet (hashrate seen by the pool, real earnings)')),
            @((New-Cell '7   ' 'Yellow'), (T 'Quitter' 'Quit'))
        )
        $choice = (Read-Answer (T 'Ton choix' 'Your choice')).ToLowerInvariant()
        try {
            if ($choice -eq '1') { Invoke-View }
            elseif ($choice -eq '2') { Invoke-ChangeTemplate }
            elseif ($choice -eq '3') { Invoke-Reboot }
            elseif ($choice -eq '4') { Invoke-LiveLogs }
            elseif ($choice -eq '5') { Invoke-ApiKeys }
            elseif ($choice -eq '6') { Invoke-Market }
            elseif (@('p', 'pool', 'wallet', 'portefeuille') -contains $choice) { Invoke-PoolMenu }
            elseif (@('7', 'q', 'quit', 'quitter') -contains $choice) { return }
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
