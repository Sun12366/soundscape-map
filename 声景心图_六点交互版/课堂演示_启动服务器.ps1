param([int]$Port = 8000)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$LocalUrl = "http://localhost:$Port/"

function Get-LanIp {
  $ips = @()
  try {
    $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
      Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
      Sort-Object InterfaceMetric |
      Select-Object -ExpandProperty IPAddress
  } catch {
    $ips = @()
  }
  if ($ips -and $ips.Count -gt 0) {
    return $ips[0]
  }
  try {
    $line = ipconfig | Select-String -Pattern "IPv4" | Select-Object -First 1
    if ($line -and $line.ToString() -match "([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)") {
      return $Matches[1]
    }
  } catch {
    return "电脑的局域网IP"
  }
  return "电脑的局域网IP"
}

$listener = $null
try {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $Port)
  $listener.Start()
} catch {
  Write-Host ""
  Write-Host "端口 $Port 启动失败，可能被其他程序占用。" -ForegroundColor Red
  Write-Host "请关闭占用 8000 端口的程序，或修改本文件第一行的 Port。" -ForegroundColor Yellow
  Write-Host ""
  Read-Host "按回车退出"
  exit 1
}

$lanIp = Get-LanIp
Write-Host ""
Write-Host "==============================================" -ForegroundColor DarkGray
Write-Host "  声景心图 · 课堂演示服务器已启动" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor DarkGray
Write-Host ""
$openUrl = $LocalUrl
if ($lanIp -ne "电脑的局域网IP") {
  $openUrl = "http://$($lanIp):$Port/"
}

Write-Host "  电脑浏览器打开： $openUrl" -ForegroundColor Cyan
Write-Host "  手机扫码地址：    $openUrl" -ForegroundColor Cyan
Write-Host "  本机备用地址：    $LocalUrl" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  手机需要和这台电脑在同一个 WiFi。" -ForegroundColor Yellow
Write-Host "  电脑浏览器请用上面的局域网地址，不要用 localhost，否则二维码会编码成 localhost。" -ForegroundColor Yellow
Write-Host "  如果手机打不开，请在 Windows 防火墙弹窗中允许访问。"
Write-Host "  关闭这个窗口或按 Ctrl+C 即停止服务器。" -ForegroundColor DarkGray
Write-Host ""

try {
  Start-Process $openUrl
} catch {
}

$mime = @{
  ".html" = "text/html; charset=utf-8"
  ".htm"  = "text/html; charset=utf-8"
  ".css"  = "text/css; charset=utf-8"
  ".js"   = "application/javascript; charset=utf-8"
  ".json" = "application/json; charset=utf-8"
  ".jpg"  = "image/jpeg"
  ".jpeg" = "image/jpeg"
  ".png"  = "image/png"
  ".webp" = "image/webp"
  ".gif"  = "image/gif"
  ".svg"  = "image/svg+xml"
  ".ico"  = "image/x-icon"
  ".wav"  = "audio/wav"
  ".mp3"  = "audio/mpeg"
  ".m4a"  = "audio/mp4"
  ".mp4"  = "video/mp4"
  ".woff" = "font/woff"
  ".woff2"= "font/woff2"
  ".ttf"  = "font/ttf"
  ".otf"  = "font/otf"
}

function Send-Response($stream, [string]$status, [string]$contentType, [long]$length, [byte[]]$body, $extraHeaders = @()) {
  $head = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $length`r`nAccept-Ranges: bytes`r`nConnection: close`r`n"
  foreach ($h in $extraHeaders) { $head += "$h`r`n" }
  $head += "`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body -ne $null -and $body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}

while ($true) {
  $client = $null
  try {
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 15000
    $client.SendTimeout = 15000
    $stream = $client.GetStream()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 2048, $true)

    $requestLine = $reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($requestLine)) { continue }
    $parts = $requestLine.Split(" ")
    if ($parts.Length -lt 2) { continue }
    $method = $parts[0].ToUpperInvariant()
    $rawPath = $parts[1]

    $headers = @{}
    while ($true) {
      $line = $reader.ReadLine()
      if ($line -eq $null -or $line -eq "") { break }
      $idx = $line.IndexOf(":")
      if ($idx -gt 0) {
        $headers[$line.Substring(0, $idx).Trim().ToLowerInvariant()] = $line.Substring($idx + 1).Trim()
      }
    }

    $pathOnly = ($rawPath -split "\?")[0]
    try { $pathOnly = [System.Uri]::UnescapeDataString($pathOnly) } catch {}
    if ($pathOnly -eq "/" -or $pathOnly -eq "") { $pathOnly = "/index.html" }
    $rel = $pathOnly.TrimStart("/").Replace("/", "\")
    $full = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\") + "\"
    if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      Send-Response $stream "403 Forbidden" "text/plain; charset=utf-8" 9 ([System.Text.Encoding]::UTF8.GetBytes("Forbidden"))
      continue
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
      $full = Join-Path $full "index.html"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
      $msg = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found`n$rel")
      Send-Response $stream "404 Not Found" "text/plain; charset=utf-8" $msg.Length $msg
      continue
    }

    $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
    $contentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { "application/octet-stream" }
    $fileLen = (Get-Item -LiteralPath $full).Length
    $start = 0
    $end = $fileLen - 1
    $status = "200 OK"
    $extra = @()

    if ($headers.ContainsKey("range") -and $headers["range"] -match "bytes=(\d*)-(\d*)") {
      $s = $Matches[1]; $e = $Matches[2]
      if ($s -ne "") { $start = [long]$s }
      if ($e -ne "") { $end = [long]$e }
      if ($start -lt 0) { $start = 0 }
      if ($end -ge $fileLen) { $end = $fileLen - 1 }
      if ($start -gt $end) {
        Send-Response $stream "416 Range Not Satisfiable" "text/plain; charset=utf-8" 0 $null @("Content-Range: bytes */$fileLen")
        continue
      }
      $status = "206 Partial Content"
      $extra += "Content-Range: bytes $start-$end/$fileLen"
    }

    $sendLen = $end - $start + 1
    $head = "HTTP/1.1 $status`r`nContent-Type: $contentType`r`nContent-Length: $sendLen`r`nAccept-Ranges: bytes`r`nConnection: close`r`n"
    foreach ($h in $extra) { $head += "$h`r`n" }
    $head += "`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
    $stream.Write($hb, 0, $hb.Length)
    if ($method -ne "HEAD" -and $sendLen -gt 0) {
      $fs = [System.IO.File]::Open($full, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
      try {
        $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buf = New-Object byte[] 65536
        $remain = $sendLen
        while ($remain -gt 0) {
          $want = [int][Math]::Min($buf.Length, $remain)
          $read = $fs.Read($buf, 0, $want)
          if ($read -le 0) { break }
          $stream.Write($buf, 0, $read)
          $remain -= $read
        }
        $stream.Flush()
      } finally { $fs.Dispose() }
    }
  } catch {
    # keep the server alive on broken pipes / cancelled requests
  } finally {
    if ($client) { try { $client.Close() } catch {} }
  }
}
