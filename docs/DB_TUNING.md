# MySQL Tuning Parameters

The `db` service in `docker-compose.yml` passes InnoDB and server parameters via `command:`. This document explains each setting and why it was chosen for an Omeka S workload.

## InnoDB Settings

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `innodb-buffer-pool-size` | 512M | Main memory area for caching table data and indexes. Sized to hold the working set of a typical Omeka S database (metadata, resource values, search indexes). Increase if the database grows beyond a few hundred thousand items. |
| `innodb-log-buffer-size` | 32M | In-memory buffer for redo log writes. Larger buffer reduces disk I/O during bulk imports (CSVImport, sideload). |
| `innodb-redo-log-capacity` | 256M | Total size of the redo log on disk (MySQL 8.0.30+ unified parameter). Larger logs allow more write batching before checkpoint flushes, improving import throughput. |
| `innodb-write-io-threads` | 4 | Background threads for writing dirty pages to disk. Four threads is a reasonable default for SSD-backed storage. |
| `innodb-read-io-threads` | 4 | Background threads for read-ahead operations. Matches write threads for balanced I/O. |
| `innodb-flush-method` | O_DIRECT | Bypasses the OS page cache for data files, avoiding double-buffering (InnoDB has its own buffer pool). Reduces memory pressure on the host. |
| `innodb-flush-log-at-trx-commit` | 1 | Writes and flushes redo on each commit to protect committed catalog edits against host failure, assuming storage honors flush requests. Value `2` writes on commit but flushes periodically; it can lose recent committed changes on host failure. Measure before trading durability for throughput. |
| `innodb-file-per-table` | 1 | Stores each table in its own `.ibd` file. Makes it possible to reclaim disk space after dropping tables or running `OPTIMIZE TABLE`. |

> `innodb-buffer-pool-instances` is intentionally **not set**. MySQL recommends at least ~1 GiB of buffer pool per instance; splitting a 512M pool into multiple instances just shrinks each below that threshold for no lock-contention benefit at this scale. MySQL therefore uses a single instance automatically. Set it explicitly only if you first raise `innodb-buffer-pool-size` to 1G+ (see *When to Adjust*).

## Server Settings

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `max-connections` | 50 | Maximum simultaneous client connections. Each PHP-FPM worker holds at most one (default 5 workers), plus the entrypoint, cron jobs, backups and monitoring. The reference deployment peaked at 9 (`Max_used_connections`). The cap keeps a connection storm from multiplying the per-connection buffers below past the container's memory limit; raise it together with `PHP_PM_MAX_CHILDREN`. |
| `table-open-cache` | 2000 | Number of open table handles to cache. Omeka S with a typical set of modules has a few hundred tables, and each concurrent session needs its own handle. At the old 400 the reference deployment sat at the cap (`Open_tables` = 400) and reopened tables 187,000 times in six days (`Opened_tables`); 2000 holds the whole working set. The MySQL default is 4000. |
| `tmp-table-size` | 32M | Maximum size of in-memory temporary tables before they spill to disk. Helps complex Omeka S queries (faceted browse, advanced search) stay in memory. |
| `max-heap-table-size` | 32M | Must match `tmp-table-size` for the in-memory limit to take effect. |
| `sort-buffer-size` | 2M | Per-session buffer for ORDER BY operations. Slightly above the 256K default to improve sorting of large result sets without over-allocating per connection. |
| `join-buffer-size` | 2M | Per-session buffer for joins that cannot use indexes. Helps with module queries that join across resource values. |
| `thread-cache-size` | 8 | Number of threads to keep cached for reuse. Avoids thread creation overhead for the relatively steady connection pattern from PHP-FPM. |
| `skip-log-bin` | — | Turns binary logging off. Binary logs serve replication and point-in-time recovery; a single server backed up with `mysqldump` uses neither, and MySQL's default (on, kept 30 days) had grown to 4.9 GB on the reference deployment. See *Binary logs* below to turn them back on. |

## Binary logs

