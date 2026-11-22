#!/bin/bash
# Notarize an already signed app so retries use the very same executable.
set -euo pipefail
if [[ $# != 3 || ! -d "$1/Contents" ]]; then
    echo "Usage: bash notarize-mac.sh APP KEYCHAIN_PROFILE OUTPUT.zip" >&2
    exit 2
fi
app="$(cd "$1" && pwd)"
profile="$2"
output_dir="$(cd "$(dirname "$3")" && pwd)"
output_zip="$output_dir/$(basename "$3")"
[[ "$output_zip" == *.zip ]]
stage=$(mktemp -d "$output_dir/.notary.XXXXXX")
trap 'rm -rf "$stage"' EXIT
codesign --verify --strict --all-architectures \
    -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
ditto -c -k --keepParent "$app" "$stage/submission.zip"
if ! xcrun notarytool submit "$stage/submission.zip" --keychain-profile "$profile" \
    --wait --output-format json > "$stage/result.json"; then
    cat "$stage/result.json" >&2
    exit 1
fi
cat "$stage/result.json"
[[ "$(plutil -extract status raw -o - "$stage/result.json")" == Accepted ]]
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=4 "$app"
ditto -c -k --keepParent "$app" "$stage/distribution.zip"
ditto -x -k "$stage/distribution.zip" "$stage/extracted"
extracted="$stage/extracted/$(basename "$app")"
codesign --verify --strict --all-architectures "$extracted"
xcrun stapler validate "$extracted"
mv "$stage/distribution.zip" "$output_zip"
printf 'Notarized archive saved to %s\n' "$output_zip"
