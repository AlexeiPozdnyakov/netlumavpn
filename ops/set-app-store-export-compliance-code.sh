#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
target_file="$repo_root/Config/AppStoreExportCompliance.local.xcconfig"

usage() {
  cat <<'EOF'
Usage:
  ops/set-app-store-export-compliance-code.sh <code-from-App-Store-Connect>

The code is written to Config/AppStoreExportCompliance.local.xcconfig, which is
gitignored and consumed by Xcode's Product > Archive flow.
EOF
}

if [ "${1:-}" = "" ]; then
  usage
  exit 1
fi

code=$1
if [ "$code" = "REPLACE_WITH_CODE_FROM_APP_STORE_CONNECT" ]; then
  echo "error: replace the placeholder with the code shown in App Store Connect." >&2
  exit 1
fi

mkdir -p "$(dirname "$target_file")"
cat > "$target_file" <<EOF
APP_STORE_EXPORT_COMPLIANCE_CODE = $code
EOF
chmod 600 "$target_file"

echo "Wrote Config/AppStoreExportCompliance.local.xcconfig."
echo "The file is gitignored; run Product > Archive again in Xcode."