Binary logging is off (`--skip-log-bin`). `scripts/backup.sh` restores to the
moment of a dump; anything written after the last dump is lost if the volume
is. If you need to recover to an arbitrary point in time instead, turn binary
logs back on and keep them off-host along with the dumps. In a
`docker-compose.override.yml` (or your deployment overlay), repeat the whole
`command:` of the `db` service with `--skip-log-bin` replaced by:

```
--log-bin=binlog
--binlog-expire-logs-seconds=604800
```

`604800` keeps seven days; keep at least the interval between two backups,
since a restore replays the logs written after the dump it starts from. That
replay also needs each dump to record its binlog position, which
`scripts/backup.sh` does not do (it would need `mysqldump --source-data=2` and
an account with the matching privileges), so plan that part too. Apply with
`docker compose up -d db`. Binary logs add disk writes and space roughly
proportional to the write volume (imports are heavy), so watch the data volume
afterwards.

**Turning them off does not delete existing files.** MySQL simply stops
writing and ignores the old `binlog.0000NN` files and `binlog.index`, which
stay on the data volume. Once the server runs with `--skip-log-bin`, remove
them like this:

```bash
# 1. Confirm binary logging is really off (expect 0).
docker compose exec db sh -c 'mysql -h 127.0.0.1 -u"$MYSQL_USER" -p"$MYSQL_PASSWORD" -N -e "SELECT @@log_bin"'
# 2. See what is there.
docker compose exec db sh -c 'ls -la /var/lib/mysql/binlog.*'
# 3. Delete the logs and their index (only those files).
docker compose exec db sh -c 'rm -f /var/lib/mysql/binlog.[0-9]* /var/lib/mysql/binlog.index'
```

Never delete them by hand while binary logging is still on — the server still
tracks them in `binlog.index`; `PURGE BINARY LOGS` is the tool for that case.
`scripts/backup.sh` works from `mysqldump` and never reads these files.

## Running unprivileged

The `db` service runs as the image's `mysql` user (uid/gid 999 in the pinned
`mysql:9.7.4` image) from its first process, with no capabilities and a
read-only root filesystem. The MySQL entrypoint skips its `chown` step when it
does not start as root, and a fresh named volume is seeded from the image's
`/var/lib/mysql`, which is already owned by 999 — so a new install initialises
normally. Its only writable paths besides the data volume are two tmpfs mounts
owned by 999: `/var/run/mysqld` (socket and pid file) and `/tmp`.

**Existing volumes need no migration.** Before this change the container
started as root but `mysqld` itself always ran as uid 999, so everything it
wrote is already owned by 999. Only a file someone put into the volume by hand
as root would be unreadable now. To check before switching, while the old
container (which still runs as root) is up:

```bash
docker compose exec db find /var/lib/mysql ! -user 999   # expect no output
```

If a later image bump changed the `mysql` uid, `user:` in `docker-compose.yml`
and the two tmpfs owners must change with it; check with
`docker run --rm --entrypoint id <image> mysql`.

**`/tmp` is a 256M tmpfs** whose pages count toward `DB_MEMORY_LIMIT`. MySQL
writes filesort merge files there, and online `ALTER TABLE` sort files
(`innodb_tmpdir` defaults to `tmpdir`). Adding an index to a very large table —
usually during a module upgrade — can need more than that and fail with
"No space left on device". If it does, raise the `/tmp` tmpfs `size` for the
duration of the upgrade (in an override, restate both db mounts under
`tmpfs: !override`) and `DB_MEMORY_LIMIT` with it.

## When to Adjust

- **Large collections (100k+ items):** Increase `innodb-buffer-pool-size` to 1G or more; only then add `innodb-buffer-pool-instances` (roughly one per GiB of pool).
- **Heavy concurrent usage:** Increase `max-connections` and corresponding PHP-FPM `pm.max_children`.
- **Many modules:** If `SHOW GLOBAL STATUS LIKE 'Open_tables'` sits at `table-open-cache` and `Opened_tables` keeps climbing, raise `table-open-cache`.
- **Bulk imports:** Keep durability enabled; measure transaction batching and I/O before relaxing crash guarantees.
- **Limited host memory:** Reduce `innodb-buffer-pool-size` and `apc.shm_size` proportionally. Keep the buffer pool at roughly 50-70% of available container memory.
