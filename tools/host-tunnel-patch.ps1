<#
.SYNOPSIS
    Патч экрана загрузки хоста для MapSingularity: тоннель со звёздами вместо
    стандартной страницы GMod — только во время прыжка через портал.

.DESCRIPTION
    Хосту (одиночная игра, хост listen-сервера) меню GMod всегда показывает
    garrysmod\html\loading.html и игнорирует sv_loadingurl. Патч кладёт рядом
    web\ms_tunnel.js и добавляет в loading.html одну строку. Аддон на время прыжка
    ставит в hostname невидимую метку, и только тогда страница показывает тоннель.
    Обычные загрузки карт выглядят как раньше.

    Это изменение файлов самой игры, а не аддона: работает только на этом ПК.
    Обновление GMod или проверка целостности файлов в Steam вернёт оригинал —
    тогда просто запустите install ещё раз.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\host-tunnel-patch.ps1 install
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\host-tunnel-patch.ps1 uninstall
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\host-tunnel-patch.ps1 status -GarrysModDir 'D:\SteamLibrary\steamapps\common\GarrysMod\garrysmod'
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'uninstall', 'status')]
    [string]$Action = 'status',

    [string]$GarrysModDir = 'C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod'
)

$ErrorActionPreference = 'Stop'

$Tag = '<script src="ms_tunnel.js" data-ms-host></script>'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

$htmlDir = Join-Path $GarrysModDir 'html'
$page = Join-Path $htmlDir 'loading.html'
$backup = "$page.ms-backup"
$jsTarget = Join-Path $htmlDir 'ms_tunnel.js'
$webDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'web'
# Файлы, которые патч кладёт рядом с loading.html.
$PatchFiles = @('ms_tunnel.js', 'ms_prime.html')

if (-not (Test-Path -LiteralPath $page)) {
    throw "Не найден $page. Укажите папку игры: -GarrysModDir '...\GarrysMod\garrysmod'"
}

$text = [System.IO.File]::ReadAllText($page)
$newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
$hasTag = $text.Contains($Tag)
$hasJs = Test-Path -LiteralPath $jsTarget

switch ($Action) {
    'status' {
        Write-Host "loading.html: $page"
        Write-Host ("  строка патча:  " + $(if ($hasTag) { 'есть' } else { 'нет' }))
        foreach ($name in $PatchFiles) {
            Write-Host ("  ${name}:  " + $(if (Test-Path -LiteralPath (Join-Path $htmlDir $name)) { 'есть' } else { 'нет' }))
        }
        Write-Host ("  резервная копия: " + $(if (Test-Path -LiteralPath $backup) { $backup } else { 'нет' }))
        if ($hasTag -and $hasJs) { Write-Host 'Патч установлен.' } else { Write-Host 'Патч не установлен.' }
    }

    'install' {
        foreach ($name in $PatchFiles) {
            $src = Join-Path $webDir $name
            if (-not (Test-Path -LiteralPath $src)) { throw "Не найден $src" }
            Copy-Item -LiteralPath $src -Destination (Join-Path $htmlDir $name) -Force
        }

        if ($hasTag) {
            Write-Host ('Строка уже есть в loading.html — обновлены файлы: ' + ($PatchFiles -join ', ') + '.')
            break
        }

        $idx = $text.LastIndexOf('</body>')
        if ($idx -lt 0) { throw 'В loading.html нет </body> — формат страницы изменился, патч не применён.' }

        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $page -Destination $backup }

        # Строго в конце <body>: после встроенного скрипта страницы, чтобы
        # перехватить уже объявленную функцию GameDetails. Отдельной строкой с тем же
        # отступом, что у </body>, — uninstall вернёт файл байт в байт.
        $lineStart = $text.LastIndexOf("`n", $idx) + 1
        $indent = $text.Substring($lineStart, $idx - $lineStart)
        if ($indent.Trim().Length -ne 0) { $indent = '' ; $lineStart = $idx }
        $patched = $text.Insert($lineStart, "$indent$Tag$newline")
        [System.IO.File]::WriteAllText($page, $patched, $Utf8NoBom)

        Write-Host 'Готово. Перезапустите GMod: при прыжке через портал вместо стандартного'
        Write-Host 'экрана загрузки будет тоннель. Проверка в игре: ms_status -> "патч тоннеля у хоста: установлен".'
    }

    'uninstall' {
        if ($hasTag) {
            $lines = $text -split "\r?\n" | Where-Object { $_.Trim() -ne $Tag }
            [System.IO.File]::WriteAllText($page, ($lines -join $newline), $Utf8NoBom)
        }
        foreach ($name in $PatchFiles) {
            $target = Join-Path $htmlDir $name
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        Write-Host 'Патч удалён, loading.html в исходном виде.'
    }
}
