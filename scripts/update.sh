#!/bin/zsh
set -euo pipefail

support_root="${DSH_LOCAL_SUPPORT_ROOT:-$HOME/Library/Application Support/DSHLocalOfficial}"
node_bin="${DSH_LOCAL_NODE_BIN:-$HOME/.local/bin/node}"
npm_bin="${DSH_LOCAL_NPM_BIN:-$HOME/.local/bin/npm}"
repository_url="https://github.com/deepseek-ai/deepseek-harness.git"
releases_api="https://api.github.com/repos/deepseek-ai/deepseek-harness/releases?per_page=20"
npm_registry="https://registry.npmjs.org"
dsh_home="${DSH_HOME:-$HOME/.dsh}"
source_archive_root="${DSH_LOCAL_SOURCE_ARCHIVE_ROOT:-$HOME/Application/CODE/DSH-Local-Official/upstream}"
timestamp="$(date '+%Y%m%d-%H%M%S')"

mkdir -p "$support_root/logs" "$support_root/state" "$support_root/staging" \
  "$support_root/versions" "$support_root/backups" "$support_root/failures" \
  "$support_root/build-records" "$source_archive_root"
log_file="$support_root/logs/update.log"
exec >>"$log_file" 2>&1

log() {
  print -- "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# DSH 0.1.2+ protects the browser surface with a one-time launch token. The
# token is exchanged at the printed root URL for an HttpOnly browser cookie.
# Smoke tests run in throwaway processes, so they may consume that token; the
# production desktop process must instead hand its token directly to WebKit.
redact_web_tokens() {
  sed -E 's/([?&]token=)[A-Za-z0-9_-]+/\1<redacted>/g'
}

redact_web_tokens_in_file() {
  local source_file="$1"
  local redacted_file="$source_file.redacted.$$"
  [[ -f "$source_file" ]] || return 0
  if redact_web_tokens <"$source_file" >| "$redacted_file"; then
    mv -fh "$redacted_file" "$source_file"
  else
    : >| "$redacted_file"
  fi
}

auth_artifacts=()
sanitize_auth_artifacts() {
  local artifact
  for artifact in "${auth_artifacts[@]}"; do
    [[ -f "$artifact" ]] && : >| "$artifact"
  done
  if [[ -n "$stage" && -d "$stage" ]]; then
    local log_path
    while IFS= read -r log_path; do
      redact_web_tokens_in_file "$log_path"
    done < <(find "$stage" -type f -name '*.log' 2>/dev/null)
  fi
}

# Wait for the official readiness URL, validate its loopback authority, perform
# the one-time token exchange when present, then verify the authenticated root.
# The cookie jar is caller-owned so a following API probe can reuse it.
wait_for_authenticated_web() {
  local web_port="$1"
  local output_log="$2"
  local process_pid="$3"
  local cookie_jar="$4"
  local origin="http://127.0.0.1:$web_port"
  local launch_url=""
  local launch_token=""
  local exchange_headers="$cookie_jar.headers"
  local exchange_error="$cookie_jar.error"
  local exchange_status=""

  auth_artifacts+=("$cookie_jar" "$exchange_headers" "$exchange_error")
  : >| "$cookie_jar"
  : >| "$exchange_headers"
  : >| "$exchange_error"

  for _ in {1..180}; do
    launch_url="$(awk -v marker="dsh web: $origin/" '
      index($0, marker) {
        value = substr($0, index($0, marker) + 9)
        sub(/[[:space:]].*$/, "", value)
        print value
        exit
      }
    ' "$output_log")"
    [[ -n "$launch_url" ]] && break
    if ! kill -0 "$process_pid" 2>/dev/null; then
      return 1
    fi
    sleep 1
  done

  case "$launch_url" in
    "$origin/")
      ;;
    "$origin/?token="*)
      launch_token="${launch_url#"$origin/?token="}"
      if [[ ! "$launch_token" =~ '^[A-Za-z0-9_-]{43}$' ]]; then
        log "ERROR DSH printed an invalid browser launch token"
        return 1
      fi
      if ! exchange_status="$(curl --noproxy '*' -sS --max-time 10 \
        -c "$cookie_jar" -D "$exchange_headers" -o /dev/null -w '%{http_code}' \
        "$launch_url" 2>"$exchange_error")"; then
        redact_web_tokens <"$exchange_error" || true
        return 1
      fi
      if [[ "$exchange_status" != "303" ]] \
        || ! rg -qi '^location:[[:space:]]*/[[:space:]]*$' "$exchange_headers" \
        || ! rg -qi '^set-cookie:' "$exchange_headers"; then
        log "ERROR DSH browser token exchange returned HTTP $exchange_status"
        return 1
      fi
      ;;
    *)
      [[ -n "$launch_url" ]] && log "ERROR DSH printed an unexpected readiness URL (redacted)"
      return 1
      ;;
  esac

  if [[ -n "$launch_token" ]]; then
    curl --noproxy '*' -fsS --max-time 10 -b "$cookie_jar" "$origin/" \
      | rg -q '<html|DeepSeek Harness'
  else
    curl --noproxy '*' -fsS --max-time 10 "$origin/" \
      | rg -q '<html|DeepSeek Harness'
  fi
}

