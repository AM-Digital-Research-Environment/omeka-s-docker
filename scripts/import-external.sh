#!/bin/bash
# Convert an existing ("classic") Omeka S installation into a backup directory
# that scripts/restore.sh accepts.
#
# Usage: bash scripts/import-external.sh --files <dir|archive> --database <dump> [options]
#        bash scripts/import-external.sh --omeka-root <omeka-dir> --database <dump> [options]
# Example:
#   bash scripts/import-external.sh --omeka-root /var/www/omeka-s --database omeka-dump.sql
#   bash scripts/restore.sh backups/imported-20261120-101500
#
# WHY: restore.sh only reads this template's own backup format (BACKUP_FORMAT
# marker, omeka_db.sql, omeka_media.tar.gz rooted at the media volume with its
# .immutable-layout-v1 marker, local.config.php, SHA256SUMS). Somebody moving
# an Apache/PHP/MySQL site, a shared-hosting site or another Docker image into
# this stack has the same data in a different shape. This script reshapes it
# once, checks the things that are known to break a restore into MySQL 9 /
# PHP 8.5 containers, and writes a directory that restores exactly like a
# backup made by scripts/backup.sh:
#   - BACKUP_FORMAT        omeka-docker-backup-v2 / layout=immutable
#   - omeka_db.sql         plain SQL (decompressed; optionally made portable)
#   - omeka_media.tar.gz   the old files/ directory, rooted at ".", plus the
#                          layout marker, every entry owned by 33:33 (www-data)
#   - local.config.php     the old site's config, or this template's default
#   - omeka_modules.tar.gz the old modules/ directory (optional)
#   - omeka_themes.tar.gz  the old themes/ directory (optional)
#   - SHA256SUMS
#
# Ownership matters: restore.sh extracts the archives as root in a helper
# container and never chowns afterwards, so the uid/gid stored in each archive
# is what php-fpm (www-data, uid 33) and nginx later see. The archives are
# therefore written with --owner=33 --group=33 --numeric-owner and modes that
# keep everything readable (nginx serves media and assets read-only).
#
# The source is never modified. The script needs only bash, coreutils, GNU tar
# and gzip (plus unzip for .zip inputs), so it can run on the OLD server; copy
# the resulting directory to the new server afterwards. It never needs Docker.
#
# The database cannot be dumped here: that needs the old credentials. With
# --omeka-root and no --database the script prints the exact mysqldump command
# to run (user/database/host read from the old config/database.ini, never the
# password).
#
# See docs/MIGRATING.md for the full walk-through.

set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WWW_DATA_UID=33

FILES_SRC=""
DATABASE=""
CONFIG_SRC=""
MODULES_SRC=""
THEMES_SRC=""
OUTPUT=""
OMEKA_ROOT=""
NO_MODULES=false
NO_THEMES=false
TEMPLATE_CONFIG=false
FIX_MARIADB=false
FIX_PORTABILITY=false
DRY_RUN=false
WARNINGS=0

usage() {
    cat <<'EOF'
Usage: bash scripts/import-external.sh [options]

Turns an existing Omeka S site into a backup directory for scripts/restore.sh.

Sources (either --omeka-root, or at least --files; --database is always needed):
  --omeka-root DIR     The old Omeka S directory. Finds files/, config/local.config.php,
                       modules/ and themes/ in it and reads the Omeka version. Without
                       --database it prints the mysqldump command to run and stops.
  --files PATH         The old files/ directory, or a .tar/.tar.gz/.tgz/.zip of it.
  --database FILE      SQL dump of the old database: .sql, .sql.gz or a .zip with one .sql.
  --config FILE        The old config/local.config.php (default: this template's
                       _docker/local.config.php).
  --modules PATH       The old modules/ directory or an archive of it.
  --themes PATH        The old themes/ directory or an archive of it.

Options:
  --output DIR         Where to write (default: backups/imported-YYYYmmdd-HHMMSS).
                       Must not exist yet.
  --no-modules         Do not include modules (with --omeka-root).
  --no-themes          Do not include themes (with --omeka-root).
  --use-template-config  Use _docker/local.config.php even if an old config was found.
  --fix-mariadb        Rewrite MariaDB-only syntax for MySQL 9 (sandbox-mode line,
                       uca1400 collations, Aria tables). Off by default.
  --fix-portability    Strip DEFINER clauses, CREATE DATABASE/USE lines and GTID /
                       SQL_LOG_BIN statements, which need privileges or another
                       database name. Off by default.
  --dry-run            Validate and print what would be written; write nothing.
  -h, --help           Show this help.

Then, on the new server:
  bash scripts/restore.sh <output-directory>
See docs/MIGRATING.md.
EOF
}

log() { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() {
    WARNINGS=$((WARNINGS + 1))
    printf 'WARNING: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do printf '         %s\n' "$line" >&2; done
}
die() {
    printf 'ERROR: %s\n' "$1" >&2
    shift
    local line
    for line in "$@"; do printf '       %s\n' "$line" >&2; done
    exit 1
}
quote() { printf '%q' "$1"; }
# Succeeds when $1 equals one of the remaining arguments.
in_list() {
    local needle="$1" item
    shift
    for item in "$@"; do [[ "$item" != "$needle" ]] || return 0; done
    return 1
}
abspath() {
    case "$1" in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$PWD" "${1#./}" ;;
    esac
}
human_kb() {
    awk -v k="$1" 'BEGIN { split("KiB MiB GiB TiB", u); i = 1
        while (k >= 1024 && i < 4) { k /= 1024; i++ }
        printf "%.1f %s", k, u[i] }'
}
# Succeeds when version $1 is strictly newer than version $2.
version_gt() {
    [[ "$1" != "$2" ]] && [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]
}

# --- Arguments -----------------------------------------------------------------
set_opt() {
    case "$1" in
        --files) FILES_SRC="$2" ;;
        --database) DATABASE="$2" ;;
        --config) CONFIG_SRC="$2" ;;
        --modules) MODULES_SRC="$2" ;;
        --themes) THEMES_SRC="$2" ;;
        --output) OUTPUT="$2" ;;
        --omeka-root) OMEKA_ROOT="$2" ;;
    esac
    [[ -n "$2" ]] || die "$1 needs a non-empty value."
}
while (($#)); do
    case "$1" in
        --files|--database|--config|--modules|--themes|--output|--omeka-root)
            (($# >= 2)) || die "$1 needs a value."
            set_opt "$1" "$2"
            shift 2
            continue
            ;;
        --files=*|--database=*|--config=*|--modules=*|--themes=*|--output=*|--omeka-root=*)
            set_opt "${1%%=*}" "${1#*=}" ;;
        --no-modules) NO_MODULES=true ;;
        --no-themes) NO_THEMES=true ;;
        --use-template-config) TEMPLATE_CONFIG=true ;;
        --fix-mariadb) FIX_MARIADB=true ;;
        --fix-portability) FIX_PORTABILITY=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# --- Tools ---------------------------------------------------------------------
for tool in tar gzip sha256sum awk sed find du df od sort; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' is required but not installed."
done
# --owner/--group/--numeric-owner/--mode are GNU tar options; bsdtar spells them
# differently and would silently store the wrong ownership.
[[ "$(tar --version 2>/dev/null)" == *"GNU tar"* ]] \
    || die "GNU tar is required (found: $(tar --version 2>&1 | sed -n 1p))."

# --- Locate sources ------------------------------------------------------------
OLD_VERSION=""
DBINI_USER="" DBINI_NAME="" DBINI_HOST="" DBINI_PORT=""
if [[ -n "$OMEKA_ROOT" ]]; then
    OMEKA_ROOT="$(abspath "$OMEKA_ROOT")"
    [[ -d "$OMEKA_ROOT" ]] || die "--omeka-root is not a directory: $OMEKA_ROOT"
    [[ -f "$OMEKA_ROOT/application/Module.php" ]] \
        || die "$OMEKA_ROOT does not look like an Omeka S directory (no application/Module.php)."
    OLD_VERSION="$(sed -nE "s/.*const[[:space:]]+VERSION[[:space:]]*=[[:space:]]*'([^']+)'.*/\1/p" \
        "$OMEKA_ROOT/application/Module.php" | sed -n 1p)"
    [[ -n "$FILES_SRC" ]] || FILES_SRC="$OMEKA_ROOT/files"
    if [[ -z "$CONFIG_SRC" && "$TEMPLATE_CONFIG" != true && -f "$OMEKA_ROOT/config/local.config.php" ]]; then
        CONFIG_SRC="$OMEKA_ROOT/config/local.config.php"
    fi
    if [[ -z "$MODULES_SRC" && "$NO_MODULES" != true && -d "$OMEKA_ROOT/modules" ]]; then
        MODULES_SRC="$OMEKA_ROOT/modules"
    fi
    if [[ -z "$THEMES_SRC" && "$NO_THEMES" != true && -d "$OMEKA_ROOT/themes" ]]; then
        THEMES_SRC="$OMEKA_ROOT/themes"
    fi
    if [[ -f "$OMEKA_ROOT/config/database.ini" ]]; then
        ini_value() {
            sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" \
                "$OMEKA_ROOT/config/database.ini" | sed -n 1p
        }
        DBINI_USER="$(ini_value user)"
        DBINI_NAME="$(ini_value dbname)"
        DBINI_HOST="$(ini_value host)"
        DBINI_PORT="$(ini_value port)"
    fi
fi
[[ "$NO_MODULES" != true ]] || MODULES_SRC=""
[[ "$NO_THEMES" != true ]] || THEMES_SRC=""
[[ "$TEMPLATE_CONFIG" != true ]] || CONFIG_SRC=""

print_dump_command() {
    local user="<db-user>" name="<db-name>" host="localhost" port_opt=""
    [[ -z "$DBINI_USER" ]] || user="$(quote "$DBINI_USER")"
    [[ -z "$DBINI_NAME" ]] || name="$(quote "$DBINI_NAME")"
    [[ -z "$DBINI_HOST" ]] || host="$(quote "$DBINI_HOST")"
    [[ -z "$DBINI_PORT" || "$DBINI_PORT" == 3306 ]] || port_opt=" -P $(quote "$DBINI_PORT")"
    echo "Run this on the OLD server (it asks for the database password):"
    echo ""
    echo "  mysqldump --single-transaction --routines --triggers --no-tablespaces \\"
    echo "    --default-character-set=utf8mb4 -h $host$port_opt -u $user -p \\"
    echo "    $name > omeka-dump.sql"
    echo ""
    echo "On MySQL (not MariaDB) with GTIDs enabled, also add --set-gtid-purged=OFF."
    if [[ -n "$OMEKA_ROOT" && -z "$DBINI_USER" ]]; then
        echo "(No readable config/database.ini was found; fill in the placeholders.)"
    fi
}

if [[ -z "$DATABASE" ]]; then
    if [[ -n "$OMEKA_ROOT" ]]; then
        log "A database dump is needed (--database)."
        print_dump_command
        echo ""
        echo "Then run this script again with --database omeka-dump.sql."
        exit 2
    fi
    echo "ERROR: --database is required." >&2
    print_dump_command >&2
    echo "Run with --help for all options." >&2
    exit 2
fi
[[ -n "$FILES_SRC" ]] || die "--files (or --omeka-root) is required."

