# MySQL database (docker-compose.yml, service "db").
#
# The pinned upstream image, minus two components this deployment never runs.
# Between MySQL releases they are the source of nearly every finding the
# weekly image scan reports for db (.github/workflows/security.yml):
#
#   - gosu, a Go binary built with an old toolchain. The entrypoint calls it
#     only when the container starts as root, to drop to the mysql user. The
#     db service runs as `user: "999:999"` from its first process on, so
#     gosu never runs. Without it, starting the container as root fails with
#     "gosu: command not found" instead of starting mysqld.
#   - MySQL Shell (the mysql-shell package: mysqlsh plus a bundled Python with
#     its own copies of cryptography, urllib3, certifi, ...). Backups use
#     mysqldump and health checks use mysqladmin. Both come from other
#     packages and are kept. No package depends on mysql-shell.
#
# The server binary, the entrypoint and every other file are upstream's
# unchanged.
#
# Pinned by digest. Dependabot watches this directory; the LTS-only rule for
# the mysql tag lives with it in .github/dependabot.yml.
FROM mysql:9.7.4@sha256:1f2ca53a9e94ff9f1f313099fa7dc7fb2f72e180ca5b2ef83574031e451bbbf1

# rpm -e removes the package from the rpm database too, so scanners do not
# report it as installed. --nodeps is not needed: nothing requires it.
RUN rpm -e mysql-shell \
    && rm -f /usr/local/bin/gosu