for command_name in awk curl ditto find jq git lsof rg sed shasum tar; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    log "ERROR required command is unavailable: $command_name"
    exit 69
  fi
done

if [[ ! -x "$node_bin" || ! -x "$npm_bin" ]]; then
  log "ERROR Node/npm unavailable: node=$node_bin npm=$npm_bin"
  exit 69
fi

lock_dir="$support_root/update.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  log "Another update check is already running"
  exit 0
fi

stage=""
smoke_pid=""
history_lite_compatibility="not-installed"
history_lite_plugin_path=""
plugin_smoke_home=""
plugin_smoke_log=""
finish() {
  exit_code=$?
  if [[ -n "$smoke_pid" ]] && kill -0 "$smoke_pid" 2>/dev/null; then
    kill -TERM "$smoke_pid" 2>/dev/null || true
    wait "$smoke_pid" 2>/dev/null || true
  fi
  sanitize_auth_artifacts
  if (( exit_code != 0 )) && [[ -n "$stage" && -d "$stage" ]]; then
    failure_path="$support_root/failures/${stage:t}-$timestamp"
    mv "$stage" "$failure_path" 2>/dev/null || true
    log "Failed staging tree retained at $failure_path"
  fi
  rmdir "$lock_dir" 2>/dev/null || true
  if (( exit_code == 0 )); then
    log "Update check finished successfully"
  else
    log "Update check failed with exit code $exit_code; current runtime was not replaced"
  fi
}
trap finish EXIT

log "Checking immutable releases from $repository_url"
release_json="$(curl -fsSL --retry 3 --connect-timeout 15 "$releases_api")"
tag="$(print -r -- "$release_json" | jq -r '[.[] | select(.draft == false and (.tag_name | startswith("dsh-v")))] | sort_by(.published_at) | last | .tag_name // empty')"
published_at="$(print -r -- "$release_json" | jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .published_at')"
release_name="$(print -r -- "$release_json" | jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .name // .tag_name')"
release_url="$(print -r -- "$release_json" | jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .html_url // empty')"
release_body="$(print -r -- "$release_json" | jq -r --arg tag "$tag" '.[] | select(.tag_name == $tag) | .body // empty')"

if [[ ! "$tag" =~ '^dsh-v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' ]]; then
  log "ERROR unexpected official release tag: $tag"
  exit 65
fi
version="${tag#dsh-v}"

if [[ "$release_body" == *'[中文]'* || "$release_body" == *'id="cn'* ]]; then
  release_notes_zh="$(print -r -- "$release_body" | awk '
    /^[[:space:]]*---[[:space:]]*$/ { exit }
    NR == 1 && /^\[中文\]/ { next }
    { print }
  ')"
