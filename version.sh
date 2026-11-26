#!/bin/sh
# 从 AppVersion.swift 读取版本身份，避免脚本与界面各写一份版本号。
set -eu
cd "$(dirname "$0")"

source_file="Sources/SnowSweepCore/AppVersion.swift"
number=$(sed -n 's/.*number: "\([^"]*\)".*/\1/p' "$source_file" | head -n 1)
codename=$(sed -n 's/.*codeName: "\([^"]*\)".*/\1/p' "$source_file" | head -n 1)
devtag=$(sed -n 's/.*devTag: "\([^"]*\)".*/\1/p' "$source_file" | head -n 1)

printf 'V%s · %s' "$number" "$codename"
if [ -n "$devtag" ]; then
  printf '（%s）' "$devtag"
fi
printf '\n'
