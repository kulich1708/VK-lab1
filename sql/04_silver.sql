SET SESSION lakekeeper.compression_codec = 'ZSTD';

DROP TABLE IF EXISTS lakekeeper.silver.part;
CREATE TABLE lakekeeper.silver.part WITH (format = 'PARQUET') AS
SELECT partkey,
       upper(trim(brand)) AS brand,
       upper(trim(type))  AS type,
       size
FROM lakekeeper.bronze.part
WHERE partkey IS NOT NULL
  AND brand IS NOT NULL AND trim(brand) <> ''
  AND size  IS NOT NULL;

DROP TABLE IF EXISTS lakekeeper.silver.supplier;
CREATE TABLE lakekeeper.silver.supplier WITH (format = 'PARQUET') AS
SELECT suppkey,
       comment,
       comment LIKE '%Customer%Complaints%' AS has_complaint
FROM lakekeeper.bronze.supplier
WHERE suppkey IS NOT NULL;

DROP TABLE IF EXISTS lakekeeper.silver.partsupp;
CREATE TABLE lakekeeper.silver.partsupp WITH (format = 'PARQUET') AS
SELECT partkey, suppkey
FROM (
    SELECT partkey, suppkey,
           row_number() OVER (PARTITION BY partkey, suppkey ORDER BY partkey) AS rn
    FROM lakekeeper.bronze.partsupp
    WHERE partkey IS NOT NULL AND suppkey IS NOT NULL
)
WHERE rn = 1;