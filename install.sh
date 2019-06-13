#!/bin/bash

set -x

## 有些系统中 cp 是 cp -i 的别名
unalias cp || true
BASE_DIR="$(pwd)" && export BASE_DIR

## 初始化集群配置
# shellcheck disable=SC1091
source ./cluster.conf.sh && cd "${BASE_DIR}"

## 制作并分发证书，支持ssl通信
# shellcheck disable=SC1091
source ./cluster.secrets.sh && cd "${BASE_DIR}"

## 安装k8s集群组件
# shellcheck disable=SC1091
source ./cluster.install.sh && cd "${BASE_DIR}"

## 安装Goehey平台应用
# shellcheck disable=SC1091
source ./geohey.apps.sh