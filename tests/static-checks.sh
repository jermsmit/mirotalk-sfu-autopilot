#!/usr/bin/env bash

set -euo pipefail

for script in install.sh uninstall.sh scripts/*.sh; do
  bash -n "${script}"
done

shellcheck install.sh uninstall.sh scripts/*.sh tests/*.sh

grep -Fq 'TRUST_PROXY=true' install.sh
grep -Fq 'HOST_USER_AUTH=false' install.sh
grep -Fq './app/src/config.js:/src/app/src/config.js:ro' install.sh
grep -Fq 'cp -f app/src/config.template.js .autopilot-config-base.js' install.sh
grep -Fq 'image: mirotalk/sfu:autopilot-current' install.sh
grep -Fq 'pull_policy: never' install.sh
grep -Fq 'mirotalk mediasoup TCP fallback' install.sh
grep -Fq 'mirotalk/sfu:autopilot-rollback' scripts/update-mirotalksfu.sh
grep -Fq -- '--wait-timeout 120' scripts/update-mirotalksfu.sh
grep -Fq 'flock -n 9' scripts/update-mirotalksfu.sh
grep -Fq "config.js.\${STAMP}" scripts/update-mirotalksfu.sh
grep -Fq 'ADDED_ENV_VARS' scripts/update-mirotalksfu.sh
grep -Fq 'git merge-file' scripts/update-mirotalksfu.sh
grep -Fq 'print "    pull_policy: never"' scripts/update-mirotalksfu.sh

if grep -Eq '^[[:space:]]*source[[:space:]]+' uninstall.sh; then
  echo "uninstall.sh must not source installation state" >&2
  exit 1
fi

bash tests/update-lifecycle.sh
