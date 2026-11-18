<#
    MapSingularity — экран загрузки для хоста (тоннель со звёздами при прыжке через портал).
    MapSingularity — host loading screen (a star tunnel while jumping through the portal).

    Хосту (одиночная игра, хост listen-сервера) GMod всегда показывает свою страницу загрузки
    garrysmod\html\loading.html. Скрипт кладёт рядом два файла и добавляет в страницу одну строку;
    тоннель включается только во время прыжка, обычные загрузки не меняются.
    Обновление GMod / проверка целостности файлов в Steam вернёт оригинал — запустите install снова.

    install.bat / uninstall.bat / status.bat — двойной щелчок. Или:
    powershell -ExecutionPolicy Bypass -File MapSingularity-HostLoadingScreen.ps1 install [-GarrysModDir "...\GarrysMod\garrysmod"]

    Собран tools/build_host_installer.py — файлы тоннеля встроены ниже (base64).
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status')]
    [string]$Action = 'status',
    [string]$GarrysModDir = '',
    [switch]$Pause
)

$ErrorActionPreference = 'Stop'

$Tag = '<script src="ms_tunnel.js" data-ms-host></script>'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$Files = @{
    'ms_tunnel.js'  = '@@TUNNEL_B64@@'
    'ms_prime.html' = '@@PRIME_B64@@'
}

$Lang = (Get-Culture).TwoLetterISOLanguageName
if ($Lang -ne 'uk' -and $Lang -ne 'ru') { $Lang = 'en' }
$Msg = @{
    uk = @{
        notfound  = "Не знайдено Garry's Mod. Вкажіть папку: -GarrysModDir '...\GarrysMod\garrysmod'"
        found     = "Garry's Mod: {0}"
        badpage   = 'У loading.html немає </body> — сторінку змінено, патч не застосовано.'
        installed = 'Готово. Перезапустіть GMod: під час стрибка через портал замість стандартного екрана буде тунель.'
        updated   = 'Патч уже стояв — файли тунелю оновлено.'
        removed   = 'Патч видалено, loading.html у початковому вигляді.'
        on        = 'Патч встановлено.'
        off       = 'Патч не встановлено.'
        elevate   = 'Потрібні права адміністратора — Windows зараз запитає дозвіл.'
        line      = '  рядок у loading.html: {0}'
        file      = '  {0}: {1}'
        yes = 'є'; no = 'немає'
        press     = 'Натисніть Enter, щоб закрити'
    }
    ru = @{
        notfound  = "Не найден Garry's Mod. Укажите папку: -GarrysModDir '...\GarrysMod\garrysmod'"
        found     = "Garry's Mod: {0}"
        badpage   = 'В loading.html нет </body> — страница изменилась, патч не применён.'
        installed = 'Готово. Перезапустите GMod: при прыжке через портал вместо стандартного экрана будет тоннель.'
        updated   = 'Патч уже стоял — файлы тоннеля обновлены.'
        removed   = 'Патч удалён, loading.html в исходном виде.'
        on        = 'Патч установлен.'
        off       = 'Патч не установлен.'
        elevate   = 'Нужны права администратора — сейчас появится запрос Windows.'
        line      = '  строка в loading.html: {0}'
        file      = '  {0}: {1}'
        yes = 'есть'; no = 'нет'
        press     = 'Нажмите Enter, чтобы закрыть'
    }
    en = @{
        notfound  = "Garry's Mod not found. Specify the folder: -GarrysModDir '...\GarrysMod\garrysmod'"
        found     = "Garry's Mod: {0}"
        badpage   = 'loading.html has no </body> — the page changed, the patch was not applied.'
        installed = 'Done. Restart GMod: jumping through a portal now shows the tunnel instead of the default screen.'
        updated   = 'The patch was already there — tunnel files updated.'
        removed   = 'The patch is removed, loading.html is back to the original.'
        on        = 'The patch is installed.'
        off       = 'The patch is not installed.'
        elevate   = 'Administrator rights are needed — Windows will ask now.'
        line      = '  line in loading.html: {0}'
        file      = '  {0}: {1}'
        yes = 'yes'; no = 'no'
        press     = 'Press Enter to close'
    }
}[$Lang]

