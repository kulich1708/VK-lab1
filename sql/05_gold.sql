SET SESSION lakekeeper.compression_codec = 'ZSTD';

DROP TABLE IF EXISTS lakekeeper.gold.parts_supplier_count;
CREATE TABLE lakekeeper.gold.parts_supplier_count WITH (format = 'PARQUET') AS
SELECT p.brand,
       p.type,
       p.size,
       count(DISTINCT ps.suppkey) AS supplier_cnt
FROM lakekeeper.silver.partsupp AS ps
JOIN lakekeeper.silver.part     AS p ON p.partkey = ps.partkey
JOIN lakekeeper.silver.supplier AS s ON s.suppkey = ps.suppkey
WHERE p.brand <> 'BRAND#45'
  AND p.type NOT LIKE 'MEDIUM POLISHED%'
  AND p.size IN (49, 14, 23, 45, 19, 3, 36, 9)
  AND s.has_complaint = false
GROUP BY p.brand, p.type, p.size
ORDER BY supplier_cnt DESC, p.brand, p.type, p.size;

SELECT * FROM lakekeeper.gold.parts_supplier_count
ORDER BY supplier_cnt DESC, brand, type, size;