else
  release_notes_zh=$'官方暂未提供中文发布说明。\n\n请点击“查看官方发布页”阅读完整更新内容。'
fi

write_release_notes() {
  local destination_root="$1"
  local temporary_notes="$destination_root/.release-notes-zh.md.new.$$"
  mkdir -p "$destination_root"
  print -r -- "$release_notes_zh" >| "$temporary_notes"
  mv -fh "$temporary_notes" "$destination_root/release-notes-zh.md"
}

tag_ref_api="https://api.github.com/repos/deepseek-ai/deepseek-harness/git/ref/tags/$tag"
tag_ref_json="$(curl -fsSL --retry 3 --connect-timeout 15 "$tag_ref_api")"
tag_object_type="$(print -r -- "$tag_ref_json" | jq -r '.object.type // empty')"
expected_tag_commit="$(print -r -- "$tag_ref_json" | jq -r '.object.sha // empty')"
if [[ "$tag_object_type" == "tag" ]]; then
  tag_object_url="$(print -r -- "$tag_ref_json" | jq -r '.object.url // empty')"
  if [[ "$tag_object_url" != https://api.github.com/repos/deepseek-ai/deepseek-harness/git/tags/* ]]; then
    log "ERROR unexpected annotated tag object URL"
    exit 65
  fi
  tag_object_json="$(curl -fsSL --retry 3 --connect-timeout 15 "$tag_object_url")"
  tag_object_type="$(print -r -- "$tag_object_json" | jq -r '.object.type // empty')"
  expected_tag_commit="$(print -r -- "$tag_object_json" | jq -r '.object.sha // empty')"
fi
if [[ "$tag_object_type" != "commit" || ! "$expected_tag_commit" =~ '^[0-9a-f]{40}$' ]]; then
  log "ERROR official tag did not resolve to a commit"
  exit 65
fi

current_version=""
if [[ -f "$support_root/state/current-version" ]]; then
  current_version="$(<"$support_root/state/current-version")"
fi
if [[ "$current_version" == "$version" && -f "$support_root/current/apps/cli/lib/bin.js" ]]; then
  write_release_notes "$support_root/versions/$version"
  log "Already current: $version"
  exit 0
fi

log "Official release discovered: $tag, published $published_at"
npm_metadata="$(PATH="${node_bin:h}:$HOME/.local/bin:$HOME/.hermes/node/bin:/usr/bin:/bin" \
  "$npm_bin" view "@deepseek-ai/dsh@$version" version dist.integrity repository.url \
  --json --registry="$npm_registry")"
npm_version="$(print -r -- "$npm_metadata" | jq -r '.version // empty')"
npm_integrity="$(print -r -- "$npm_metadata" | jq -r '."dist.integrity" // empty')"
if [[ "$npm_version" != "$version" || -z "$npm_integrity" ]]; then
  log "ERROR GitHub release and official npm publication do not agree"
  exit 65
fi
log "Official npm publication matched; integrity=$npm_integrity"

stage="$support_root/staging/$version-$$"
mkdir -p "$stage"
source_root="$stage/source"
clone_succeeded=0
source_cache="$source_archive_root/$tag"
if [[ -d "$source_cache/.git" ]]; then
  cached_commit="$(git -C "$source_cache" rev-parse HEAD 2>/dev/null || true)"
  cached_tag="$(git -C "$source_cache" describe --tags --exact-match 2>/dev/null || true)"
  cached_version="$(jq -r '.version // empty' "$source_cache/package.json" 2>/dev/null || true)"
  if [[ "$cached_commit" == "$expected_tag_commit" && "$cached_tag" == "$tag" && "$cached_version" == "$version" ]]; then
    log "Using locally cached official source after tag and commit verification"
    ditto "$source_cache" "$source_root"
    clone_succeeded=1
  else
    log "Ignoring source cache because its tag, commit, or version does not match the official release"
  fi
fi
clone_attempt_limit="${DSH_LOCAL_GIT_CLONE_ATTEMPTS:-3}"
if [[ ! "$clone_attempt_limit" =~ '^[0-5]$' ]]; then
  log "ERROR DSH_LOCAL_GIT_CLONE_ATTEMPTS must be an integer from 0 to 5"
  exit 64
fi
for (( clone_attempt = 1; clone_succeeded == 0 && clone_attempt <= clone_attempt_limit; clone_attempt++ )); do
  if git -c http.version=HTTP/1.1 clone --filter=blob:none --depth 1 \
    --branch "$tag" "$repository_url" "$source_root"; then
    clone_succeeded=1
    break
  fi
  if [[ -e "$source_root" ]]; then
    mv "$source_root" "$stage/source-attempt-$clone_attempt.failed"
  fi
  log "Official source clone attempt $clone_attempt failed; retrying with HTTP/1.1"
done
source_mode="git"
archive_sha256=""
if (( clone_succeeded == 0 )); then
  source_mode="github-tag-archive"
  archive_path="$stage/official-source.tar.gz"
  archive_url="https://codeload.github.com/deepseek-ai/deepseek-harness/tar.gz/refs/tags/$tag"
  log "Git clone unavailable; downloading the official immutable tag archive"
  curl -fsSL --retry 3 --connect-timeout 15 "$archive_url" -o "$archive_path"
  archive_sha256="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  mkdir -p "$source_root"
  tar -xzf "$archive_path" -C "$source_root" --strip-components=1
fi

source_version="$(jq -r '.version' "$source_root/package.json")"
if [[ "$source_mode" == "git" ]]; then
  local_commit="$(git -C "$source_root" rev-parse HEAD)"
  tag_commit="$(git -C "$source_root" rev-list -n 1 "$tag")"
  exact_tag="$(git -C "$source_root" describe --tags --exact-match)"
  if [[ "$local_commit" != "$tag_commit" || "$local_commit" != "$expected_tag_commit" || "$exact_tag" != "$tag" ]]; then
    log "ERROR Git source verification failed: head=$local_commit localTag=$tag_commit apiTag=$expected_tag_commit exactTag=$exact_tag"
    exit 65
  fi
else
  local_commit="$expected_tag_commit"
fi
if [[ "$source_version" != "$version" ]]; then
  log "ERROR source package version $source_version does not match release $version"
  exit 65
fi
log "Verified official source: mode=$source_mode commit=$local_commit version=$source_version archiveSha256=$archive_sha256"

if [[ ! -e "$source_cache" ]]; then
  source_cache_staging="$source_archive_root/.$tag.new.$$"
  ditto "$source_root" "$source_cache_staging"
  mv -fh "$source_cache_staging" "$source_cache"
  log "Archived clean official source at $source_cache"
fi

package_manager="$(jq -r '.packageManager' "$source_root/package.json")"
if [[ ! "$package_manager" =~ '^pnpm@[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  log "ERROR unsupported packageManager declaration: $package_manager"
  exit 65
fi
pnpm_version="${package_manager#pnpm@}"
run_pnpm() {
  PATH="${node_bin:h}:$HOME/.local/bin:$HOME/.hermes/node/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    npm_config_registry="$npm_registry" \
    PNPM_DISABLE_SELF_UPDATE_CHECK=1 \
    "$npm_bin" exec --yes --package="pnpm@$pnpm_version" -- pnpm "$@"
}

log "Installing the official frozen dependency graph with pnpm $pnpm_version"
(cd "$source_root" && CI=1 run_pnpm install --frozen-lockfile)
log "Building official source"
(cd "$source_root" && CI=1 run_pnpm run build)

if [[ ! -f "$source_root/apps/cli/lib/bin.js" ]]; then
  log "ERROR official build did not produce apps/cli/lib/bin.js"
  exit 70
fi

smoke_port=$((39080 + ($$ % 500)))
while lsof -nP -iTCP:"$smoke_port" -sTCP:LISTEN >/dev/null 2>&1; do
  (( smoke_port += 1 ))
done
smoke_home="$stage/smoke-home"
smoke_log="$stage/smoke.log"
mkdir -p "$smoke_home"
log "Starting isolated smoke test on 127.0.0.1:$smoke_port"
(
  cd "$source_root"
  DSH_HOME="$smoke_home" "$node_bin" "$source_root/apps/cli/lib/bin.js" \
    web --no-open --port "$smoke_port" >"$smoke_log" 2>&1
) &
smoke_pid=$!

healthy=false
smoke_cookie_jar="$smoke_home/browser-cookie.jar"
if wait_for_authenticated_web "$smoke_port" "$smoke_log" "$smoke_pid" "$smoke_cookie_jar"; then
  healthy=true
fi
if [[ "$healthy" != true ]]; then
  log "ERROR isolated health check failed"
  tail -n 120 "$smoke_log" | redact_web_tokens || true
  exit 70
fi
kill -TERM "$smoke_pid" 2>/dev/null || true
wait "$smoke_pid" 2>/dev/null || true
smoke_pid=""
log "Isolated health check passed"

# Out-of-tree Host plugins can depend on internal APIs. Test the locally
# installed history compactor against the candidate official runtime before
# activation. A failure does not block the official upgrade: start-current.sh
# disables only the optional plugin row for that version.
profile_manifest="$dsh_home/profiles/web/package.json"
if [[ -f "$profile_manifest" ]] && jq -e '.dependencies["dsh-host-history-lite-local"]' "$profile_manifest" >/dev/null 2>&1; then
  plugin_spec="$(jq -r '.dependencies["dsh-host-history-lite-local"]' "$profile_manifest")"
  case "$plugin_spec" in
    link:*) history_lite_plugin_path="${plugin_spec#link:}" ;;
    file:*) history_lite_plugin_path="${plugin_spec#file:}" ;;
    /*) history_lite_plugin_path="$plugin_spec" ;;
  esac

  history_lite_compatibility="incompatible"
  plugin_smoke_home="$stage/history-lite-smoke-home"
  plugin_smoke_log="$stage/history-lite-smoke.log"
  mkdir -p "$plugin_smoke_home"

  if [[ -f "$history_lite_plugin_path/package.json" ]]; then
    log "Testing history-lite-local against candidate runtime $version"
    if DSH_HOME="$plugin_smoke_home" \
      "$node_bin" "$source_root/apps/cli/lib/bin.js" plugin --profile web add "$history_lite_plugin_path" \
      >"$plugin_smoke_log" 2>&1; then
      plugin_smoke_port=$((39600 + ($$ % 300)))
      while lsof -nP -iTCP:"$plugin_smoke_port" -sTCP:LISTEN >/dev/null 2>&1; do
        (( plugin_smoke_port += 1 ))
      done
      (
        cd "$source_root"
        DSH_HOME="$plugin_smoke_home" "$node_bin" "$source_root/apps/cli/lib/bin.js" \
          web --no-open --port "$plugin_smoke_port" >>"$plugin_smoke_log" 2>&1
      ) &
      smoke_pid=$!

      plugin_healthy=false
      plugin_cookie_jar="$plugin_smoke_home/browser-cookie.jar"
      if wait_for_authenticated_web "$plugin_smoke_port" "$plugin_smoke_log" "$smoke_pid" "$plugin_cookie_jar"; then
        plugin_healthy=true
      fi

      if [[ "$plugin_healthy" == true ]]; then
        probe_headers="$plugin_smoke_home/probe.headers"
        probe_body="$plugin_smoke_home/probe.json"
        if curl -sS --max-time 10 -D "$probe_headers" -o "$probe_body" \
          -b "$plugin_cookie_jar" \
          -H 'content-type: application/json' \
          --data-binary '{"type":"client-request","rpcId":"history-lite-update-smoke","method":"session.history","payload":{"sessionId":"session-00000000-0000-4000-8000-000000000000","maxMessages":1}}' \
          "http://127.0.0.1:$plugin_smoke_port/api/session.history" \
          && rg -qi '^x-dsh-history-lite:[[:space:]]*local\.1' "$probe_headers"; then
          history_lite_compatibility="compatible"
        fi
      fi

      if kill -0 "$smoke_pid" 2>/dev/null; then
        kill -TERM "$smoke_pid" 2>/dev/null || true
        wait "$smoke_pid" 2>/dev/null || true
      fi
      smoke_pid=""
    fi
  fi

  if [[ "$history_lite_compatibility" == "compatible" ]]; then
    log "history-lite-local compatibility smoke passed for $version"
  else
    log "WARNING history-lite-local did not pass on $version; the official runtime will update and the optional plugin will be disabled"
  fi
fi

sanitize_auth_artifacts

version_root="$support_root/versions/$version"
if [[ -e "$version_root/source" ]]; then
  existing_path="$support_root/build-records/replaced-$version-$timestamp"
  mv "$version_root/source" "$existing_path"
  log "Previous build of the same version retained at $existing_path"
fi
mkdir -p "$version_root"
mv "$source_root" "$version_root/source"
write_release_notes "$version_root"

if [[ -n "$current_version" && -d "$dsh_home" ]]; then
  backup_path="$support_root/backups/dsh-$timestamp-before-$version"
  ditto "$dsh_home" "$backup_path"
  log "User data backup created at $backup_path"
fi

if [[ -n "$current_version" && "$current_version" != "$version" ]]; then
  print -r -- "$current_version" >| "$support_root/state/previous-version"
fi
temporary_link="$support_root/current.new.$$"
ln -s "versions/$version/source" "$temporary_link"
mv -fh "$temporary_link" "$support_root/current"
print -r -- "$version" >| "$support_root/state/current-version"
case "$history_lite_compatibility" in
  compatible)
    print -r -- "$version" >| "$support_root/state/history-lite-compatible-version"
    ;;
  incompatible)
    print -r -- "$version" >| "$support_root/state/history-lite-incompatible-version"
    ;;
esac

jq -n \
  --arg version "$version" \
  --arg tag "$tag" \
  --arg commit "$local_commit" \
  --arg publishedAt "$published_at" \
  --arg releaseName "$release_name" \
  --arg releaseUrl "$release_url" \
  --arg npmIntegrity "$npm_integrity" \
  --arg sourceMode "$source_mode" \
  --arg archiveSha256 "$archive_sha256" \
  --arg builtAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{version:$version,tag:$tag,commit:$commit,publishedAt:$publishedAt,releaseName:$releaseName,releaseUrl:$releaseUrl,releaseNotesFile:"release-notes-zh.md",releaseNotesLocale:"zh-CN",npmIntegrity:$npmIntegrity,sourceMode:$sourceMode,archiveSha256:$archiveSha256,builtAt:$builtAt,source:"https://github.com/deepseek-ai/deepseek-harness"}' \
  >| "$version_root/build-metadata.json"

record_path="$support_root/build-records/$version-$timestamp"
mkdir -p "$record_path"
mv "$smoke_log" "$record_path/smoke.log"
mv "$smoke_home" "$record_path/smoke-home"
if [[ -n "$plugin_smoke_log" && -f "$plugin_smoke_log" ]]; then
  mv "$plugin_smoke_log" "$record_path/history-lite-smoke.log"
fi
if [[ -n "$plugin_smoke_home" && -d "$plugin_smoke_home" ]]; then
  mv "$plugin_smoke_home" "$record_path/history-lite-smoke-home"
fi
rmdir "$stage" 2>/dev/null || true
stage=""
log "Activated verified official runtime $version for the next application launch"
