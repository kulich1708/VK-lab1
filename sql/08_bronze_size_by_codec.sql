SELECT '__CODEC__' AS codec, sum(files) AS files, sum(bytes) AS bytes,
       round(CAST(sum(bytes) AS double)/1048576, 4) AS size_mb
FROM (
  SELECT count(*) AS files, sum(file_size_in_bytes) AS bytes FROM lakekeeper.bronze."part$files"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.bronze."partsupp$files"
  UNION ALL
  SELECT count(*), sum(file_size_in_bytes) FROM lakekeeper.bronze."supplier$files"
);