Set-Location (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$logFile = Join-Path $logDir "codec-benchmark.log"
if (Test-Path $logFile) { Remove-Item $logFile }
Start-Transcript -Path $logFile -Force | Out-Null

try {
    Get-Content -Raw -Encoding UTF8 "sql/01_schemas.sql" | docker exec -i trino trino --output-format ALIGNED | Out-Null

    foreach ($codec in @("GZIP", "ZSTD")) {
        Write-Host ""
        Write-Host ("#" * 18 + "  BRONZE: $codec  " + "#" * 18) -ForegroundColor Yellow

        $bronzeSql = (Get-Content -Raw -Encoding UTF8 "sql/02_bronze.sql.tpl") -replace "__CODEC__", $codec
        $tmp = Join-Path $logDir "_bronze_$codec.sql"
        Set-Content -Path $tmp -Value $bronzeSql -Encoding UTF8

        $t = Measure-Command {
            Get-Content -Raw -Encoding UTF8 $tmp | docker exec -i trino trino --output-format ALIGNED | Out-Null
        }
        Write-Host "Bronze write ($codec): $([math]::Round($t.TotalSeconds, 3)) s"

        # Bronze size
        docker exec trino trino --output-format ALIGNED --execute "
SELECT '$codec' AS codec, sum(files) AS files, sum(bytes) AS bytes,
       round(CAST(sum(bytes) AS double)/1048576, 4) AS size_mb
FROM (
  SELECT count(*) AS files, sum(file_size_in_bytes) AS bytes FROM lakekeeper.bronze.`"part`$files`"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.bronze.`"partsupp`$files`"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.bronze.`"supplier`$files`"
)
"

        # 3 runs of Q16
        for ($run = 1; $run -le 3; $run++) {
            $sql = @"
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
                docker exec trino trino --output-format ALIGNED --execute $sql | Out-Null
            }
            Write-Host "Q16 on Bronze ($codec), run ${run}: $([math]::Round($t.TotalSeconds, 3)) s"
        }
    }

    Write-Host ""
    Write-Host "#### Timings from system.runtime.queries ####" -ForegroundColor Cyan
    docker exec trino trino --output-format ALIGNED --execute '
SELECT regexp_extract(query, ''p1q16_[A-Z]+_run[0-9]'') AS tag,
       state,
       date_diff(''millisecond'', started, "end") AS exec_ms
FROM system.runtime.queries
WHERE query LIKE ''%p1q16_%''
  AND query NOT LIKE ''%system.runtime.queries%''
ORDER BY created
'
    Write-Host "DONE" -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
}