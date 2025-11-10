#!/usr/bin/env bash
set -euo pipefail

# --- usage ---
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version>    e.g. $0 2.7.0"
  exit 64
fi
version="$1"  # e.g. 2.7.0  (no leading 'v')

# Optional: basic semver check
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: version '$version' is not valid semver (e.g. 2.7.0)"
  exit 65
fi

# --- helpers ---
branch_exists_local()  { git show-ref --verify --quiet "refs/heads/$1"; }
branch_exists_remote() { git ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }
ensure_clean_worktree() {
  # Abort if there are staged or unstaged changes
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: working tree is dirty. Commit/stash your changes and retry."
    git status --porcelain
    exit 66
  fi
}

# --- preliminaries ---
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a git repo"; exit 67; }
ensure_clean_worktree

# Make sure we can see remote branches/tags
git fetch --prune --tags origin

# Pick base branch:
# 1) If BASE_BRANCH env is set, use it (and verify it exists).
# 2) Otherwise prefer 'main' if present, else 'master'.
if [[ -n "${BASE_BRANCH:-}" ]]; then
  base_branch="$BASE_BRANCH"
  if ! branch_exists_local "$base_branch" && ! branch_exists_remote "$base_branch"; then
    echo "Error: BASE_BRANCH='$base_branch' does not exist locally or on origin."
    exit 68
  fi
else
  if branch_exists_local main || branch_exists_remote main; then
    base_branch="main"
  elif branch_exists_local master || branch_exists_remote master; then
    base_branch="master"
  else
    echo "Error: neither 'main' nor 'master' exists locally or on origin. Set BASE_BRANCH env."
    exit 69
  fi
fi

prepare_branch="release/v${version}-prepare"
release_branch="release/v${version}"

# Safety: don’t clobber existing release branches or tags
for b in "$release_branch" "$prepare_branch"; do
  if branch_exists_local "$b" || branch_exists_remote "$b"; then
    echo "Error: branch '$b' already exists."
    exit 70
  fi
done
if git rev-parse -q --verify "refs/tags/v${version}" >/dev/null; then
  echo "Error: tag 'v${version}' already exists."
  exit 71
fi

# --- create branches ---
# Sync base and create empty release branch
git checkout "$base_branch"
git pull --ff-only origin "$base_branch"

git switch -c "$release_branch"
git push -u origin "$release_branch"

# Create prepare branch with metadata (no code changes)
git switch -c "$prepare_branch"

echo "${version}" > VERSION
mkdir -p .release
# Record the base branch HEAD we intend to tag
git rev-parse "origin/${base_branch}" > .release/target_sha

git add VERSION .release/target_sha
git commit -m "Prepare release v${version}"
git push -u origin "$prepare_branch"

echo
echo "✅ Done."
echo "Open a PR: base='${release_branch}'  ←  compare='${prepare_branch}'"
