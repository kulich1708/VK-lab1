param([string]$Codec = "ZSTD")

Set-Location (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$logFile = Join-Path $logDir "build-medallion.log"
if (Test-Path $logFile) { Remove-Item $logFile }
Start-Transcript -Path $logFile -Force | Out-Null

try {
    foreach ($c in @("lakehouse-minio", "lakehouse-pg", "lakekeeper", "trino")) {
        $running = docker inspect -f '{{.State.Running}}' $c 2>$null
        if ($running -ne "true") {
            Write-Host "Container $c is not running. Run .\infra\restart-stack.ps1 first" -ForegroundColor Red
            exit 1
        }
    }
    $info = curl.exe -sf http://localhost:18080/v1/info
    if (-not ($info -match '"starting":false')) {
        Write-Host "Trino is still starting, please wait." -ForegroundColor Red
        exit 1
    }
    Write-Host "Stack is healthy"

    Write-Host "=== 0. Schemas ===" -ForegroundColor Cyan
    Get-Content -Raw -Encoding UTF8 "sql/01_schemas.sql" | docker exec -i trino trino --output-format ALIGNED

    Write-Host "=== 1. Bronze (codec $Codec) ===" -ForegroundColor Cyan
    $bronzeSql = (Get-Content -Raw -Encoding UTF8 "sql/02_bronze.sql.tpl") -replace "__CODEC__", $Codec
    $bronzeTmp = Join-Path $logDir "_bronze_rendered.sql"
    Set-Content -Path $bronzeTmp -Value $bronzeSql -Encoding UTF8

    $t = Measure-Command {
        Get-Content -Raw -Encoding UTF8 $bronzeTmp | docker exec -i trino trino --output-format ALIGNED | Out-Null
    }
    Write-Host "Bronze write: $([math]::Round($t.TotalSeconds, 3)) s"

    Write-Host "=== 1a. Bronze data quality report ===" -ForegroundColor Cyan
    Get-Content -Raw -Encoding UTF8 "sql/03_data_checks.sql" | docker exec -i trino trino --output-format ALIGNED

    Write-Host "=== 2. Silver ===" -ForegroundColor Cyan
    $t = Measure-Command {
        Get-Content -Raw -Encoding UTF8 "sql/04_silver.sql" | docker exec -i trino trino --output-format ALIGNED | Out-Null
    }
    Write-Host "Silver write: $([math]::Round($t.TotalSeconds, 3)) s"
    docker exec trino trino --output-format ALIGNED --execute "SELECT count(*) AS rows_cnt FROM lakekeeper.silver.partsupp"
    docker exec trino trino --output-format ALIGNED --execute "DESCRIBE lakekeeper.silver.part"

    Write-Host "=== 3. Gold ===" -ForegroundColor Cyan
    $t = Measure-Command {
        Get-Content -Raw -Encoding UTF8 "sql/05_gold.sql" | docker exec -i trino trino --output-format ALIGNED | Out-Null
    }
    Write-Host "Gold write: $([math]::Round($t.TotalSeconds, 3)) s"

    Write-Host "=== 4. Reconcile Gold with Q16 directly ===" -ForegroundColor Cyan
    Get-Content -Raw -Encoding UTF8 "sql/06_reconcile.sql" | docker exec -i trino trino --output-format ALIGNED

    Write-Host "=== 5. Layer sizes ===" -ForegroundColor Cyan
    Get-Content -Raw -Encoding UTF8 "sql/07_layer_sizes.sql" | docker exec -i trino trino --output-format ALIGNED

    Write-Host "=== 6. Codecs in table properties ===" -ForegroundColor Cyan
    docker exec trino trino --output-format ALIGNED --execute "
SELECT 'bronze.part' AS t, key, value FROM lakekeeper.bronze.`"part`$properties`" WHERE key LIKE 'write.%'
UNION ALL SELECT 'silver.part', key, value FROM lakekeeper.silver.`"part`$properties`" WHERE key LIKE 'write.%'
UNION ALL SELECT 'gold.parts_supplier_count', key, value FROM lakekeeper.gold.`"parts_supplier_count`$properties`" WHERE key LIKE 'write.%'
"

    Write-Host "DONE" -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
}