DATABASE="$(abspath "$DATABASE")"
FILES_SRC="$(abspath "$FILES_SRC")"
[[ -z "$CONFIG_SRC" ]] || CONFIG_SRC="$(abspath "$CONFIG_SRC")"
[[ -z "$MODULES_SRC" ]] || MODULES_SRC="$(abspath "$MODULES_SRC")"
[[ -z "$THEMES_SRC" ]] || THEMES_SRC="$(abspath "$THEMES_SRC")"
OUTPUT="$(abspath "${OUTPUT:-$PROJECT_DIR/backups/imported-$TIMESTAMP}")"
OUTPUT="${OUTPUT%/}"

[[ -f "$DATABASE" && -r "$DATABASE" ]] || die "Database dump not found or not readable: $DATABASE"
[[ -e "$FILES_SRC" ]] || die "Files source not found: $FILES_SRC"
[[ -z "$CONFIG_SRC" || -f "$CONFIG_SRC" ]] || die "Config file not found: $CONFIG_SRC"
[[ -z "$MODULES_SRC" || -e "$MODULES_SRC" ]] || die "Modules source not found: $MODULES_SRC"
[[ -z "$THEMES_SRC" || -e "$THEMES_SRC" ]] || die "Themes source not found: $THEMES_SRC"
if [[ -e "$OUTPUT" || -L "$OUTPUT" ]]; then
    die "Output directory already exists: $OUTPUT" \
        "Refusing to overwrite it. Choose another --output or remove it yourself."
fi
for src in "$FILES_SRC" "$MODULES_SRC" "$THEMES_SRC"; do
    [[ -n "$src" && -d "$src" ]] || continue
    case "$OUTPUT/" in
        "${src%/}/"*) die "The output directory must not be inside a source directory ($src)." ;;
    esac
done

log "Omeka S import (dry-run=$DRY_RUN)"
info "Files:     $FILES_SRC"
info "Database:  $DATABASE"
info "Config:    ${CONFIG_SRC:-<template default: _docker/local.config.php>}"
info "Modules:   ${MODULES_SRC:-<not included>}"
info "Themes:    ${THEMES_SRC:-<not included>}"
info "Output:    $OUTPUT"
echo ""

# --- Archive helpers -----------------------------------------------------------
# Kind of a directory-or-archive source: dir, tar or zip.
source_kind() {
    local path="$1" magic
    if [[ -d "$path" ]]; then echo dir; return; fi
    [[ -f "$path" && -r "$path" ]] || die "Not a readable file or directory: $path"
    magic="$(od -An -tx1 -N4 "$path" | tr -d ' \n')"
    case "$magic" in
        504b0304) command -v unzip >/dev/null 2>&1 || die "unzip is required to read $path"; echo zip ;;
        *) echo tar ;;
    esac
}
# Lists an archive's member paths with any leading "./" removed.
archive_list() {
    if [[ "$1" == zip ]]; then
        unzip -Z1 "$2"
    else
        tar -tf "$2"
    fi | sed -e 's#^\./##' -e '/^$/d'
}
# Extracts an archive into a new directory; it is never run in --dry-run.
archive_extract() {
    mkdir -p "$3"
    if [[ "$1" == zip ]]; then
        unzip -q "$2" -d "$3"
    else
        tar -xf "$2" -C "$3" --no-same-owner
    fi
}
# Writes a restore.sh-compatible archive of directory $1 to $2, rooted at "."
# like backup.sh's `tar czf ... -C /data .`. Extra arguments are prepended
# (used for the media layout marker, which lives in a separate directory so the
# source is never touched).
make_archive() {
    local src="$1" out="$2"
    shift 2
    tar --create --gzip --file "$out" \
        --owner="$WWW_DATA_UID" --group="$WWW_DATA_UID" --numeric-owner \
        --mode='u+rwX,go+rX' \
        "$@" -C "$src" .
}

# --- 1. Media ------------------------------------------------------------------
log "Checking files/ ..."
FILES_KIND="$(source_kind "$FILES_SRC")"
FILES_ROOT=""      # directory holding original/ (real run, or directory source)
FILES_PREFIX=""    # path of that directory inside an archive source
if [[ "$FILES_KIND" == dir ]]; then
    if [[ -d "$FILES_SRC/original" ]]; then
        FILES_ROOT="$FILES_SRC"
    elif [[ -d "$FILES_SRC/files/original" ]]; then
        FILES_ROOT="$FILES_SRC/files"
        info "Using $FILES_ROOT (the given path is the Omeka root, not files/)."
    else
        die "No original/ directory in $FILES_SRC." \
            "--files must point at Omeka's files/ directory, the one that contains" \
            "original/, large/, medium/, square/ and asset/."
    fi
    FILE_COUNT="$(find "$FILES_ROOT/original" -type f | wc -l | tr -d ' ')"
    for sub in original large medium square asset; do
        if [[ -d "$FILES_ROOT/$sub" ]]; then
            info "$(printf '%-9s %8s files  %s' "$sub/" \
                "$(find "$FILES_ROOT/$sub" -type f | wc -l | tr -d ' ')" \
                "$(human_kb "$(du -sk "$FILES_ROOT/$sub" | cut -f1)")")"
        fi
    done
    FILES_KB="$(du -sk "$FILES_ROOT" | cut -f1)"
    info "Total: $(human_kb "$FILES_KB")"
    [[ -r "$FILES_ROOT/original" ]] || die "$FILES_ROOT/original is not readable by $(id -un)."
    if [[ -n "$(find "$FILES_ROOT" ! -readable -print -quit 2>/dev/null)" ]]; then
        die "Some files under $FILES_ROOT are not readable by $(id -un)." \
            "Run the script as a user that can read all of them (for example with sudo)."
    fi
    if [[ -e "$FILES_ROOT/.immutable-layout-v1" ]]; then
        info "The source already carries the layout marker; keeping it."
    fi
