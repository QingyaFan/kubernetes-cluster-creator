#!/bin/bash

set -x

export NODE_IPS=("10.10.0.82" "10.10.0.83" "10.10.0.84")
export USER=root

## 停掉 Master 节点所有服务
systemctl stop kube-scheduler kube-controller-manager kube-apiserver docker flanneld etcd 
rm -rf /etc/kubernetes/*
rm -rf /var/lib/etcd

## 停掉所有 Node 节点所有服务
for node in "${NODE_IPS[@]}"
do
    ssh "${USER}@${node}" "systemctl stop kube-proxy kubelet docker flanneld etcd"
    ssh "${USER}@${node}" "rm -rf /etc/kubernetes/*"
    ssh "${USER}@${node}" "rm -rf /var/lib/etcd"
done
