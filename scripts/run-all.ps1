Set-Location (Split-Path -Parent $PSScriptRoot)

& ".\scripts\build-medallion.ps1"       -Codec ZSTD
& ".\scripts\codec-benchmark.ps1"
& ".\scripts\evolve-and-timetravel.ps1"
& ".\scripts\spark-bronze.ps1"
& ".\scripts\format-matrix.ps1"

Write-Host "DONE. All logs in logs/" -ForegroundColor Green