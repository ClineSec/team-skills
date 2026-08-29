from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts" / "team-skills.ps1"
POWERSHELL = shutil.which("powershell.exe") or shutil.which("powershell")


@unittest.skipUnless(os.name == "nt" and POWERSHELL, "native PowerShell tests run on Windows CI")
class PowerShellInstallerTests(unittest.TestCase):
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
                "USERPROFILE": str(self.home),
                "LOCALAPPDATA": str(self.home / "AppData" / "Local"),
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

    def make_catalog(self, label: str, body: str) -> tuple[Path, Path]:
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
        (skill / "references").mkdir(parents=True)
        (skill / "SKILL.md").write_text(
            "---\nname: common-skill\ndescription: A fixture skill.\n---\n\n" + body + "\n",
            encoding="utf-8",
        )
        (skill / "references" / "fixture.txt").write_bytes(b"fixture bytes\r\n")
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
        assert POWERSHELL
        return subprocess.run(
            [
                POWERSHELL,
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(INSTALLER),
                action,
                str(origin),
                *extra,
            ],
            text=True,
            capture_output=True,
            check=False,
            env=self.env,
        )

    def remove_junction(self, path: Path) -> None:
        # os.rmdir maps to RemoveDirectoryW and removes the junction, not its target.
        os.rmdir(path)

    def test_two_origins_collision_prefix_idempotence_and_safe_remove(self) -> None:
        _, first_origin = self.make_catalog("first", "# First catalog")
        _, second_origin = self.make_catalog("second", "# Second catalog")

        first = self.run_installer("install", first_origin)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_exposure = self.agents / "common-skill"
        self.assertIn("# First catalog", (first_exposure / "SKILL.md").read_text())

        repeated = self.run_installer("install", first_origin)
        self.assertEqual(repeated.returncode, 0, repeated.stderr)
        self.assertEqual(len(list((self.state / "catalogs").iterdir())), 1)

        collision = self.run_installer("install", second_origin)
        self.assertEqual(collision.returncode, 0, collision.stderr)
        self.assertIn("warning", collision.stderr.lower())
        self.assertIn("common-skill skipped", collision.stderr)
        self.assertIn("# First catalog", (first_exposure / "SKILL.md").read_text())

        prefixed = self.run_installer("install", second_origin, "-Prefix", "second")
        self.assertEqual(prefixed.returncode, 0, prefixed.stderr)
        prefixed_exposure = self.claude / "second-common-skill"
        prefixed_text = (prefixed_exposure / "SKILL.md").read_text()
        self.assertIn("name: second-common-skill", prefixed_text)
        self.assertIn("# Second catalog", prefixed_text)
        self.assertEqual(
            (prefixed_exposure / "references" / "fixture.txt").read_bytes(), b"fixture bytes\r\n"
        )

        changed = self.claude / "common-skill"
        self.remove_junction(changed)
        changed.mkdir()
        marker = changed / "user-owned.txt"
        marker.write_bytes(b"preserve me byte-for-byte\r\n")
        removed = self.run_installer("remove", first_origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(first_exposure.exists())
        self.assertEqual(marker.read_bytes(), b"preserve me byte-for-byte\r\n")
        self.assertIn("not removing changed path", removed.stderr)
        self.assertTrue(prefixed_exposure.exists())

    def test_invalid_update_retains_last_known_good_and_output_hides_credentials(self) -> None:
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

        secret_url = "file://fixture-user:fixture-password@/definitely/missing/catalog.git"
        clone_failure = self.run_installer("install", secret_url)
        self.assertNotEqual(clone_failure.returncode, 0)
        combined = clone_failure.stdout + clone_failure.stderr
        self.assertNotIn("fixture-user", combined)
        self.assertNotIn("fixture-password", combined)
        self.assertIn("unable to clone the supplied repository", combined)

    def test_configured_origin_can_change_without_changing_instance_ownership(self) -> None:
        _, initial_origin = self.make_catalog("initial", "# Initial origin")
        _, replacement_origin = self.make_catalog("replacement", "# Replacement origin")
        installed = self.run_installer("install", initial_origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)

        instance_roots = list((self.state / "catalogs").iterdir())
        self.assertEqual(len(instance_roots), 1)
        managed_repo = instance_roots[0] / "repo"
        self.git("remote", "set-url", "origin", str(replacement_origin), cwd=managed_repo)

        reconciled = self.run_installer("install", initial_origin)
        self.assertEqual(reconciled.returncode, 0, reconciled.stderr)
        self.assertIn(
            "# Replacement origin", (self.agents / "common-skill" / "SKILL.md").read_text()
        )
        self.assertEqual(list((self.state / "catalogs").iterdir()), instance_roots)

        removed = self.run_installer("remove", initial_origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse(self.agents.joinpath("common-skill").exists())

    def test_late_exposure_race_rolls_back_generation_and_ownership(self) -> None:
        work, origin = self.make_catalog("race", "# Known good")
        installed = self.run_installer("install", origin)
        self.assertEqual(installed.returncode, 0, installed.stderr)
        original = (self.agents / "common-skill" / "SKILL.md").read_bytes()

        common_skill = work / "skills" / "common-skill" / "SKILL.md"
        common_skill.write_text(
            common_skill.read_text(encoding="utf-8").replace("# Known good", "# Candidate"),
            encoding="utf-8",
        )
        # Creating several planned junctions makes the post-activation race deterministic on CI.
        for index in range(24):
            skill_name = f"a{index:02d}-filler-skill"
            skill = work / "skills" / skill_name
            skill.mkdir()
            (skill / "SKILL.md").write_text(
                f"---\nname: {skill_name}\ndescription: Race fixture.\n---\n\n# Filler\n",
                encoding="utf-8",
            )
        raced_skill = work / "skills" / "zz-race-skill"
        raced_skill.mkdir()
        (raced_skill / "SKILL.md").write_text(
            "---\nname: zz-race-skill\ndescription: Raced fixture.\n---\n\n# Raced\n",
            encoding="utf-8",
        )
        self.git("add", ".", cwd=work)
        self.git("commit", "-m", "valid raced candidate", cwd=work)
        self.git("push", cwd=work)

        race_path = self.agents / "zz-race-skill"
        race_created = threading.Event()
        stop_racer = threading.Event()

        def race_after_activation() -> None:
            while not stop_racer.is_set():
                try:
                    if b"# Candidate" in (self.agents / "common-skill" / "SKILL.md").read_bytes():
                        race_path.write_bytes(b"race winner\r\n")
                        race_created.set()
                        return
                except (FileNotFoundError, OSError):
                    pass
                time.sleep(0.001)

        racer = threading.Thread(target=race_after_activation, daemon=True)
        racer.start()
        failed = self.run_installer("install", origin)
        stop_racer.set()
        racer.join(timeout=5)

        self.assertTrue(race_created.is_set(), "test racer did not observe candidate activation")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("cannot expose skill zz-race-skill", failed.stderr)
        self.assertEqual(race_path.read_bytes(), b"race winner\r\n")
        self.assertEqual((self.agents / "common-skill" / "SKILL.md").read_bytes(), original)

        install_root = next((self.state / "catalogs").iterdir()) / "installs" / "_default"
        self.assertIn("# Known good", (install_root / "current" / "common-skill" / "SKILL.md").read_text())
        self.assertFalse((install_root / "ownership" / "agents" / "zz-race-skill.owner").exists())
        for index in range(24):
            skill_name = f"a{index:02d}-filler-skill"
            self.assertFalse((self.agents / skill_name).exists())
            self.assertFalse((self.claude / skill_name).exists())
        for product_root, product in ((self.agents, "agents"), (self.claude, "claude")):
            owner_file = install_root / "ownership" / product / "common-skill.owner"
            self.assertTrue(owner_file.is_file())
            self.assertTrue((product_root / "common-skill").exists())

        race_path.unlink()
        rerun = self.run_installer("install", origin)
        self.assertEqual(rerun.returncode, 0, rerun.stderr)
        self.assertIn("# Candidate", (self.agents / "common-skill" / "SKILL.md").read_text())
        self.assertIn("# Raced", (self.claude / "zz-race-skill" / "SKILL.md").read_text())

        removed = self.run_installer("remove", origin)
        self.assertEqual(removed.returncode, 0, removed.stderr)
        self.assertFalse((self.agents / "common-skill").exists())
        self.assertFalse((self.claude / "zz-race-skill").exists())


if __name__ == "__main__":
    unittest.main()
