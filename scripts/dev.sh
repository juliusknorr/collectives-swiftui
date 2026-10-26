#!/bin/bash
# Local Mac build helper. Xcode remains the path for iOS/device/release builds.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
action="${1:-build}"
case "$action" in
    build|run|test) ;;
    *) printf 'Usage: bash scripts/dev.sh [build|run|test]\n' >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != Darwin ]]; then
    printf 'The native Mac app requires macOS and Apple developer tools.\n' >&2
    exit 1
fi
command -v python3 >/dev/null 2>&1 || { printf 'Python 3 is required to bundle the app.\n' >&2; exit 1; }
developer_dir="$(xcode-select -p)"
swift_path="$(xcrun --find swift)"
toolchain_usr="$(cd "$(dirname "$swift_path")/.." && pwd)"
selected_sdk="$(xcrun --sdk macosx --show-sdk-path)"
configuration="${COLLECTIVES_CONFIGURATION:-debug}"
case "$configuration" in
    debug|release) ;;
    *) printf 'COLLECTIVES_CONFIGURATION must be debug or release.\n' >&2; exit 2 ;;
esac

swift_options=(--scratch-path "$repo_root/.build/local" --configuration "$configuration")
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$repo_root/.build/cache/swift"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"

if [[ -n "${COLLECTIVES_SDK:-}" ]]; then
    [[ -d "$COLLECTIVES_SDK" ]] || { printf 'COLLECTIVES_SDK must point to an installed SDK directory.\n' >&2; exit 1; }
    swift_options+=(--sdk "$COLLECTIVES_SDK")
elif [[ "$developer_dir" == */CommandLineTools && ! -f "$toolchain_usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]; then
    # Some preview CLT SDKs reference SwiftUI macros absent from their toolchain.
    needs_older_sdk=false
    for interface in "$selected_sdk"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*.swiftinterface; do
        if [[ -f "$interface" && "$(< "$interface")" == *SwiftUIMacros* ]]; then
            needs_older_sdk=true
            break
        fi
    done
    if [[ "$needs_older_sdk" == true ]]; then
        compatible_sdk="$developer_dir/SDKs/MacOSX26.5.sdk"
        if [[ ! -d "$compatible_sdk" ]]; then
            printf 'Selected CLT SDK needs unavailable SwiftUI macros. Select full Xcode with xcode-select or set COLLECTIVES_SDK to a compatible installed SDK.\n' >&2
            exit 1
        fi
        printf 'Using installed macOS 26.5 SDK for the preview Command Line Tools workaround.\n' >&2
        swift_options+=(--sdk "$compatible_sdk")
    fi
fi

if [[ "$developer_dir" == */CommandLineTools ]]; then
    swift_options+=(--disable-sandbox)
    testing_plugin="$toolchain_usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    if [[ -f "$testing_plugin" ]]; then
        swift_options+=(-Xswiftc -load-plugin-library -Xswiftc "$testing_plugin")
    fi
fi

if [[ "$action" == test ]]; then
    exec "$swift_path" test "${swift_options[@]}"
fi

"$swift_path" build "${swift_options[@]}" --product Collectives
bin_path="$("$swift_path" build "${swift_options[@]}" --show-bin-path)"
executable="$bin_path/Collectives"
[[ -x "$executable" ]] || { printf 'Built executable was not found at %s\n' "$executable" >&2; exit 1; }
python3 scripts/bundle-mac.py "$executable" --output "$repo_root/.build/Collectives.app"
if [[ "$action" == run ]]; then
    printf 'Opening Collectives. Quit an older running copy first to use this build.\n'
    open "$repo_root/.build/Collectives.app"
fi
