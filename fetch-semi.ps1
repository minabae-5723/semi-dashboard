# =============================================================
#  반도체 밸류체인 대시보드 데이터 수집 (장 마감 3:30 기준)
#
#  peer-config.json 의 종목마다:
#    - Yahoo Finance v8/chart  -> 1년 종가 (1W / 1M / YTD 수익률 계산)
#    - Naver 종목 메인          -> 시총, PER, PBR, 선행 PER/PBR
#    - Naver 외국인·기관 동향   -> 외국인/기관 순매수(5D 누적), 외국인 지분율,
#                                  거래대금, 회전율, 상장주식수
#  Output: data.json  (app.js 가 읽는 단일 데이터 소스)
#
#  주의: 이 스크립트는 ASCII 전용. 한글 종목명/카테고리는
#  peer-config.json(UTF-8)에 둔다 (PS 5.1 은 .ps1 을 cp949 로 읽음).
#
#  Usage: powershell -ExecutionPolicy Bypass -File .\fetch-semi.ps1
# =============================================================
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
Set-Location $root

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36'

# ---- config (UTF-8, preserves Korean) ----
$cfgPath = Join-Path $root 'peer-config.json'
$cfgRaw  = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
$cfg     = $cfgRaw | ConvertFrom-Json
$tickers = $cfg.tickers

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host (" Semi value-chain fetch (" + $tickers.Count + " tickers)") -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# ----------- Helpers -----------

function Get-YahooHistory {
    param([string]$symbol)
    $url = "https://query1.finance.yahoo.com/v8/finance/chart/${symbol}?interval=1d&range=1y"
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent $UA -TimeoutSec 15
        $data = $r.Content | ConvertFrom-Json
        if (-not $data.chart.result) { return @() }
        $res = $data.chart.result[0]
        $ts = $res.timestamp
        $cs = $res.indicators.quote[0].close
        $out = @()
        for ($i = 0; $i -lt $ts.Count; $i++) {
            if ($null -ne $cs[$i]) {
                $out += [PSCustomObject]@{
                    date  = [DateTimeOffset]::FromUnixTimeSeconds([long]$ts[$i]).ToString('yyyy-MM-dd')
                    close = [double]$cs[$i]
                }
            }
        }
        return ,$out
    } catch {
        Write-Host ("    Yahoo error " + $symbol + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
        return @()
    }
}

function Find-ClosestClose {
    param($history, [string]$targetDate)
    if (-not $history -or $history.Count -eq 0) { return $null }
    $best = $null
    foreach ($row in $history) {
        if ($row.date -le $targetDate) {
            if ($null -eq $best -or $row.date -gt $best.date) { $best = $row }
        }
    }
    return $best
}

function Get-NaverSnapshot {
    param([string]$code)
    $url = "https://finance.naver.com/item/main.naver?code=${code}"
    $result = [ordered]@{ mcap=$null; per=$null; pbr=$null; eps=$null; bps=$null; fwdPer=$null; fwdPbr=$null }
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent $UA -TimeoutSec 15
        $rawBytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($r.Content)
        $html = [System.Text.Encoding]::GetEncoding('EUC-KR').GetString($rawBytes)

        # Market cap: <em id="_market_sum"> "1,655 9,584" (조 억) or "3,069" (억)
        $mcapM = [regex]::Match($html, 'id="_market_sum"[^>]*>(.*?)</em>', 'Singleline')
        if ($mcapM.Success) {
            $raw = $mcapM.Groups[1].Value -replace '<[^>]+>', '' -replace '&nbsp;', ' '
            $nums = @([regex]::Matches($raw, '[\d,]+') | ForEach-Object { [double]($_.Value -replace ',', '') })
            if ($nums.Count -ge 2)     { $result.mcap = ($nums[0] * 10000) + $nums[1] }
            elseif ($nums.Count -eq 1) { $result.mcap = $nums[0] }
        }

        foreach ($key in @('per','pbr','eps','bps')) {
            $m = [regex]::Match($html, ('id="_' + $key + '"[^>]*>(.*?)</em>'), 'Singleline')
            if ($m.Success) {
                $v = ($m.Groups[1].Value -replace '<[^>]+>', '' -replace ',', '').Trim()
                if ($v -match '^-?\d+(\.\d+)?$') { $result[$key] = [double]$v }
            }
        }

        # Forward (FY1) PER & PBR: 기업실적분석 4th <td> = next-fiscal estimate.
        $fwdMap = @{ fwdPer = 'th_cop_anal20'; fwdPbr = 'th_cop_anal21' }
        foreach ($key in $fwdMap.Keys) {
            $cls = $fwdMap[$key]
            $rowM = [regex]::Match($html, ('<tr[^>]*>\s*<th[^>]*' + $cls + '[^>]*>.*?</tr>'), 'Singleline')
            if ($rowM.Success) {
                $tdMatches = [regex]::Matches($rowM.Value, '<td[^>]*>(.*?)</td>', 'Singleline')
                if ($tdMatches.Count -ge 4) {
                    $cell = $tdMatches[3].Groups[1].Value
                    $val = ($cell -replace '<[^>]+>', '' -replace '&nbsp;', '' -replace '[,\s]', '').Trim()
                    if ($val -match '^-?\d+(\.\d+)?$') { $result[$key] = [double]$val }
                }
            }
        }
        return $result
    } catch {
        Write-Host ("    Naver snapshot error " + $code + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
        return $result
    }
}

