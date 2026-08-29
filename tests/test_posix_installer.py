from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "team-skills.sh"


@unittest.skipIf(os.name == "nt", "POSIX installer tests run on POSIX CI workers")
class PosixInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="team skills ")
        self.base = Path(self.temporary.name)
        self.home = self.base / "disposable home"
        self.state = self.base / "state root"
        self.agents = self.home / ".agents" / "skills"
        self.claude = self.home / ".claude" / "skills"
        self.home.mkdir()
        self.env = os.environ.copy()
        self.env.update(
            {
                "HOME": str(self.home),
                "TEAM_SKILLS_STATE_ROOT": str(self.state),
                "TEAM_SKILLS_AGENTS_ROOT": str(self.agents),
                "TEAM_SKILLS_CLAUDE_ROOT": str(self.claude),
                "GIT_CONFIG_NOSYSTEM": "1",
            }
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *args: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            ["git", *args], cwd=cwd, text=True, capture_output=True, check=False, env=self.env
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def make_catalog(
        self, label: str, body: str, *, executable_resource: bool = False
    ) -> tuple[Path, Path]:
        work = self.base / f"{label} work"
        origin = self.base / f"{label} origin.git"
        work.mkdir()
        manifest = {
            "$schema": "./schemas/catalog.schema.json",
            "schema_version": 1,
            "catalog_id": "shared-catalog-id",
            "display_name": label,
            "skills_directory": "skills",
            "default_prefix": "",
        }
        (work / "catalog.json").write_text(json.dumps(manifest, indent=2) + "\n")
        skill = work / "skills" / "common-skill"
        (skill / "scripts").mkdir(parents=True)
        (skill / "SKILL.md").write_text(
            "---\nname: common-skill\ndescription: A fixture skill.\n---\n\n" + body + "\n",
            encoding="utf-8",
        )
        helper = skill / "scripts" / "helper.sh"
        helper.write_text("#!/bin/sh\nprintf 'fixture\\n'\n", encoding="utf-8")
        if executable_resource:
            helper.chmod(helper.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        self.git("init", "--initial-branch=main", str(work))
        self.git("config", "user.name", "Installer Test", cwd=work)
        self.git("config", "user.email", "installer@example.invalid", cwd=work)
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "fixture catalog", cwd=work)
        self.git("init", "--bare", str(origin))
        self.git("remote", "add", "origin", str(origin), cwd=work)
        self.git("push", "-u", "origin", "main", cwd=work)
        self.git("symbolic-ref", "HEAD", "refs/heads/main", cwd=origin)
        return work, origin

    def run_installer(
        self, action: str, origin: Path | str, *extra: str
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["sh", str(INSTALLER), action, str(origin), *extra],
            text=True,
            capture_output=True,
            check=False,
            env=self.env,
        )

    def test_two_origins_collision_prefix_idempotence_and_safe_remove(self) -> None:
        _, first_origin = self.make_catalog("first", "# First catalog")
        _, second_origin = self.make_catalog(
            "second", "# Second catalog", executable_resource=True
        )

        first = self.run_installer("install", first_origin)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_link = self.agents / "common-skill"
        self.assertTrue(first_link.is_symlink())
        self.assertIn("# First catalog", (first_link / "SKILL.md").read_text())

        repeated = self.run_installer("install", first_origin)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(len(list((self.state / "catalogs").iterdir())), 1)

        collision = self.run_installer("install", second_origin)
        self.assertEqual(collision.returncode, 0, collision.stderr)
        self.assertIn("warning: catalog shared-catalog-id skill common-skill skipped", collision.stderr)
        self.assertIn("# First catalog", (first_link / "SKILL.md").read_text())
        self.assertEqual(len(list((self.state / "catalogs").iterdir())), 2)

        prefixed = self.run_installer("install", second_origin, "--prefix", "second")
        self.assertEqual(prefixed.returncode, 0, prefixed.stderr)
        prefixed_link = self.claude / "second-common-skill"
        self.assertTrue(prefixed_link.is_symlink())
        prefixed_text = (prefixed_link / "SKILL.md").read_text()
        self.assertIn("name: second-common-skill", prefixed_text)
        self.assertIn("# Second catalog", prefixed_text)
        helper_mode = (prefixed_link / "scripts" / "helper.sh").stat().st_mode
        self.assertTrue(helper_mode & stat.S_IXUSR)

        # A user replacement at an owned path revokes proof of ownership and survives removal.
        claude_first = self.claude / "common-skill"
        claude_first.unlink()
        claude_first.mkdir()
        marker = claude_first / "user-owned.txt"
        marker.write_bytes(b"preserve me byte-for-byte\n")
        removed = self.run_installer("remove", first_origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(first_link.exists())
        self.assertFalse(first_link.is_symlink())
        self.assertEqual(marker.read_bytes(), b"preserve me byte-for-byte\n")
        self.assertIn("not removing changed path", removed.stderr)
        self.assertTrue(prefixed_link.is_symlink())

    def test_invalid_fetched_catalog_retains_last_known_good_view(self) -> None:
        work, origin = self.make_catalog("update", "# Known good")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        exposed = self.agents / "common-skill" / "SKILL.md"
        original = exposed.read_bytes()

        skill_file = work / "skills" / "common-skill" / "SKILL.md"
        skill_file.write_text(
            skill_file.read_text(encoding="utf-8").replace(
                "name: common-skill", "name: mismatched-name"
            ),
            encoding="utf-8",
        )
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "malformed update", cwd=work)
        self.git("push", cwd=work)

        failed = self.run_installer("install", origin)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("keeping the last known-good installation", failed.stderr)
        self.assertEqual(exposed.read_bytes(), original)

    def test_clone_failure_does_not_print_credentials(self) -> None:
        secret_url = "file://fixture-user:fixture-password@/definitely/missing/catalog.git"
        result = self.run_installer("install", secret_url)
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertNotIn("fixture-user", combined)
        self.assertNotIn("fixture-password", combined)
        self.assertIn("unable to clone the supplied repository", combined)

    def test_invalid_root_fails_before_clone_or_mutation(self) -> None:
        self.env["TEAM_SKILLS_STATE_ROOT"] = "relative/state"
        result = self.run_installer("install", "/not/used")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be an absolute path", result.stderr)
        self.assertFalse((self.base / "relative").exists())


if __name__ == "__main__":
    unittest.main()
