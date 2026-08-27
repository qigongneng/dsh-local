#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
plugin_root="$project_root/plugins/dsh-host-history-lite-local"
support_root="${DSH_LOCAL_SUPPORT_ROOT:-$HOME/Library/Application Support/DSHLocalOfficial}"
node_bin="${DSH_LOCAL_NODE_BIN:-/Applications/DSH Local.app/Contents/Resources/bin/node}"
profile_root="${DSH_HOME:-$HOME/.dsh}/profiles/web"
timestamp="$(date '+%Y%m%d-%H%M%S')"

if [[ ! -x "$node_bin" || ! -f "$support_root/current/apps/cli/lib/bin.js" ]]; then
  print -u2 -- "DSH Local runtime is unavailable"
  exit 66
fi

"$node_bin" --test "$plugin_root"/tests/*.test.mjs
PATH="$HOME/.nvm/versions/node/v26.2.0/bin:$PATH" pnpm --dir "$plugin_root" install --prod

mkdir -p "$support_root/backups/history-lite-$timestamp"
if [[ -d "$profile_root" ]]; then
  ditto "$profile_root" "$support_root/backups/history-lite-$timestamp/web-profile"
fi

PATH="$HOME/.nvm/versions/node/v26.2.0/bin:$PATH" \
  "$node_bin" "$support_root/current/apps/cli/lib/bin.js" \
  plugin --profile web add "$plugin_root"

if [[ -f "$support_root/state/current-version" ]]; then
  ditto "$support_root/state/current-version" "$support_root/state/history-lite-compatible-version"
fi
print -- "history-lite-local installed; restart DSH Local to apply"
