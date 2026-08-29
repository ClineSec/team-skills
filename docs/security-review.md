# Milestone 5 security review

This review treats bootstrap input, Git origins, fetched commits, catalog files, product
configuration, and owned-state files as untrusted data. It does not add source signing or claim
that a valid catalog author is benign.

## Trust boundaries

- The bootstrap script is executable code obtained and approved by the user. It may clone only the
  URL supplied for that initial operation.
- The managed clone's configured `origin` is the sole later network authority. There is no baked
  upstream or fallback. Origin text and Git diagnostics may contain credentials and are suppressed
  from lifecycle output and hook logs.
- A fetched commit is only a candidate. It must fast-forward the installed revision and contain a
  complete, ordinary-path catalog plus all POSIX and Windows lifecycle files. Native syntax is
  checked before the managed clone advances.
- Canonical skills are instructions trusted from the selected catalog author after structural
  validation. Team Skills does not sandbox skill behavior or authenticate commits beyond Git's
  configured transport.
- Hook commands are locally generated executable configuration. Exact config path, exact command,
  and exact structural entry jointly prove ownership for removal.
- Product hook files and foreign skill destinations are user-owned. They are staged, compared
  again before atomic replacement, and never recursively deleted by Team Skills.

## Adversary and protected assets

Relevant attackers include a compromised or mistaken catalog origin, malformed local product
configuration, a concurrent product start, a racing local process, and corrupted catalog-owned
state. Protected assets are unrelated user skills and configuration, last-known-good generations,
catalog isolation, credential-bearing origin values, and predictable session startup.

The main controls are origin-only fetches with prompting disabled, per-catalog locks and throttle
stamps, exact pinned candidates across prefixes, fast-forward-only history, ordinary-file and
reparse-point checks, collision no-clobber semantics, immutable generations, atomic current-view
activation, exact ownership records, staged hook merges, bounded atomic logs, and rollback after
late failures.

## Accepted and rejected cases

Accepted cases include spaces, Unicode, quotes, and shell metacharacters in disposable absolute
paths; same-history mirror origins; concurrent session starts; foreign hook entries; foreign skill
collisions; and dead well-formed locks after the stale interval.

Rejected without mutation include relative, filesystem-root, non-normalized POSIX, symlinked or
reparse-point override targets; malformed or unsupported JSON; duplicate owned entries; changed
owned commands; linked canonical content; missing or malformed lifecycle files; invalid catalog
identity or names; credential-bearing fetch failures; unexpected lock contents; and non-fast-
forward, downgrade, or unrelated history.

## Residual risks and ownership

- Git transport and repository authorization are the catalog owner's trust decision. Commit
  signing, transparency, key management, and rollback authorization are outside the MVP and need a
  separate human-approved architecture.
- POSIX shell cannot make a multi-path user-profile transaction immune to a hostile same-user
  process replacing parent directories between checks. Final link creation is atomic/no-clobber,
  recursive deletion is limited to validated catalog-owned state, and ambiguous changes fail
  closed; stronger descriptor-relative filesystem operations would require a nonstandard runtime.
- Each prefix activation is individually transactional. The updater pins one candidate and does
  not mark success until every prefix completes, but an environmental failure after an earlier
  prefix commits can temporarily leave prefixes at different known-good generations until retry.
  Catalog-wide filesystem transactions are not portable in the approved shell/PowerShell MVP.
- Human Claude Code, Codex, Cursor, and WSL verification remains pending. Automated tests do not
  substitute for those product checks, and no product was launched during this review.
