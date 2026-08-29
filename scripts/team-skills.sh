#!/bin/sh
set -eu

# Team Skills milestone-2 lifecycle utility. Runtime dependencies: POSIX shell and Git.

PROGRAM=${0##*/}
ACTION=install
PREFIX_SET=0
PREFIX=
REPOSITORY_URL=

die() {
    printf '%s\n' "error: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $PROGRAM install <repository-url> [--prefix <prefix>]
       $PROGRAM remove  <repository-url> [--prefix <prefix>]

Environment overrides (primarily for tests and managed environments):
  TEAM_SKILLS_STATE_ROOT   default: \${XDG_DATA_HOME:-\$HOME/.local/share}/team-skills
  TEAM_SKILLS_AGENTS_ROOT  default: \$HOME/.agents/skills
  TEAM_SKILLS_CLAUDE_ROOT  default: \$HOME/.claude/skills
EOF
    exit 2
}

if [ "$#" -lt 2 ]; then
    usage
fi
ACTION=$1
REPOSITORY_URL=$2
shift 2
case $ACTION in
    install|remove) ;;
    *) usage ;;
esac
while [ "$#" -gt 0 ]; do
    case $1 in
        --prefix)
            [ "$#" -ge 2 ] || usage
            PREFIX=$2
            PREFIX_SET=1
            shift 2
            ;;
        *) usage ;;
    esac
done
[ -n "$REPOSITORY_URL" ] || die "repository URL must not be blank"

: "${HOME:?HOME must be set}"
STATE_ROOT=${TEAM_SKILLS_STATE_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/team-skills}
AGENTS_ROOT=${TEAM_SKILLS_AGENTS_ROOT:-$HOME/.agents/skills}
CLAUDE_ROOT=${TEAM_SKILLS_CLAUDE_ROOT:-$HOME/.claude/skills}

reject_unsafe_root() {
    root_value=$1
    root_label=$2
    [ -n "$root_value" ] || die "$root_label must not be blank"
    case $root_value in
        *'
'*|*''*|*'	'*) die "$root_label must not contain control characters" ;;
    esac
    case $root_value in
        /*) ;;
        *) die "$root_label must be an absolute path" ;;
    esac
    [ "$root_value" != / ] || die "$root_label must not be the filesystem root"
}

reject_unsafe_root "$STATE_ROOT" TEAM_SKILLS_STATE_ROOT
reject_unsafe_root "$AGENTS_ROOT" TEAM_SKILLS_AGENTS_ROOT
reject_unsafe_root "$CLAUDE_ROOT" TEAM_SKILLS_CLAUDE_ROOT

mkdir -p "$STATE_ROOT" || die "cannot create state root"
WORK_ROOT=$(mktemp -d "$STATE_ROOT/.operation.XXXXXXXX") || die "cannot create temporary state"
cleanup() {
    if [ -n "${CANDIDATE_WORKTREE:-}" ] && [ -n "${MANAGED_REPO:-}" ]; then
        git -C "$MANAGED_REPO" worktree remove --force "$CANDIDATE_WORKTREE" >/dev/null 2>&1 || :
    fi
    if [ -n "${NEXT_LINK:-}" ] && [ -L "$NEXT_LINK" ]; then
        rm "$NEXT_LINK" >/dev/null 2>&1 || :
    fi
    rm -rf "$WORK_ROOT"
}
trap cleanup EXIT HUP INT TERM

valid_name() {
    value=$1
    [ ${#value} -le 64 ] || return 1
    printf '%s\n' "$value" | LC_ALL=C grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'
}

json_string() {
    json_file=$1
    json_key=$2
    sed -n "s/^[[:space:]]*\"$json_key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p" "$json_file"
}

validate_skill() {
    skill_dir=$1
    expected_name=$2
    skill_file=$skill_dir/SKILL.md
    [ -f "$skill_file" ] && [ ! -L "$skill_file" ] || return 1
    declared_name=$(awk '
        NR == 1 { if ($0 != "---") exit 2; in_frontmatter=1; next }
        in_frontmatter && $0 == "---" { closed=1; exit }
        in_frontmatter && $0 ~ /^name:[[:space:]]*/ {
            if (seen) exit 3
            seen=1
            sub(/^name:[[:space:]]*/, "")
            print
        }
        END { if (!closed || !seen) exit 4 }
    ' "$skill_file") || return 1
    [ "$declared_name" = "$expected_name" ] || return 1
}

