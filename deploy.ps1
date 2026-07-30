# =============================================================
#  장 마감 배포 (매일 15:30 KST 작업 스케줄러용)
#
#  1) origin 에서 pull (다른 PC 변경 반영)
#  2) refresh.ps1 실행 → data.json 갱신
#  3) data.json 커밋 + push  →  Cloudflare Pages 자동 빌드 (1~2분)
#
#  Usage: powershell -ExecutionPolicy Bypass -File .\deploy.ps1
# =============================================================
$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
Set-Location $root
$env:GIT_TERMINAL_PROMPT = '0'
$env:GCM_INTERACTIVE = 'Never'

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host " SEMI deploy - $((Get-Date).ToString('yyyy-MM-dd HH:mm'))" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 0. git 저장소 여부 확인
$isRepo = (& git -C $root rev-parse --is-inside-work-tree 2>$null)
if ($isRepo -ne 'true') {
    Write-Host " (git 저장소 아님 — 데이터만 갱신하고 종료. 배포 설정은 README 참고)" -ForegroundColor DarkYellow
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'refresh.ps1')
    return
}

# 1. sync
Write-Host "[1/3] git pull..." -ForegroundColor Yellow
& git -C $root pull --rebase --autostash 2>&1 | Out-Null

# 2. refresh data
Write-Host "[2/3] refresh data..." -ForegroundColor Yellow
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'refresh.ps1')

# 3. commit + push (data.json 만)
Write-Host "[3/3] commit + push..." -ForegroundColor Yellow
$status = git -C $root status --porcelain 2>&1
if ([string]::IsNullOrWhiteSpace($status)) {
    Write-Host "  변경 없음 — 커밋 생략." -ForegroundColor DarkGray
} else {
    git -C $root add -f data.json 2>&1 | Out-Null
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    git -C $root commit -m "data: 장마감 갱신 $ts" 2>&1 | Out-Null
    git -C $root pull --rebase --autostash 2>&1 | Out-Null
    git -C $root push 2>&1 | Tee-Object -Variable pushOut | Out-Null
    $pushOut | ForEach-Object { Write-Host "    $_" -ForegroundColor Green }
    Write-Host "  Cloudflare 자동 배포 1~2분 내 반영." -ForegroundColor Green
}
Write-Host "==============================================" -ForegroundColor Cyan
