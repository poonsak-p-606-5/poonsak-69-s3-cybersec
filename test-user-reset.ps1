#Requires -Version 5.1
<#
  One-shot test for POST /api/auth/reset-password (Users & Permissions) WITHOUT SMTP:
    1. POST /api/auth/forgot-password  -> Strapi stores a reset code in up_users
    2. read up_users.reset_password_token from Postgres (docker exec psql)
    3. POST /api/auth/reset-password with { code, password, passwordConfirmation }
    4. persist the code into .env as userResetCode so api.rest
       {{$dotenv userResetCode}} resolves and the User Reset Password request works

  NOTE: forgot-password answers HTTP 500 (no SMTP wired -> email plugin throws)
  but it STILL creates and stores the token before the throw, so we ignore
  that status and read the token from the DB.

  Usage:
    powershell -ExecutionPolicy Bypass -File .\test-user-reset.ps1
    powershell -ExecutionPolicy Bypass -File .\test-user-reset.ps1 -NoPersist   # don't write userResetCode
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
$email    = Get-EnvValue $EnvFile 'userEmail'
$password = Get-EnvValue $EnvFile 'userPassword'
$dbUser   = Get-EnvValue $EnvFile 'DATABASE_USER'
$dbName   = Get-EnvValue $EnvFile 'DATABASE_DB'
$dbPass   = Get-EnvValue $EnvFile 'DATABASE_PASSWORD'

if (-not $base -or -not $email) { throw "Missing baseUrl/userEmail in $EnvFile" }

Write-Host "==> POST /api/auth/forgot-password ($base)"
try {
  $null = Invoke-RestMethod -Uri "$base/api/auth/forgot-password" -Method Post `
    -ContentType 'application/json' -Body (@{ email = $email } | ConvertTo-Json)
} catch {
  Write-Host "    forgot-password answered $([int]$_.Exception.Response.StatusCode) - expected without SMTP; token is still stored"
}

$sql = "SELECT reset_password_token FROM up_users WHERE email = '$($email.Replace("'", "''"))';"
$token = ($sql | docker exec -i -e "PGPASSWORD=$dbPass" $DBContainer `
  psql -U $dbUser -d $dbName -t -A 2>$null | Select-Object -Last 1).Trim()

if (-not $token) {
  throw "No reset token found for '$email'. Is '$DBContainer' up and does the user exist?"
}

if ($NoPersist) {
  Write-Host "==> (skip writing userResetCode to .env)"
} else {
  Set-EnvValue $EnvFile 'userResetCode' $token
  Write-Host "==> wrote userResetCode to .env (api.rest {{userResetCode}} ready)"
}

Write-Host "==> POST /api/auth/reset-password"
$resetBody = @{ code = $token; password = $password; passwordConfirmation = $password } | ConvertTo-Json
try {
  $result = Invoke-RestMethod -Uri "$base/api/auth/reset-password" -Method Post `
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