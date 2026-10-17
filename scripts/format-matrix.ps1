Set-Location (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$logFile = Join-Path $logDir "format-matrix.log"
if (Test-Path $logFile) { Remove-Item $logFile }
Start-Transcript -Path $logFile -Force | Out-Null

try {
    foreach ($fmt in @("PARQUET", "ORC")) {
        foreach ($codec in @("NONE", "SNAPPY", "GZIP", "ZSTD")) {
            $schema = "fmt_$($fmt.ToLower())_$($codec.ToLower())"
            $tag = "p1fmt_$($fmt)_$($codec)"
            Write-Host ""
            Write-Host ("#" * 10 + "  $fmt / $codec (схема $schema)  " + "#" * 10) -ForegroundColor Yellow

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
            $tmp = Join-Path $logDir "_fmt_${schema}.sql"
            Set-Content -Path $tmp -Value $writeSql -Encoding UTF8

            $t = Measure-Command {
                Get-Content -Raw -Encoding UTF8 $tmp | docker exec -i trino trino --output-format ALIGNED | Out-Null
            }
            Write-Host "Запись ($fmt/$codec): $([math]::Round($t.TotalSeconds, 3)) с"

            # Размер + файлы
            docker exec trino trino --output-format ALIGNED --execute "
SELECT '$fmt' AS format, '$codec' AS codec, sum(files) AS files, sum(bytes) AS bytes,
       round(CAST(sum(bytes) AS double)/1048576, 4) AS size_mb
FROM (
  SELECT count(*) AS files, sum(file_size_in_bytes) AS bytes FROM lakekeeper.$schema.`"part`$files`"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.$schema.`"partsupp`$files`"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.$schema.`"supplier`$files`"
)
"

            # Кодек в свойствах
            docker exec trino trino --output-format ALIGNED --execute "
SELECT key, value FROM lakekeeper.$schema.`"part`$properties`"
WHERE key LIKE 'write.%compression-codec' OR key = 'write.format.default'
"

            # 3 прогона Q16
            for ($run = 1; $run -le 3; $run++) {
                $sql = @"
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
                docker exec trino trino --output-format ALIGNED --execute $sql | Out-Null
            }

            # Время из системной таблицы
            docker exec trino trino --output-format ALIGNED --execute "
SELECT regexp_extract(query, 'p1fmt_[A-Z]+_[A-Z]+_run[0-9]') AS tag,
       state,
       date_diff('millisecond', started, `"end`") AS exec_ms
FROM system.runtime.queries
WHERE query LIKE '%${tag}_run%'
  AND query NOT LIKE '%system.runtime.queries%'
ORDER BY created
"
        }
    }
    Write-Host "ГОТОВО" -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
}