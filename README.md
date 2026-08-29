# Team Skills

Team Skills is a fork-first catalog for distributing user-global, portable Agent Skills to Claude
Code, Codex, and Cursor. A team forks the repository, curates `skills/`, and treats its own clone's
configured Git `origin` as the authority for future updates. No operational path may silently fall
back to the original upstream repository.

## Foundation status

Milestone 1 currently provides:

- a versioned catalog manifest and a normative multi-catalog contract;
- cross-agent authoring rules for canonical skills;
- a portable bundled `skill-creator` with a deterministic scaffold helper;
- dependency-free validation, tests, and a three-OS CI definition.

It does **not** yet install skills into user directories, merge product configuration or hooks,
fetch updates, provide rollback/uninstall, or prove behavior inside the three products. Those are
milestones 2-5. There is intentionally no bootstrap install command yet; adding one before the
installer exists would misrepresent the foundation as usable lifecycle tooling.

## Fork-first workflow

1. Fork this repository and clone the fork so `origin` points to the team's repository.
2. Keep `catalog.json` portable. Forks do not need to change `catalog_id`; the future installer
   distinguishes catalog instances with an origin-derived fingerprint.
3. Create or revise skills under `skills/`. The bundled `skill-creator` describes the authoring
   workflow and its helper can scaffold a complete skill without a product-native creator.
4. Run the validation commands below and commit directly to the fork's `main` branch.
5. After milestone 2 lands, use that fork's bootstrap command. The repository URL will be used only
   to make the initial clone; updates will read the clone's configured `origin`.

## Repository layout

```text
catalog.json                   Catalog metadata and defaults
schemas/catalog.schema.json    Machine-readable manifest schema
skills/<name>/                 Canonical portable skills
docs/catalog-contract.md       Identity, collision, prefix, and update contract
docs/skill-authoring.md        Cross-agent authoring subset
scripts/validate.py            Dependency-free repository validator
tests/                         Foundation contract tests
```

## Validate

Python 3.9 or newer is sufficient; the repository has no runtime package dependencies.

```sh
python3 scripts/validate.py
python3 -m unittest discover -s tests -v
```

The canonical format follows the primary documentation reviewed on 2026-08-29:

- [Agent Skills specification](https://agentskills.io/specification)
- [Claude Code skills](https://code.claude.com/docs/en/skills)
- [Codex skills](https://developers.openai.com/codex/skills)
- [Cursor Agent Skills](https://cursor.com/docs/skills)

See [the catalog contract](docs/catalog-contract.md) for the exact multi-catalog semantics and
[the authoring guide](docs/skill-authoring.md) for the portable subset.
