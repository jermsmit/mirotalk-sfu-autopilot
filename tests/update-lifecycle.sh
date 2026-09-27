#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
  echo "update lifecycle test failed: $1" >&2
  exit 1
}

write_mocks() {
  local bin_dir="$1"
  mkdir -p "${bin_dir}"

  cat > "${bin_dir}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_DOCKER_LOG}"

case "$*" in
  "compose ps -q mirotalksfu")
    echo mock-container
    ;;
  "inspect --format={{.Image}} mock-container")
    echo sha256:old
    ;;
  "pull -q mirotalk/sfu:latest")
    echo pulled
    ;;
  "image inspect --format={{.Id}} mirotalk/sfu:latest")
    echo sha256:new
    ;;
  "run --rm --entrypoint cat mirotalk/sfu:latest /src/app/src/config.js")
    cat "${MOCK_NEW_CONFIG}"
    ;;
  "compose up -d --force-recreate --wait --wait-timeout 120 mirotalksfu")
    count=0
    [[ -f "${MOCK_COMPOSE_COUNT}" ]] && count="$(<"${MOCK_COMPOSE_COUNT}")"
    ((count += 1))
    printf '%s\n' "${count}" > "${MOCK_COMPOSE_COUNT}"
    if [[ "${MOCK_FAIL_FIRST_UP:-false}" == "true" && "${count}" -eq 1 ]]; then
      exit 1
    fi
    ;;
  "image tag "*)
    ;;
  *)
    echo "Unexpected docker command: $*" >&2
    exit 1
    ;;
esac
EOF

  cat > "${bin_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *raw.githubusercontent.com* ]]; then
  cat "${MOCK_ENV_TEMPLATE}"
fi
EOF

  cat > "${bin_dir}/systemd-cat" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
EOF

  cat > "${bin_dir}/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "${bin_dir}/docker" "${bin_dir}/curl" "${bin_dir}/systemd-cat" "${bin_dir}/flock"
}

create_fixture() {
  local case_dir="$1"
  mkdir -p "${case_dir}/app/src" "${case_dir}/mock-bin"
  cp "${REPO_DIR}/scripts/update-mirotalksfu.sh" "${case_dir}/update-mirotalksfu.sh"
  chmod +x "${case_dir}/update-mirotalksfu.sh"

  cat > "${case_dir}/.env" <<'EOF'
SERVER_LISTEN_PORT=3010
EXISTING_VALUE=preserved
EOF
  cat > "${case_dir}/docker-compose.yml" <<'EOF'
services:
  mirotalksfu:
    image: mirotalk/sfu:latest
EOF
  cat > "${case_dir}/.autopilot-config-base.js" <<'EOF'
const localSetting = 'default';

const upstreamSetting = 'old';
EOF
  cat > "${case_dir}/app/src/config.js" <<'EOF'
const localSetting = 'customized';

const upstreamSetting = 'old';
EOF
  cat > "${case_dir}/new-config.js" <<'EOF'
const localSetting = 'default';

const upstreamSetting = 'new';
EOF
  cat > "${case_dir}/new-env.template" <<'EOF'
EXISTING_VALUE=upstream-default
NEW_PUBLIC_VALUE=enabled
NEW_API_KEY=replace-me
EOF

  : > "${case_dir}/docker.log"
  : > "${case_dir}/compose-count"
  write_mocks "${case_dir}/mock-bin"
}

run_updater() {
  local case_dir="$1"
  PATH="${case_dir}/mock-bin:${PATH}" \
    MOCK_DOCKER_LOG="${case_dir}/docker.log" \
    MOCK_COMPOSE_COUNT="${case_dir}/compose-count" \
    MOCK_NEW_CONFIG="${case_dir}/new-config.js" \
    MOCK_ENV_TEMPLATE="${case_dir}/new-env.template" \
    MOCK_FAIL_FIRST_UP="${MOCK_FAIL_FIRST_UP:-false}" \
    MIROTALK_LOCK_FILE="${case_dir}/maintenance.lock" \
    "${case_dir}/update-mirotalksfu.sh"
}

