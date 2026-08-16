#!/bin/zsh

set -euo pipefail

script_dir="${0:A:h}"
source_root="${script_dir:h}"
project_root="${source_root:h:h}"
output_root="$project_root/outputs"
module_cache="/private/tmp/edison-swift-module-cache"
spm_cache="/private/tmp/edison-spm-cache"
spm_config="/private/tmp/edison-spm-config"
spm_security="/private/tmp/edison-spm-security"
stage_root="/private/tmp/edison-app-stage"
app_path="$output_root/edison.app"
icon_root="/private/tmp/edison-icon-build"

export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$module_cache"

mkdir -p "$module_cache" "$spm_cache" "$spm_config" "$spm_security" "$output_root"

/usr/bin/swift build \
    --package-path "$source_root" \
    --configuration release \
    --triple arm64-apple-macosx26.0 \
    --disable-sandbox \
    --cache-path "$spm_cache" \
    --config-path "$spm_config" \
    --security-path "$spm_security"

rm -rf "$stage_root"
mkdir -p "$stage_root/edison.app/Contents/MacOS" "$stage_root/edison.app/Contents/Resources"

cp "$source_root/.build/arm64-apple-macosx/release/edison" \
    "$stage_root/edison.app/Contents/MacOS/edison"
ditto "$source_root/.build/arm64-apple-macosx/release/edison_EdisonApp.bundle" \
    "$stage_root/edison.app/Contents/Resources/edison_EdisonApp.bundle"
cp "$source_root/Resources/Info.plist" "$stage_root/edison.app/Contents/Info.plist"

rm -rf "$icon_root"
mkdir -p "$icon_root/AppIcon.iconset"
/usr/bin/swiftc \
    -target arm64-apple-macosx26.0 \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    -module-cache-path "$module_cache" \
    -framework AppKit \
    "$source_root/Scripts/generate-icon.swift" \
    -o "$icon_root/generate-icon"
"$icon_root/generate-icon" "$icon_root/AppIcon-1024.png"

for spec in \
    '16 icon_16x16.png' \
    '32 icon_16x16@2x.png' \
    '32 icon_32x32.png' \
    '64 icon_32x32@2x.png' \
    '128 icon_128x128.png' \
    '256 icon_128x128@2x.png' \
    '256 icon_256x256.png' \
    '512 icon_256x256@2x.png' \
    '512 icon_512x512.png' \
    '1024 icon_512x512@2x.png'; do
    size="${spec%% *}"
    filename="${spec#* }"
    /usr/bin/sips -z "$size" "$size" "$icon_root/AppIcon-1024.png" \
        --out "$icon_root/AppIcon.iconset/$filename" >/dev/null
done
/usr/bin/swiftc \
    -target arm64-apple-macosx26.0 \
    -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
    -module-cache-path "$module_cache" \
    "$source_root/Scripts/make-icns.swift" \
    -o "$icon_root/make-icns"
"$icon_root/make-icns" \
    "$stage_root/edison.app/Contents/Resources/AppIcon.icns" \
    "icp4=$icon_root/AppIcon.iconset/icon_16x16.png" \
    "icp5=$icon_root/AppIcon.iconset/icon_32x32.png" \
    "icp6=$icon_root/AppIcon.iconset/icon_32x32@2x.png" \
    "ic07=$icon_root/AppIcon.iconset/icon_128x128.png" \
    "ic08=$icon_root/AppIcon.iconset/icon_256x256.png" \
    "ic09=$icon_root/AppIcon.iconset/icon_512x512.png" \
    "ic10=$icon_root/AppIcon.iconset/icon_512x512@2x.png"

# Cloud-synced working folders can add Finder/FileProvider metadata to files
# copied into the bundle. Clear it before signing, then sign the final copy.
/usr/bin/xattr -cr "$stage_root/edison.app" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$stage_root/edison.app"

rm -rf "$app_path"
/usr/bin/ditto "$stage_root/edison.app" "$app_path"
# Some synchronized Documents folders attach Finder/FileProvider metadata to
# the copied bundle. Those extended attributes invalidate strict code-signature
# verification, so the deliverable is normalized after the copy.
/usr/bin/xattr -cr "$app_path" 2>/dev/null || true
/usr/bin/codesign --force --deep --sign - "$app_path"

echo "$app_path"
