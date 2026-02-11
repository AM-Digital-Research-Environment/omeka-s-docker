# MySQL Tuning Parameters

The `db` service in `docker-compose.yml` passes InnoDB and server parameters via `command:`. This document explains each setting and why it was chosen for an Omeka S workload.

## InnoDB Settings

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `innodb-buffer-pool-size` | 512M | Main memory area for caching table data and indexes. Sized to hold the working set of a typical Omeka S database (metadata, resource values, search indexes). Increase if the database grows beyond a few hundred thousand items. |
| `innodb-buffer-pool-instances` | 2 | Splits the buffer pool into separate regions to reduce lock contention on multi-core systems. Two instances is appropriate for the 512M pool size. |
| `innodb-log-buffer-size` | 32M | In-memory buffer for redo log writes. Larger buffer reduces disk I/O during bulk imports (CSVImport, sideload). |
| `innodb-redo-log-capacity` | 256M | Total size of the redo log on disk (MySQL 8.0.30+ unified parameter). Larger logs allow more write batching before checkpoint flushes, improving import throughput. |
| `innodb-write-io-threads` | 4 | Background threads for writing dirty pages to disk. Four threads is a reasonable default for SSD-backed storage. |
| `innodb-read-io-threads` | 4 | Background threads for read-ahead operations. Matches write threads for balanced I/O. |
| `innodb-flush-method` | O_DIRECT | Bypasses the OS page cache for data files, avoiding double-buffering (InnoDB has its own buffer pool). Reduces memory pressure on the host. |
| `innodb-flush-log-at-trx-commit` | 2 | Flushes the log buffer to the OS once per second rather than on every commit. Provides a significant write performance boost at the cost of losing up to one second of transactions on OS crash (container crash is safe because the log buffer is still written). Set to `1` if you need strict ACID guarantees. |
| `innodb-file-per-table` | 1 | Stores each table in its own `.ibd` file. Makes it possible to reclaim disk space after dropping tables or running `OPTIMIZE TABLE`. |

## Server Settings

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `max-connections` | 250 | Maximum simultaneous client connections. Sized for the PHP-FPM pool (default 10 children) plus headroom for admin connections, cron jobs, and monitoring. |
| `table-open-cache` | 400 | Number of open table descriptors to cache. Omeka S uses many tables (core + modules), so a larger cache reduces file-open overhead. |
| `tmp-table-size` | 32M | Maximum size of in-memory temporary tables before they spill to disk. Helps complex Omeka S queries (faceted browse, advanced search) stay in memory. |
| `max-heap-table-size` | 32M | Must match `tmp-table-size` for the in-memory limit to take effect. |
| `sort-buffer-size` | 2M | Per-session buffer for ORDER BY operations. Slightly above the 256K default to improve sorting of large result sets without over-allocating per connection. |
| `join-buffer-size` | 2M | Per-session buffer for joins that cannot use indexes. Helps with module queries that join across resource values. |
| `thread-cache-size` | 8 | Number of threads to keep cached for reuse. Avoids thread creation overhead for the relatively steady connection pattern from PHP-FPM. |

## When to Adjust

- **Large collections (100k+ items):** Increase `innodb-buffer-pool-size` to 1G or more, and raise `innodb-buffer-pool-instances` to 4.
- **Heavy concurrent usage:** Increase `max-connections` and corresponding PHP-FPM `pm.max_children`.
- **Bulk imports:** Temporarily set `innodb-flush-log-at-trx-commit=0` for maximum import speed, then restore to `2` afterward.
- **Limited host memory:** Reduce `innodb-buffer-pool-size` and `apc.shm_size` proportionally. Keep the buffer pool at roughly 50-70% of available container memory.
