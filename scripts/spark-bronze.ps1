Set-Location (Split-Path -Parent $PSScriptRoot)

$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$log = Join-Path $logDir "spark-bronze.log"
if (Test-Path $log) { Remove-Item $log }

function Write-Log([string]$Text) {
    Write-Host $Text
    Add-Content -Path $log -Value $Text -Encoding UTF8
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

$image = "apache/spark:3.5.1"
docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Log "Image $image not found locally. Pulling..."
    docker pull $image
    if ($LASTEXITCODE -ne 0) {
        Write-Log "docker pull failed. Check network/DNS and retry: docker pull $image"
        exit 1
    }
}

$demoAbs = (Resolve-Path "spark/bronze_demo.py").Path

Write-Log "Starting Spark container..."

docker run --rm `
    --add-host host.docker.internal:host-gateway `
    -v "${demoAbs}:/opt/spark/work-dir/bronze_demo.py" `
    --entrypoint /bin/bash `
    $image --% -c "mkdir -p /tmp/ivy2/cache /tmp/ivy2/jars && /opt/spark/bin/spark-submit --conf spark.jars.ivy=/tmp/ivy2 --packages org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.5.2,org.apache.iceberg:iceberg-aws-bundle:1.5.2 --conf spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions --conf spark.sql.catalog.lakekeeper=org.apache.iceberg.spark.SparkCatalog --conf spark.sql.catalog.lakekeeper.type=rest --conf spark.sql.catalog.lakekeeper.uri=http://host.docker.internal:8181/catalog --conf spark.sql.catalog.lakekeeper.warehouse=demo --conf spark.sql.catalog.lakekeeper.io-impl=org.apache.iceberg.aws.s3.S3FileIO --conf spark.sql.catalog.lakekeeper.s3.endpoint=http://host.docker.internal:9000 --conf spark.sql.catalog.lakekeeper.s3.path-style-access=true --conf spark.sql.catalog.lakekeeper.s3.access-key-id=minioadmin --conf spark.sql.catalog.lakekeeper.s3.secret-access-key=minioadmin /opt/spark/work-dir/bronze_demo.py" 2>&1 |
    ForEach-Object {
        Write-Host $_
        Add-Content -Path $log -Value $_ -Encoding UTF8
    }

Write-Log "DONE"