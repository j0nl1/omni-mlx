#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    printf '%s\n' 'Native distribution packaging requires an Apple Silicon Mac.' >&2
    exit 1
fi

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$project_dir/dist"}
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
cd "$project_dir"
if [ ! -f Sources/AudioHTTP/Resources/AdminUI/index.html ]; then
    printf '%s\n' 'Build the administration UI first with ./scripts/build-ui.sh.' >&2
    exit 1
fi
swift build -c release --product omni-mlx -j 4
binary_dir=$(swift build -c release --show-bin-path)
staging_dir=$(mktemp -d "$output_dir/.package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
package_name=omni-mlx-macos-arm64
package_dir="$staging_dir/$package_name"
mkdir -p "$package_dir/configs"
cp "$binary_dir/omni-mlx" "$package_dir/omni-mlx"

# Include back-deployment libraries instead of depending on the build machine's Xcode.
mkdir -p "$package_dir/lib"
xcrun swift-stdlib-tool --copy --platform macosx \
    --scan-executable "$package_dir/omni-mlx" \
    --destination "$package_dir/lib" --sign -
otool -l "$package_dir/omni-mlx" | awk '
    /cmd LC_RPATH/ { in_rpath = 1; next }
    in_rpath && $1 == "path" {
        sub(/^[[:space:]]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print; in_rpath = 0
    }
' | while IFS= read -r runtime_path; do
    install_name_tool -delete_rpath "$runtime_path" "$package_dir/omni-mlx"
done
install_name_tool -add_rpath '@executable_path/lib' "$package_dir/omni-mlx"
install_name_tool -add_rpath '/usr/lib/swift' "$package_dir/omni-mlx"
install_name_tool -add_rpath '@loader_path' "$package_dir/omni-mlx"
codesign --force --sign - "$package_dir/omni-mlx"
codesign --verify --strict "$package_dir/omni-mlx"

# SwiftPM native resources must remain beside the relocated executable.
resource_count=0
for resource in "$binary_dir"/*.bundle; do
    [ -d "$resource" ] || continue
    cp -R "$resource" "$package_dir/"
    resource_count=$((resource_count + 1))
done
if [ "$resource_count" -eq 0 ]; then
    printf '%s\n' 'No SwiftPM resource bundles were found; refusing an incomplete package.' >&2
    exit 1
fi
cp README.md LICENSE CONTRIBUTING.md "$package_dir/"
cp -R docs "$package_dir/"
cp configs/*.example.toml "$package_dir/configs/"
for checkout in "$project_dir"/.build/checkouts/*; do
    [ -d "$checkout" ] || continue
    checkout_name=$(basename "$checkout")
    for notice in "$checkout"/LICENSE* "$checkout"/NOTICE* "$checkout"/COPYING* "$checkout"/COPYRIGHT*; do
        [ -f "$notice" ] || continue
        mkdir -p "$package_dir/licenses/$checkout_name"
        cp "$notice" "$package_dir/licenses/$checkout_name/"
    done
done
tar -czf "$output_dir/$package_name.tar.gz" -C "$staging_dir" "$package_name"
printf 'Created %s\n' "$output_dir/$package_name.tar.gz"
