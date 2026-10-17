"""
Читает Bronze-слой (part / partsupp / supplier) через Lakekeeper из Spark,
сверяет счётчики с Trino и прогоняет Q16 на Bronze.
Запускается из scripts/spark-bronze.ps1.
"""
from pyspark.sql import SparkSession
import time

spark = (SparkSession.builder
    .appName("p1-q16-bronze")
    .config("spark.sql.extensions",
            "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
    .config("spark.sql.catalog.lakekeeper",
            "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.lakekeeper.type", "rest")
    .config("spark.sql.catalog.lakekeeper.uri",
            "http://host.docker.internal:8181/catalog")
    .config("spark.sql.catalog.lakekeeper.warehouse", "demo")
    .config("spark.sql.catalog.lakekeeper.io-impl",
            "org.apache.iceberg.aws.s3.S3FileIO")
    .config("spark.sql.catalog.lakekeeper.s3.endpoint",
            "http://host.docker.internal:9000")
    .config("spark.sql.catalog.lakekeeper.s3.path-style-access", "true")
    .config("spark.sql.catalog.lakekeeper.s3.access-key-id", "minioadmin")
    .config("spark.sql.catalog.lakekeeper.s3.secret-access-key", "minioadmin")
    .getOrCreate())

spark.sparkContext.setLogLevel("WARN")

print("=== Таблицы в lakekeeper.bronze ===")
spark.sql("SHOW TABLES IN lakekeeper.bronze").show(truncate=False)

for t in ("part", "partsupp", "supplier"):
    rows = spark.table(f"lakekeeper.bronze.{t}").count()
    print(f"lakekeeper.bronze.{t}: {rows} строк")

print("=== Q16 на Bronze (то же, что считается на Gold) ===")
q16 = """
SELECT p.brand, p.type, p.size,
       count(DISTINCT ps.suppkey) AS supplier_cnt
FROM lakekeeper.bronze.partsupp ps
JOIN lakekeeper.bronze.part     p ON p.partkey = ps.partkey
WHERE p.brand <> 'BRAND#45'
  AND p.type NOT LIKE 'MEDIUM POLISHED%'
  AND p.size IN (49, 14, 23, 45, 19, 3, 36, 9)
  AND ps.suppkey NOT IN (
    SELECT suppkey FROM lakekeeper.bronze.supplier
    WHERE comment LIKE '%Customer%Complaints%'
  )
GROUP BY p.brand, p.type, p.size
ORDER BY supplier_cnt DESC, p.brand, p.type, p.size
"""
spark.sql(q16).show(20, truncate=False)

for run in (1, 2, 3):
    t0 = time.time()
    spark.sql(q16).collect()
    print(f"Q16 на Bronze, прогон {run}: {time.time() - t0:.2f} с")

spark.stop()