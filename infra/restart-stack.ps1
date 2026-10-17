# Поднимает уже созданные контейнеры (данные сохраняются).
# Запускать из папки infra:  .\restart-stack.ps1

Write-Host "==> Состояние"
docker ps -a --filter "name=lakehouse-pg" --filter "name=lakekeeper" --filter "name=trino" --filter "name=lakehouse-minio"

Write-Host "==> Старт MinIO"
docker start lakehouse-minio | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    if (curl.exe -sf http://localhost:9000/minio/health/live) { break }
    Start-Sleep 1
}
Write-Host "MinIO OK"

Write-Host "==> Старт Postgres"
docker start lakehouse-pg | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    docker exec lakehouse-pg pg_isready *> $null
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep 1
}
docker exec lakehouse-pg pg_isready

Write-Host "==> Старт Lakekeeper"
docker start lakekeeper | Out-Null
for ($i = 0; $i -lt 30; $i++) {
    if (curl.exe -sf http://localhost:8181/health) { break }
    Start-Sleep 1
}
Write-Host "Lakekeeper OK"

Write-Host "==> Старт Trino"
docker start trino | Out-Null
for ($i = 0; $i -lt 60; $i++) {
    $info = curl.exe -sf http://localhost:18080/v1/info
    if ($info -and ($info -match '"starting":false')) { break }
    Start-Sleep 1
}
Write-Host "Trino OK"

docker ps