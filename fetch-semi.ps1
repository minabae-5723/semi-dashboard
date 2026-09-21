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

# ----- Naver mobile JSON parse helpers (ASCII-only; unit chars via code points) -----
$NV_HDR = @{ Referer = 'https://m.stock.naver.com/' }

function ConvertTo-Num {
    # strip all but digits/dot/minus -> double, else null
    param($s)
    if ($null -eq $s) { return $null }
    $t = ([string]$s) -replace '[^0-9.\-]', ''
    if ($t -match '^-?\d+(\.\d+)?$') { return [double]$t } else { return $null }
}

function ConvertTo-Mcap {
    # market cap string -> value in 100M-KRW (eok). "N jo M eok" -> N*10000+M ; "M eok" -> M
    param($s)
    if ($null -eq $s) { return $null }
    $str = [string]$s
    $jo  = [char]0xC870
    $nums = @([regex]::Matches($str, '[\d,]+') | ForEach-Object { [double]($_.Value -replace ',', '') })
    if ($nums.Count -eq 0) { return $null }
    if ($str.Contains($jo)) {
        if ($nums.Count -ge 2) { return ($nums[0] * 10000) + $nums[1] }
        return $nums[0] * 10000
    }
    return $nums[0]
}

function Get-NaverSnapshot {
    # Naver desktop HTML broke (2026-09); use mobile JSON APIs.
    #   /integration    -> marketValue, per, pbr, eps, bps (TTM)
    #   /finance/annual -> forward PER/PBR (latest annual column = FY estimate)
    param([string]$code)
    $result = [ordered]@{ mcap=$null; per=$null; pbr=$null; eps=$null; bps=$null; fwdPer=$null; fwdPbr=$null }
    try {
        $u1 = "https://m.stock.naver.com/api/stock/$code/integration"
        $j  = (Invoke-WebRequest -Uri $u1 -Headers $NV_HDR -UserAgent $UA -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        $map = @{}
        foreach ($ti in $j.totalInfos) { $map[$ti.code] = $ti.value }
        $result.mcap = ConvertTo-Mcap $map['marketValue']
        $result.per  = ConvertTo-Num  $map['per']
        $result.pbr  = ConvertTo-Num  $map['pbr']
        $result.eps  = ConvertTo-Num  $map['eps']
        $result.bps  = ConvertTo-Num  $map['bps']
    } catch {
        Write-Host ("    Naver integration error " + $code + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
    }
    try {
        $u2 = "https://m.stock.naver.com/api/stock/$code/finance/annual"
        $f  = (Invoke-WebRequest -Uri $u2 -Headers $NV_HDR -UserAgent $UA -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        $rows = $f.financeInfo.rowList
        $perRow = $rows | Where-Object { $_.title -eq 'PER' } | Select-Object -First 1
        $pbrRow = $rows | Where-Object { $_.title -eq 'PBR' } | Select-Object -First 1
        if ($perRow) {
            $lastKey = ($perRow.columns.PSObject.Properties.Name | Sort-Object)[-1]
            $result.fwdPer = ConvertTo-Num $perRow.columns.$lastKey.value
            if ($pbrRow) { $result.fwdPbr = ConvertTo-Num $pbrRow.columns.$lastKey.value }
        }
    } catch {
        Write-Host ("    Naver annual error " + $code + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
    }
    return $result
}

function Get-NaverFlow {
    # Foreign/institution flow. frgn.naver HTML broke (2026-09); use mobile /trend JSON.
    #   fields: bizdate, foreignerPureBuyQuant, organPureBuyQuant, foreignerHoldRatio,
    #           closePrice, accumulatedTradingVolume (10 rows, newest first)
    # Returns: 5D cumulative foreign/inst net BUY (eok), foreign holding %,
    #          latest trading value (eok), turnover %. Turn needs shares -> from mcap/price.
    param([string]$code, [double]$mcap = 0, [double]$price = 0)
    $out = [ordered]@{ fxNet=$null; instNet=$null; fxPct=$null; tval=$null; turn=$null }
    try {
        $url = "https://m.stock.naver.com/api/stock/$code/trend"
        $arr = (Invoke-WebRequest -Uri $url -Headers $NV_HDR -UserAgent $UA -UseBasicParsing -TimeoutSec 15).Content | ConvertFrom-Json
        if (-not $arr -or $arr.Count -eq 0) { return $out }

        $latest = $arr[0]
        $out.fxPct = ConvertTo-Num $latest.foreignerHoldRatio
        $lvol   = ConvertTo-Num $latest.accumulatedTradingVolume
        $lclose = ConvertTo-Num $latest.closePrice

        # trading value (eok) = volume * close / 1e8
        if ($null -ne $lvol -and $null -ne $lclose) {
            $out.tval = [Math]::Round(($lvol * $lclose) / 1e8, 0)
        }
        # turnover = volume / shares * 100 ; shares = mcap(eok)*1e8 / price
        if ($mcap -gt 0 -and $price -gt 0 -and $null -ne $lvol) {
            $shares = ($mcap * 1e8) / $price
            if ($shares -gt 0) { $out.turn = [Math]::Round(($lvol / $shares) * 100.0, 2) }
        }

        # 5D cumulative net buy (eok) = sum(netQty * close) / 1e8 over up to 5 latest rows
        $take = [Math]::Min(5, $arr.Count)
        $fxSum = 0.0; $instSum = 0.0; $ok = $false
        for ($j = 0; $j -lt $take; $j++) {
            $p = $arr[$j]
            $c = ConvertTo-Num $p.closePrice
            if ($null -ne $c) {
                $fq = ConvertTo-Num $p.foreignerPureBuyQuant
                $oq = ConvertTo-Num $p.organPureBuyQuant
                if ($null -ne $fq) { $fxSum   += $fq * $c; $ok = $true }
                if ($null -ne $oq) { $instSum += $oq * $c }
            }
        }
        if ($ok) {
            $out.fxNet   = [Math]::Round($fxSum   / 1e8, 0)
            $out.instNet = [Math]::Round($instSum / 1e8, 0)
        }
        return $out
    } catch {
        Write-Host ("    Naver trend error " + $code + ": " + $_.Exception.Message) -ForegroundColor DarkYellow
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

$rowsAll = @()

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
    $flow = Get-NaverFlow -code $t.code -mcap ([double]($nav.mcap)) -price ([double]$price)

    $rowsAll += [PSCustomObject]@{
        code   = $t.code
        n      = $t.name
        stage  = $t.stage
        type   = $t.type
        step   = $t.step
        cust   = @($t.cust)
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
    stages   = @($cfg.stages)
    types    = @($cfg.types)
    steps    = $cfg.steps
    custs    = @($cfg.custs)
    rows     = @($rowsAll)
}

$out = Join-Path $root 'data.json'
$json = $result | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ""
Write-Host (" Saved -> " + $out + "  (" + ((Get-Item -LiteralPath $out).Length) + " bytes)") -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Cyan
