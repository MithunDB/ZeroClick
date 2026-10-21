#!/usr/bin/env bash
set -euo pipefail

resource_dir="${1:?Pass the Upscaler resource directory}"
test -d "$resource_dir"
expected=(
  'Notices/MoltenVK-Apache-2.0.txt'
  'Notices/Real-ESRGAN-BSD-3-Clause.txt'
  'Notices/Real-ESRGAN-NCNN-MIT.txt'
  'Notices/libwebp-COPYING.txt'
  'Notices/libwebp-PATENTS.txt'
  'Notices/ncnn-LICENSE.txt'
  'models/realesr-animevideov3-x4.bin'
  'models/realesr-animevideov3-x4.param'
  'realesrgan-ncnn-vulkan'
)
actual="$(find "$resource_dir" -type f | sed "s|^$resource_dir/||" | sort)"
sorted_expected="$(printf '%s\n' "${expected[@]}" | sort)"
if [[ "$actual" != "$sorted_expected" ]]; then
  printf 'Unexpected upscaler contents:\n' >&2
  printf '%s\n' "$actual" >&2
  exit 1
fi
if find "$resource_dir" -type l | grep -q .; then
  echo 'Upscaler resources contain a symbolic link' >&2
  exit 1
fi
printf '%s  %s\n' \
  'c1c35d92079085de96b9d547fd7e4464bc8a2e9ccf28d7b8c712d72ade91b7cc' "$resource_dir/realesrgan-ncnn-vulkan" \
  '548a36f9c3f4ab8da56cd3b13badf23968bee207b396dad14d04b830e5f2ab2d' "$resource_dir/models/realesr-animevideov3-x4.bin" \
  '850a248e7c14c27e5bd8cf7265113a9441036a7db63963bb8aa5169d788a435e' "$resource_dir/models/realesr-animevideov3-x4.param" | shasum -a 256 -c -
test -x "$resource_dir/realesrgan-ncnn-vulkan"
file "$resource_dir/realesrgan-ncnn-vulkan" | grep -q arm64
echo 'Upscaler resources verified'