SUCCESS_DIR="${TEST_ROOT}/success"
create_fixture "${SUCCESS_DIR}"
run_updater "${SUCCESS_DIR}"
grep -Fq 'image: mirotalk/sfu:autopilot-current' "${SUCCESS_DIR}/docker-compose.yml" || fail "legacy image reference was not migrated"
grep -Fq 'pull_policy: never' "${SUCCESS_DIR}/docker-compose.yml" || fail "local image pull policy was not added"
grep -Fq "const localSetting = 'customized';" "${SUCCESS_DIR}/app/src/config.js" || fail "local config change was lost"
grep -Fq "const upstreamSetting = 'new';" "${SUCCESS_DIR}/app/src/config.js" || fail "upstream config change was not applied"
cmp -s "${SUCCESS_DIR}/new-config.js" "${SUCCESS_DIR}/.autopilot-config-base.js" || fail "config baseline was not advanced"
grep -Fq 'NEW_PUBLIC_VALUE=enabled' "${SUCCESS_DIR}/.env" || fail "non-secret environment default was not added"
if grep -Fq 'NEW_API_KEY=' "${SUCCESS_DIR}/.env"; then
  fail "sensitive environment default was added"
fi

ROLLBACK_DIR="${TEST_ROOT}/rollback"
create_fixture "${ROLLBACK_DIR}"
cp "${ROLLBACK_DIR}/.env" "${ROLLBACK_DIR}/expected.env"
cp "${ROLLBACK_DIR}/docker-compose.yml" "${ROLLBACK_DIR}/expected-compose.yml"
cp "${ROLLBACK_DIR}/app/src/config.js" "${ROLLBACK_DIR}/expected-config.js"
cp "${ROLLBACK_DIR}/.autopilot-config-base.js" "${ROLLBACK_DIR}/expected-base.js"
if MOCK_FAIL_FIRST_UP=true run_updater "${ROLLBACK_DIR}"; then
  fail "failed deployment unexpectedly succeeded"
fi
cmp -s "${ROLLBACK_DIR}/expected.env" "${ROLLBACK_DIR}/.env" || fail ".env was not restored"
cmp -s "${ROLLBACK_DIR}/expected-compose.yml" "${ROLLBACK_DIR}/docker-compose.yml" || fail "Compose file was not restored"
cmp -s "${ROLLBACK_DIR}/expected-config.js" "${ROLLBACK_DIR}/app/src/config.js" || fail "config.js was not restored"
cmp -s "${ROLLBACK_DIR}/expected-base.js" "${ROLLBACK_DIR}/.autopilot-config-base.js" || fail "config baseline changed after rollback"
grep -Fq 'image tag mirotalk/sfu:autopilot-rollback mirotalk/sfu:autopilot-current' "${ROLLBACK_DIR}/docker.log" || fail "rollback image was not restored"
grep -Fq 'image tag mirotalk/sfu:autopilot-rollback mirotalk/sfu:latest' "${ROLLBACK_DIR}/docker.log" || fail "legacy rollback image alias was not restored"

CONFLICT_DIR="${TEST_ROOT}/conflict"
create_fixture "${CONFLICT_DIR}"
cat > "${CONFLICT_DIR}/new-config.js" <<'EOF'
const localSetting = 'changed-upstream';

const upstreamSetting = 'old';
EOF
cp "${CONFLICT_DIR}/app/src/config.js" "${CONFLICT_DIR}/expected-config.js"
cp "${CONFLICT_DIR}/.autopilot-config-base.js" "${CONFLICT_DIR}/expected-base.js"
if run_updater "${CONFLICT_DIR}"; then
  fail "conflicting config update unexpectedly succeeded"
fi
cmp -s "${CONFLICT_DIR}/expected-config.js" "${CONFLICT_DIR}/app/src/config.js" || fail "config.js changed after merge conflict"
cmp -s "${CONFLICT_DIR}/expected-base.js" "${CONFLICT_DIR}/.autopilot-config-base.js" || fail "config baseline changed after merge conflict"
compgen -G "${CONFLICT_DIR}/backups/config.js.merge-conflict.*" >/dev/null || fail "merge conflict file was not saved"
[[ ! -s "${CONFLICT_DIR}/compose-count" ]] || fail "deployment started after merge conflict"

echo "Update lifecycle tests passed."