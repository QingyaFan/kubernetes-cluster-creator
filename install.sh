#!/bin/bash

set -exo pipefail

BASE_PATH="$(pwd)" && export BASE_PATH
export USER=root

## cluster conf
# shellcheck disable=SC1091
source ./cluster.conf.sh && cd "${BASE_PATH}"

## precheck
# shellcheck disable=SC1091
source ./cluster.check.sh && cd "${BASE_PATH}"

## install
# shellcheck disable=SC1091
source ./cluster.install.sh && cd "${BASE_PATH}"