else
    LISTING="$(archive_list "$FILES_KIND" "$FILES_SRC")" || die "Could not read archive $FILES_SRC"
    # The prefix of the shallowest original/ directory: "", "files/", "x/files/".
    FILES_PREFIX="$(awk '/(^|\/)original\// { p = $0; sub(/original\/.*$/, "", p); print length(p) "\t" p }' \
        <<< "$LISTING" | sort -n | sed -n '1s/^[0-9]*\t//p')"
    if ! awk -v p="${FILES_PREFIX}original/" 'index($0, p) == 1 { found = 1 } END { exit !found }' <<< "$LISTING"; then
        die "The archive $FILES_SRC contains no original/ directory." \
            "It must be an archive of Omeka's files/ directory."
    fi
    FILE_COUNT="$(awk -v p="${FILES_PREFIX}original/" 'index($0, p) == 1 && !/\/$/ { n++ } END { print n + 0 }' <<< "$LISTING")"
    info "Archive root: ${FILES_PREFIX:-<top level>}; $FILE_COUNT entries under original/"
    FILES_KB="$(du -sk "$FILES_SRC" | cut -f1)"
fi
if [[ "$FILE_COUNT" == 0 ]]; then
    warn "files/original is empty. That is only right for a site without uploaded media."
fi

# --- 2. Database ---------------------------------------------------------------
log "Checking the database dump..."
DUMP_MAGIC="$(od -An -tx1 -N4 "$DATABASE" | tr -d ' \n')"
case "$DUMP_MAGIC" in
    1f8b*) DUMP_KIND=gzip ;;
    504b0304)
        command -v unzip >/dev/null 2>&1 || die "unzip is required to read $DATABASE"
        [[ "$(unzip -Z1 "$DATABASE" | grep -vc '/$')" == 1 ]] \
            || die "A zipped dump must contain exactly one .sql file."
        DUMP_KIND=zip ;;
    *) DUMP_KIND=plain ;;
