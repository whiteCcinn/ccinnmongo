#!/usr/bin/env bash
# Starts one authenticated MongoDB container per supported generation for integration tests.
#
#   scripts/it-up.sh            # start all versions
#   scripts/it-up.sh 2.6 8.0    # start selected versions
#
# Prints the CCINNMONGO_IT_URIS value to export before running `swift test --filter IntegrationTests`.
set -euo pipefail

USER_NAME="ccinn"
USER_PASSWORD="ccinn-secret"
ALL_VERSIONS=(2.6 3.0 3.2 3.4 3.6 4.0 8.0)
VERSIONS=("${@:-${ALL_VERSIONS[@]}}")

port_for() {
  case "$1" in
    2.6) echo 27126 ;; 3.0) echo 27130 ;; 3.2) echo 27132 ;; 3.4) echo 27134 ;;
    3.6) echo 27136 ;; 4.0) echo 27140 ;; 8.0) echo 27180 ;;
    *) echo "unsupported version $1" >&2; exit 1 ;;
  esac
}

platform_for() {
  # Images before 3.6 only exist for amd64 and run under emulation on Apple Silicon.
  case "$1" in 2.6|3.0|3.2|3.4) echo "linux/amd64" ;; *) echo "" ;; esac
}

uris=()
for version in "${VERSIONS[@]}"; do
  name="ccinnmongo-it-${version/./}"
  port="$(port_for "$version")"
  platform="$(platform_for "$version")"
  if ! docker ps --format '{{.Names}}' | grep -qx "$name"; then
    docker rm -f "$name" >/dev/null 2>&1 || true
    platform_args=()
    [[ -n "$platform" ]] && platform_args=(--platform "$platform")
    docker run -d --name "$name" ${platform_args[@]+"${platform_args[@]}"} -p "127.0.0.1:${port}:27017" "mongo:${version}" --auth >/dev/null
    echo "started $name on port $port" >&2
  fi

  shell="mongo"
  docker exec "$name" sh -c 'command -v mongosh' >/dev/null 2>&1 && shell="mongosh"

  # Wait until the server answers, then create the user through the localhost exception.
  for _ in $(seq 1 90); do
    if docker exec "$name" "$shell" --quiet admin --eval 'db.runCommand({ping: 1}).ok' >/dev/null 2>&1; then break; fi
    sleep 1
  done
  # createUser fails harmlessly when the user already exists (mongosh's auth() throws, so don't probe with it).
  docker exec "$name" "$shell" --quiet admin --eval \
    "db.createUser({user: '$USER_NAME', pwd: '$USER_PASSWORD', roles: ['root']})" \
    >/dev/null 2>&1 || true
  uris+=("${version}=mongodb://${USER_NAME}:${USER_PASSWORD}@127.0.0.1:${port}/?authSource=admin")
done

joined="$(IFS=,; echo "${uris[*]}")"
echo "export CCINNMONGO_IT_URIS=\"${joined}\""
