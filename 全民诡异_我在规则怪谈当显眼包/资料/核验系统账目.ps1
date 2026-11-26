param(
    [Parameter(Mandatory=$true)][string]$ContractPath,
    [switch]$WriteReport
)

$ErrorActionPreference = 'Stop'
$novelRoot = Split-Path -Parent $PSScriptRoot
$contractSource = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ContractPath).Path)
$expectedRows = @([regex]::Matches($contractSource, '(?m)^(\d{3})《([^》]+)》(?:\+)?(\d+)/(?:-)?(\d+)：') | ForEach-Object {
    [pscustomobject]@{chapter=[int]$_.Groups[1].Value;title=$_.Groups[2].Value;income=[int]$_.Groups[3].Value;spend=[int]$_.Groups[4].Value}
})
if ($expectedRows.Count -ne 30) { throw 'The volume contract must define 30 chapter ledger rows.' }
$countReport = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '字数核验.json') | ConvertFrom-Json
if ($countReport.structuralStatus -ne 'verified') { throw 'Verify chapter structure before checking the ledger.' }

function Convert-LedgerNumber([string]$numberText) {
    if ($numberText -match '^\d+$') { return [int]$numberText }
    $digits = @{'零'=0;'一'=1;'二'=2;'三'=3;'四'=4;'五'=5;'六'=6;'七'=7;'八'=8;'九'=9;'两'=2}
    if ($digits.ContainsKey($numberText)) { return $digits[$numberText] }
    $parts = $numberText.Split('十')
    if ($parts.Count -eq 2) {
        $tens = if ($parts[0]) { $digits[$parts[0]] } else { 1 }
        $units = if ($parts[1]) { $digits[$parts[1]] } else { 0 }
        if ($null -ne $tens -and $null -ne $units) { return 10 * $tens + $units }
    }
    throw "Unrecognized ledger number: $numberText"
}

$ledger = @()
$paragraphs = @()
$writingTraceCandidates = @()
$sourceCache = @{}
foreach ($expected in $expectedRows) {
    $chapterRows = @($countReport.chapterCounts | Where-Object chapter -eq $expected.chapter)
    if ($chapterRows.Count -ne 1) { throw "Expected one formal chapter $($expected.chapter)." }
    $chapter = $chapterRows[0]
    if (-not $sourceCache.ContainsKey($chapter.file)) {
        $sourceCache[$chapter.file] = [IO.File]::ReadAllText((Join-Path (Join-Path $novelRoot '正文') $chapter.file))
    }
    $match = [regex]::Match($sourceCache[$chapter.file], '(?ms)^## 第' + ('{0:D3}' -f $chapter.chapter) + '章 [^\r\n]+\r?\n(.*?)(?=^## 第\d{3}章 |\z)')
    if (-not $match.Success) { throw "Missing body for chapter $($chapter.chapter)." }
    $body = $match.Groups[1].Value
    $systemText = ([regex]::Matches($body, '【[^】]*】') | ForEach-Object Value) -join "`n"
    $income = 0
    $spend = 0
    foreach ($item in [regex]::Matches($systemText, '(?:获得破防值|破防值增加|破防值[＋+])[：:\s]*([零一二三四五六七八九十两0-9]+)')) {
        $income += Convert-LedgerNumber $item.Groups[1].Value
    }
    foreach ($item in [regex]::Matches($systemText, '(?:(?:消耗|支出|扣除)(?:破防值)?|破防值[－-])[：:\s]*([零一二三四五六七八九十两0-9]+)')) {
        $spend += Convert-LedgerNumber $item.Groups[1].Value
    }
    $ledger += [pscustomobject]@{
        chapter=$chapter.chapter; income=$income; spend=$spend
        expectedIncome=$expected.income; expectedSpend=$expected.spend
        matches=($income -eq $expected.income -and $spend -eq $expected.spend)
    }
    foreach ($item in [regex]::Matches($body, '第[〇一二三四五六七八九十百零两0-9]{1,8}章|总纲|本合同|此处省略|略写')) {
        $writingTraceCandidates += [pscustomobject]@{chapter=$chapter.chapter;text=$item.Value}
    }
    foreach ($paragraph in [regex]::Split($body, '\r?\n\s*\r?\n')) {
        $normalized = [regex]::Replace($paragraph, '\s', '')
        if ([regex]::Matches($normalized, '[\u4e00-\u9fff]').Count -ge 30) {
            $paragraphs += [pscustomobject]@{chapter=$chapter.chapter;text=$normalized}
        }
    }
}
$mismatches = @($ledger | Where-Object {-not $_.matches})
$repeatedParagraphs = @($paragraphs | Group-Object text | Where-Object Count -gt 1 | ForEach-Object {
    [pscustomobject]@{chapters=@($_.Group.chapter);text=$_.Name}
})
$result = [ordered]@{
    checkedAt=[DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd HH:mm:ss zzz')
    contract=(Split-Path -Leaf $ContractPath);chapters=$ledger.Count
    income=($ledger | Measure-Object income -Sum).Sum
    spend=($ledger | Measure-Object spend -Sum).Sum
    ledger=$ledger;mismatches=$mismatches
    writingTraceCandidates=$writingTraceCandidates;repeatedLongParagraphs=$repeatedParagraphs
    reviewNote='Ledger declarations are checked against the volume plan. Trace candidates and repeated prose require editorial review; this does not prove narrative quality or cash/causal continuity.'
}
if ($mismatches.Count -gt 0) {
    $mismatches | ConvertTo-Json -Depth 4 | Write-Output
    throw 'System ledger mismatch; inspect the actual prose and parser before changing either.'
}
if ($WriteReport) {
    $reportName = ([IO.Path]::GetFileNameWithoutExtension($ContractPath) -replace '续写合同$', '') + '质量核验.json'
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot $reportName), ($result | ConvertTo-Json -Depth 7), [Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{chapters=$ledger.Count;income=$result.income;spend=$result.spend;net=$result.income-$result.spend;ledgerMismatches=$mismatches.Count;writingTraceCandidates=$writingTraceCandidates;repeatedLongParagraphs=$repeatedParagraphs;reportWritten=[bool]$WriteReport} | ConvertTo-Json -Depth 5
