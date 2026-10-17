SELECT 'part' AS tbl,
       count(*)                                     AS total_rows,
       count_if(partkey IS NULL)                    AS null_keys,
       count_if(brand IS NULL OR trim(brand) = '')  AS empty_brand,
       count_if(size IS NULL)                       AS null_size,
       count(*) - count(DISTINCT partkey)           AS duplicate_rows
FROM lakekeeper.bronze.part;

SELECT 'partsupp' AS tbl,
       count(*)                                      AS total_rows,
       count_if(partkey IS NULL OR suppkey IS NULL)  AS null_keys,
       count(*) - count(DISTINCT (partkey, suppkey)) AS duplicate_rows
FROM lakekeeper.bronze.partsupp;

SELECT 'supplier' AS tbl,
       count(*)                                     AS total_rows,
       count_if(suppkey IS NULL)                    AS null_keys,
       count(*) - count(DISTINCT suppkey)           AS duplicate_rows
FROM lakekeeper.bronze.supplier;

SELECT brand AS raw_brand, count(*) AS cnt
FROM lakekeeper.bronze.part
GROUP BY brand ORDER BY brand;

SELECT type AS raw_type, count(*) AS cnt
FROM lakekeeper.bronze.part
GROUP BY type ORDER BY type;

SELECT count(*) AS complaint_suppliers
FROM lakekeeper.bronze.supplier
WHERE comment LIKE '%Customer%Complaints%';