#requires -Version 7.4
[CmdletBinding()]
param([string]$Version = 'v1.1.0')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$paths = @('Install.ps1','bootstrap.ps1','config/config.example.json','templates/email-template.html')
$paths += @(Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1' | ForEach-Object { 'scripts/' + $_.Name })
$paths += @(Get-ChildItem $root -Filter '*.md' | ForEach-Object Name)
$hashes = [ordered]@{}
foreach ($relative in ($paths | Sort-Object -Unique)) {
    $hashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $root $relative) -Algorithm SHA256).Hash
}
@{ Version = $Version; Algorithm = 'SHA256'; Files = $hashes } | ConvertTo-Json -Depth 6 |
    Set-Content -LiteralPath (Join-Path $root 'release-manifest.json') -Encoding utf8
