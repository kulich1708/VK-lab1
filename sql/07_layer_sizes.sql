SELECT 'bronze.part' AS tbl,
       (SELECT count(*) FROM lakekeeper.bronze.part) AS rows_cnt,
       count(*) AS files,
       sum(file_size_in_bytes) AS bytes,
       round(CAST(sum(file_size_in_bytes) AS double)/1048576, 4) AS size_mb
FROM lakekeeper.bronze."part$files"
UNION ALL SELECT 'bronze.partsupp',
       (SELECT count(*) FROM lakekeeper.bronze.partsupp), count(*), sum(file_size_in_bytes),
       round(CAST(sum(file_size_in_bytes) AS double)/1048576, 4) FROM lakekeeper.bronze."partsupp$files"
UNION ALL SELECT 'bronze.supplier',
       (SELECT count(*) FROM lakekeeper.bronze.supplier), count(*), sum(file_size_in_bytes),
       round(CAST(sum(file_size_in_bytes) AS double)/1048576, 4) FROM lakekeeper.bronze."supplier$files"
UNION ALL SELECT 'silver.part',
       (SELECT count(*) FROM lakekeeper.silver.part), count(*), sum(file_size_in_bytes),
       round(CAST(sum(file_size_in_bytes) AS double)/1048576, 4) FROM lakekeeper.silver."part$files"
UNION ALL SELECT 'silver.partsupp',
       (SELECT count(*) FROM lakekeeper.silver.partsupp), count(*), sum(file_size_in_bytes),
       round(CAST(sum(file_size_in_bytes) AS double)/1048576, 4) FROM lakekeeper.silver."partsupp$files"
UNION ALL SELECT 'silver.supplier',
       (SELECT count(*) FROM lakekeeper.silver.supplier), count(*), sum(file_size_in_bytes),
       round(CAST(sum(file_size_in_bytes) AS double)/1048576, 4) FROM lakekeeper.silver."supplier$files"
UNION ALL SELECT 'gold.parts_supplier_count',
       (SELECT count(*) FROM lakekeeper.gold.parts_supplier_count), count(*), sum(file_size_in_bytes),
       round(CAST(sum(file_size_in_bytes) AS double)/1048576, 4) FROM lakekeeper.gold."parts_supplier_count$files";