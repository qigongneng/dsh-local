#!/bin/zsh
set -euo pipefail

support_root="${DSH_LOCAL_SUPPORT_ROOT:-$HOME/Library/Application Support/DSHLocalOfficial}"
node_bin="${DSH_LOCAL_NODE_BIN:-/Applications/DSH Local.app/Contents/Resources/bin/node}"
profile_root="${DSH_HOME:-$HOME/.dsh}/profiles/web"
timestamp="$(date '+%Y%m%d-%H%M%S')"

if [[ ! -x "$node_bin" || ! -f "$support_root/current/apps/cli/lib/bin.js" ]]; then
  print -u2 -- "DSH Local runtime is unavailable"
  exit 66
fi

mkdir -p "$support_root/backups/history-lite-uninstall-$timestamp"
if [[ -d "$profile_root" ]]; then
  ditto "$profile_root" "$support_root/backups/history-lite-uninstall-$timestamp/web-profile"
fi

PATH="$HOME/.nvm/versions/node/v26.2.0/bin:$PATH" \
  "$node_bin" "$support_root/current/apps/cli/lib/bin.js" \
  plugin --profile web remove dsh-host-history-lite-local
print -- "history-lite-local removed; restart DSH Local to apply"
