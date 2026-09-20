#Requires -Version 5.1
<#
  One-shot test for POST /admin/reset-password (Strapi admin) WITHOUT SMTP:
    1. POST /admin/forgot-password  -> Strapi stores a reset token in admin_users
    2. read admin_users.reset_password_token from Postgres (docker exec psql)
    3. POST /admin/reset-password with { resetPasswordToken, password }
    4. persist the token into .env as adminResetCode so api.rest
       {{$dotenv adminResetCode}} resolves and the Admin Reset Password request works

  Usage:
    powershell -ExecutionPolicy Bypass -File .\test-admin-reset.ps1
    powershell -ExecutionPolicy Bypass -File .\test-admin-reset.ps1 -NoPersist   # don't write adminResetCode
#>
param(
  [switch]$NoPersist,
  [string]$EnvFile = (Join-Path $PSScriptRoot '.env'),
  [string]$DBContainer = '69-s3-db'
)
$ErrorActionPreference = 'Stop'

function Get-EnvValue {
  param([string]$File, [string]$Key)
  Get-Content $File | ForEach-Object {
    if ($_ -match '^\s*#') { return }
    if ($_ -match "^$([regex]::Escape($Key))=(.*)$") { return $matches[1].Trim() }
  }
}

function Set-EnvValue {
  param([string]$File, [string]$Key, [string]$Value)
  $raw = Get-Content $File -Raw
  $pattern = "(?m)^(\s*#?\s*$([regex]::Escape($Key))\s*=).*$"
  if ($raw -match $pattern) {
    $raw = $raw -replace $pattern, "`$1$Value"
  } else {
    $raw = $raw.TrimEnd("`r", "`n") + "`r`n$Key=$Value`r`n"
  }
  Set-Content -Path $File -Value $raw -NoNewline -Encoding UTF8
}

$base     = Get-EnvValue $EnvFile 'baseUrl'
$email    = Get-EnvValue $EnvFile 'adminEmail'
$password = Get-EnvValue $EnvFile 'adminPassword'
$dbUser   = Get-EnvValue $EnvFile 'DATABASE_USER'
$dbName   = Get-EnvValue $EnvFile 'DATABASE_DB'
$dbPass   = Get-EnvValue $EnvFile 'DATABASE_PASSWORD'

if (-not $base -or -not $email) { throw "Missing baseUrl/adminEmail in $EnvFile" }

Write-Host "==> POST /admin/forgot-password ($base)"
$null = Invoke-RestMethod -Uri "$base/admin/forgot-password" -Method Post `
  -ContentType 'application/json' -Body (@{ email = $email } | ConvertTo-Json)
Write-Host "    ok: token generated"

$sql = "SELECT reset_password_token FROM admin_users WHERE email = '$($email.Replace("'", "''"))';"
$token = ($sql | docker exec -i -e "PGPASSWORD=$dbPass" $DBContainer `
  psql -U $dbUser -d $dbName -t -A 2>$null | Select-Object -Last 1).Trim()

if (-not $token) {
  throw "No reset token found for '$email'. Is '$DBContainer' up and is the admin user created?"
}

if ($NoPersist) {
  Write-Host "==> (skip writing adminResetCode to .env)"
} else {
  Set-EnvValue $EnvFile 'adminResetCode' $token
  Write-Host "==> wrote adminResetCode to .env (api.rest {{adminResetCode}} ready)"
}

Write-Host "==> POST /admin/reset-password"
$resetBody = @{ resetPasswordToken = $token; password = $password } | ConvertTo-Json
try {
  $result = Invoke-RestMethod -Uri "$base/admin/reset-password" -Method Post `
    -ContentType 'application/json' -Body $resetBody
  Write-Host "SUCCESS (200):"
  $result | ConvertTo-Json -Depth 6
} catch {
  $status = ''
  $msg = $_.Exception.Message
  try {
    $resp = $_.Exception.Response
    $status = [int]$resp.StatusCode
    $stream = $resp.GetResponseStream()
    if ($stream) {
      $reader = New-Object System.IO.StreamReader($stream)
      $msg = $reader.ReadToEnd()
    }
  } catch { }
  Write-Warning "FAILED ($status): $msg"
  exit 1
}