#!/bin/bash

set -exo pipefail

## 有些系统中 cp 是 cp -i 的别名
unalias cp || true
BASE_DIR="$(pwd)" && export BASE_DIR

## 初始化集群配置
# shellcheck disable=SC1091
bash ./cluster.conf.sh && cd "${BASE_DIR}"

## 安装k8s集群组件
# shellcheck disable=SC1091
bash ./cluster.install.sh && cd "${BASE_DIR}"