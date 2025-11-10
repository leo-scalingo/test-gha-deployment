#!/bin/bash

set -eo pipefail

version=$0
base_branch="${BASE_BRANCH:-main}"
prepare_branch="release/v${version}-prepare"
release_branch="release/v${version}"

git checkout "${base_branch}" && git pull origin "${base_branch}"
git checkout -b "${release_branch}"
git push origin "${release_branch}"

git checkout -b "${prepare_branch}"
echo "${version}" > VERSION
mkdir -p .release
git rev-parse "origin/${base_branch}" > .release/target_sha
git add VERSION .release/target_sha
git commit -m "Prepare release v${version}"
git push origin "${prepare_branch}"
