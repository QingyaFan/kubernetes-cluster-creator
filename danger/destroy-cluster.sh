#!/bin/bash

set -exuo pipefail

export NODE_IPS=("192.168.31.81" "192.168.31.82" "192.168.31.83")

## 停掉 Master 节点所有服务
systemctl stop kube-scheduler kube-controller-manager kube-apiserver docker flanneld etcd 
rm -rf /etc/kubernetes/* | true

## 停掉所有 Node 节点所有服务
for node in "${NODE_IPS[@]}"
do
    ssh "${USER}@${node}" "systemctl stop kube-proxy kubelet docker flanneld etcd"
    ssh "${USER}@${node}" "rm -rf /etc/kubernetes/*"
done
