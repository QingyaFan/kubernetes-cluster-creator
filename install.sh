#!/bin/bash

set -exo pipefail

## 有些系统中 cp 是 cp -i 的别名
unalias cp || true
BASE_PATH="$(pwd)" && export BASE_PATH
# 根据集群服务器实际分配情况配置环境变量，包括Master、Nodes服务器
USER=root
ALL_SERVER_IPS=("192.168.31.81" "192.168.31.82" "192.168.31.83")
MASTER_IP=192.168.31.81
NODE_IPS=("192.168.31.81" "192.168.31.82" "192.168.31.83")

DOCKER_LOCATION=/home/docker
# SERVICE_UNIT_LOCATION=/lib/systemd/system # for ubuntu
SERVICE_UNIT_LOCATION=/usr/lib/systemd/system # for centos

export USER
export ALL_SERVER_IPS
export MASTER_IP
export NODE_IPS
export DOCKER_LOCATION
export SERVICE_UNIT_LOCATION

## 初始化集群配置
# shellcheck disable=SC1091
source ./cluster.conf.sh && cd "${BASE_PATH}"

## 安装k8s集群组件
# shellcheck disable=SC1091
source ./cluster.install.sh && cd "${BASE_PATH}"
