Set-Location (Split-Path -Parent $PSScriptRoot)

$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$log = Join-Path $logDir "codec-benchmark.log"

try {
    if (Test-Path $log) { Clear-Content -Path $log -ErrorAction Stop }
    else { New-Item -ItemType File -Path $log | Out-Null }
} catch {
    Write-Host "Cannot open $log (opened in another app?). Close it and retry." -ForegroundColor Red
    exit 1
}

function Write-Log([string]$Text) {
    Write-Host $Text
    Add-Content -Path $log -Value $Text -Encoding UTF8
}

function Invoke-SqlStdin([string]$SqlText) {
    $out = $SqlText | docker exec -i trino trino --no-progress --output-format ALIGNED 2>&1
    foreach ($line in $out) {
        $t = "$line"
        if ($t -match 'WARNING: Unable to create a system terminal') { continue }
        if ($t -match 'org\.jline') { continue }
        Write-Host $t
        Add-Content -Path $log -Value $t -Encoding UTF8
    }
}

foreach ($c in @("lakehouse-minio", "lakehouse-pg", "lakekeeper", "trino")) {
    $running = docker inspect -f '{{.State.Running}}' $c 2>$null
    if ($running -ne "true") {
        Write-Log "Container $c is not running. Run .\infra\restart-stack.ps1 first."
        exit 1
    }
}
$info = curl.exe -sf http://localhost:18080/v1/info
if (-not ($info -match '"starting":false')) {
    Write-Log "Trino is still starting, wait and retry."
    exit 1
}
Write-Log "Stack is healthy"

Get-Content -Raw -Encoding UTF8 "sql/01_schemas.sql" |
    docker exec -i trino trino --no-progress --output-format ALIGNED 2>&1 | Out-Null

foreach ($codec in @("GZIP", "ZSTD")) {

    Write-Log ""
    Write-Log ("#" * 18 + "  BRONZE: $codec  " + "#" * 18)

    $bronzeSql = (Get-Content -Raw -Encoding UTF8 "sql/02_bronze.sql.tpl") -replace "__CODEC__", $codec
    $tmp = Join-Path $logDir "_bronze_$codec.sql"
    Set-Content -Path $tmp -Value $bronzeSql -Encoding UTF8

    $t = Measure-Command {
        Get-Content -Raw -Encoding UTF8 $tmp |
            docker exec -i trino trino --no-progress --output-format ALIGNED 2>&1 | Out-Null
    }
    Write-Log "Bronze write ($codec): $([math]::Round($t.TotalSeconds, 3)) s"

    Write-Log "Bronze size ($codec):"
    $sizeSql = (Get-Content -Raw -Encoding UTF8 "sql/08_bronze_size_by_codec.sql") -replace "__CODEC__", $codec
    Invoke-SqlStdin $sizeSql

    for ($run = 1; $run -le 3; $run++) {
        $q = @"
/* p1q16_${codec}_run${run} */
SELECT p.brand, p.type, p.size, count(DISTINCT ps.suppkey) AS supplier_cnt
FROM lakekeeper.bronze.partsupp AS ps
JOIN lakekeeper.bronze.part     AS p ON p.partkey = ps.partkey
WHERE p.brand <> 'BRAND#45'
  AND p.type NOT LIKE 'MEDIUM POLISHED%'
  AND p.size IN (49, 14, 23, 45, 19, 3, 36, 9)
  AND ps.suppkey NOT IN (
    SELECT suppkey FROM lakekeeper.bronze.supplier
    WHERE comment LIKE '%Customer%Complaints%'
  )
GROUP BY p.brand, p.type, p.size
ORDER BY supplier_cnt DESC, p.brand, p.type, p.size
"@
        $t = Measure-Command {
            $q | docker exec -i trino trino --no-progress --output-format ALIGNED 2>&1 | Out-Null
        }
        Write-Log "Q16 on Bronze ($codec), run ${run}: $([math]::Round($t.TotalSeconds, 3)) s"
    }
}

Write-Log ""
Write-Log "#### Timings from system.runtime.queries ####"
$timingsSql = @'
SELECT regexp_extract(query, 'p1q16_[A-Z]+_run[0-9]') AS tag,
       state,
       date_diff('millisecond', started, "end") AS exec_ms
FROM system.runtime.queries
WHERE query LIKE '%p1q16_%'
  AND query NOT LIKE '%system.runtime.queries%'
ORDER BY created
'@
Invoke-SqlStdin $timingsSql

Write-Log "DONE"