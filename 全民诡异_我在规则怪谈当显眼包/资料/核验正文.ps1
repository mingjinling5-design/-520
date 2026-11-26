param(
    [int]$ExpectedLastChapter = 0,
    [int]$NewStart = 61,
    [int]$MinNewHan = 2800,
    [int]$MaxNewHan = 3100,
    [switch]$WriteReport
)

$ErrorActionPreference = 'Stop'
$novelRoot = Split-Path -Parent $PSScriptRoot
$bodyDirectory = Join-Path $novelRoot '正文'
$finalVolumeDirectories = @(Get-ChildItem -LiteralPath $bodyDirectory -Directory | Where-Object Name -match '^第.+卷_')
$finalVolumeFiles = @($finalVolumeDirectories | ForEach-Object {
    Get-ChildItem -LiteralPath $_.FullName -Filter '*.md'
})
$finalVolumeNames = @{}
foreach ($finalVolumeFile in $finalVolumeFiles) {
    if ($finalVolumeNames.ContainsKey($finalVolumeFile.Name)) {
        throw "Duplicate filename in final volume folders: $($finalVolumeFile.Name)"
    }
    $finalVolumeNames[$finalVolumeFile.Name] = $true
}
$files = @(@(Get-ChildItem -LiteralPath $bodyDirectory -Filter '*.md' | Where-Object {
    -not $finalVolumeNames.ContainsKey($_.Name)
}) + $finalVolumeFiles | Sort-Object Name)
$rows = @()
$fileChecks = @()
$utf8 = [Text.UTF8Encoding]::new($false)

foreach ($file in $files) {
    $source = [IO.File]::ReadAllText($file.FullName)
    if ($source.Contains([char]0xFFFD)) {
        throw "Encoding replacement character: $($file.Name)"
    }
    $matches = [regex]::Matches($source, '(?ms)^## 第(\d{3})章 ([^\r\n]+)\r?\n(.*?)(?=^## 第\d{3}章 |\z)')
    foreach ($match in $matches) {
        $body = $match.Groups[3].Value
        $rows += [pscustomobject]@{
            chapter = [int]$match.Groups[1].Value
            title = $match.Groups[2].Value
            han = [regex]::Matches($body, '[\u4e00-\u9fff]').Count
            nonWhitespace = [regex]::Replace($body, '\s', '').Length
            file = [IO.Path]::GetRelativePath($bodyDirectory, $file.FullName)
        }
    }
    $semantic = [regex]::Replace($source, '\s', '')
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        $semanticHash = [Convert]::ToHexString($hasher.ComputeHash($utf8.GetBytes($semantic)))
    } finally {
        $hasher.Dispose()
    }
    $fileChecks += [pscustomobject]@{
        file = [IO.Path]::GetRelativePath($bodyDirectory, $file.FullName)
        chapterCount = $matches.Count
        semanticSha256 = $semanticHash
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        paragraphBreaks = [regex]::Matches($source, '\r?\n\r?\n').Count
    }
}

$rows = @($rows | Sort-Object chapter)
if ($rows.Count -eq 0) { throw 'No chapter bodies found.' }
$duplicateNumbers = @($rows | Group-Object chapter | Where-Object Count -gt 1)
if ($duplicateNumbers.Count -gt 0) { throw 'Duplicate chapter numbers.' }
$lastChapter = ($rows | Select-Object -Last 1).chapter
$missing = @(Compare-Object (1..$lastChapter) @($rows | ForEach-Object chapter))
if ($ExpectedLastChapter -gt 0 -and $missing.Count -gt 0) { throw 'Chapter numbers are not continuous from 001.' }
if ($ExpectedLastChapter -gt 0 -and $lastChapter -ne $ExpectedLastChapter) {
    throw "Expected last chapter $ExpectedLastChapter, found $lastChapter."
}

$outline = [IO.File]::ReadAllText((Join-Path $novelRoot '总纲.md'))
$titles = @{}
foreach ($match in [regex]::Matches($outline, '(?m)^(\d{1,3})\. ([^：\r\n]+)：')) {
    $titles[[int]$match.Groups[1].Value] = $match.Groups[2].Value
}
$newRows = @($rows | Where-Object chapter -ge $NewStart)
$shortOrLong = @($newRows | Where-Object { $_.han -lt $MinNewHan -or $_.han -gt $MaxNewHan })
$titleMismatches = @($newRows | Where-Object {
    $titles.ContainsKey($_.chapter) -and
    ([regex]::Replace($_.title, '\s', '') -cne [regex]::Replace($titles[$_.chapter], '\s', ''))
})
if ($ExpectedLastChapter -gt 0 -and ($shortOrLong.Count -gt 0 -or $titleMismatches.Count -gt 0)) {
    $shortOrLong | Format-Table chapter,title,han | Out-String | Write-Output
    $titleMismatches | Format-Table chapter,title | Out-String | Write-Output
    throw 'New chapter length/title verification failed.'
}

$volumeCounts = @($rows | Group-Object { [int][Math]::Ceiling($_.chapter / 30.0) } | ForEach-Object {
    [pscustomobject]@{
        volume = [int]$_.Name
        chapters = $_.Count
        han = [int](($_.Group | Measure-Object han -Sum).Sum)
        nonWhitespace = [int](($_.Group | Measure-Object nonWhitespace -Sum).Sum)
    }
})
$report = [ordered]@{
    checkedAt = [DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss zzz')
    timezone = 'Asia/Shanghai'
    countingRule = 'Chapter bodies only. Han U+4E00-U+9FFF and non-whitespace characters counted separately. Headings, outline, notes, scripts and backups excluded.'
    completedChapters = $lastChapter
    structuralStatus = $(if ($missing.Count -eq 0 -and $shortOrLong.Count -eq 0 -and $titleMismatches.Count -eq 0) { 'verified' } else { 'draft' })
    nextChapter = $lastChapter + 1
    nextTitle = $titles[$lastChapter + 1]
    totalHan = [int](($rows | Measure-Object han -Sum).Sum)
    totalNonWhitespace = [int](($rows | Measure-Object nonWhitespace -Sum).Sum)
    newStart = $NewStart
    newChapters = $newRows.Count
    newHan = [int](($newRows | Measure-Object han -Sum).Sum)
    newNonWhitespace = [int](($newRows | Measure-Object nonWhitespace -Sum).Sum)
    novelTargetHan = 1000000
    goalStatus = 'active'
    chapterCounts = $rows
    volumeCounts = $volumeCounts
    fileChecks = $fileChecks
    lengthIssues = $shortOrLong
    titleIssues = $titleMismatches
    missingNumbers = @($missing | ForEach-Object InputObject)
}
if ($WriteReport) {
    if ($ExpectedLastChapter -le 0) { throw 'Specify ExpectedLastChapter before writing an authoritative report.' }
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot '字数核验.json'), ($report | ConvertTo-Json -Depth 7), $utf8)
}
[pscustomobject]@{
    chapters = $rows.Count
    lastChapterFound = $lastChapter
    totalHan = $report.totalHan
    totalNonWhitespace = $report.totalNonWhitespace
    newChapters = $newRows.Count
    newHan = $report.newHan
    lengthIssues = $shortOrLong
    titleIssues = $titleMismatches
    missingNumbers = @($missing | ForEach-Object InputObject)
    nextChapter = $report.nextChapter
    nextTitle = $report.nextTitle
    volumes = $volumeCounts
    reportWritten = [bool]$WriteReport
} | ConvertTo-Json -Depth 6
