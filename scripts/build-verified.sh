#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
mode="${1:-check}"
if [[ "$mode" != check && "$mode" != release ]]; then
  echo 'Usage: scripts/build-verified.sh [check|release]' >&2
  exit 2
fi

resource_dir="$project_root/Resources/Upscaler"
if ! "$project_root/scripts/verify-upscaler-resources.sh" "$resource_dir" >/dev/null 2>&1; then
  echo 'Bundled upscaler resources are missing or unverified; preparing pinned releases.'
  "$project_root/scripts/prepare-upscaler.sh"
fi
"$project_root/scripts/verify-upscaler-resources.sh" "$resource_dir"
"$project_root/scripts/check.sh"

if [[ "$mode" == release ]]; then
  brisk archive --release
  app="$project_root/.brisk/Archives/ZeroClick.app"
  codesign --verify --deep --strict "$app"
  "$project_root/scripts/verify-upscaler-resources.sh" "$app/Contents/Resources/Resources/Upscaler"
  package_dir="$(mktemp -d "$project_root/.brisk/Archives/verified.XXXXXX")"
  package="$package_dir/ZeroClick-macOS-arm64.zip"
  python3 "$project_root/scripts/package-private-release.py" --app "$app" --output "$package"
  unzip -t "$package" >/dev/null
  extracted="$package_dir/extracted"
  mkdir "$extracted"
  unzip -q "$package" -d "$extracted"
  codesign --verify --deep --strict "$extracted/ZeroClick.app"
  "$project_root/scripts/verify-upscaler-resources.sh" "$extracted/ZeroClick.app/Contents/Resources/Resources/Upscaler"
  printf 'Verified local release package: %s\n' "$package"
fi