function Get-NaverFlow {
    # 외국인/기관 매매동향 (frgn). Table columns per dated row:
    #  0 date | 1 close | 2 chg | 3 chg% | 4 volume | 5 inst netQty
    #  6 foreign netQty | 7 foreign shares held | 8 foreign holding %
    # Returns: 5D cumulative foreign/inst net BUY in 억원 (netQty*close/1e8),
    #          foreign holding %, latest 거래대금(억), 회전율(%), 상장주식수.
    param([string]$code)
    $url = "https://finance.naver.com/item/frgn.naver?code=${code}"
    $out = [ordered]@{ fxNet=$null; instNet=$null; fxPct=$null; tval=$null; turn=$null }
    try {
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent $UA -TimeoutSec 15
        $rawBytes = [System.Text.Encoding]::GetEncoding('iso-8859-1').GetBytes($r.Content)
        $html = [System.Text.Encoding]::GetEncoding('EUC-KR').GetString($rawBytes)

        $rows = [regex]::Matches($html, '<tr[^>]*>(?:(?!</tr>).)*?\d{4}\.\d{2}\.\d{2}(?:(?!</tr>).)*?</tr>', 'Singleline')
        if ($rows.Count -eq 0) { return $out }

        $parsed = @()
        foreach ($row in $rows) {
            $cells = @([regex]::Matches($row.Value, '<td[^>]*>(.*?)</td>', 'Singleline') |
                ForEach-Object { ($_.Groups[1].Value -replace '<[^>]+>','' -replace '&nbsp;',' ' -replace '\s+',' ').Trim() })
            if ($cells.Count -lt 9) { continue }
            $num = { param($s) $t = ($s -replace '[+,%\s]','') ; if ($t -match '^-?\d+(\.\d+)?$') { [double]$t } else { $null } }
            $parsed += [PSCustomObject]@{
                close   = & $num $cells[1]
                vol     = & $num $cells[4]
                instQty = & $num $cells[5]
                fxQty   = & $num $cells[6]
                fxShare = & $num $cells[7]
                fxPct   = & $num $cells[8]
            }
        }
        if ($parsed.Count -eq 0) { return $out }

        $latest = $parsed[0]
        $out.fxPct = $latest.fxPct

        # 거래대금(억) = 거래량 * 종가 / 1e8
        if ($null -ne $latest.vol -and $null -ne $latest.close) {
            $out.tval = [Math]::Round(($latest.vol * $latest.close) / 1e8, 0)
        }
        # 상장주식수 = 외국인 보유주수 / (외국인 지분율/100)  ->  회전율 = 거래량/상장주식수*100
        if ($null -ne $latest.fxShare -and $null -ne $latest.fxPct -and $latest.fxPct -gt 0 -and $null -ne $latest.vol) {
            $shares = $latest.fxShare / ($latest.fxPct / 100.0)
            if ($shares -gt 0) { $out.turn = [Math]::Round(($latest.vol / $shares) * 100.0, 2) }
        }

        # 5D 누적 순매수 (억원) = sum(netQty * close) / 1e8  over up to 5 latest rows
        $take = [Math]::Min(5, $parsed.Count)
        $fxSum = 0.0; $instSum = 0.0; $ok = $false
        for ($j = 0; $j -lt $take; $j++) {
            $p = $parsed[$j]
            if ($null -ne $p.close) {
                if ($null -ne $p.fxQty)   { $fxSum   += $p.fxQty   * $p.close; $ok = $true }
                if ($null -ne $p.instQty) { $instSum += $p.instQty * $p.close }
            }
        }
        if ($ok) {
            $out.fxNet   = [Math]::Round($fxSum   / 1e8, 0)
            $out.instNet = [Math]::Round($instSum / 1e8, 0)
        }
        return $out
    } catch {
        Write-Host ("    Naver flow error " + $code + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
        return $out
    }
}

# ----------- Date refs from pivot ticker (Samsung) -----------

$pivot = Get-YahooHistory -symbol '005930.KS'
if (-not $pivot -or $pivot.Count -eq 0) {
    Write-Host "FATAL: pivot 005930.KS returned no history" -ForegroundColor Red
    exit 1
}
$refRow  = $pivot[-1]
$refDate = $refRow.date
$refYear = ([datetime]$refDate).Year
$wTarget = ([datetime]$refDate).AddDays(-7).ToString('yyyy-MM-dd')
$mTarget = ([datetime]$refDate).AddMonths(-1).ToString('yyyy-MM-dd')
$wRow  = Find-ClosestClose -history $pivot -targetDate $wTarget
$mRow  = Find-ClosestClose -history $pivot -targetDate $mTarget
$yRow  = $pivot | Where-Object { ([datetime]$_.date).Year -eq $refYear } | Select-Object -First 1

Write-Host (" Ref date:   " + $refDate)
if ($wRow) { Write-Host (" 1W ago:     " + $wRow.date) }
if ($mRow) { Write-Host (" 1M ago:     " + $mRow.date) }
if ($yRow) { Write-Host (" Year start: " + $yRow.date) }

# ----------- Per-ticker fetch -----------

$rowsBySeg = [ordered]@{}
foreach ($s in $cfg.segments) { $rowsBySeg[$s.id] = @() }

$i = 0
foreach ($t in $tickers) {
    $i++
    $sym = $t.code + '.' + $t.market
    Write-Host ("[" + $i + "/" + $tickers.Count + "] " + $t.name + " (" + $sym + ")") -ForegroundColor Yellow

    $hist = Get-YahooHistory -symbol $sym
    $closeRef  = if ($hist.Count -gt 0) { $hist[-1] } else { $null }
    $closeW    = Find-ClosestClose -history $hist -targetDate $wTarget
    $closeM    = Find-ClosestClose -history $hist -targetDate $mTarget
    $closeY    = $hist | Where-Object { ([datetime]$_.date).Year -eq $refYear } | Select-Object -First 1

    $price = if ($closeRef) { [Math]::Round($closeRef.close, 0) } else { $null }
    $pct = {
        param($a, $b)
        if ($a -and $b -and $b.close -gt 0) { [Math]::Round(((($a.close / $b.close) - 1.0) * 100.0), 1) } else { $null }
    }
    $w = & $pct $closeRef $closeW
    $m = & $pct $closeRef $closeM
    $y = & $pct $closeRef $closeY

    Start-Sleep -Milliseconds 250
    $nav  = Get-NaverSnapshot -code $t.code
    Start-Sleep -Milliseconds 250
    $flow = Get-NaverFlow -code $t.code

    $rowsBySeg[$t.seg] += [PSCustomObject]@{
        code   = $t.code
        n      = $t.name
        mc     = $nav.mcap
        price  = $price
        w      = $w
        m      = $m
        y      = $y
        per    = $nav.per
        pbr    = $nav.pbr
        fwPer  = $nav.fwdPer
        fwPbr  = $nav.fwdPbr
        fxPct  = $flow.fxPct
        fxNet  = $flow.fxNet
        instNet= $flow.instNet
        tval   = $flow.tval
        turn   = $flow.turn
    }

    $wD = if ($null -ne $w) { ("{0}%" -f $w) } else { "-" }
    Write-Host ("    price=" + $price + " | mc=" + $nav.mcap + " | fPER=" + $nav.fwdPer + " | 1W=" + $wD + " | 외국인%=" + $flow.fxPct) -ForegroundColor DarkGray
}

# ----------- Save -----------

$result = [ordered]@{
    meta = [ordered]@{
        updated   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        updatedKr = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        refDate   = $refDate
        wDate     = if ($wRow) { $wRow.date } else { $null }
        mDate     = if ($mRow) { $mRow.date } else { $null }
        yDate     = if ($yRow) { $yRow.date } else { $null }
        source    = 'Yahoo Finance (price/returns) + Naver Finance (mcap/PER/PBR/수급)'
        note      = '순매수는 최근 5거래일 누적(억원, 종가기준 환산). PER/PBR은 TTM, fPER/fPBR은 선행(FY1). EPS성장/ROE 컨센서스는 별도 주간 갱신.'
    }
    segments = @($cfg.segments)
    rows     = $rowsBySeg
}

$out = Join-Path $root 'data.json'
$json = $result | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host (" Saved -> " + $out + "  (" + ((Get-Item -LiteralPath $out).Length) + " bytes)") -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Cyan
