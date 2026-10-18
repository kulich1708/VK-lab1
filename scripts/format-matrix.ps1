Set-Location (Split-Path -Parent $PSScriptRoot)

$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$log = Join-Path $logDir "format-matrix.log"
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

foreach ($fmt in @("PARQUET", "ORC")) {
    foreach ($codec in @("NONE", "SNAPPY", "GZIP", "ZSTD")) {
        $schema = "fmt_$($fmt.ToLower())_$($codec.ToLower())"
        $tag    = "p1fmt_$($fmt)_$($codec)"

        Write-Log ""
        Write-Log ("#" * 10 + "  $fmt / $codec (schema $schema)  " + "#" * 10)

        $writeSql = @"
SET SESSION lakekeeper.compression_codec = '$codec';
CREATE SCHEMA IF NOT EXISTS lakekeeper.$schema;
DROP TABLE IF EXISTS lakekeeper.$schema.part;
CREATE TABLE lakekeeper.$schema.part WITH (format = '$fmt') AS
SELECT partkey, upper(trim(brand)) AS brand, upper(trim(type)) AS type, size
FROM tpch.sf1.part;
DROP TABLE IF EXISTS lakekeeper.$schema.partsupp;
CREATE TABLE lakekeeper.$schema.partsupp WITH (format = '$fmt') AS
SELECT partkey, suppkey FROM tpch.sf1.partsupp;
DROP TABLE IF EXISTS lakekeeper.$schema.supplier;
CREATE TABLE lakekeeper.$schema.supplier WITH (format = '$fmt') AS
SELECT suppkey, comment, comment LIKE '%Customer%Complaints%' AS has_complaint
FROM tpch.sf1.supplier;
"@
        $t = Measure-Command {
            $writeSql | docker exec -i trino trino --no-progress --output-format ALIGNED 2>&1 | Out-Null
        }
        Write-Log "Write ($fmt/$codec): $([math]::Round($t.TotalSeconds, 3)) s"

        Write-Log "Size ($fmt/$codec):"
        Show-Sql @"
SELECT '$fmt' AS format, '$codec' AS codec, sum(files) AS files, sum(bytes) AS bytes,
       round(CAST(sum(bytes) AS double)/1048576, 4) AS size_mb
FROM (
  SELECT count(*) AS files, sum(file_size_in_bytes) AS bytes FROM lakekeeper.$schema."part`$files"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.$schema."partsupp`$files"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.$schema."supplier`$files"
)
"@

        Write-Log "Codec in properties ($fmt/$codec):"
        Show-Sql @"
SELECT key, value FROM lakekeeper.$schema."part`$properties"
WHERE key LIKE 'write.%compression-codec' OR key = 'write.format.default'
"@

        for ($run = 1; $run -le 3; $run++) {
            $q = @"
/* ${tag}_run${run} */
SELECT p.brand, p.type, p.size, count(DISTINCT ps.suppkey) AS supplier_cnt
FROM lakekeeper.$schema.partsupp AS ps
JOIN lakekeeper.$schema.part     AS p ON p.partkey = ps.partkey
WHERE p.brand <> 'BRAND#45'
  AND p.type NOT LIKE 'MEDIUM POLISHED%'
  AND p.size IN (49, 14, 23, 45, 19, 3, 36, 9)
  AND ps.suppkey NOT IN (
    SELECT suppkey FROM lakekeeper.$schema.supplier
    WHERE comment LIKE '%Customer%Complaints%'
  )
GROUP BY p.brand, p.type, p.size
ORDER BY supplier_cnt DESC, p.brand, p.type, p.size
"@
            $t = Measure-Command {
                $q | docker exec -i trino trino --no-progress --output-format ALIGNED 2>&1 | Out-Null
            }
            Write-Log "Q16 ($fmt/$codec), run ${run}: $([math]::Round($t.TotalSeconds, 3)) s"
        }

        Write-Log "Timings ($fmt/$codec):"
        Show-Sql @"
SELECT regexp_extract(query, 'p1fmt_[A-Z]+_[A-Z]+_run[0-9]') AS tag,
       state, date_diff('millisecond', started, "end") AS exec_ms
FROM system.runtime.queries
WHERE query LIKE '%${tag}_run%'
  AND query NOT LIKE '%system.runtime.queries%'
ORDER BY created
"@
    }
}

Write-Log "DONE"