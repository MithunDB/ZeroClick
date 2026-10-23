#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
working="$(mktemp -d "${TMPDIR:-/tmp}/zeroclick-upscaler.XXXXXX")"
trap 'rm -rf "$working"' EXIT

engine_zip="$working/engine.zip"
model_zip="$working/model.zip"
curl --fail --location --silent --show-error --max-time 120 \
  'https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan/releases/download/v0.2.0/realesrgan-ncnn-vulkan-v0.2.0-macos.zip' \
  -o "$engine_zip"
curl --fail --location --silent --show-error --max-time 120 \
  'https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip' \
  -o "$model_zip"
printf '%s  %s\n' \
  'f1cc31f13398126ddec25a186b9e50c7ab3e4f2bc011d0222331b43ce2037d3b' "$engine_zip" \
  'e0ad05580abfeb25f8d8fb55aaf7bedf552c375b5b4d9bd3c8d59764d2cc333a' "$model_zip" | shasum -a 256 -c -

destination="$project_root/Resources/Upscaler"
staged="$project_root/Resources/.Upscaler-staged-$$"
mkdir -p "$staged/models" "$staged/Notices"
trap 'rm -rf "$working" "$staged"' EXIT
unzip -p "$engine_zip" 'realesrgan-ncnn-vulkan-v0.2.0-macos/realesrgan-ncnn-vulkan' > "$staged/realesrgan-ncnn-vulkan"
unzip -p "$engine_zip" 'realesrgan-ncnn-vulkan-v0.2.0-macos/LICENSE' > "$staged/Notices/Real-ESRGAN-NCNN-MIT.txt"
unzip -p "$model_zip" 'models/realesr-animevideov3-x4.bin' > "$staged/models/realesr-animevideov3-x4.bin"
unzip -p "$model_zip" 'models/realesr-animevideov3-x4.param' > "$staged/models/realesr-animevideov3-x4.param"
cp "$project_root"/third_party/upscaler/licenses/* "$staged/Notices/"
chmod 755 "$staged/realesrgan-ncnn-vulkan"
test "$(file -b "$staged/realesrgan-ncnn-vulkan")" != ''
"$project_root/scripts/verify-upscaler-resources.sh" "$staged"
if [[ -e "$destination" ]]; then rm -rf "$destination"; fi
mv "$staged" "$destination"
printf 'Prepared verified local upscaler resources at %s\n' "$destination"
