#!/bin/sh
# release.sh — builds the distributable package, verifies the version tag,
# and publishes a GitHub release with the package attached.
#
# Usage: sh scripts/release.sh v0.2.0
#
# Prerequisites: the tag must already exist locally (git tag -a vX.Y.Z -m "...")
# and point at a clean, committed working tree. This script does not create
# the tag itself — tagging stays a deliberate, separate step.
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

TAG="$1"
if [ -z "$TAG" ]; then
	echo "Usage: sh scripts/release.sh vX.Y.Z" >&2
	exit 1
fi
case "$TAG" in
	v*) VERSION="${TAG#v}" ;;
	*) echo "release.sh: tag must look like vX.Y.Z (got: $TAG)" >&2; exit 1 ;;
esac

PLUGIN_SRC="TimelapseCreator.lrdevplugin"
PLUGIN_NAME="TimelapseCreator"
DIST_DIR="dist"
PACKAGE_DIR="$DIST_DIR/$PLUGIN_NAME.lrplugin"
ZIP_PATH="$DIST_DIR/$PLUGIN_NAME-$VERSION.zip"

echo "==> Checking prerequisites"
command -v lua  >/dev/null 2>&1 || { echo "release.sh: 'lua' is required" >&2; exit 1; }
command -v luac >/dev/null 2>&1 || { echo "release.sh: 'luac' is required" >&2; exit 1; }
command -v zip  >/dev/null 2>&1 || { echo "release.sh: 'zip' is required" >&2; exit 1; }
command -v gh   >/dev/null 2>&1 || { echo "release.sh: 'gh' (GitHub CLI) is required" >&2; exit 1; }

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
	echo "release.sh: tag '$TAG' does not exist locally. Create it first:" >&2
	echo "  git tag -a $TAG -m \"...\"" >&2
	exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "release.sh: working tree is not clean. Commit or stash changes first." >&2
	git status --short >&2
	exit 1
fi

TAG_COMMIT="$(git rev-parse "$TAG^{commit}")"
HEAD_COMMIT="$(git rev-parse HEAD)"
if [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
	echo "release.sh: tag '$TAG' does not point at HEAD." >&2
	echo "  $TAG -> $TAG_COMMIT" >&2
	echo "  HEAD -> $HEAD_COMMIT" >&2
	exit 1
fi

echo "==> Verifying version consistency (Info.lua, Version.lua, tag $TAG)"
lua scripts/check_version.lua "$VERSION"

echo "==> Checking Lua syntax"
for f in "$PLUGIN_SRC"/*.lua; do
	luac -p "$f"
done

echo "==> Running unit tests"
lua tests/test_ffmpeg_command.lua

echo "==> Building package"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$PACKAGE_DIR"
# Copy plugin files only (excludes .DS_Store and any other OS cruft).
find "$PLUGIN_SRC" -maxdepth 1 -type f ! -name '.DS_Store' -exec cp {} "$PACKAGE_DIR/" \;
cp README.md "$DIST_DIR/"
cp LICENSE "$DIST_DIR/"
( cd "$DIST_DIR" && zip -rq "../$ZIP_PATH" "$PLUGIN_NAME.lrplugin" README.md LICENSE )

echo "==> Package built:"
ls -lh "$ZIP_PATH"

echo
echo "About to:"
echo "  1. Push tag $TAG to origin (if not already there)"
echo "  2. Create GitHub release $TAG with $ZIP_PATH attached"
printf 'Proceed? [y/N] '
read -r CONFIRM
case "$CONFIRM" in
	y|Y|yes|YES) ;;
	*) echo "Aborted."; exit 1 ;;
esac

if ! git ls-remote --tags origin | grep -q "refs/tags/$TAG\$"; then
	echo "==> Pushing tag $TAG to origin"
	git push origin "$TAG"
else
	echo "==> Tag $TAG already on origin"
fi

echo "==> Creating GitHub release"
gh release create "$TAG" "$ZIP_PATH" \
	--title "Timelapse Creator $TAG" \
	--generate-notes

echo "==> Done."
