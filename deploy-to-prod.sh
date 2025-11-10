#!/usr/bin/env bash
set -euo pipefail

# --- usage ---
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <version>    e.g. $0 2.7.0"
  exit 64
fi
version="$1"  # e.g. 2.7.0 (no leading 'v')

# --- helpers ---
branch_exists_local()  { git show-ref --verify --quiet "refs/heads/$1"; }
branch_exists_remote() { git ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; }
ensure_clean_worktree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: working tree is dirty. Commit/stash your changes and retry."
    git status --short
    exit 66
  fi
}
ensure_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Error: missing command '$1'"; exit 67; }; }

# Collect GitHub usernames of commit authors between previous tag and base head
collect_reviewers() {
  local base_branch="$1"
  git fetch --tags origin >/dev/null 2>&1 || true

  # previous tag reachable from base branch (nearest v* tag)
  local prev_tag
  prev_tag="$(git tag --sort=-creatordate | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"

  local range
  if [[ -n "$prev_tag" ]]; then
    range="${prev_tag}..origin/${base_branch}"
  else
    # no previous tag; consider entire history on base (could be large)
    range="origin/${base_branch}"
  fi

  # gather commit SHAs (no merges)
  mapfile -t shas < <(git log --no-merges --format='%H' $range | head -n 400)

  # map to GitHub logins via API (if commit linked to a GH user)
  # requires: gh authenticated & repo context
  declare -A uniq
  for sha in "${shas[@]}"; do
    # author.login can be null if email not linked; skip in that case
    login="$(gh api repos/:owner/:repo/commits/"$sha" -q .author.login 2>/dev/null || true)"
    [[ -z "${login}" || "${login}" == "null" ]] && continue
    # filter bots
    if [[ "$login" =~ bot$ ]] || [[ "$login" == "dependabot" ]] || [[ "$login" == "github-actions" ]]; then
      continue
    fi
    uniq["$login"]=1
  done

  # to array, limit to 15 (GitHub CLI allows up to 15 reviewers)
  local reviewers=()
  for u in "${!uniq[@]}"; do reviewers+=("$u"); done
  if ((${#reviewers[@]} > 15)); then
    reviewers=("${reviewers[@]:0:15}")
  fi

  # echo CSV to stdout
  if ((${#reviewers[@]} > 0)); then
    (IFS=,; echo "${reviewers[*]}")
  else
    echo ""
  fi
}

# --- sanity checks ---
ensure_cmd git
ensure_cmd gh
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a git repo"; exit 68; }
ensure_clean_worktree
git fetch --prune --tags origin

# Pick base branch automatically (or from env)
if [[ -n "${BASE_BRANCH:-}" ]]; then
  base_branch="$BASE_BRANCH"
else
  if branch_exists_local main || branch_exists_remote main; then
    base_branch="main"
  elif branch_exists_local master || branch_exists_remote master; then
    base_branch="master"
  else
    echo "Error: neither 'main' nor 'master' exists. Set BASE_BRANCH."
    exit 69
  fi
fi

prepare_branch="release/v${version}-prepare"
release_branch="release/v${version}"

# Prevent clobbering
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
git checkout "$base_branch"
git pull --ff-only origin "$base_branch"

git switch -c "$release_branch"
git push -u origin "$release_branch"

git switch -c "$prepare_branch"
echo "${version}" > VERSION
git add VERSION
git commit -m "Prepare release v${version}"
git push -u origin "$prepare_branch"

# --- compute reviewers from commits since previous release tag ---
reviewers_csv="$(collect_reviewers "$base_branch" || echo "")"
if [[ -n "$reviewers_csv" ]]; then
  echo "Reviewers: $reviewers_csv"
else
  echo "No eligible reviewers found (no previous tag or no mapped GH authors)."
fi

# --- open PR with gh ---
echo "Opening PR: base='${release_branch}' ← compare='${prepare_branch}'"
# shellcheck disable=SC2086
if [[ -n "$reviewers_csv" ]]; then
  gh pr create \
    --base "$release_branch" \
    --head "$prepare_branch" \
    --title "Release v${version}" \
    --body "Automated release PR for v${version}." \
    --reviewer "$reviewers_csv"
else
  gh pr create \
    --base "$release_branch" \
    --head "$prepare_branch" \
    --title "Release v${version}" \
    --body "Automated release PR for v${version}."
fi

echo
echo "✅ Release PR created successfully!"
echo "   Base:   $release_branch"
echo "   Head:   $prepare_branch"
[[ -n "$reviewers_csv" ]] && echo "   Reviewers: $reviewers_csv"
