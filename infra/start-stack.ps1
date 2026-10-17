# Starts the stack MinIO -> Postgres -> Lakekeeper -> Trino.
# Ports: MinIO 9000/9001, Postgres 55432, Lakekeeper 8181, Trino 18080.
# Run from the infra folder:  .\start-stack.ps1

Set-Location $PSScriptRoot

Write-Host "==> Checking Docker"
docker --version
docker info *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Docker daemon is not responding. Start Docker Desktop and try again." -ForegroundColor Red
    exit 1
}

Write-Host "==> Checking ports 9000/9001/55432/8181/18080"
$busy = Get-NetTCPConnection -State Listen -LocalPort 9000,9001,55432,8181,18080 -ErrorAction SilentlyContinue
if ($busy) {
    $busy | Format-Table -AutoSize
    Write-Host "Ports are busy. Free them and try again." -ForegroundColor Red
    exit 1
}
Write-Host "Ports are free"

# ---------- 1. MinIO (Silo) ----------
Write-Host "==> 1. MinIO"
docker rm -f lakehouse-minio 2>$null | Out-Null
docker run -d --name lakehouse-minio `
    -p 9000:9000 -p 9001:9001 `
    -e MINIO_ROOT_USER=minioadmin `
    -e MINIO_ROOT_PASSWORD=minioadmin `
    -v minio-data:/data `
    pgsty/silo:latest server /data --console-address ":9001"

for ($i = 0; $i -lt 30; $i++) {
    if (curl.exe -sf http://localhost:9000/minio/health/live) { break }
    Start-Sleep 1
}

Write-Host "Creating bucket warehouse"
docker run --rm --entrypoint /bin/sh --add-host host.docker.internal:host-gateway `
    pgsty/mc:latest -c "mc alias set m http://host.docker.internal:9000 minioadmin minioadmin && mc mb --ignore-existing m/warehouse"

# ---------- 2. Postgres (port 55432) ----------
Write-Host "==> 2. Postgres (port 55432)"
docker rm -f lakehouse-pg 2>$null | Out-Null
docker run -d --name lakehouse-pg `
    -e POSTGRES_PASSWORD=postgres `
    -p 55432:5432 `
    -v pg-data:/var/lib/postgresql/data `
    postgres:17

for ($i = 0; $i -lt 30; $i++) {
    docker exec lakehouse-pg pg_isready *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 1
}
docker exec lakehouse-pg pg_isready

# ---------- 3. Lakekeeper migrations ----------
Write-Host "==> 3. Lakekeeper migrations"
docker run --rm --add-host host.docker.internal:host-gateway `
    -e 'LAKEKEEPER__PG_ENCRYPTION_KEY=This-is-NOT-Secure!' `
    -e 'LAKEKEEPER__PG_DATABASE_URL_READ=postgresql://postgres:postgres@host.docker.internal:55432/postgres' `
    -e 'LAKEKEEPER__PG_DATABASE_URL_WRITE=postgresql://postgres:postgres@host.docker.internal:55432/postgres' `
    quay.io/lakekeeper/catalog:latest-main migrate

# ---------- 4. Lakekeeper ----------
Write-Host "==> 4. Lakekeeper"
docker rm -f lakekeeper 2>$null | Out-Null
docker run -d --name lakekeeper --add-host host.docker.internal:host-gateway `
    -e 'LAKEKEEPER__PG_ENCRYPTION_KEY=This-is-NOT-Secure!' `
    -e 'LAKEKEEPER__PG_DATABASE_URL_READ=postgresql://postgres:postgres@host.docker.internal:55432/postgres' `
    -e 'LAKEKEEPER__PG_DATABASE_URL_WRITE=postgresql://postgres:postgres@host.docker.internal:55432/postgres' `
    -p 8181:8181 `
    quay.io/lakekeeper/catalog:latest-main serve

for ($i = 0; $i -lt 30; $i++) {
    if (curl.exe -sf http://localhost:8181/health) { break }
    Start-Sleep 1
}
Write-Host "Lakekeeper health OK"

# ---------- 4.1 Bootstrap + warehouse demo ----------
Write-Host "==> 4.1 Bootstrap + warehouse demo"
curl.exe -s -X POST http://localhost:8181/management/v1/bootstrap `
    -H "Content-Type: application/json" `
    -d '{\"accept-terms-of-use\": true}'

curl.exe -s -X POST http://localhost:8181/management/v1/warehouse `
    -H "Content-Type: application/json" `
    -d '@create-warehouse.json'

# ---------- 5. Trino (port 18080) ----------
Write-Host "==> 5. Trino (port 18080)"
docker rm -f trino 2>$null | Out-Null
docker run -d --name trino `
    -p 18080:8080 `
    -v "${PWD}/catalog:/etc/trino/catalog" `
    trinodb/trino:476

for ($i = 0; $i -lt 60; $i++) {
    $info = curl.exe -sf http://localhost:18080/v1/info
    if ($info -and ($info -match '"starting":false')) { break }
    Start-Sleep 1
}
Write-Host "Trino is ready"
docker ps