validate_catalog() {
    catalog_root=$1
    manifest=$catalog_root/catalog.json
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 1
    keys=$WORK_ROOT/manifest-keys
    expected=$WORK_ROOT/manifest-expected
    sed -n 's/^[[:space:]]*"\([^"]*\)"[[:space:]]*:.*/\1/p' "$manifest" | LC_ALL=C sort >"$keys"
    printf '%s\n' '$schema' catalog_id default_prefix display_name schema_version skills_directory | LC_ALL=C sort >"$expected"
    cmp -s "$keys" "$expected" || return 1
    [ "$(json_string "$manifest" '\$schema')" = './schemas/catalog.schema.json' ] || return 1
    [ "$(sed -n 's/^[[:space:]]*"schema_version"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*,\{0,1\}[[:space:]]*$/\1/p' "$manifest")" = 1 ] || return 1
    CATALOG_ID=$(json_string "$manifest" catalog_id)
    DISPLAY_NAME=$(json_string "$manifest" display_name)
    DEFAULT_PREFIX=$(json_string "$manifest" default_prefix)
    [ "$(json_string "$manifest" skills_directory)" = skills ] || return 1
    valid_name "$CATALOG_ID" || return 1
    [ -n "$DISPLAY_NAME" ] && [ ${#DISPLAY_NAME} -le 128 ] || return 1
    if [ -n "$DEFAULT_PREFIX" ]; then valid_name "$DEFAULT_PREFIX" || return 1; fi
    [ ${#DEFAULT_PREFIX} -le 62 ] || return 1
    skills_root=$catalog_root/skills
    [ -d "$skills_root" ] && [ ! -L "$skills_root" ] || return 1
    [ -z "$(find "$skills_root" -type l -print -quit)" ] || return 1
    found_skill=0
    for skill_dir in "$skills_root"/*; do
        [ -e "$skill_dir" ] || continue
        [ -d "$skill_dir" ] && [ ! -L "$skill_dir" ] || return 1
        skill_name=${skill_dir##*/}
        valid_name "$skill_name" || return 1
        validate_skill "$skill_dir" "$skill_name" || return 1
        found_skill=1
    done
    [ "$found_skill" -eq 1 ] || return 1
}

# Exact bootstrap URL values normally become exact configured-origin values. This private index
# lets reruns and removal find existing state without contacting a possibly unavailable remote.
SUPPLIED_DIGEST=$(printf '%s' "$REPOSITORY_URL" | git hash-object --stdin) || die "cannot calculate catalog identity"
ORIGIN_INDEX_ROOT=$STATE_ROOT/origins
ORIGIN_INDEX=$ORIGIN_INDEX_ROOT/$SUPPLIED_DIGEST.instance
EXISTING_INSTANCE=0
if [ -f "$ORIGIN_INDEX" ] && [ ! -L "$ORIGIN_INDEX" ]; then
    INSTANCE_KEY=$(sed -n '1p' "$ORIGIN_INDEX")
    case $INSTANCE_KEY in
        *[!a-z0-9-]*|'') die "catalog origin index is invalid" ;;
    esac
    INSTANCE_ROOT=$STATE_ROOT/catalogs/$INSTANCE_KEY
    MANAGED_REPO=$INSTANCE_ROOT/repo
    [ -d "$MANAGED_REPO/.git" ] || die "catalog origin index does not reference a managed clone"
    if ! validate_catalog "$MANAGED_REPO"; then
        die "managed catalog clone is invalid; keeping the last known-good installation"
    fi
    CONFIGURED_ORIGIN=$(git -C "$MANAGED_REPO" remote get-url origin 2>/dev/null) || die "managed clone has no configured origin"
    [ -n "$CONFIGURED_ORIGIN" ] || die "managed clone origin must not be blank"
    INSTANCE_DIGEST=${INSTANCE_KEY#"$CATALOG_ID"-}
    [ "$INSTANCE_DIGEST" != "$INSTANCE_KEY" ] || die "catalog origin index identity mismatch"
    [ ${#INSTANCE_DIGEST} -eq 40 ] || die "catalog origin index identity mismatch"
    case $INSTANCE_DIGEST in *[!0-9a-f]*) die "catalog origin index identity mismatch" ;; esac
    INSTANCE_CATALOG_ID=$CATALOG_ID
    EXISTING_INSTANCE=1
else
    # Clone output is deliberately suppressed: Git may echo credential-bearing URLs on failure.
    BOOTSTRAP_CLONE=$WORK_ROOT/bootstrap
    if ! git clone --quiet --no-local -- "$REPOSITORY_URL" "$BOOTSTRAP_CLONE" >"$WORK_ROOT/clone.log" 2>&1; then
        die "unable to clone the supplied repository"
    fi
    if ! validate_catalog "$BOOTSTRAP_CLONE"; then
        die "supplied repository is not a valid catalog"
    fi
    CONFIGURED_ORIGIN=$(git -C "$BOOTSTRAP_CLONE" remote get-url origin 2>/dev/null) || die "clone has no configured origin"
    [ -n "$CONFIGURED_ORIGIN" ] || die "clone origin must not be blank"
    ORIGIN_DIGEST=$(printf '%s' "$CONFIGURED_ORIGIN" | git hash-object --stdin) || die "cannot calculate catalog identity"
    INSTANCE_KEY=$CATALOG_ID-$ORIGIN_DIGEST
    INSTANCE_CATALOG_ID=$CATALOG_ID
    INSTANCE_ROOT=$STATE_ROOT/catalogs/$INSTANCE_KEY
    MANAGED_REPO=$INSTANCE_ROOT/repo
fi

if [ "$PREFIX_SET" -eq 0 ]; then
    PREFIX=$DEFAULT_PREFIX
fi
if [ -n "$PREFIX" ]; then
    valid_name "$PREFIX" || die "invalid prefix"
    [ ${#PREFIX} -le 62 ] || die "prefix exceeds 62 characters"
    INSTALL_KEY=$PREFIX
else
    INSTALL_KEY=_default
fi
INSTALL_ROOT=$INSTANCE_ROOT/installs/$INSTALL_KEY

if [ "$ACTION" = remove ]; then
    [ -d "$MANAGED_REPO" ] || die "catalog instance is not installed"
    [ -d "$INSTALL_ROOT" ] || {
        printf '%s\n' "Catalog $CATALOG_ID prefix '$PREFIX' is already absent."
        exit 0
    }
    for product in agents claude; do
        case $product in
            agents) product_root=$AGENTS_ROOT ;;
            claude) product_root=$CLAUDE_ROOT ;;
        esac
        owners=$INSTALL_ROOT/ownership/$product
        [ -d "$owners" ] || continue
        for owner_file in "$owners"/*.owner; do
            [ -f "$owner_file" ] || continue
            effective_name=${owner_file##*/}
            effective_name=${effective_name%.owner}
            destination=$product_root/$effective_name
            expected_target=$(sed -n '1p' "$owner_file")
            if [ -L "$destination" ] && [ "$(readlink "$destination")" = "$expected_target" ]; then
                rm "$destination" || die "cannot remove owned exposure $destination"
            elif [ -e "$destination" ] || [ -L "$destination" ]; then
                printf '%s\n' "warning: not removing changed path $destination" >&2
            fi
        done
    done
    rm -rf "$INSTALL_ROOT"
    if [ -d "$INSTANCE_ROOT/installs" ] && [ -z "$(find "$INSTANCE_ROOT/installs" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        rm -rf "$INSTANCE_ROOT"
        if [ -f "$ORIGIN_INDEX" ] && [ "$(sed -n '1p' "$ORIGIN_INDEX")" = "$INSTANCE_KEY" ]; then
            rm "$ORIGIN_INDEX"
        fi
    fi
    printf '%s\n' "Removed catalog $CATALOG_ID prefix '$PREFIX'."
    exit 0
fi

if [ "$EXISTING_INSTANCE" -eq 0 ]; then
    mkdir -p "$INSTANCE_ROOT"
    mv "$BOOTSTRAP_CLONE" "$MANAGED_REPO"
    mkdir -p "$ORIGIN_INDEX_ROOT"
    INDEX_TEMP=$ORIGIN_INDEX_ROOT/.$SUPPLIED_DIGEST.$$
    printf '%s\n' "$INSTANCE_KEY" >"$INDEX_TEMP"
    mv "$INDEX_TEMP" "$ORIGIN_INDEX"
    SOURCE_ROOT=$MANAGED_REPO
else
    # All later network behavior names the managed clone's configured origin, never a baked URL.
    if ! git -C "$MANAGED_REPO" fetch --quiet origin >"$WORK_ROOT/fetch.log" 2>&1; then
        die "unable to fetch the managed catalog origin"
    fi
    REMOTE_HEAD=$(git -C "$MANAGED_REPO" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null) || die "managed origin has no default branch"
    CANDIDATE_WORKTREE=$WORK_ROOT/candidate
    if ! git -C "$MANAGED_REPO" worktree add --quiet --detach "$CANDIDATE_WORKTREE" "$REMOTE_HEAD" >"$WORK_ROOT/worktree.log" 2>&1; then
        die "unable to stage the fetched catalog"
    fi
    SOURCE_ROOT=$CANDIDATE_WORKTREE
    if ! validate_catalog "$SOURCE_ROOT"; then
        die "fetched catalog is invalid; keeping the last known-good installation"
    fi
fi

# Re-read from the selected candidate, not from bootstrap discovery data.
if ! validate_catalog "$SOURCE_ROOT"; then
    die "catalog is invalid; keeping the last known-good installation"
fi
[ "$CATALOG_ID" = "$INSTANCE_CATALOG_ID" ] || die "fetched catalog identity changed; keeping the last known-good installation"
if [ "$PREFIX_SET" -eq 0 ]; then
    PREFIX=$DEFAULT_PREFIX
fi
if [ -n "$PREFIX" ]; then
    INSTALL_KEY=$PREFIX
else
    INSTALL_KEY=_default
fi
INSTALL_ROOT=$INSTANCE_ROOT/installs/$INSTALL_KEY

GENERATION_ID=$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null) || die "catalog has no Git revision"
STAGED_GENERATION=$WORK_ROOT/generation
mkdir -p "$STAGED_GENERATION"
for skill_dir in "$SOURCE_ROOT/skills"/*; do
    skill_name=${skill_dir##*/}
    if [ -n "$PREFIX" ]; then
        effective_name=$PREFIX-$skill_name
    else
        effective_name=$skill_name
    fi
    valid_name "$effective_name" || die "effective skill name is invalid or exceeds 64 characters: $effective_name"
    cp -Rp "$skill_dir" "$STAGED_GENERATION/$effective_name" || die "cannot stage skill $skill_name"
    if [ -n "$PREFIX" ]; then
        skill_file=$STAGED_GENERATION/$effective_name/SKILL.md
        rewritten=$skill_file.rewritten
        awk -v replacement="$effective_name" '
            NR == 1 { in_frontmatter=1; print; next }
            in_frontmatter && $0 == "---" { in_frontmatter=0; print; next }
            in_frontmatter && $0 ~ /^name:[[:space:]]*/ { print "name: " replacement; next }
            { print }
        ' "$skill_file" >"$rewritten" || die "cannot rewrite skill $skill_name"
        mv "$rewritten" "$skill_file"
    fi
    validate_skill "$STAGED_GENERATION/$effective_name" "$effective_name" || die "generated skill failed validation: $effective_name"
done

mkdir -p "$INSTALL_ROOT/generations" "$INSTALL_ROOT/ownership/agents" "$INSTALL_ROOT/ownership/claude"
GENERATION_PATH=$INSTALL_ROOT/generations/$GENERATION_ID
CURRENT_TARGET=$INSTALL_ROOT/current

# Preflight every destination before changing the current generation.
for product in agents claude; do
    case $product in
        agents) product_root=$AGENTS_ROOT ;;
        claude) product_root=$CLAUDE_ROOT ;;
    esac
    if [ -e "$product_root" ] && [ ! -d "$product_root" ]; then
        die "product skills root is not a directory: $product_root"
    fi
    for generated_skill in "$STAGED_GENERATION"/*; do
        effective_name=${generated_skill##*/}
        destination=$product_root/$effective_name
        owner_file=$INSTALL_ROOT/ownership/$product/$effective_name.owner
        expected_target=$CURRENT_TARGET/$effective_name
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            if [ -f "$owner_file" ] && [ -L "$destination" ] && [ "$(readlink "$destination")" = "$expected_target" ]; then
                :
            else
                printf '%s\n' "warning: catalog $CATALOG_ID skill $effective_name skipped; destination exists: $destination" >&2
            fi
        fi
    done
