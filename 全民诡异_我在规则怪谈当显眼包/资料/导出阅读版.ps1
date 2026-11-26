param([string]$ReportPath = (Join-Path $PSScriptRoot '字数核验.json'))

$ErrorActionPreference = 'Stop'
$novelRoot = Split-Path -Parent $PSScriptRoot
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
if ($report.structuralStatus -ne 'verified') { throw 'Verify the manuscript before exporting.' }
$volumeNames = @([regex]::Matches([IO.File]::ReadAllText((Join-Path $novelRoot '总纲.md')), '(?m)^## 第[^\r\n]+卷 ([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value })
$builder = [Text.StringBuilder]::new()
[void]$builder.AppendLine('全民诡异：我在规则怪谈当显眼包')
[void]$builder.AppendLine('靠热梗把 BOSS 整破防了')
[void]$builder.AppendLine(('第001—{0:D3}章正式阅读版' -f [int]$report.completedChapters))
$han = 0
$nonWhitespace = 0
$chapters = @($report.chapterCounts | Sort-Object chapter)
foreach ($chapter in $chapters) {
    $volumeIndex = [int][Math]::Ceiling($chapter.chapter / 30.0) - 1
    if ($volumeIndex -ge $volumeNames.Count) { throw 'Missing volume title.' }
    if (($chapter.chapter - 1) % 30 -eq 0) {
        [void]$builder.AppendLine()
        [void]$builder.AppendLine(('第{0}卷 {1}' -f ($volumeIndex + 1), $volumeNames[$volumeIndex]))
    }
    $path = Join-Path (Join-Path $novelRoot '正文') $chapter.file
    $source = [IO.File]::ReadAllText($path)
    $pattern = '(?ms)^## 第' + ('{0:D3}' -f $chapter.chapter) + '章 [^\r\n]+\r?\n(.*?)(?=^## 第\d{3}章 |\z)'
    $match = [regex]::Match($source, $pattern)
    if (-not $match.Success) { throw "Missing chapter $($chapter.chapter)." }
    $body = $match.Groups[1].Value.Trim()
    $chapterHan = [regex]::Matches($body, '[\u4e00-\u9fff]').Count
    $chapterNonWhitespace = [regex]::Replace($body, '\s', '').Length
    if ($chapterHan -ne $chapter.han -or $chapterNonWhitespace -ne $chapter.nonWhitespace) {
        throw "Chapter changed since verification: $($chapter.chapter)."
    }
    $han += $chapterHan
    $nonWhitespace += $chapterNonWhitespace
    [void]$builder.AppendLine()
    [void]$builder.AppendLine(('第{0:D3}章 {1}' -f $chapter.chapter, $chapter.title))
    [void]$builder.AppendLine()
    [void]$builder.AppendLine($body)
}
if ($chapters.Count -ne $report.completedChapters -or $han -ne $report.totalHan -or $nonWhitespace -ne $report.totalNonWhitespace) {
    throw 'Reading export totals do not match the verified manuscript.'
}
$outputPath = Join-Path $novelRoot ('全民诡异_第001-{0:D3}章_阅读版.txt' -f [int]$report.completedChapters)
[IO.File]::WriteAllText($outputPath, $builder.ToString(), [Text.UTF8Encoding]::new($true))
$readback = [IO.File]::ReadAllText($outputPath)
if ($readback -cne $builder.ToString() -or [regex]::Matches($readback, '(?m)^第\d{3}章 ').Count -ne $chapters.Count) {
    throw 'Reading export readback mismatch.'
}
[pscustomobject]@{path=$outputPath;chapters=$chapters.Count;bodyHan=$han;bodyNonWhitespace=$nonWhitespace;bytes=(Get-Item -LiteralPath $outputPath).Length} | ConvertTo-Json
