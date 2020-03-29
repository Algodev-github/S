#!/bin/bash
set -euo pipefail

pushd "$(dirname "${BASH_SOURCE[0]}")/unit_tests"

# get bats
bash get_bats.sh

# get lsblk
if ! command -v lsblk >/dev/null 2>&1; then
  echo "installing lsblk with util-linux..."
  if ! apk add util-linux >/dev/null 2>&1; then
    apt-get update >/dev/null 2>&1
    apt-get install -y util-linux >/dev/null 2>&1
  fi
  command -v lsblk >/dev/null 2>&1
fi

# run tests
bats .

popd
