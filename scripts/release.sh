#!/bin/sh
# release.sh — builds the distributable package, verifies the version tag,
# and publishes a GitHub release with the package attached.
#
# Usage: sh scripts/release.sh v0.2.0
#
# Prerequisites: the tag must already exist locally (git tag -a vX.Y.Z -m "...")
# and point at a clean, committed working tree. This script does not create
# the tag itself — tagging stays a deliberate, separate step.
#
# The release package ships compiled Lua bytecode, not source: every plugin
# script (except Info.lua — see below) is compiled with the Lua 5.1 compiler
# bundled in the Lightroom Classic SDK, the same Lua version Lightroom itself
# runs (confirmed: Lightroom Classic embeds Lua 5.1.5, not the system Lua on
# a typical dev machine). That compiler is NOT part of this repository (the
# SDK folder is gitignored, and its redistribution terms are unclear), so it
# must be present locally — set ADOBE_LUAC to its path, or install the SDK
# at the default location below.
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
ADOBE_LUAC="${ADOBE_LUAC:-$REPO_ROOT/AdobeSDK/LrC_15/Lua Compiler/mac/luac}"

echo "==> Checking prerequisites"
command -v lua  >/dev/null 2>&1 || { echo "release.sh: 'lua' is required" >&2; exit 1; }
command -v luac >/dev/null 2>&1 || { echo "release.sh: 'luac' is required" >&2; exit 1; }
command -v zip  >/dev/null 2>&1 || { echo "release.sh: 'zip' is required" >&2; exit 1; }
command -v gh   >/dev/null 2>&1 || { echo "release.sh: 'gh' (GitHub CLI) is required" >&2; exit 1; }
if [ ! -x "$ADOBE_LUAC" ]; then
	echo "release.sh: Adobe's Lua 5.1 compiler was not found or is not executable:" >&2
	echo "  $ADOBE_LUAC" >&2
	echo "Install the Lightroom Classic SDK there, or set ADOBE_LUAC to its 'luac' binary." >&2
	exit 1
fi

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

echo "==> Checking Lua syntax (system Lua + Lightroom's actual Lua 5.1)"
for f in "$PLUGIN_SRC"/*.lua; do
	luac -p "$f"
	"$ADOBE_LUAC" -p "$f"
done

echo "==> Running unit tests"
lua tests/test_ffmpeg_command.lua

echo "==> Building package (compiled bytecode, Lua 5.1)"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
mkdir -p "$PACKAGE_DIR"
for f in "$PLUGIN_SRC"/*.lua; do
	base="$(basename "$f")"
	if [ "$base" = "Info.lua" ]; then
		# Info.lua is parsed by Lightroom in a restricted environment before
		# the plugin loads; kept as source rather than risk an untested
		# bytecode path there (see the comment in Info.lua itself).
		cp "$f" "$PACKAGE_DIR/$base"
	else
		"$ADOBE_LUAC" -s -o "$PACKAGE_DIR/$base" "$f"
	fi
done
# Non-Lua assets, copied as-is (excludes .DS_Store and other OS cruft).
find "$PLUGIN_SRC" -maxdepth 1 -type f ! -name '*.lua' ! -name '.DS_Store' \
	-exec cp {} "$PACKAGE_DIR/" \;
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
