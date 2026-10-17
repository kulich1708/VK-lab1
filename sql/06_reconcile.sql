WITH direct AS (
  SELECT p.brand, p.type, p.size,
         count(DISTINCT ps.suppkey) AS supplier_cnt
  FROM tpch.sf1.partsupp AS ps
  JOIN tpch.sf1.part     AS p ON p.partkey = ps.partkey
  WHERE p.brand <> 'Brand#45'
    AND p.type NOT LIKE 'MEDIUM POLISHED'
    AND p.size IN (49, 14, 23, 45, 19, 3, 36, 9)
    AND ps.suppkey NOT IN (
      SELECT suppkey FROM tpch.sf1.supplier
      WHERE comment LIKE '%Customer%Complaints%'
    )
  GROUP BY p.brand, p.type, p.size
),
gold AS (
  SELECT brand, type, size, supplier_cnt
  FROM lakekeeper.gold.parts_supplier_count
)
SELECT (SELECT count(*) FROM (SELECT * FROM direct EXCEPT SELECT * FROM gold)) AS direct_minus_gold,
       (SELECT count(*) FROM (SELECT * FROM gold EXCEPT SELECT * FROM direct)) AS gold_minus_direct,
       (SELECT count(*) FROM gold)   AS gold_rows,
       (SELECT count(*) FROM direct) AS direct_rows;