# =============================================================
#  반도체 밸류체인 대시보드 - 로컬 정적 서버
#  http://localhost:8090  (static files only)
#
#  Usage: powershell -ExecutionPolicy Bypass -File .\serve.ps1
#         powershell -ExecutionPolicy Bypass -File .\serve.ps1 -Port 8091 -NoBrowser
# =============================================================
param([int]$Port = 8090, [switch]$NoBrowser)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$mime = @{
  '.html'='text/html; charset=utf-8'; '.css'='text/css; charset=utf-8';
  '.js'='application/javascript; charset=utf-8'; '.json'='application/json; charset=utf-8';
  '.svg'='image/svg+xml'; '.png'='image/png'; '.ico'='image/x-icon'; '.map'='application/json';
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try { $listener.Start() }
catch { Write-Host ("포트 $Port 사용 중이거나 권한 부족: " + $_.Exception.Message) -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host (" SEMI dashboard  ->  http://localhost:$Port/") -ForegroundColor Green
Write-Host " Ctrl+C 로 종료" -ForegroundColor DarkGray
Write-Host "========================================================" -ForegroundColor Cyan

if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    $reqPath = $ctx.Request.Url.LocalPath.TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($reqPath)) { $reqPath = 'index.html' }
    $reqPath = $reqPath -replace '\.\.', ''   # basic traversal guard
    $full = Join-Path $root $reqPath

    if (Test-Path -LiteralPath $full -PathType Leaf) {
      $ext = [System.IO.Path]::GetExtension($full).ToLower()
      $ct  = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
      $bytes = [System.IO.File]::ReadAllBytes($full)
      $ctx.Response.ContentType = $ct
      $ctx.Response.Headers.Add('Cache-Control', 'no-cache')
      $ctx.Response.ContentLength64 = $bytes.Length
      $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
      Write-Host ("  200  /$reqPath") -ForegroundColor DarkGray
    } else {
      $ctx.Response.StatusCode = 404
      $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: $reqPath")
      $ctx.Response.OutputStream.Write($msg, 0, $msg.Length)
      Write-Host ("  404  /$reqPath") -ForegroundColor DarkYellow
    }
    $ctx.Response.OutputStream.Close()
  } catch {
    Write-Host ("  ERR  " + $_.Exception.Message) -ForegroundColor Red
  }
}
