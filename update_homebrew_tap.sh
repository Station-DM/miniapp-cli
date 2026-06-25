#!/bin/bash
set -e

VERSION=$1

# 如果没有传参，尝试从 Version.swift 里自动读取
if [ -z "$VERSION" ]; then
    if [ -f "Sources/Version.swift" ]; then
        VERSION=$(grep 'let miniAppCLIVersion' Sources/Version.swift | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    fi
    if [ -z "$VERSION" ]; then
        echo "Usage: $0 <version> (e.g. v0.1.5)"
        exit 1
    fi
    echo "Detected version $VERSION from Sources/Version.swift"
fi

# 确保版本号带有 v 前缀
if [[ ! "$VERSION" == v* ]]; then
    VERSION="v$VERSION"
fi

TARBALL_URL="https://github.com/Station-DM/miniapp-cli/archive/refs/tags/${VERSION}.tar.gz"

echo "Downloading $TARBALL_URL to calculate SHA256..."
SHA256=$(curl -sL "$TARBALL_URL" | shasum -a 256 | awk '{print $1}')

if [ -z "$SHA256" ] || [ ${#SHA256} -ne 64 ]; then
    echo "Failed to calculate SHA256. Please ensure the tag $VERSION has been pushed to remote."
    exit 1
fi

echo "SHA256: $SHA256"

# 假设 homebrew-miniapp 和 miniapp-cli-public 是平级目录
TAP_DIR="../homebrew-miniapp"
if [ ! -d "$TAP_DIR" ]; then
    echo "Error: Homebrew tap repository not found at $TAP_DIR."
    echo "Please clone it or update the TAP_DIR path in this script."
    exit 1
fi

FORMULA_FILE="$TAP_DIR/Formula/miniapp.rb"
if [ ! -f "$FORMULA_FILE" ]; then
    echo "Error: Formula file not found at $FORMULA_FILE."
    exit 1
fi

echo "Updating Formula at $FORMULA_FILE..."

# 使用 perl 替换文件内容，兼容 MacOS 上的文本替换
perl -pi -e "s|url \".*\"|url \"$TARBALL_URL\"|g" "$FORMULA_FILE"
perl -pi -e "s|sha256 \".*\"|sha256 \"$SHA256\"|g" "$FORMULA_FILE"

echo "Committing and pushing to tap repository..."
cd "$TAP_DIR"
git add Formula/miniapp.rb
# 如果没有变更说明已经是最新，忽略 commit 报错
git commit -m "chore(release): bump miniapp to $VERSION" || true
git push origin main

echo "Done! Homebrew tap successfully updated to $VERSION."
