param([string]$Codec = "ZSTD")

Set-Location (Split-Path -Parent $PSScriptRoot)

$logDir = Join-Path (Get-Location) "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

$log = Join-Path $logDir "build-medallion.log"
if (Test-Path $log) { Remove-Item $log }

function Write-Log([string]$Text) {
    Write-Host $Text
    Add-Content -Path $log -Value $Text -Encoding UTF8
}

function Run-SqlFile([string]$Path) {
    $out = Get-Content -Raw -Encoding UTF8 $Path |
        docker exec -i trino trino --output-format ALIGNED
    foreach ($line in $out) {
        Write-Host $line
        Add-Content -Path $log -Value $line -Encoding UTF8
    }
}
$JLineOpt = "-Dorg.jline.terminal.dumb=true"

function Run-Sql([string]$Sql) {
    $out = docker exec -e "JAVA_TOOL_OPTIONS=$JLineOpt" trino trino --no-progress --output-format ALIGNED --execute $Sql
    foreach ($line in $out) {
        Write-Host $line
        Add-Content -Path $log -Value $line -Encoding UTF8
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
    docker exec -i trino trino --output-format ALIGNED | Out-Null

$bronzeSql = (Get-Content -Raw -Encoding UTF8 "sql/02_bronze.sql.tpl") -replace "__CODEC__", $Codec
$bronzeTmp = Join-Path $logDir "_bronze_rendered.sql"
Set-Content -Path $bronzeTmp -Value $bronzeSql -Encoding UTF8

$t = Measure-Command {
    Get-Content -Raw -Encoding UTF8 $bronzeTmp |
        docker exec -i trino trino --output-format ALIGNED | Out-Null
}
Write-Log "Bronze write: $([math]::Round($t.TotalSeconds, 3)) s"

$t = Measure-Command {
    Get-Content -Raw -Encoding UTF8 "sql/04_silver.sql" |
        docker exec -i trino trino --output-format ALIGNED | Out-Null
}
Write-Log "Silver write: $([math]::Round($t.TotalSeconds, 3)) s"

$t = Measure-Command {
    Get-Content -Raw -Encoding UTF8 "sql/05_gold.sql" |
        docker exec -i trino trino --output-format ALIGNED | Out-Null
}
Write-Log "Gold write: $([math]::Round($t.TotalSeconds, 3)) s"

Write-Log "Reconcile Gold vs Q16 directly (expect 0 0 N N):"
Run-SqlFile "sql/06_reconcile.sql"

Write-Log "Layers (rows, files, MB, codec):"
Run-SqlFile "sql/07_layer_sizes.sql"

Write-Log "DONE"