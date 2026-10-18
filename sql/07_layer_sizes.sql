WITH sizes AS (
  SELECT 'bronze.part' AS tbl,
         (SELECT count(*) FROM lakekeeper.bronze.part) AS rows_cnt,
         count(*) AS files, sum(file_size_in_bytes) AS bytes
  FROM lakekeeper.bronze."part$files"
  UNION ALL SELECT 'bronze.partsupp',
         (SELECT count(*) FROM lakekeeper.bronze.partsupp), count(*), sum(file_size_in_bytes)
  FROM lakekeeper.bronze."partsupp$files"
  UNION ALL SELECT 'bronze.supplier',
         (SELECT count(*) FROM lakekeeper.bronze.supplier), count(*), sum(file_size_in_bytes)
  FROM lakekeeper.bronze."supplier$files"
  UNION ALL SELECT 'silver.part',
         (SELECT count(*) FROM lakekeeper.silver.part), count(*), sum(file_size_in_bytes)
  FROM lakekeeper.silver."part$files"
  UNION ALL SELECT 'silver.partsupp',
         (SELECT count(*) FROM lakekeeper.silver.partsupp), count(*), sum(file_size_in_bytes)
  FROM lakekeeper.silver."partsupp$files"
  UNION ALL SELECT 'silver.supplier',
         (SELECT count(*) FROM lakekeeper.silver.supplier), count(*), sum(file_size_in_bytes)
  FROM lakekeeper.silver."supplier$files"
  UNION ALL SELECT 'gold.parts_supplier_count',
         (SELECT count(*) FROM lakekeeper.gold.parts_supplier_count), count(*), sum(file_size_in_bytes)
  FROM lakekeeper.gold."parts_supplier_count$files"
),
codecs AS (
  SELECT 'bronze.part' AS tbl, value AS codec FROM lakekeeper.bronze."part$properties"             WHERE key = 'write.parquet.compression-codec'
  UNION ALL SELECT 'bronze.partsupp', value FROM lakekeeper.bronze."partsupp$properties"           WHERE key = 'write.parquet.compression-codec'
  UNION ALL SELECT 'bronze.supplier', value FROM lakekeeper.bronze."supplier$properties"           WHERE key = 'write.parquet.compression-codec'
  UNION ALL SELECT 'silver.part',     value FROM lakekeeper.silver."part$properties"               WHERE key = 'write.parquet.compression-codec'
  UNION ALL SELECT 'silver.partsupp', value FROM lakekeeper.silver."partsupp$properties"           WHERE key = 'write.parquet.compression-codec'
  UNION ALL SELECT 'silver.supplier', value FROM lakekeeper.silver."supplier$properties"           WHERE key = 'write.parquet.compression-codec'
  UNION ALL SELECT 'gold.parts_supplier_count', value FROM lakekeeper.gold."parts_supplier_count$properties" WHERE key = 'write.parquet.compression-codec'
)
SELECT s.tbl, s.rows_cnt, s.files, round(CAST(s.bytes AS double)/1048576, 4) AS size_mb, c.codec
FROM sizes s
LEFT JOIN codecs c ON c.tbl = s.tbl
ORDER BY s.tbl;