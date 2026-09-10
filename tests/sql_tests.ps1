# Compatibility entry point; Python is the single SQL suite implementation.
param([string]$Binary = (Join-Path $PSScriptRoot '..\cyboudb.exe'))
$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command python3 -ErrorAction Stop }
& $python.Source (Join-Path $PSScriptRoot 'sql_tests.py') $Binary
exit $LASTEXITCODE
