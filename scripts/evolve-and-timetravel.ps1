Set-Location (Split-Path -Parent $PSScriptRoot)

$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$log = Join-Path $logDir "evolve-and-timetravel.log"
try {
    if (Test-Path $log) { Clear-Content -Path $log -ErrorAction Stop }
    else { New-Item -ItemType File -Path $log | Out-Null }
} catch { Write-Host "Cannot open $log. Close it and retry." -ForegroundColor Red; exit 1 }

function Write-Log([string]$Text) {
    Write-Host $Text
    Add-Content -Path $log -Value $Text -Encoding UTF8
}

function Show-Sql([string]$Sql) {
    $Sql | docker exec -i trino trino --no-progress --output-format ALIGNED 2>&1 |
        ForEach-Object {
            Write-Host $_
            if ("$_" -notmatch 'WARNING: Unable|org\.jline') {
                Add-Content -Path $log -Value $_ -Encoding UTF8
            }
        }
}

function Get-SqlScalar([string]$Sql) {
    $out = $Sql | docker exec -i trino trino --no-progress --output-format CSV_UNQUOTED 2>$null
    return ($out | Select-Object -Last 1).Trim()
}

foreach ($c in @("lakehouse-minio", "lakehouse-pg", "lakekeeper", "trino")) {
    if ((docker inspect -f '{{.State.Running}}' $c 2>$null) -ne "true") {
        Write-Log "Container $c is not running. Run .\infra\restart-stack.ps1 first."
        exit 1
    }
}
if (-not ((curl.exe -sf http://localhost:18080/v1/info) -match '"starting":false')) {
    Write-Log "Trino is still starting, wait and retry."
    exit 1
}
Write-Log "Stack is healthy"

$T = "lakekeeper.silver.partsupp"

Write-Log ""
Write-Log "#### SCHEMA EVOLUTION ####"

Write-Log "Schema before:"
Show-Sql "DESCRIBE $T;"

$filesBefore = Get-SqlScalar 'SELECT count(*) FROM lakekeeper.silver."partsupp$files";'
$rowsBefore  = Get-SqlScalar "SELECT count(*) FROM $T;"
Write-Log "Files before: $filesBefore, rows before: $rowsBefore"

Write-Log "--- ADD COLUMN supply_share ---"
Show-Sql "ALTER TABLE $T ADD COLUMN supply_share double;"
Write-Log "First 5 rows (supply_share must be NULL):"
Show-Sql "SELECT partkey, suppkey, supply_share FROM $T LIMIT 5;"
Write-Log "Row counts (new_col_not_null must be 0):"
Show-Sql "SELECT count(*) AS rows_total, count(supply_share) AS new_col_not_null FROM $T;"

$filesAfter = Get-SqlScalar 'SELECT count(*) FROM lakekeeper.silver."partsupp$files";'
Write-Log "Files after ADD COLUMN: $filesAfter (must equal $filesBefore - files not rewritten)"

Write-Log "--- RENAME COLUMN supply_share to line_share ---"
Show-Sql "ALTER TABLE $T RENAME COLUMN supply_share TO line_share;"
Show-Sql "DESCRIBE $T;"

Write-Log "--- DROP COLUMN line_share (back to original schema) ---"
Show-Sql "ALTER TABLE $T DROP COLUMN line_share;"
Show-Sql "DESCRIBE $T;"

Write-Log ""
Write-Log "#### TIME TRAVEL ####"
Write-Log "Snapshot history:"
Show-Sql 'SELECT snapshot_id, committed_at, operation FROM lakekeeper.silver."partsupp$snapshots" ORDER BY committed_at;'

$good = Get-SqlScalar 'SELECT snapshot_id FROM lakekeeper.silver."partsupp$snapshots" ORDER BY committed_at DESC LIMIT 1;'
Write-Log "Good snapshot id: $good"

$rowsAccidentBefore = Get-SqlScalar "SELECT count(*) FROM $T;"
Write-Log "Rows before accident: $rowsAccidentBefore"

Write-Log "--- ACCIDENT: DELETE ... WHERE suppkey % 2 = 1 ---"
Show-Sql "DELETE FROM $T WHERE suppkey % 2 = 1;"
$rowsAfterAccident = Get-SqlScalar "SELECT count(*) FROM $T;"
Write-Log "Rows after accident: $rowsAfterAccident"

Write-Log "--- Read old snapshot via FOR VERSION AS OF $good ---"
$rowsInOldSnapshot = Get-SqlScalar "SELECT count(*) FROM $T FOR VERSION AS OF $good;"
Write-Log "Rows in old snapshot: $rowsInOldSnapshot"

Write-Log "--- RESTORE: rollback_to_snapshot($good) ---"
Show-Sql "ALTER TABLE $T EXECUTE rollback_to_snapshot($good);"
$rowsAfterRestore = Get-SqlScalar "SELECT count(*) FROM $T;"
Write-Log "Rows after restore: $rowsAfterRestore"

Write-Log "Snapshot history after restore:"
Show-Sql 'SELECT snapshot_id, committed_at, operation FROM lakekeeper.silver."partsupp$snapshots" ORDER BY committed_at;'

Write-Log ""
Write-Log "DONE"