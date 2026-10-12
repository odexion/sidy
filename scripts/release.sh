#!/bin/zsh
# Tags, builds, signs and publishes a release.
#   scripts/release.sh <version> <notes.md>
# The notes file is the release's description on GitHub. Commits since the last release are listed below
# when it's missing, to write it from.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version> <notes.md>}
VERSION=${VERSION#v}
NOTES=${2:-}
TAG=v$VERSION
LAST=$(git describe --tags --abbrev=0)

if [[ -z "$NOTES" || ! -f "$NOTES" ]]; then
    echo "Write the release notes to a file and pass it as the second argument. Since $LAST:"
    git log --format='  - %s' "$LAST"..HEAD
    exit 1
fi
[[ $(git branch --show-current) == main ]] || { echo "Release from main."; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "Commit or stash your changes first."; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists."; exit 1; }
[[ $(printf '%s\n' "${LAST#v}" "$VERSION" | sort -V | tail -1) == "$VERSION" && "${LAST#v}" != "$VERSION" ]] \
    || { echo "$VERSION isn't newer than $LAST."; exit 1; }

swift test
SIDY_VERSION=$VERSION ./build.sh --release
ZIP=build/Sidy-$VERSION-arm64.zip

git tag "$TAG"
git push origin main "$TAG"
gh release create "$TAG" "$ZIP" "$ZIP.sig" --title "Sidy $VERSION" --notes-file "$NOTES"
echo "Released $TAG"
