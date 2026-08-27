#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 "usage: start-current.sh <node-bin> <port>"
  exit 64
fi

node_bin="$1"
port="$2"
support_root="${DSH_LOCAL_SUPPORT_ROOT:-$HOME/Library/Application Support/DSHLocalOfficial}"
current_link="$support_root/current"

if [[ ! -x "$node_bin" ]]; then
  print -u2 "DSH Local: Node executable is unavailable: $node_bin"
  exit 66
fi

if [[ ! -e "$current_link/apps/cli/lib/bin.js" ]]; then
  print -u2 "DSH Local: no verified official runtime is installed"
  exit 66
fi

source_root="$(cd "$current_link" && pwd -P)"
export DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
export PATH="${node_bin:h}:$HOME/.local/bin:$HOME/.hermes/node/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
launch_args=(web)

# A locally installed history compactor uses Host-internal APIs. The updater
# records every official version that passed an isolated plugin smoke test. If
# an upgrade has not passed, keep the official runtime available and disable
# only this optional row until it is revalidated.
profile_manifest="$DSH_HOME/profiles/web/package.json"
current_version_file="$support_root/state/current-version"
history_lite_compatible_file="$support_root/state/history-lite-compatible-version"
if [[ -f "$profile_manifest" ]] \
  && grep -q '"dsh-host-history-lite-local"' "$profile_manifest" \
  && [[ -f "$current_version_file" ]]; then
  current_version="$(<"$current_version_file")"
  compatible_version=""
  [[ -f "$history_lite_compatible_file" ]] && compatible_version="$(<"$history_lite_compatible_file")"
  if [[ "$compatible_version" != "$current_version" ]]; then
    compatibility_patch="$support_root/state/history-lite-disabled.patch.yml"
    mkdir -p "$support_root/state"
    print -r -- $'- id: history-lite-local\n  disabled: true' >| "$compatibility_patch"
    launch_args+=(--patch "$compatibility_patch")
    print -u2 -- "DSH Local: history-lite-local is disabled for unverified runtime $current_version"
  fi
fi

launch_args+=(--no-open --port "$port")
cd "$source_root"
exec "$node_bin" "$source_root/apps/cli/lib/bin.js" "${launch_args[@]}"
