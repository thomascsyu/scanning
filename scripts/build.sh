#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Build outside cloud-synchronized Documents to avoid Finder metadata breaking codesign.
statement_build_dir="${TMPDIR:-/tmp}/StatementManagerRelease"
xcodebuild -project StatementManager.xcodeproj -scheme StatementManager -configuration Release -derivedDataPath "$statement_build_dir" CODE_SIGN_IDENTITY=- build
statement_release_dir="$HOME/Library/Developer/StatementManager/Release"
mkdir -p "$statement_release_dir"
ditto --norsrc "$statement_build_dir/Build/Products/Release/Statement Manager.app" "$statement_release_dir/Statement Manager.app"
xattr -cr "$statement_release_dir/Statement Manager.app"
codesign --verify --deep --strict "$statement_release_dir/Statement Manager.app"
printf '\nBuilt: %s/Statement Manager.app\n' "$statement_release_dir"
