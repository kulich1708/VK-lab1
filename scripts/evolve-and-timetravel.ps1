Set-Location (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$logFile = Join-Path $logDir "evolve-and-timetravel.log"
if (Test-Path $logFile) { Remove-Item $logFile }
Start-Transcript -Path $logFile -Force | Out-Null

try {
    $T = "lakekeeper.silver.partsupp"

    Write-Host "#### SCHEMA EVOLUTION ####" -ForegroundColor Yellow
    docker exec trino trino --output-format ALIGNED --execute "DESCRIBE $T"
    $filesBefore = docker exec trino trino --output-format CSV_UNQUOTED --execute "SELECT count(*) FROM lakekeeper.silver.`"partsupp`$files`""
    $rowsBefore  = docker exec trino trino --output-format CSV_UNQUOTED --execute "SELECT count(*) FROM $T"
    Write-Host "Файлов до: $($filesBefore[-1]), строк: $($rowsBefore[-1])"

    Write-Host "--- ADD COLUMN supply_share ---"
    docker exec trino trino --output-format ALIGNED --execute "ALTER TABLE $T ADD COLUMN supply_share double"
    docker exec trino trino --output-format ALIGNED --execute "SELECT partkey, suppkey, supply_share FROM $T LIMIT 5"
    docker exec trino trino --output-format ALIGNED --execute "SELECT count(*) AS rows_total, count(supply_share) AS new_col_not_null FROM $T"
    $filesAfter = docker exec trino trino --output-format CSV_UNQUOTED --execute "SELECT count(*) FROM lakekeeper.silver.`"partsupp`$files`""
    Write-Host "Файлов после ADD COLUMN: $($filesAfter[-1]) (не переписывались)"

    Write-Host "--- RENAME COLUMN supply_share -> line_share ---"
    docker exec trino trino --output-format ALIGNED --execute "ALTER TABLE $T RENAME COLUMN supply_share TO line_share"
    docker exec trino trino --output-format ALIGNED --execute "DESCRIBE $T"

    Write-Host "--- DROP COLUMN line_share, схема как раньше ---"
    docker exec trino trino --output-format ALIGNED --execute "ALTER TABLE $T DROP COLUMN line_share"
    docker exec trino trino --output-format ALIGNED --execute "DESCRIBE $T"

    Write-Host ""
    Write-Host "#### TIME TRAVEL ####" -ForegroundColor Yellow
    docker exec trino trino --output-format ALIGNED --execute "SELECT snapshot_id, committed_at, operation FROM lakekeeper.silver.`"partsupp`$snapshots`" ORDER BY committed_at"

    $goodOut = docker exec trino trino --output-format CSV_UNQUOTED --execute "SELECT snapshot_id FROM lakekeeper.silver.`"partsupp`$snapshots`" ORDER BY committed_at DESC LIMIT 1"
    $good = $goodOut[-1]
    Write-Host "Хороший снапшот: $good"

    docker exec trino trino --output-format ALIGNED --execute "SELECT count(*) AS rows_before_accident FROM $T"

    Write-Host "--- АВАРИЯ: удаляем все связи с нечётными suppkey ---"
    docker exec trino trino --output-format ALIGNED --execute "DELETE FROM $T WHERE suppkey % 2 = 1"
    docker exec trino trino --output-format ALIGNED --execute "SELECT count(*) AS rows_after_accident FROM $T"

    Write-Host "--- Читаем старый снапшот через FOR VERSION AS OF ---"
    docker exec trino trino --output-format ALIGNED --execute "SELECT count(*) AS rows_in_old_snapshot FROM $T FOR VERSION AS OF $good"

    Write-Host "--- ВОССТАНОВЛЕНИЕ: rollback_to_snapshot ---"
    docker exec trino trino --output-format ALIGNED --execute "ALTER TABLE $T EXECUTE rollback_to_snapshot($good)"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "(ALTER TABLE EXECUTE не прошёл, пробуем CALL)"
        docker exec trino trino --output-format ALIGNED --execute "CALL lakekeeper.system.rollback_to_snapshot('silver', 'partsupp', $good)"
    }
    docker exec trino trino --output-format ALIGNED --execute "SELECT count(*) AS rows_after_restore FROM $T"
    docker exec trino trino --output-format ALIGNED --execute "SELECT snapshot_id, committed_at, operation FROM lakekeeper.silver.`"partsupp`$snapshots`" ORDER BY committed_at"

    Write-Host "ГОТОВО" -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
}