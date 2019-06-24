#!/bin/bash

set -exo pipefail

BASE_PATH="$(pwd)" && export BASE_PATH
export USER=root

## 初始化集群配置
# shellcheck disable=SC1091
source ./cluster.conf.sh && cd "${BASE_PATH}"

## 使集群间机器满足安装集群条件
# shellcheck disable=SC1091
source ./cluster.check.sh && cd "${BASE_PATH}"

## 安装k8s集群组件
# shellcheck disable=SC1091
source ./cluster.install.sh && cd "${BASE_PATH}"
