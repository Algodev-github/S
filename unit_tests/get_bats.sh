#!/bin/sh
set -euo pipefail

# settings
test_framework="https://github.com/bats-core/bats-core"
commit="87b16eb"
destination_root="/tmp"
destination_path="bats-core"
download_destination="${destination_root}/${destination_path}"

# download
if [[ ! -d ${download_destination} ]]; then
    PREVPWD=$(pwd)
    cd "${destination_root}"

    curl -L "${test_framework}/tarball/${commit}" | tar xz
    mv "bats-core-bats-core-${commit}" "${destination_path}"

    cd ${PREVPWD}
fi

# install
if command -v bash >/dev/null 2>&1; then
    if ! "${download_destination}/install.sh" /usr/local; then
        echo "retrying with root privileges"
        sudo "${download_destination}/install.sh" /usr/local
    fi
    command -v bats
fi