done

if [ ! -d "$GENERATION_PATH" ]; then
    mv "$STAGED_GENERATION" "$GENERATION_PATH"
fi
NEXT_LINK=$INSTALL_ROOT/.current.$$
ln -s "generations/$GENERATION_ID" "$NEXT_LINK" || die "cannot stage current generation link"
if [ -e "$CURRENT_TARGET" ] || [ -L "$CURRENT_TARGET" ]; then
    [ -L "$CURRENT_TARGET" ] || die "catalog current view is not an owned directory link"
fi
# Plain POSIX mv follows a destination symlink to a directory. Use each supported platform's
# no-follow form so replacement changes the link itself and never writes inside an immutable view.
case $(uname -s) in
    Darwin) mv -f -h "$NEXT_LINK" "$CURRENT_TARGET" || die "cannot activate generated view" ;;
    *) mv -f -T "$NEXT_LINK" "$CURRENT_TARGET" || die "cannot activate generated view" ;;
esac

for product in agents claude; do
    case $product in
        agents) product_root=$AGENTS_ROOT ;;
        claude) product_root=$CLAUDE_ROOT ;;
    esac
    mkdir -p "$product_root" || die "cannot create product skills root"
    # Remove exposures for skills no longer present, but only while both ownership proofs agree.
    owners=$INSTALL_ROOT/ownership/$product
    for owner_file in "$owners"/*.owner; do
        [ -f "$owner_file" ] || continue
        owned_name=${owner_file##*/}
        owned_name=${owned_name%.owner}
        [ -e "$CURRENT_TARGET/$owned_name" ] && continue
        destination=$product_root/$owned_name
        expected_target=$(sed -n '1p' "$owner_file")
        if [ -L "$destination" ] && [ "$(readlink "$destination")" = "$expected_target" ]; then
            rm "$destination" || die "cannot remove stale owned exposure $destination"
        elif [ -e "$destination" ] || [ -L "$destination" ]; then
            printf '%s\n' "warning: not removing changed path $destination" >&2
        fi
        rm "$owner_file"
    done
    for generated_skill in "$CURRENT_TARGET"/*; do
        effective_name=${generated_skill##*/}
        destination=$product_root/$effective_name
        owner_file=$INSTALL_ROOT/ownership/$product/$effective_name.owner
        expected_target=$CURRENT_TARGET/$effective_name
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            if [ -f "$owner_file" ] && [ -L "$destination" ] && [ "$(readlink "$destination")" = "$expected_target" ]; then
                continue
            fi
            continue
        fi
        printf '%s\n' "$expected_target" >"$owner_file"
        link_tmp=$product_root/.team-skills-$effective_name-$$
        ln -s "$expected_target" "$link_tmp" || die "cannot stage exposure for $effective_name"
        if ! mv "$link_tmp" "$destination"; then
            rm -f "$link_tmp" "$owner_file"
            die "cannot expose skill $effective_name"
        fi
    done
done

if [ -n "${CANDIDATE_WORKTREE:-}" ]; then
    git -C "$MANAGED_REPO" reset --quiet --hard "$REMOTE_HEAD" >"$WORK_ROOT/reset.log" 2>&1 || die "installed view is valid but managed clone could not advance"
fi
printf '%s\n' "Installed catalog $CATALOG_ID as instance $INSTANCE_KEY with prefix '$PREFIX'."
