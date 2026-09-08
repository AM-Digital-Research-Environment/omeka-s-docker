#!/usr/bin/env python3
"""Exercise operation failure paths with a fake Docker CLI; no real data touched."""
import json
import os
from pathlib import Path
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
    echo '| Probe | 1.0 | needs_upgrade |' ;;
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
        fake = fake.replace("echo '| Probe | 1.0 | needs_upgrade |'",
                            "printf '%s\\n' '| Probe | 1.0 | needs_upgrade |' '| SecondProbe | 1.0 | needs_upgrade |'")
        docker.write_text(fake)
        result = self.run_script("update-extensions.sh", "--no-backup")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        log = self.log.read_text()
        for name in ("First", "Second"):
            self.assertIn("https://example.org/" + name + ".zip", log)
        for name in ("Probe", "SecondProbe"):
            self.assertIn("module:upgrade --base-path /var/www/html " + name, log)

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


if __name__ == "__main__":
    unittest.main()