esac
dump_cat() {
    case "$DUMP_KIND" in
        gzip) gzip -dc "$DATABASE" ;;
        zip) unzip -p "$DATABASE" ;;
        *) cat "$DATABASE" ;;
    esac
}
# One pass over the dump collects every fact the checks below need. Statement
# checks skip INSERT lines: those carry the data and can be very long.
analyse_dump() {
    awk '
        NR == 1 && /^\/\*M?!999999\\- enable the sandbox mode/ { sandbox = 1 }
        NR <= 6 && /MariaDB/ { mariadb = 1 }
        NR <= 6 && /phpMyAdmin SQL Dump/ { pma = 1 }
        NR <= 6 && /^-- (MySQL|MariaDB) dump/ { mysqldump = 1 }
        /^-- Dump completed/ { completed = 1 }
        index($0, "'"'"'version'"'"'") && !version &&
            match($0, /\('"'"'version'"'"', ?'"'"'\\?"[0-9][0-9.]*[^'"'"']*'"'"'\)/) {
            v = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", v); sub(/\\?".*$/, "", v); version = v
        }
        /^INSERT/ { next }
        /^CREATE TABLE/ {
            t = $0; sub(/^CREATE TABLE (IF NOT EXISTS )?/, "", t); gsub(/`/, "", t); sub(/[ (].*$/, "", t)
            print "table=" t
        }
        /DEFINER=/ { definer++ }
        /^(CREATE (DATABASE|SCHEMA)|USE )/ { usedb++; if (!usedb_line) usedb_line = substr($0, 1, 80) }
        /^SET @@(GLOBAL\.GTID_PURGED|SESSION\.SQL_LOG_BIN)/ { gtid++ }
        /uca1400_/ { uca++ }
        /ENGINE=Aria/ { aria++ }
        END {
            printf "sandbox=%d\nmariadb=%d\npma=%d\nmysqldump=%d\ncompleted=%d\n", sandbox, mariadb, pma, mysqldump, completed
            printf "version=%s\ndefiner=%d\nusedb=%d\nusedb_line=%s\ngtid=%d\nuca=%d\naria=%d\nlines=%d\n", version, definer, usedb, usedb_line, gtid, uca, aria, NR
        }
    '
}
fact() { sed -n "s/^$1=//p" <<< "$ANALYSIS" | sed -n 1p; }
if ! ANALYSIS="$(dump_cat | analyse_dump)"; then
    die "Could not read the database dump $DATABASE (corrupt or truncated archive?)."
fi
[[ "$(fact lines)" -gt 0 ]] || die "The database dump is empty: $DATABASE"
mapfile -t DUMP_TABLES < <(sed -n 's/^table=//p' <<< "$ANALYSIS")
info "$(fact lines) lines, ${#DUMP_TABLES[@]} tables ($DUMP_KIND$( (($(fact pma))) && echo ', phpMyAdmin export')$( (($(fact mariadb))) && echo ', MariaDB'))"
missing_tables=()
for table in resource item media setting module user site vocabulary; do
    in_list "$table" "${DUMP_TABLES[@]}" || missing_tables+=("$table")
done
if ((${#missing_tables[@]})); then
    prefixed="$(printf '%s\n' "${DUMP_TABLES[@]}" | grep -E '^[A-Za-z0-9]+_resource$' | sed -n 1p || true)"
    die "This does not look like an Omeka S database dump: no table(s) ${missing_tables[*]}." \
        "Export the whole Omeka S database, structure and data, as SQL." \
        ${prefixed:+"Found '$prefixed': Omeka S does not use table prefixes; is this another application?"}
fi
DUMP_VERSION="$(fact version)"
[[ -z "$DUMP_VERSION" ]] || info "Omeka S version recorded in the database: $DUMP_VERSION"
if (($(fact mysqldump))) && ! (($(fact completed))); then
    warn "The dump has a mysqldump header but no '-- Dump completed' trailer." \
        "It is probably truncated. Dump the database again and check the command's errors."
fi
if (($(fact mariadb))); then
    info "The dump comes from MariaDB; this stack runs MySQL 9."
fi
if (($(fact sandbox))); then
    if [[ "$FIX_MARIADB" == true ]]; then
        info "Will remove MariaDB's sandbox-mode first line (--fix-mariadb)."
    else
        warn "Line 1 is MariaDB's '/*!999999\\- enable the sandbox mode */'." \
            "The MySQL client stops on it with \"Unknown command '\\-'\". Re-run with --fix-mariadb."
    fi
fi
if (($(fact uca))) || (($(fact aria))); then
    if [[ "$FIX_MARIADB" == true ]]; then
        info "Will map $(fact uca) uca1400 collation line(s) to utf8mb4_unicode_ci and $(fact aria) Aria table(s) to InnoDB (--fix-mariadb)."
    else
        warn "The dump uses MariaDB-only collations (uca1400, $(fact uca) lines) or Aria tables ($(fact aria))." \
            "MySQL 9 rejects them. Re-run with --fix-mariadb."
    fi
fi
if (($(fact definer))); then
    if [[ "$FIX_PORTABILITY" == true ]]; then
        info "Will strip $(fact definer) DEFINER clause(s) (--fix-portability)."
    else
        warn "The dump has $(fact definer) DEFINER= clause(s) (views, triggers or routines)." \
            "The unprivileged database user cannot create objects for another definer." \
            "Re-run with --fix-portability, or dump again with a matching user."
    fi
fi
if (($(fact usedb))); then
    if [[ "$FIX_PORTABILITY" == true ]]; then
        info "Will remove $(fact usedb) CREATE DATABASE/USE line(s) (--fix-portability)."
    else
        warn "The dump contains CREATE DATABASE/USE statements: $(fact usedb_line)" \
            "restore.sh imports into MYSQL_DATABASE; these would switch to the old database name" \
            "and fail (or write elsewhere). Re-run with --fix-portability, or export without them."
    fi
fi
if (($(fact gtid))); then
    if [[ "$FIX_PORTABILITY" == true ]]; then
        info "Will remove $(fact gtid) GTID_PURGED/SQL_LOG_BIN statement(s) (--fix-portability)."
    else
        warn "The dump sets GTID_PURGED or SQL_LOG_BIN, which need admin privileges." \
            "Re-run with --fix-portability, or dump with --set-gtid-purged=OFF."
    fi
fi

# --- 3. Omeka version ----------------------------------------------------------
TEMPLATE_VERSION=""
[[ ! -f "$PROJECT_DIR/Dockerfile" ]] \
    || TEMPLATE_VERSION="$(sed -nE 's/^ARG OMEKA_VERSION=(.*)$/\1/p' "$PROJECT_DIR/Dockerfile" | sed -n 1p)"
SITE_VERSION="${OLD_VERSION:-$DUMP_VERSION}"
log "Omeka S version"
info "Old site code:       ${OLD_VERSION:-unknown (pass --omeka-root to read it)}"
info "Old site database:   ${DUMP_VERSION:-unknown}"
info "This template:       ${TEMPLATE_VERSION:-unknown}"
if [[ -n "$OLD_VERSION" && -n "$DUMP_VERSION" && "$OLD_VERSION" != "$DUMP_VERSION" ]]; then
    warn "The old code ($OLD_VERSION) and its database ($DUMP_VERSION) disagree." \
        "The old site has a pending migration; the newer of the two is what counts."
    version_gt "$DUMP_VERSION" "$OLD_VERSION" && SITE_VERSION="$DUMP_VERSION"
fi
RECOMMENDED_VERSION="$TEMPLATE_VERSION"
NEEDS_MIGRATE=false
if [[ -n "$SITE_VERSION" && -n "$TEMPLATE_VERSION" ]]; then
    if version_gt "$SITE_VERSION" "$TEMPLATE_VERSION"; then
        RECOMMENDED_VERSION="$SITE_VERSION"
        warn "The old site ($SITE_VERSION) is NEWER than this template's default ($TEMPLATE_VERSION)." \
            "Omeka S cannot downgrade a database. Set OMEKA_VERSION=$SITE_VERSION in .env" \
            "(untested with this image) or update the template first."
    elif version_gt "$TEMPLATE_VERSION" "$SITE_VERSION"; then
        NEEDS_MIGRATE=true
        info "The database will need Omeka's core migration after the first start:"
        info "  docker compose exec php omeka-s-cli core:migrate"
        info "The container does not run it automatically."
    fi
fi
[[ -z "$RECOMMENDED_VERSION" ]] || info "Set in .env:         OMEKA_VERSION=$RECOMMENDED_VERSION"

# --- 4. local.config.php -------------------------------------------------------
log "Checking local.config.php..."
TEMPLATE_CONFIG_FILE="$PROJECT_DIR/_docker/local.config.php"
if [[ -n "$CONFIG_SRC" ]]; then
    CONFIG_FILE="$CONFIG_SRC"
    [[ "$(head -c 200 "$CONFIG_FILE")" == *"<?php"* ]] || die "$CONFIG_FILE is not a PHP file."
    if command -v php >/dev/null 2>&1 && ! php -l "$CONFIG_FILE" >/dev/null 2>&1; then
        die "$CONFIG_FILE has a PHP syntax error (php -l)."
    fi
    # Print line numbers and keys only: a config can hold SMTP or S3 secrets.
    config_lines() { grep -nE "$1" "$CONFIG_FILE" | grep -vE '^[0-9]+:[[:space:]]*(//|#|\*)' | cut -d: -f1 | paste -sd, - || true; }
    check_config() {
        local lines
        lines="$(config_lines "$1")"
        [[ -z "$lines" ]] || warn "local.config.php line(s) $lines: $2" "${@:3}"
    }
    check_config "'phpcli_path'[[:space:]]*=>[[:space:]]*['\"]" \
        "phpcli_path is set; the container's PHP is found automatically." "Set it to null."
    magick_lines="$(grep -nE "'imagemagick_dir'[[:space:]]*=>[[:space:]]*['\"]" "$CONFIG_FILE" \
        | grep -vE "=>[[:space:]]*['\"]/usr/bin/?['\"]" | cut -d: -f1 | paste -sd, - || true)"
    [[ -z "$magick_lines" ]] || warn "local.config.php line(s) $magick_lines: imagemagick_dir points outside /usr/bin," \
        "where the image has ImageMagick. Set it to null."
    check_config "'file_store'" \
        "a custom file_store (base_path/base_uri) is configured." \
        "Media must live in /var/www/html/files; remove the file_store block."
    store_lines="$(grep -nE "File.{1,2}Store'[[:space:]]*=>" "$CONFIG_FILE" | grep -vE "Store.{1,2}Local'" | cut -d: -f1 | paste -sd, - || true)"
    [[ -z "$store_lines" ]] || warn "local.config.php line(s) $store_lines: Omeka\\File\\Store is not the local store." \
        "Media in a cloud store is not in files/; this import would restore none of it."
    check_config "(AnyCloud|[Aa]mazon[Ss]3|amazonaws|'s3'|[Ff]lysystem|[Aa]zure|[Ww]asabi|[Mm]in[Ii][Oo])" \
        "cloud storage (S3/AnyCloud/Azure) settings found." \
        "Download the media into files/ first, or keep the module and its credentials."
    check_config "'save_path'" \
        "a session save_path is set; the image keeps sessions in /var/lib/php-sessions." "Remove it."
    check_config "'(sslcapath|sslcafile)'[[:space:]]*=>[[:space:]]*['\"]" \
        "http_client CA paths are set; they may not exist in the container." "Set them to null."
    check_config "['\"](/var/www|/home/|/srv/|/opt/|/usr/local/|/data/|[A-Za-z]:\\\\)" \
        "an absolute host path is referenced; it will not exist in the container."
    info "Reference for container-safe settings: _docker/local.config.php"
    info "After restore, edit _docker/restored-local.config.php and run 'docker compose restart php'."
else
    [[ -f "$TEMPLATE_CONFIG_FILE" ]] || die "No --config given and $TEMPLATE_CONFIG_FILE was not found." \
        "Run the script from a checkout of this template, or pass --config."
    CONFIG_FILE="$TEMPLATE_CONFIG_FILE"
    info "Using this template's default _docker/local.config.php."
    info "Re-apply the old site's custom settings (locale, thumbnails, mail) there after restore."
fi

# --- 5. Modules and themes -----------------------------------------------------
# Prints the names of the module/theme directories in a source. For archives,
# also sets <VAR>_PREFIX to the path of that directory inside the archive.
EXT_PREFIX=""
list_extensions() {
    local kind="$1" src="$2" ini="$3" listing
    EXT_PREFIX=""
    if [[ "$kind" == dir ]]; then
        [[ ! -f "$src/config/$ini" ]] || die "$src is a single extension; pass the directory that contains it."
        find "$src" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' | sort
        return
    fi
    listing="$(archive_list "$kind" "$src")" || die "Could not read archive $src"
    EXT_PREFIX="$(awk -v ini="$ini" '$0 ~ "(^|/)[^/]+/config/" ini "$" {
            p = $0; sub("[^/]+/config/" ini "$", "", p); print length(p) "\t" p }' <<< "$listing" \
        | sort -n | sed -n '1s/^[0-9]*\t//p')"
    awk -v p="$EXT_PREFIX" 'index($0, p) == 1 { r = substr($0, length(p) + 1); sub(/\/.*$/, "", r)
        if (r != "" && r !~ /^\./) print r }' <<< "$listing" | sort -u
}
module_version() {
    [[ -f "$1/config/module.ini" ]] || return 0
    sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"?([^"]*)"?.*$/\1/p' "$1/config/module.ini" | sed -n 1p
}
# Module directory names this template bakes into its image, derived from the
# omeka-s-cli URIs in _docker/default-modules.txt (and extra-modules.txt).
default_modules() {
    local file
    for file in "$PROJECT_DIR/_docker/default-modules.txt" "$PROJECT_DIR/_docker/extra-modules.txt"; do
        [[ -f "$file" ]] || continue
        sed -e 's/#.*//' -e 's/[[:space:]].*//' "$file"
    done | sed -e '/^$/d' -e 's#.*/##' -e 's/\.zip$//' -e 's/^Omeka-S-module-//' -e 's/-v\{0,1\}[0-9][0-9.]*$//' \
        | sort -u
}

MODULES_KIND="" THEMES_KIND="" MODULES_PREFIX="" THEMES_PREFIX=""
mapfile -t STACK_MODULES < <(default_modules)
log "Modules"
if [[ -n "$MODULES_SRC" ]]; then
    MODULES_KIND="$(source_kind "$MODULES_SRC")"
    mapfile -t OLD_MODULES < <(list_extensions "$MODULES_KIND" "$MODULES_SRC" module.ini)
    MODULES_PREFIX="$EXT_PREFIX"
    only_old=() both=() only_stack=()
    for m in "${OLD_MODULES[@]}"; do
        label="$m"
        if [[ "$MODULES_KIND" == dir ]]; then
            ver="$(module_version "$MODULES_SRC/$m")"
            [[ -z "$ver" ]] || label="$m $ver"
        fi
        if in_list "$m" "${STACK_MODULES[@]}"; then both+=("$label"); else only_old+=("$label"); fi
    done
    for m in "${STACK_MODULES[@]}"; do
        in_list "$m" "${OLD_MODULES[@]}" || only_stack+=("$m")
    done
    info "${#OLD_MODULES[@]} module(s) in the old site; they will be restored onto the modules volume."
    info "Also in this template's defaults: ${both[*]:-none}"
    info "Only in the old site:              ${only_old[*]:-none}"
    if ((${#only_stack[@]})); then
        warn "These template defaults are NOT in the old site and will be absent after restore:" \
            "${only_stack[*]}" \
            "The modules archive replaces the whole volume. Add them afterwards with" \
            "'docker compose exec php omeka-s-cli module:download <name>', or omit --modules."
    fi
    info "Old module versions may not run on PHP 8.5; update them after restore"
    info "(Easy Admin, or 'docker compose exec php omeka-s-cli module:update <name>')."
else
    info "Not included: the modules volume is seeded with this template's defaults:"
    info "  ${STACK_MODULES[*]:-none}"
    info "Modules the old database knows but the volume lacks show as \"not found\" until"
    info "you install them (Easy Admin, omeka-s-cli module:download) or re-run with --modules."
fi

log "Themes"
if [[ -n "$THEMES_SRC" ]]; then
    THEMES_KIND="$(source_kind "$THEMES_SRC")"
    mapfile -t OLD_THEMES < <(list_extensions "$THEMES_KIND" "$THEMES_SRC" theme.ini)
    THEMES_PREFIX="$EXT_PREFIX"
    info "${#OLD_THEMES[@]} theme(s) will be restored onto the themes volume: ${OLD_THEMES[*]:-none}"
    in_list default "${OLD_THEMES[@]}" \
        || warn "The old themes do not include Omeka's 'default' theme; the archive replaces the volume."
else
    info "Not included: the themes volume is seeded from the image (Omeka's 'default' theme"
    info "plus any configured extra themes). Sites using another theme need it installed."
fi

# --- 6. Space ------------------------------------------------------------------
existing_parent="$(dirname "$OUTPUT")"
while [[ ! -d "$existing_parent" ]]; do existing_parent="$(dirname "$existing_parent")"; done
need_kb="$FILES_KB"
for src in "$MODULES_SRC" "$THEMES_SRC" "$DATABASE"; do
    [[ -z "$src" ]] || need_kb=$((need_kb + $(du -sk "$src" | cut -f1)))
done
[[ "$FILES_KIND" == dir ]] || need_kb=$((need_kb * 2))   # extraction staging
[[ "$DUMP_KIND" == plain ]] || need_kb=$((need_kb + $(du -sk "$DATABASE" | cut -f1) * 5))
free_kb="$(df -Pk "$existing_parent" | awk 'NR == 2 { print $4 }')"
log "Space"
info "Needed at most about $(human_kb "$need_kb"); free in $existing_parent: $(human_kb "$free_kb")"
if [[ "$free_kb" =~ ^[0-9]+$ ]] && ((free_kb < need_kb)); then
    warn "There may not be enough free space for the output." "Choose another --output."
fi

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    log "Dry run: would write $OUTPUT with"
    info "BACKUP_FORMAT        omeka-docker-backup-v2, layout=immutable"
    info "omeka_db.sql         from $(basename "$DATABASE")$( [[ "$FIX_MARIADB" == true ]] && echo ', --fix-mariadb')$( [[ "$FIX_PORTABILITY" == true ]] && echo ', --fix-portability')"
    info "omeka_media.tar.gz   $FILES_SRC${FILES_PREFIX:+ (archive root $FILES_PREFIX)} + .immutable-layout-v1, owner 33:33"
    info "local.config.php     $CONFIG_FILE"
    [[ -z "$MODULES_SRC" ]] || info "omeka_modules.tar.gz $MODULES_SRC, owner 33:33"
    [[ -z "$THEMES_SRC" ]] || info "omeka_themes.tar.gz  $THEMES_SRC, owner 33:33"
    info "SHA256SUMS"
    echo ""
    log "Dry run finished with $WARNINGS warning(s); nothing was written."
    exit 0
fi

# --- 7. Write the backup directory ---------------------------------------------
CREATED=false
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$status" != 0 && "$CREATED" == true ]]; then
        rm -rf -- "$OUTPUT"
        echo "ERROR: Import failed; removed the partial output $OUTPUT" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

mkdir -p "$(dirname "$OUTPUT")"
mkdir "$OUTPUT" || die "Could not create $OUTPUT (does it exist already?)."
CREATED=true
chmod 700 "$OUTPUT"
# restore.sh refuses a directory with this marker, so an interrupted import can
# never be mistaken for a finished one.
touch "$OUTPUT/BACKUP_INCOMPLETE"
STAGING="$OUTPUT/.import-staging"
mkdir "$STAGING"

echo ""
printf 'omeka-docker-backup-v2\nlayout=immutable\n' > "$OUTPUT/BACKUP_FORMAT"

log "Writing omeka_db.sql..."
SED_FIXES=()
if [[ "$FIX_MARIADB" == true ]]; then
    SED_FIXES+=(
        -e '1{/^\/\*M\{0,1\}!999999\\- enable the sandbox mode/d;}'
        -e '/^INSERT/!s/utf8mb4_uca1400_[A-Za-z0-9_]*/utf8mb4_unicode_ci/g'
        -e '/^INSERT/!s/utf8mb3_uca1400_[A-Za-z0-9_]*/utf8mb3_unicode_ci/g'
        -e '/^INSERT/!s/\(COLLATE[= ]*\)uca1400_[A-Za-z0-9_]*/\1utf8mb4_unicode_ci/g'
        -e '/^INSERT/!s/ENGINE=Aria/ENGINE=InnoDB/g'
        -e '/^INSERT/!s/ \(PAGE_CHECKSUM\|TRANSACTIONAL\)=[01]//g'
    )
fi
if [[ "$FIX_PORTABILITY" == true ]]; then
    # shellcheck disable=SC2016 # backticks are SQL identifier quotes, not bash
    SED_FIXES+=(
        -e '/^INSERT/!s/ DEFINER=\(`[^`]*`\|[^ @`]*\)@\(`[^`]*`\|[^ *`]*\)//g'
        -e '/^\(CREATE \(DATABASE\|SCHEMA\)\|USE \).*;[[:space:]]*$/d'
        -e '/^SET @@GLOBAL\.GTID_PURGED.*;[[:space:]]*$/d'
        -e '/^SET @@GLOBAL\.GTID_PURGED/,/;[[:space:]]*$/d'
        -e '/^SET @@SESSION\.SQL_LOG_BIN/d'
        -e '/^SET @MYSQLDUMP_TEMP_LOG_BIN/d'
    )
fi
if ((${#SED_FIXES[@]})); then
    dump_cat | sed "${SED_FIXES[@]}" > "$OUTPUT/omeka_db.sql"
    BEFORE="$ANALYSIS"
    DATABASE="$OUTPUT/omeka_db.sql" DUMP_KIND=plain
    ANALYSIS="$(dump_cat | analyse_dump)"
    for key in sandbox uca aria definer usedb gtid; do
        before="$(sed -n "s/^$key=//p" <<< "$BEFORE")"
        after="$(fact "$key")"
        [[ "$before" == "$after" ]] || info "Rewrote $key: $before -> $after"
    done
else
    dump_cat > "$OUTPUT/omeka_db.sql"
fi
[[ -s "$OUTPUT/omeka_db.sql" ]] || die "The written dump is empty."
info "Database: $(human_kb "$(du -sk "$OUTPUT/omeka_db.sql" | cut -f1)")"

log "Writing omeka_media.tar.gz (owner 33:33)..."
if [[ "$FILES_KIND" != dir ]]; then
    archive_extract "$FILES_KIND" "$FILES_SRC" "$STAGING/files"
    FILES_ROOT="$STAGING/files/${FILES_PREFIX%/}"
    [[ -d "$FILES_ROOT/original" ]] || die "Extracted archive has no ${FILES_PREFIX}original/."
fi
MARKER_ARGS=()
if [[ ! -e "$FILES_ROOT/.immutable-layout-v1" ]]; then
    mkdir "$STAGING/marker"
    : > "$STAGING/marker/.immutable-layout-v1"
    MARKER_ARGS=(-C "$STAGING/marker" ./.immutable-layout-v1)
fi
make_archive "$FILES_ROOT" "$OUTPUT/omeka_media.tar.gz" "${MARKER_ARGS[@]}"
info "Media: $(human_kb "$(du -sk "$OUTPUT/omeka_media.tar.gz" | cut -f1)")"

cp "$CONFIG_FILE" "$OUTPUT/local.config.php"
chmod 600 "$OUTPUT/local.config.php"
log "Copied local.config.php"

for name in omeka_modules omeka_themes; do
    if [[ "$name" == omeka_modules ]]; then
        src="$MODULES_SRC" kind="$MODULES_KIND" prefix="$MODULES_PREFIX"
    else
        src="$THEMES_SRC" kind="$THEMES_KIND" prefix="$THEMES_PREFIX"
    fi
    [[ -n "$src" ]] || continue
    log "Writing ${name}.tar.gz (owner 33:33)..."
    if [[ "$kind" != dir ]]; then
        archive_extract "$kind" "$src" "$STAGING/$name"
        src="$STAGING/$name/${prefix%/}"
    fi
    make_archive "$src" "$OUTPUT/${name}.tar.gz"
    info "${name}: $(human_kb "$(du -sk "$OUTPUT/${name}.tar.gz" | cut -f1)")"
done
rm -rf -- "$STAGING"

# Same artifact order as backup.sh; restore.sh accepts only these names.
CHECKSUM_FILES=(BACKUP_FORMAT omeka_db.sql)
for file in omeka_media.tar.gz omeka_modules.tar.gz omeka_themes.tar.gz local.config.php; do
    [[ ! -f "$OUTPUT/$file" ]] || CHECKSUM_FILES+=("$file")
done
(cd "$OUTPUT" && sha256sum "${CHECKSUM_FILES[@]}" > SHA256SUMS)
log "Wrote SHA256SUMS"

# Self-check the properties restore.sh relies on before declaring success.
# No grep -q: exiting early would SIGPIPE tar and fail the pipeline.
tar -tzf "$OUTPUT/omeka_media.tar.gz" | grep -x '\./\.immutable-layout-v1' >/dev/null \
    || die "Self-check failed: the media archive has no ./.immutable-layout-v1."
(cd "$OUTPUT" && sha256sum --check --quiet SHA256SUMS) || die "Self-check failed: checksums do not match."
rm "$OUTPUT/BACKUP_INCOMPLETE"
CREATED=false

echo ""
log "Import complete: $OUTPUT ($WARNINGS warning(s))"
ls -lhA "$OUTPUT"
echo ""
echo "Next steps (see docs/MIGRATING.md):"
echo "  1. Copy this directory to the new server, into a checkout of this template."
echo "  2. There: cp .env.example .env, set MYSQL_PASSWORD${RECOMMENDED_VERSION:+ and OMEKA_VERSION=$RECOMMENDED_VERSION}."
echo "  3. bash scripts/restore.sh $(quote "$OUTPUT")"
if [[ "$NEEDS_MIGRATE" == true ]]; then
    echo "  4. docker compose exec php omeka-s-cli core:migrate"
    echo "  5. Sign in with an account from the OLD site and check media, modules and sites."
else
    echo "  4. Sign in with an account from the OLD site and check media, modules and sites."
fi
