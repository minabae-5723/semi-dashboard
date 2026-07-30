# =============================================================
#  데이터 새로고침 오케스트레이터
#  - fetch-semi.ps1 실행 (시세·수급·valuation → data.json)
#  - (선택) fetch-consensus.ps1 : 주간 컨센서스 보강 (미구현/추후)
#
#  Usage: powershell -ExecutionPolicy Bypass -File .\refresh.ps1
# =============================================================
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
Set-Location $root

Write-Host ""
Write-Host "== SEMI refresh  $((Get-Date).ToString('yyyy-MM-dd HH:mm')) ==" -ForegroundColor Cyan

Write-Host "[1] fetch-semi (시세·수급)..." -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'fetch-semi.ps1')

# 주간 컨센서스(EPS 성장·ROE·27F) 보강은 fetch-consensus.ps1 로 추가 예정.
$consensus = Join-Path $root 'fetch-consensus.ps1'
if (Test-Path $consensus) {
    Write-Host "[2] fetch-consensus (주간 컨센서스)..." -ForegroundColor Yellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File $consensus
}

Write-Host "== refresh done ==" -ForegroundColor Green
