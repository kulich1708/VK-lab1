# Запускает Spark 3.5.1 в Docker и читает Bronze через Lakekeeper.
# Запуск:  .\scripts\spark-bronze.ps1

Set-Location (Split-Path -Parent $PSScriptRoot)
$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$logFile = Join-Path $logDir "spark-bronze.log"
if (Test-Path $logFile) { Remove-Item $logFile }
Start-Transcript -Path $logFile -Force | Out-Null

try {
    $image = "apache/spark:3.5.1"
    $demoAbs = (Resolve-Path "spark/bronze_demo.py").Path

    $inner = @"
mkdir -p /tmp/ivy2/cache /tmp/ivy2/jars
/opt/spark/bin/spark-submit \
  --conf spark.jars.ivy=/tmp/ivy2 \
  --packages org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.5.2,org.apache.iceberg:iceberg-aws-bundle:1.5.2 \
  --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions \
  --conf spark.sql.catalog.lakekeeper=org.apache.iceberg.spark.SparkCatalog \
  --conf spark.sql.catalog.lakekeeper.type=rest \
  --conf spark.sql.catalog.lakekeeper.uri=http://host.docker.internal:8181/catalog \
  --conf spark.sql.catalog.lakekeeper.warehouse=demo \
  --conf spark.sql.catalog.lakekeeper.io-impl=org.apache.iceberg.aws.s3.S3FileIO \
  --conf spark.sql.catalog.lakekeeper.s3.endpoint=http://host.docker.internal:9000 \
  --conf spark.sql.catalog.lakekeeper.s3.path-style-access=true \
  --conf spark.sql.catalog.lakekeeper.s3.access-key-id=minioadmin \
  --conf spark.sql.catalog.lakekeeper.s3.secret-access-key=minioadmin \
  /opt/spark/work-dir/bronze_demo.py
"@

    docker run --rm `
        --add-host host.docker.internal:host-gateway `
        -v "${demoAbs}:/opt/spark/work-dir/bronze_demo.py" `
        --entrypoint /bin/bash $image -c $inner

    Write-Host "ГОТОВО" -ForegroundColor Green
}
finally {
    Stop-Transcript | Out-Null
}