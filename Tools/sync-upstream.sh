#!/bin/bash
set -euo pipefail

# All merges take place in a disposable clone. The caller's index, checkout,
# branches and remotes are never edited. Default mode does not push.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE=main
UPSTREAM_BRANCH=main
PUBLISH=false
DISPATCH=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="$2"; shift 2 ;;
        --base) BASE="$2"; shift 2 ;;
        --upstream-branch) UPSTREAM_BRANCH="$2"; shift 2 ;;
        --publish) PUBLISH=true; shift ;;
        --dispatch-tests) DISPATCH=true; shift ;;
        --help) echo 'sync-upstream.sh [--repo PATH] [--base main] [--upstream-branch main] [--publish] [--dispatch-tests]'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
git check-ref-format "refs/heads/$BASE" >/dev/null
git check-ref-format "refs/heads/$UPSTREAM_BRANCH" >/dev/null
ORIGIN="$(git -C "$REPO" remote get-url origin)"
UPSTREAM="$(git -C "$REPO" remote get-url upstream 2>/dev/null || echo https://github.com/azooKey/azooKey-Desktop.git)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/azookey-upstream.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
git clone -q --no-checkout --no-hardlinks "$REPO" "$WORK/repo"
cd "$WORK/repo"
git remote set-url origin "$ORIGIN"
git remote add upstream "$UPSTREAM"
git config user.name 'azooKey upstream sync'
git config user.email 'upstream-sync@users.noreply.github.com'
git config commit.gpgsign false
git fetch -q --no-tags origin "+refs/heads/$BASE:refs/remotes/origin/$BASE"
git fetch -q --no-tags upstream "+refs/heads/$UPSTREAM_BRANCH:refs/remotes/upstream/$UPSTREAM_BRANCH"
UPSTREAM_SHA="$(git rev-parse "refs/remotes/upstream/$UPSTREAM_BRANCH")"
if git merge-base --is-ancestor "$UPSTREAM_SHA" "refs/remotes/origin/$BASE"; then
    echo "Already contains upstream $UPSTREAM_SHA"
    exit 0
fi
BRANCH="automation/upstream-${UPSTREAM_SHA:0:12}"
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    git fetch -q --no-tags origin "refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
    git checkout -q -b "$BRANCH" "refs/remotes/origin/$BRANCH"
else
    git checkout -q -b "$BRANCH" "refs/remotes/origin/$BASE"
fi
for REF in "refs/remotes/origin/$BASE" "$UPSTREAM_SHA"; do
    if ! git -c filter.lfs.required=false -c filter.lfs.process= -c filter.lfs.smudge=cat merge --no-edit "$REF"; then
        echo 'Merge conflict; no branch was pushed. Resolve these files in a separate branch:' >&2
        git diff --name-only --diff-filter=U >&2
        exit 3
    fi
done
echo "Prepared merge: $BRANCH (upstream $UPSTREAM_SHA)"
git diff --stat "refs/remotes/origin/$BASE...HEAD"
if ! $PUBLISH; then
    echo 'Check only. Use --publish to push a branch and create a pull request.'
    exit 0
fi
command -v gh >/dev/null
# gh can default to a fork's parent. Resolve the explicit origin URL instead.
FORK="$(gh repo view "$ORIGIN" --json nameWithOwner --jq .nameWithOwner)"
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin "HEAD:refs/heads/$BRANCH"
EXISTING="$(gh pr list --repo "$FORK" --state open --head "$BRANCH" --base "$BASE" --json number --jq '.[0].number // empty')"
cat > "$WORK/body.md" <<EOF
上流 azooKey/azooKey-Desktop:$UPSTREAM_BRANCH の変更を取り込みます。

Upstream commit: $UPSTREAM_SHA

独自実装を含むベースブランチへ通常のmergeを行いました。競合がある場合は作成されません。マージ前にmacOSとUbuntuのCIを確認してください。
EOF
if [[ -z "$EXISTING" ]]; then
    gh pr create --repo "$FORK" --base "$BASE" --head "$BRANCH" --title "chore: sync upstream ${UPSTREAM_SHA:0:12}" --body-file "$WORK/body.md"
else
    gh pr view "$EXISTING" --repo "$FORK" --json url --jq .url
fi
# GITHUB_TOKEN-created PRs don't trigger pull_request workflows automatically.
if $DISPATCH; then
    gh workflow run tree-ci.yml --repo "$FORK" --ref "$BRANCH"
fi
