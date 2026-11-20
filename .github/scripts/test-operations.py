#!/usr/bin/env python3
"""Exercise operation failure paths with a fake Docker CLI; no real data touched."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
BASH = os.environ.get("TEST_BASH", "bash")


class Operations(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="omeka-operations-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(REPO / "scripts", self.root / "scripts")
        (self.root / "bin").mkdir()
        (self.root / "_docker").mkdir()
        for name in ("default-modules", "extra-modules", "extra-themes", "empty-modules", "empty-themes"):
            (self.root / "_docker" / (name + ".txt")).write_text("")
        (self.root / ".env").write_text("MYSQL_PASSWORD=test-only\n")
        (self.root / "_docker/restored-local.config.php").write_text("original config")
        self.log = self.root / "docker.log"
        self.config = {"name": "test", "services": {
            "php": {"build": {"args": {}}, "volumes": [
                {"type": "volume", "source": "media", "target": "/var/www/html/files"},
                {"type": "volume", "source": "logs", "target": "/var/www/html/logs"},
                {"type": "bind", "source": (self.root / "_docker/restored-local.config.php").as_posix(),
                 "target": "/var/www/html/config/local.config.php"}]},
            "db": {"volumes": [{"type": "volume", "source": "db", "target": "/var/lib/mysql"}]}},
            "volumes": {"media": {"name": "institution-media"}, "logs": {"name": "institution-logs"},
                        "db": {"name": "institution-database"}}}
        self.env = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                        TEST_LOG=self.log.as_posix(), MSYS_NO_PATHCONV="1")
        self.write_executable("python3", '#!/bin/bash\nset -o pipefail\n'
                              'if command -v cygpath >/dev/null && [[ "$1" == /* && -f "$1" ]]; then\n'
                              '  script=$(cygpath -m "$1"); shift; set -- "$script" "$@"\nfi\n"'
                              + Path(sys.executable).as_posix() + '" "$@" | tr -d "\\r"\n')
        self.write_executable("docker", '''#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG"
case "$*" in
  'compose config --format json') printf '%s\n' "$TEST_CONFIG" ;;
  'compose ps '*) printf '%s' "${TEST_RUNNING:-}" ;;
  'compose stop web php'|'compose start web php') exit 0 ;;
  'compose up -d db') exit 0 ;;
  'volume inspect '*) [[ "$3" != "${TEST_MISSING_VOLUME:-}" ]] ;;
  *'module:list'*)
    [[ "${TEST_LIST_FAIL:-}" != 1 ]] || exit 42
    printf '%s\n' "${TEST_LIST_ROWS:-| Probe | 1.0 | needs_upgrade |}" ;;
  *'mysqldump --help'*) echo '--masking-policies' ;;
  *'exec mysqldump '*) printf '%s\n' '-- SQL fixture' '-- Dump completed on test' ;;
  *'SELECT 1'*) exit 0 ;;
  'run '*'/data/.immutable-layout-v1') exit 0 ;;
  'run '*'/backup/'*'.tar.gz'*)
    [[ "${TEST_ARCHIVE_SUCCESS:-}" == 1 ]] || exit 42
    for arg in "$@"; do
        case "$arg" in
            *:/backup) destination=${arg%:/backup} ;;
            /backup/*.tar.gz) archive=${arg#/backup/} ;;
        esac
    done
    printf 'archive fixture' > "$destination/$archive" ;;
  'compose images --format json') echo '[]' ;;
  *'module:update'*|*'module:download'*|*'module:upgrade'*|*'theme:list'*) exit 0 ;;
  *) echo "Unexpected fake Docker command: $*" >&2; exit 93 ;;
esac
''')
        (self.root / "scripts/update-module.sh").write_text("#!/bin/bash\nexit 0\n")

    def write_executable(self, name, text):
        path = self.root / "bin" / name
        path.write_text(text, newline="\n")
        path.chmod(0o755)

    def run_script(self, name, *args, input=""):
        self.env["TEST_CONFIG"] = json.dumps(self.config)
        return subprocess.run([BASH, "scripts/" + name, *args], cwd=self.root,
                              env=self.env, input=input, text=True, capture_output=True, timeout=20)

    def archive(self):
        backup = self.root / "backup"
        backup.mkdir()
        for name in ("omeka_db.sql", "omeka_media.tar.gz", "local.config.php"):
            (backup / name).write_text("backup fixture")
        (backup / "BACKUP_FORMAT").write_text("omeka-docker-backup-v2\nlayout=immutable\n")
        return backup

    def test_incomplete_restore_stops_before_docker(self):
        (self.archive() / "BACKUP_INCOMPLETE").touch()
        result = self.run_script("restore.sh", "backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not finish", result.stderr)
        self.assertFalse(self.log.exists())

    def test_declined_restore_preserves_configuration(self):
        self.archive()
        original_env = (self.root / ".env").read_bytes()
        result = self.run_script("restore.sh", "backup", input="n\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Aborted", result.stdout)
        self.assertEqual((self.root / ".env").read_bytes(), original_env)
        self.assertEqual((self.root / "_docker/restored-local.config.php").read_text(), "original config")

    def test_existing_backup_is_not_overwritten(self):
        backup = self.archive()
        result = self.run_script("backup.sh", "backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be empty", result.stderr)
        self.assertEqual((backup / "omeka_db.sql").read_text(), "backup fixture")

    def test_failed_relative_backup_retains_incomplete_marker(self):
        result = self.run_script("backup.sh", "new-backup")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertTrue((self.root / "new-backup/BACKUP_INCOMPLETE").exists())
        self.assertFalse((self.root / "new-backup/SHA256SUMS").exists())
        self.assertNotIn('-v new-backup:/backup', self.log.read_text())
        self.assertIn('/new-backup:/backup', self.log.read_text())

    def test_immutable_extensions_apply_migrations(self):
        result = self.run_script("update-extensions.sh", "--no-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("module:upgrade --base-path /var/www/html Probe", self.log.read_text())
        self.assertNotIn("module:download", self.log.read_text())

    def test_generic_extensions_ignore_unselected_deployment(self):
        self.config["services"]["php"]["volumes"] = [{"target": "/var/www/html/modules"}]
        deployment = self.root / "deploy/other"
        deployment.mkdir(parents=True)
        (deployment / "modules.txt").write_text("gh:private/unselected\n")
        result = self.run_script("update-extensions.sh", "--no-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("unselected", self.log.read_text())

    def test_extension_commands_cannot_consume_manifest_or_migration_input(self):
        self.config["services"]["php"]["volumes"] = [{"target": "/var/www/html/modules"}]
        (self.root / "_docker/default-modules.txt").write_text(
            "https://example.org/First.zip\nhttps://example.org/Second.zip\n")
        docker = self.root / "bin/docker"
        fake = docker.read_text().replace(
            "case \"$*\" in", "case \"$*\" in\n  *'module:download'*|*'module:upgrade'*) cat >/dev/null; exit 0 ;;", 1)
        docker.write_text(fake)
        self.env["TEST_LIST_ROWS"] = "| Probe | 1.0 | needs_upgrade |\n| SecondProbe | 1.0 | needs_upgrade |"
        result = self.run_script("update-extensions.sh", "--no-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.log.read_text()
        for name in ("First", "Second"):
            self.assertIn("https://example.org/" + name + ".zip", log)
        for name in ("Probe", "SecondProbe"):
            self.assertIn("module:upgrade --base-path /var/www/html " + name, log)

    def test_registry_update_skips_pinned_modules(self):
        # The registry can lag a pin and spell its ID in another case; updating a
        # pinned module from it downgraded DRESearch and unpacked DRESEO beside DRESeo.
        self.config["services"]["php"]["volumes"] = [{"target": "/var/www/html/modules"}]
        (self.root / "_docker/default-modules.txt").write_text(
            "https://example.org/v1/DRESeo.zip\ngh:owner/Omeka-S-module-Log\n")
        self.env["TEST_LIST_ROWS"] = "\n".join([
            "| DRESeo | DRE SEO | active | 0.10.1 | 0.10.1 | 0.10.0 | yes |",
            "| Log | Log | active | 3.4.41 | 3.4.41 | 3.4.40 | yes |",
            "| Mapping | Mapping | active | 2.0 | 2.0 | 2.1 | yes |",
            "| Current | Current | active | 1.0 | 1.0 | 1.0 | |"])
        result = self.run_script("update-extensions.sh", "--no-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        updates = [l for l in self.log.read_text().splitlines() if "module:update" in l]
        self.assertEqual(updates, ["compose exec -T php omeka-s-cli module:update --base-path /var/www/html Mapping"])

    def update_module_args(self, *args):
        (self.root / "scripts/update-module.sh").write_text(
            '#!/bin/bash\nprintf "%s\\n" "$*" > "$PWD/update-module.args"\n')
        result = self.run_script("update-extensions.sh", "--no-backup", *args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return (self.root / "update-module.args").read_text().strip()

    def test_volume_extensions_skip_image_rebuild(self):
        # The site runs the volumes' copies, so rebuilding for a module bump only
        # costs time; --rebuild (or --pull) still asks for it.
        self.config["services"]["php"]["volumes"] = [{"target": "/var/www/html/modules"}]
        self.assertEqual(self.update_module_args(), "--no-rebuild")
        self.assertEqual(self.update_module_args("--rebuild"), "")
        self.assertEqual(self.update_module_args("--pull"), "--pull")

    def test_immutable_extensions_always_rebuild(self):
        self.assertEqual(self.update_module_args(), "")

    def test_failed_module_inventory_is_not_success(self):
        self.env["TEST_LIST_FAIL"] = "1"
        result = self.run_script("update-extensions.sh", "--no-backup")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertNotIn("Extension update complete", result.stdout)

    def test_invalid_project_name_never_selects_volumes(self):
        self.config["name"] = ""
        result = self.run_script("backup.sh", "new-backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("volume inspect", self.log.read_text())
        self.assertFalse((self.root / "new-backup").exists())

    def test_backup_uses_custom_volume_name(self):
        result = self.run_script("backup.sh", "new-backup")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        self.assertIn("volume inspect institution-media", self.log.read_text())
        self.assertNotIn("test_omeka_media", self.log.read_text())

    def test_bind_media_is_rejected_before_creating_backup(self):
        self.config["services"]["php"]["volumes"][0]["type"] = "bind"
        result = self.run_script("backup.sh", "new-backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use a named volume", result.stderr)
        self.assertFalse((self.root / "new-backup").exists())

    def test_quiesced_backup_restarts_services_on_failure(self):
        self.env["TEST_RUNNING"] = "web\nphp\ndb\n"
        result = self.run_script("backup.sh", "--quiesce", "new-backup")
        self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
        commands = self.log.read_text()
        self.assertIn("compose stop web php", commands)
        self.assertIn("compose start web php", commands)
        self.assertNotIn("compose stop db", commands)

    def test_release_updates_ignore_other_institutions(self):
        shutil.copyfile(REPO / "scripts/update-module.sh", self.root / "scripts/update-module.sh")
        deployment = self.root / "deploy/other"
        deployment.mkdir(parents=True)
        (deployment / "modules.txt").write_text("https://github.com/other/repo/releases/download/v1/Test.zip\n")
        self.write_executable("curl", "#!/bin/bash\necho 'unexpected network call' >&2\nexit 99\n")
        result = self.run_script("update-module.sh", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no pinned release archives", result.stdout)

    def test_successful_backup_excludes_inactive_extensions_and_search(self):
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        result = self.run_script("backup.sh", "new-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backup = self.root / "new-backup"
        self.assertTrue((backup / "SHA256SUMS").exists())
        self.assertFalse((backup / "BACKUP_INCOMPLETE").exists())
        self.assertFalse((backup / "omeka_modules.tar.gz").exists())
        self.assertFalse((backup / "typesense_data.tar.gz").exists())
        self.assertFalse((backup / "caddy_data.tar.gz").exists())

    def test_retention_keeps_newest_and_spares_unfinished(self):
        # Pruning deletes real backups, so pin down exactly which directories it
        # selects: the N newest complete ones survive, older ones go, and an
        # unfinished directory is neither deleted nor counted against the
        # window (otherwise an abandoned run would evict a good backup).
        backups = self.root / "backups"
        backups.mkdir()
        for name in ("20260101-010101", "20260102-010101", "20260103-010101"):
            (backups / name).mkdir()
            (backups / name / "SHA256SUMS").write_text("old fixture")
        (backups / "20260104-010101").mkdir()
        (backups / "20260104-010101" / "BACKUP_INCOMPLETE").touch()
        # A differently-named directory is not this script's and must be ignored.
        (backups / "pre-omeka-4.2.1-keepme").mkdir()
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        result = self.run_script("backup.sh", "--keep", "2")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        remaining = sorted(p.name for p in backups.iterdir())
        fresh = [n for n in remaining if n.startswith("2026") and n not in {
            "20260101-010101", "20260102-010101", "20260103-010101", "20260104-010101"}]
        self.assertEqual(len(fresh), 1, f"expected one new snapshot, got {remaining}")
        self.assertIn("20260104-010101", remaining, "unfinished backup must be spared")
        self.assertIn("pre-omeka-4.2.1-keepme", remaining, "foreign directory must be spared")
        # Keep 2 complete: the new one plus the newest pre-existing complete one.
        self.assertIn("20260103-010101", remaining)
        self.assertNotIn("20260102-010101", remaining)
        self.assertNotIn("20260101-010101", remaining)

    def test_retention_reads_keep_from_dotenv(self):
        # .env is where operators configure this deployment, but Compose does
        # not pass it to a plain script — assert the script reads it itself.
        backups = self.root / "backups"
        backups.mkdir()
        for name in ("20260101-010101", "20260102-010101"):
            (backups / name).mkdir()
            (backups / name / "SHA256SUMS").write_text("old fixture")
        (self.root / ".env").write_text("MYSQL_PASSWORD=test-only\nBACKUP_KEEP=1\n")
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        self.env.pop("BACKUP_KEEP", None)
        result = self.run_script("backup.sh")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        remaining = sorted(p.name for p in backups.iterdir())
        self.assertNotIn("20260101-010101", remaining)
        self.assertNotIn("20260102-010101", remaining)
        self.assertEqual(len(remaining), 1, f"only the new snapshot should remain: {remaining}")

    def test_retention_rejects_an_explicit_destination(self):
        result = self.run_script("backup.sh", "--keep", "2", "somewhere-else")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("default backups/ location", result.stderr)
        self.assertFalse(self.log.exists())

    def test_retention_rejects_a_non_numeric_value(self):
        result = self.run_script("backup.sh", "--keep", "all")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("non-negative integer", result.stderr)
        self.assertFalse(self.log.exists())

    def test_retention_accepts_a_zero_padded_value(self):
        # Bash arithmetic reads a leading zero as octal, so "08" must not abort
        # the run part-way through with "value too great for base".
        backups = self.root / "backups"
        backups.mkdir()
        for name in ("20260101-010101", "20260102-010101"):
            (backups / name).mkdir()
            (backups / name / "SHA256SUMS").write_text("old fixture")
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        result = self.run_script("backup.sh", "--keep", "08")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # 8 is more than exists, so nothing is pruned.
        self.assertIn("20260101-010101", [p.name for p in backups.iterdir()])

    def test_missing_external_volume_is_not_created_locally(self):
        self.archive()
        self.config["volumes"]["media"]["external"] = True
        self.env["TEST_MISSING_VOLUME"] = "institution-media"
        result = self.run_script("restore.sh", "--force", "backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be provisioned", result.stderr)
        self.assertNotIn("volume create", self.log.read_text())

    def test_invalid_fpm_pool_is_rejected_before_writing(self):
        entrypoint = (REPO / "docker-entrypoint.sh").read_text()
        function = entrypoint[entrypoint.index("fpm_pool_config() {"):entrypoint.index("omeka_create_db_config() {")]
        (self.root / "scripts/pool-test.sh").write_text(
            '#!/bin/bash\nset -eu\nlog_step() { :; }\nlog_error() { echo "$*" >&2; }\n'
            + function + '\nfpm_pool_config\n')
        self.env["PHP_PM_MAX_CHILDREN"] = "1"
        result = self.run_script("pool-test.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("min_spare <= start_servers", result.stderr)

    def test_refused_smoke_test_does_not_delete_real_configuration(self):
        shutil.copyfile(REPO / ".github/scripts/smoke.sh", self.root / "scripts/smoke-test.sh")
        result = self.run_script("smoke-test.sh", "base")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disposable checkout", result.stderr)
        self.assertEqual((self.root / "_docker/restored-local.config.php").read_text(), "original config")
        self.assertTrue((self.root / ".env").exists())
        self.assertFalse(self.log.exists())


class SecretFiles(unittest.TestCase):
    """compose.secrets.yml: backup.sh and restore.sh carry the secret files."""

    # Same fixture as Operations, without inheriting (and re-running) its tests.
    setUp = Operations.setUp
    write_executable = Operations.write_executable
    run_script = Operations.run_script
    archive = Operations.archive

    NAMES = ("mysql_password", "omeka_secret_key", "typesense_api_key", "omeka_admin_password")

    def use_secrets(self):
        directory = self.root / "secrets"
        self.config["secrets"] = {
            name: {"name": "test_" + name, "file": (directory / name).as_posix()} for name in self.NAMES
        }
        return directory

    def permissive_docker(self):
        # restore.sh runs many containers; accept them all, log every call.
        self.write_executable("docker", '#!/bin/bash\nprintf "%s\\n" "$*" >> "$TEST_LOG"\n'
                              'if [[ "$*" == compose*"config --format json" ]]; then printf "%s\\n" "$TEST_CONFIG"; fi\n'
                              'exit 0\n')

    def test_backup_copies_secret_files_privately(self):
        directory = self.use_secrets()
        directory.mkdir(mode=0o700)
        for name in self.NAMES:
            (directory / name).write_text("value-of-" + name)
            (directory / name).chmod(0o644)
        (directory / "omeka_admin_password").write_text("")
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        result = self.run_script("backup.sh", "new-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backup = self.root / "new-backup"
        self.assertEqual((backup / "secrets").stat().st_mode & 0o777, 0o700)
        sums = (backup / "SHA256SUMS").read_text()
        for name in self.NAMES:
            copy = backup / "secrets" / name
            self.assertEqual(copy.read_text(), (directory / name).read_text())
            self.assertEqual(copy.stat().st_mode & 0o777, 0o600)
            self.assertIn("  secrets/" + name + "\n", sums)

    def test_backup_fails_on_a_missing_secret_file(self):
        self.use_secrets().mkdir()
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        result = self.run_script("backup.sh", "new-backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Secret file for mysql_password is missing", result.stderr)
        self.assertTrue((self.root / "new-backup/BACKUP_INCOMPLETE").exists())

    def checksummed_archive_with_secrets(self):
        backup = self.archive()
        (backup / "secrets").mkdir(mode=0o700)
        for name in self.NAMES:
            (backup / "secrets" / name).write_text("backed-up-" + name)
        names = ["BACKUP_FORMAT", "omeka_db.sql", "omeka_media.tar.gz", "local.config.php"]
        names += ["secrets/" + name for name in self.NAMES]
        (backup / "SHA256SUMS").write_text("".join(
            hashlib.sha256((backup / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names))
        return backup

    def test_restore_puts_back_missing_secrets_and_keeps_existing_ones(self):
        backup = self.checksummed_archive_with_secrets()
        directory = self.use_secrets()
        directory.mkdir(mode=0o700)
        (directory / "mysql_password").write_text("current-db-password")
        self.permissive_docker()
        result = self.run_script("restore.sh", "--force", "backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The database user's password lives in the existing volume: keep it.
        self.assertEqual((directory / "mysql_password").read_text(), "current-db-password")
        self.assertIn("differs from the backup", result.stderr)
        for name in self.NAMES[1:]:
            self.assertEqual((directory / name).read_text(), (backup / "secrets" / name).read_text())
            self.assertEqual((directory / name).stat().st_mode & 0o777, 0o644)

    def test_restore_refuses_a_secret_it_cannot_supply(self):
        self.archive()
        self.use_secrets().mkdir()
        self.permissive_docker()
        result = self.run_script("restore.sh", "--force", "backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backup has no copy", result.stderr)
        self.assertNotIn("volume create", self.log.read_text())

    def test_restore_rejects_an_unlisted_secret_file(self):
        backup = self.checksummed_archive_with_secrets()
        (backup / "secrets" / "extra").write_text("not in the manifest")
        self.permissive_docker()
        result = self.run_script("restore.sh", "--force", "backup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("secrets/extra exists but is not covered", result.stderr)


class CaddyCertificates(unittest.TestCase):
    """compose.tls.yml: the caddy_data volume travels with the backup."""

    setUp = Operations.setUp
    write_executable = Operations.write_executable
    run_script = Operations.run_script
    archive = Operations.archive
    permissive_docker = SecretFiles.permissive_docker

    def use_tls(self):
        self.config["services"]["caddy"] = {"volumes": [
            {"type": "volume", "source": "caddy_data", "target": "/data"},
            {"type": "volume", "source": "caddy_config", "target": "/config"}]}
        self.config["volumes"]["caddy_data"] = {"name": "test_caddy_data"}
        self.config["volumes"]["caddy_config"] = {"name": "test_caddy_config"}

    def test_backup_includes_caddy_data_only_with_the_overlay(self):
        self.use_tls()
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        result = self.run_script("backup.sh", "new-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        backup = self.root / "new-backup"
        self.assertTrue((backup / "caddy_data.tar.gz").is_file())
        self.assertIn("  caddy_data.tar.gz\n", (backup / "SHA256SUMS").read_text())
        self.assertIn("test_caddy_data:/data:ro", self.log.read_text())
        # Caddy's autosaved running config is regenerated at start: not backed up.
        self.assertNotIn("test_caddy_config", self.log.read_text())

    def test_backup_skips_a_caddy_volume_that_was_never_created(self):
        self.use_tls()
        self.env["TEST_ARCHIVE_SUCCESS"] = "1"
        self.env["TEST_MISSING_VOLUME"] = "test_caddy_data"
        result = self.run_script("backup.sh", "new-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.root / "new-backup/caddy_data.tar.gz").exists())

    def checksummed_archive_with_caddy(self):
        backup = self.archive()
        (backup / "caddy_data.tar.gz").write_text("caddy fixture")
        names = ["BACKUP_FORMAT", "omeka_db.sql", "omeka_media.tar.gz", "local.config.php", "caddy_data.tar.gz"]
        (backup / "SHA256SUMS").write_text("".join(
            hashlib.sha256((backup / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in names))
        return backup

    def test_restore_puts_caddy_data_back_with_the_overlay(self):
        self.checksummed_archive_with_caddy()
        self.use_tls()
        self.permissive_docker()
        result = self.run_script("restore.sh", "--force", "backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.log.read_text()
        self.assertIn("volume create test_caddy_data", log)
        self.assertIn("-v test_caddy_data:/data", log)
        self.assertIn("caddy_data volume restored", result.stdout)

    def test_restore_skips_caddy_data_without_the_overlay(self):
        self.checksummed_archive_with_caddy()
        self.permissive_docker()
        result = self.run_script("restore.sh", "--force", "backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("compose.tls.yml is not active", result.stdout)
        self.assertNotIn("caddy", self.log.read_text())


class RestorePreflight(unittest.TestCase):
    """restore.sh refuses dumps MySQL 9 cannot import before changing anything."""

    setUp = Operations.setUp
    write_executable = Operations.write_executable
    run_script = Operations.run_script
    archive = Operations.archive

    # What backup.sh's mysqldump writes, abridged: header, conditional
    # comments, tables in this server's collations, data, trailer.
    OWN_DUMP = "\n".join([
        "-- MySQL dump 10.13  Distrib 9.7.0, for Linux (x86_64)",
        "--",
        "-- Host: localhost    Database: omeka",
        "-- ------------------------------------------------------",
        "-- Server version\t9.7.0",
        "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;",
        "/*!50503 SET NAMES utf8mb4 */;",
        "DROP TABLE IF EXISTS `setting`;",
        "CREATE TABLE `setting` (`id` varchar(190) COLLATE utf8mb4_unicode_ci NOT NULL)"
        " ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;",
        # Data may mention anything, including the patterns refused below.
        "INSERT INTO `setting` VALUES ('note','\\\"USE `x`; utf8mb4_uca1400_ai_ci\\\"');",
        "/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;",
        "-- Dump completed on 2026-11-20 10:00:00",
        ""])

    def restore_with(self, dump):
        backup = self.archive()
        (backup / "omeka_db.sql").write_text(dump)
        # Declined at the prompt: the pre-flight must have run by then.
        return self.run_script("restore.sh", "backup", input="n\n")

    def assert_refused(self, result, *hints):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot be imported into this stack", result.stderr)
        for hint in ("import-external.sh", "docs/MIGRATING.md", *hints):
            self.assertIn(hint, result.stderr)
        # Before Compose, volumes or containers were even looked at.
        self.assertFalse(self.log.exists())

    def test_own_backup_dump_passes_silently(self):
        result = self.restore_with(self.OWN_DUMP)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Aborted", result.stdout)
        self.assertNotIn("trailer", result.stderr)
        self.assertNotIn("ERROR", result.stderr)

    def test_mariadb_sandbox_line_is_refused(self):
        result = self.restore_with("/*M!999999\\- enable the sandbox mode */\n" + self.OWN_DUMP)
        self.assert_refused(result, "sandbox", "--fix-mariadb")

    def test_uca1400_collation_is_refused(self):
        result = self.restore_with(self.OWN_DUMP.replace("COLLATE=utf8mb4_unicode_ci", "COLLATE=utf8mb4_uca1400_ai_ci"))
        self.assert_refused(result, "uca1400", "--fix-mariadb")

    def test_use_statement_is_refused(self):
        result = self.restore_with(self.OWN_DUMP.replace("DROP TABLE", "USE `old_omeka`;\nDROP TABLE", 1))
        self.assert_refused(result, "USE `old_omeka`", "--fix-portability")

    def test_create_database_is_refused(self):
        result = self.restore_with(self.OWN_DUMP.replace(
            "DROP TABLE", "CREATE DATABASE /*!32312 IF NOT EXISTS*/ `old_omeka`;\nDROP TABLE", 1))
        self.assert_refused(result, "CREATE DATABASE", "--fix-portability")

    def test_missing_trailer_warns_but_continues(self):
        result = self.restore_with(self.OWN_DUMP.replace("-- Dump completed on 2026-11-20 10:00:00\n", ""))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("no '-- Dump completed' trailer", result.stderr)
        self.assertIn("Aborted", result.stdout)

    def test_headerless_dump_without_trailer_is_not_flagged(self):
        # Not every exporter writes the mysqldump header/trailer pair.
        result = self.restore_with("CREATE TABLE `setting` (`id` int);\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("trailer", result.stderr)


class PinnedImages(unittest.TestCase):
    """The alpine pin is repeated outside any Dependabot ecosystem."""

    def test_helper_image_matches_the_dockerfile_alpine_pin(self):
        # backup.sh and restore.sh run their tar/test work in a throwaway alpine
        # container. That pin is plain shell, so no Dependabot ecosystem offers
        # it an update and a Dockerfile bump would leave it behind on an image
        # that stops receiving security patches. Assert the three agree, so a
        # Dependabot PR that touches only the Dockerfile fails here and the
        # scripts get updated in the same commit.
        dockerfile = (REPO / "Dockerfile").read_text(encoding="utf-8")
        pins = re.findall(r"^FROM\s+(alpine:\S+)", dockerfile, re.MULTILINE)
        self.assertEqual(
            len(pins), 1, f"expected exactly one alpine FROM in the Dockerfile, got {pins}"
        )
        expected = pins[0]
        self.assertIn("@sha256:", expected, "the Dockerfile alpine pin must carry a digest")
        for script in ("scripts/backup.sh", "scripts/restore.sh"):
            found = re.findall(
                r'^HELPER_IMAGE="([^"]+)"',
                (REPO / script).read_text(encoding="utf-8"),
                re.MULTILINE,
            )
            self.assertEqual(found, [expected], f"{script} HELPER_IMAGE must be {expected}")

    def test_omeka_version_defaults_agree(self):
        # The fallback after `:-` is the version a deployment gets when .env
        # does not pin OMEKA_VERSION, which is the common case. It is spelled
        # out in the Dockerfile ARG, in three Compose entries, and once more as
        # update-omeka.sh's idea of the current version — so a partial bump
        # makes update-omeka.sh report an upgrade that is already built, or
        # rebuild php and web from different cores.
        sources = {
            "Dockerfile": r"^ARG OMEKA_VERSION=(\S+)",
            "docker-compose.yml": r"\$\{OMEKA_VERSION:-([^}]+)\}",
            "scripts/update-omeka.sh": r'^current="\$\{current:-([^}]+)\}"',
        }
        found = {}
        for name, pattern in sources.items():
            matches = re.findall(pattern, (REPO / name).read_text(encoding="utf-8"), re.MULTILINE)
            self.assertTrue(matches, f"no OMEKA_VERSION default found in {name}")
            self.assertEqual(
                len(set(matches)), 1, f"{name} disagrees with itself about OMEKA_VERSION: {matches}"
            )
            found[name] = matches[0]
        self.assertEqual(
            len(set(found.values())), 1, f"OMEKA_VERSION defaults disagree: {found}"
        )


class ImportExternal(unittest.TestCase):
    """scripts/import-external.sh must write what restore.sh, unchanged, accepts.

    Self-contained: builds a fake classic Omeka S tree (paths with spaces) and
    a fake Docker CLI that runs restore.sh's helper-container scripts against
    local directories, so the real restore.sh validation and extraction run.
    """

    TABLES = ("resource", "item", "media", "setting", "module", "user", "site", "vocabulary")

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="omeka import ")
        self.addCleanup(temp.cleanup)
        self.base = Path(temp.name)
        self.root = self.base / "project"
        shutil.copytree(REPO / "scripts", self.root / "scripts")
        (self.root / "_docker").mkdir()
        shutil.copyfile(REPO / "_docker/local.config.php", self.root / "_docker/local.config.php")
        (self.root / "_docker/default-modules.txt").write_text(
            "# comment\nActivityLog\ngh:Daniel-KM/Omeka-S-module-Common\n")
        (self.root / "Dockerfile").write_text("ARG OMEKA_VERSION=4.2.1\n")
        (self.root / ".env").write_text("MYSQL_PASSWORD=test-only\n")
        self.old = self.base / "old site"
        for sub in ("application", "config", "files/original", "files/large", "files/asset",
                    "modules/Mapping/config", "themes/default/config"):
            (self.old / sub).mkdir(parents=True)
        (self.old / "application/Module.php").write_text("<?php\nclass Module {\n    const VERSION = '4.1.1';\n}\n")
        (self.old / "config/database.ini").write_text(
            'user = "olduser"\npassword = "never-print-me"\ndbname = "old_omeka"\nhost = "db.local"\n')
        (self.old / "config/local.config.php").write_text("<?php\nreturn ['cli' => ['phpcli_path' => null]];\n")
        (self.old / "files/original/photo one.jpg").write_text("original")
        (self.old / "files/large/photo one.jpg").write_text("large")
        (self.old / "modules/Mapping/config/module.ini").write_text('[info]\nversion = "1.9.0"\n')
        (self.old / "themes/default/config/theme.ini").write_text("[info]\n")
        self.dump = self.base / "old dump.sql"
        self.dump.write_text(self.sql())
        # The fake Docker splices these paths into helper scripts, so keep them
        # free of spaces; the backup itself still lives under a spaced path.
        volumes = tempfile.TemporaryDirectory(prefix="omeka-import-volumes-")
        self.addCleanup(volumes.cleanup)
        self.volumes = Path(volumes.name)
        (self.base / "bin").mkdir()
        docker = self.base / "bin/docker"
        docker.write_text(r'''#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG"
case "$1 $2" in
  'compose config') printf '%s\n' "$TEST_CONFIG"; exit 0 ;;
  'compose ps'|'compose up'|'compose down') exit 0 ;;
  'volume inspect') exit 1 ;;
  'volume create') mkdir -p "$TEST_VOLUMES/$3"; exit 0 ;;
  'compose exec')
    case "$*" in
      *'SELECT 1'*|*'DROP DATABASE'*) exit 0 ;;
      *) cat > "$TEST_VOLUMES/imported.sql"; exit 0 ;;
    esac ;;
esac
[[ "$1" == run ]] || { echo "Unexpected fake Docker command: $*" >&2; exit 93; }
shift
envs=() data="" backup="" script=""
while (($#)); do
  case "$1" in
    -e) envs+=("$2"); shift ;;
    -v) case "$2" in
          *:/data) data="$TEST_VOLUMES/${2%:/data}" ;;
          *:/backup:ro) ln -sfn "${2%:/backup:ro}" "$TEST_VOLUMES/backup-link"; backup="$TEST_VOLUMES/backup-link" ;;
        esac
        shift ;;
    -c) script="$2"; break ;;
  esac
  shift
done
script="${script//\/data/$data}"
script="${script//\/backup/$backup}"
exec env "${envs[@]}" sh -eu -c "$script"
''', newline="\n")
        docker.chmod(0o755)
        self.config = {"name": "test", "services": {
            "php": {"volumes": [
                {"type": "volume", "source": name, "target": "/var/www/html/" + name}
                for name in ("files", "logs", "modules", "themes")]},
            "db": {"volumes": [{"type": "volume", "source": "db", "target": "/var/lib/mysql"}]}},
            "volumes": {name: {"name": "vol-" + name} for name in ("files", "logs", "modules", "themes", "db")}}
        self.env = dict(os.environ, PATH=str(self.base / "bin") + os.pathsep + os.environ["PATH"],
                        TEST_LOG=(self.base / "docker.log").as_posix(), TEST_VOLUMES=self.volumes.as_posix(),
                        TEST_CONFIG=json.dumps(self.config), MSYS_NO_PATHCONV="1")
        self.output = self.root / "backups/imported one"

    def sql(self, header="-- MySQL dump 10.13  Distrib 8.0.36", extra="", tables=TABLES):
        lines = [header] + ["CREATE TABLE `%s` (`id` int) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;" % t for t in tables]
        lines += ["INSERT INTO `setting` VALUES ('administrator_email','\\\"a@example.org\\\"'),('version','\\\"4.1.1\\\"');",
                  extra, "-- Dump completed on 2026-11-20 10:00:00", ""]
        return "\n".join(lines)

    def run_script(self, name, *args):
        return subprocess.run([BASH, "scripts/" + name, *args], cwd=self.root, env=self.env,
                              text=True, capture_output=True, timeout=60)

    def run_import(self, *args):
        return self.run_script("import-external.sh", "--database", str(self.dump),
                               "--output", str(self.output), *args)

    def snapshot(self, path):
        return sorted((str(p.relative_to(path)), p.stat().st_mode, p.stat().st_size, p.stat().st_mtime_ns)
                      for p in path.rglob("*"))

    def test_output_passes_the_real_restore(self):
        before = self.snapshot(self.old)
        result = self.run_import("--omeka-root", str(self.old))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.snapshot(self.old), before, "the source must not be modified")
        self.assertEqual(sorted(p.name for p in self.output.iterdir()), sorted([
            "BACKUP_FORMAT", "SHA256SUMS", "local.config.php", "omeka_db.sql",
            "omeka_media.tar.gz", "omeka_modules.tar.gz", "omeka_themes.tar.gz"]))
        self.assertEqual((self.output / "BACKUP_FORMAT").read_text(), "omeka-docker-backup-v2\nlayout=immutable\n")
        self.assertIn("OMEKA_VERSION=4.2.1", result.stdout)
        self.assertIn("core:migrate", result.stdout)
        self.assertIn("ActivityLog", result.stderr)  # template default missing from the old modules
        import tarfile
        for name, expected in (("omeka_media.tar.gz", "./original/photo one.jpg"),
                               ("omeka_modules.tar.gz", "./Mapping/config/module.ini"),
                               ("omeka_themes.tar.gz", "./default/config/theme.ini")):
            with tarfile.open(self.output / name) as archive:
                members = archive.getmembers()
            names = [m.name for m in members]
            self.assertIn(expected, names)
            self.assertTrue(all(n == "." or n.startswith("./") for n in names), names)
            self.assertTrue(all((m.uid, m.gid) == (33, 33) for m in members), name)
            self.assertTrue(all(m.mode & 0o044 == 0o044 for m in members), name)
            if name == "omeka_media.tar.gz":
                self.assertIn("./.immutable-layout-v1", names)

        restore = self.run_script("restore.sh", "--force", "backups/imported one")
        self.assertEqual(restore.returncode, 0, restore.stdout + restore.stderr)
        self.assertIn("Verifying backup checksums", restore.stdout)
        self.assertIn("Backup layout: immutable", restore.stdout)
        self.assertNotIn("WARNING: No SHA256SUMS", restore.stderr)
        media = self.volumes / "vol-files"
        self.assertTrue((media / ".immutable-layout-v1").is_file())
        self.assertEqual((media / "original/photo one.jpg").read_text(), "original")
        self.assertTrue((self.volumes / "vol-modules/Mapping/config/module.ini").is_file())
        self.assertTrue((self.volumes / "vol-themes/default/config/theme.ini").is_file())
        self.assertEqual((self.volumes / "imported.sql").read_text(), self.dump.read_text())
        self.assertEqual((self.root / "_docker/restored-local.config.php").read_text(),
                         (self.old / "config/local.config.php").read_text())
        self.assertIn("OMEKA_LOCAL_CONFIG=./_docker/restored-local.config.php", (self.root / ".env").read_text())

    def test_archives_and_gzipped_dump_are_accepted(self):
        import gzip
        files_archive = self.base / "files backup.tar.gz"
        subprocess.run(["tar", "czf", str(files_archive), "-C", str(self.old), "files"], check=True)
        gz = self.base / "old dump.sql.gz"
        gz.write_bytes(gzip.compress(self.dump.read_bytes()))
        self.dump = gz
        result = self.run_import("--files", str(files_archive))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.output / "omeka_db.sql").read_text(), self.sql())
        listing = subprocess.run(["tar", "tzf", str(self.output / "omeka_media.tar.gz")],
                                 check=True, capture_output=True, text=True).stdout.splitlines()
        self.assertIn("./original/photo one.jpg", listing)
        self.assertFalse(any("files/" in n for n in listing), listing)
        self.assertFalse((self.output / ".import-staging").exists())
        # No --config: the template default is used, as restore.sh requires one.
        self.assertEqual((self.output / "local.config.php").read_text(),
                         (self.root / "_docker/local.config.php").read_text())

    def test_missing_original_is_rejected(self):
        shutil.rmtree(self.old / "files/original")
        result = self.run_import("--omeka-root", str(self.old))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No original/", result.stderr)
        self.assertFalse(self.output.exists())

    def test_non_omeka_dump_is_rejected(self):
        self.dump.write_text(self.sql(tables=("wp_posts", "wp_options")))
        result = self.run_import("--omeka-root", str(self.old))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not look like an Omeka S database", result.stderr)
        self.assertFalse(self.output.exists())

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir(parents=True)
        (self.output / "keep").write_text("mine")
        result = self.run_import("--omeka-root", str(self.old))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("already exists", result.stderr)
        self.assertEqual([p.name for p in self.output.iterdir()], ["keep"])

    def test_dry_run_writes_nothing(self):
        result = self.run_import("--omeka-root", str(self.old), "--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("nothing was written", result.stdout)
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root / "backups").exists())

    def test_missing_database_prints_dump_command_without_password(self):
        result = self.run_script("import-external.sh", "--omeka-root", str(self.old))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        for fragment in ("--single-transaction --routines --triggers --no-tablespaces",
                         "--default-character-set=utf8mb4", "-u olduser -p", "old_omeka", "db.local"):
            self.assertIn(fragment, result.stdout)
        self.assertNotIn("never-print-me", result.stdout + result.stderr)

    def test_fix_mariadb_rewrites_only_when_asked(self):
        mariadb = ("/*!999999\\- enable the sandbox mode */\n"
                   + self.sql(header="-- MariaDB dump 10.19-11.4.2-MariaDB",
                              extra="CREATE TABLE `x` (`id` int) ENGINE=Aria PAGE_CHECKSUM=1 "
                                    "DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_uca1400_ai_ci;\n"
                                    "USE `old_omeka`;\n"
                                    "/*!50003 CREATE*/ /*!50017 DEFINER=`root`@`localhost`*/ /*!50003 TRIGGER t */;;"))
        self.dump.write_text(mariadb)
        plain = self.run_import("--omeka-root", str(self.old), "--dry-run")
        self.assertEqual(plain.returncode, 0, plain.stderr)
        for hint in ("sandbox mode", "--fix-mariadb", "DEFINER", "CREATE DATABASE/USE", "--fix-portability"):
            self.assertIn(hint, plain.stderr)
        result = self.run_import("--omeka-root", str(self.old), "--fix-mariadb", "--fix-portability")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        sql = (self.output / "omeka_db.sql").read_text()
        for gone in ("sandbox mode", "uca1400", "ENGINE=Aria", "PAGE_CHECKSUM", "DEFINER=", "USE `old_omeka`"):
            self.assertNotIn(gone, sql)
        self.assertIn("COLLATE=utf8mb4_unicode_ci", sql)
        self.assertIn("ENGINE=InnoDB", sql)
        self.assertIn("/*!50017*/", sql)
        self.assertIn("('version','\\\"4.1.1\\\"')", sql, "data rows must be left alone")
        self.assertEqual(self.dump.read_text(), mariadb, "the source dump must not be modified")


if __name__ == "__main__":
    unittest.main()
