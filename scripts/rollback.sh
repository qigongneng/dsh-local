#!/bin/zsh
set -euo pipefail

support_root="${DSH_LOCAL_SUPPORT_ROOT:-$HOME/Library/Application Support/DSHLocalOfficial}"
log_file="$support_root/logs/update.log"
mkdir -p "$support_root/logs" "$support_root/state"
exec >>"$log_file" 2>&1

current_version=""
previous_version=""
[[ -f "$support_root/state/current-version" ]] && current_version="$(<"$support_root/state/current-version")"
if (( $# > 0 )); then
  previous_version="$1"
elif [[ -f "$support_root/state/previous-version" ]]; then
  previous_version="$(<"$support_root/state/previous-version")"
fi

if [[ ! "$previous_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  print -u2 -- "No valid previous version is recorded"
  exit 66
fi
if [[ ! -f "$support_root/versions/$previous_version/source/apps/cli/lib/bin.js" ]]; then
  print -u2 -- "Previous version is unavailable: $previous_version"
  exit 66
fi

temporary_link="$support_root/current.rollback.$$"
ln -s "versions/$previous_version/source" "$temporary_link"
mv -fh "$temporary_link" "$support_root/current"
print -r -- "$previous_version" >| "$support_root/state/current-version"
if [[ -n "$current_version" ]]; then
  print -r -- "$current_version" >| "$support_root/state/previous-version"
fi
print -- "[$(date '+%Y-%m-%d %H:%M:%S')] Rolled back from $current_version to $previous_version; restart DSH Local to apply"