function Done([int]$code) {
    if ($Pause) { [void](Read-Host $Msg.press) }
    exit $code
}

# Папка garrysmod: реестр Steam -> все библиотеки из libraryfolders.vdf -> стандартный путь.
function Find-GarrysMod {
    $roots = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $p = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            if ($p.SteamPath) { $roots += $p.SteamPath }
            if ($p.InstallPath) { $roots += $p.InstallPath }
        } catch { }
    }
    $roots += (Join-Path ${env:ProgramFiles(x86)} 'Steam')
    $libs = @()
    foreach ($r in ($roots | Select-Object -Unique)) {
        $libs += $r
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($vdf), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($l in ($libs | Select-Object -Unique)) {
        $g = Join-Path $l 'steamapps\common\GarrysMod\garrysmod'
        if (Test-Path -LiteralPath (Join-Path $g 'html\loading.html')) { return (Resolve-Path -LiteralPath $g).Path }
    }
    return $null
}

if (-not $GarrysModDir) { $GarrysModDir = Find-GarrysMod }
if (-not $GarrysModDir -or -not (Test-Path -LiteralPath (Join-Path $GarrysModDir 'html\loading.html'))) {
    Write-Host $Msg.notfound -ForegroundColor Red
    Done 1
}
Write-Host ($Msg.found -f $GarrysModDir)

$htmlDir = Join-Path $GarrysModDir 'html'
$page = Join-Path $htmlDir 'loading.html'
$backup = "$page.ms-backup"

# Нет прав на запись (игра в Program Files) — перезапуск с правами администратора.
if ($Action -ne 'status') {
    $probe = Join-Path $htmlDir ('.ms-write-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force
    } catch {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($admin) { throw }
        Write-Host $Msg.elevate -ForegroundColor Yellow
        $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Action -GarrysModDir `"$GarrysModDir`" -Pause"
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        exit 0
    }
}

$text = [System.IO.File]::ReadAllText($page)
$newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$hasTag = $text.Contains($Tag)

switch ($Action) {
    'status' {
        Write-Host ($Msg.line -f $(if ($hasTag) { $Msg.yes } else { $Msg.no }))
        $all = $hasTag
        foreach ($name in $Files.Keys) {
            $there = Test-Path -LiteralPath (Join-Path $htmlDir $name)
            $all = $all -and $there
            Write-Host ($Msg.file -f $name, $(if ($there) { $Msg.yes } else { $Msg.no }))
        }
        if ($all) { Write-Host $Msg.on -ForegroundColor Green } else { Write-Host $Msg.off }
    }

    'install' {
        foreach ($name in $Files.Keys) {
            [System.IO.File]::WriteAllBytes((Join-Path $htmlDir $name), [Convert]::FromBase64String($Files[$name]))
        }
        if ($hasTag) {
            Write-Host $Msg.updated -ForegroundColor Green
            break
        }
        $idx = $text.LastIndexOf('</body>')
        if ($idx -lt 0) { Write-Host $Msg.badpage -ForegroundColor Red; Done 1 }
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $page -Destination $backup }

        # Строго в конце <body> (после встроенного скрипта страницы, чтобы перехватить GameDetails),
        # отдельной строкой с отступом </body> — uninstall вернёт файл байт в байт.
        $lineStart = $text.LastIndexOf("`n", $idx) + 1
        $indent = $text.Substring($lineStart, $idx - $lineStart)
        if ($indent.Trim().Length -ne 0) { $indent = ''; $lineStart = $idx }
        [System.IO.File]::WriteAllText($page, $text.Insert($lineStart, "$indent$Tag$newline"), $Utf8NoBom)
        Write-Host $Msg.installed -ForegroundColor Green
    }

    'uninstall' {
        if ($hasTag) {
            $lines = $text -split "\r?\n" | Where-Object { $_.Trim() -ne $Tag }
            [System.IO.File]::WriteAllText($page, ($lines -join $newline), $Utf8NoBom)
        }
        foreach ($name in $Files.Keys) {
            $target = Join-Path $htmlDir $name
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        Write-Host $Msg.removed -ForegroundColor Green
    }
}
Done 0
