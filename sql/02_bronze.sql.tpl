SET SESSION lakekeeper.compression_codec = '__CODEC__';

DROP TABLE IF EXISTS lakekeeper.bronze.part;
CREATE TABLE lakekeeper.bronze.part WITH (format = 'PARQUET') AS
SELECT partkey, brand, type, size, comment
FROM tpch.sf1.part;

DROP TABLE IF EXISTS lakekeeper.bronze.partsupp;
CREATE TABLE lakekeeper.bronze.partsupp WITH (format = 'PARQUET') AS
SELECT partkey, suppkey
FROM tpch.sf1.partsupp;

DROP TABLE IF EXISTS lakekeeper.bronze.supplier;
CREATE TABLE lakekeeper.bronze.supplier WITH (format = 'PARQUET') AS
SELECT suppkey, comment
FROM tpch.sf1.supplier;