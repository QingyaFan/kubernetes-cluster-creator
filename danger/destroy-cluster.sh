#!/bin/bash

set -exu

export NODE_IPS=("192.168.31.81" "192.168.31.82" "192.168.31.83")
export USER=root

## 停掉 Master 节点所有 k8s 服务，并清理安装文件
systemctl stop kube-scheduler || true
systemctl stop kube-controller-manager || true
systemctl stop kube-apiserver || true
systemctl disable kube-scheduler || true
systemctl disable kube-controller-manager || true
systemctl disable kube-apiserver || true
rm -rf /usr/lib/systemd/system/kube-scheduler.service
rm -rf /usr/lib/systemd/system/kube-controller-manager.service
rm -rf /usr/lib/systemd/system/kube-apiserver.service
rm -rf /usr/local/bin/kube-*
rm -rf /etc/kubernetes

## 停掉所有 Node 节点所有 k8s 服务，并删除安装文件
for node in "${NODE_IPS[@]}"
do
    ssh "${USER}@${node}" "systemctl stop kube-proxy || true"
    ssh "${USER}@${node}" "systemctl stop kubelet || true"
    ssh "${USER}@${node}" "rm -rf /usr/lib/systemd/system/kube-proxy.service && rm -rf /usr/lib/systemd/system/kubelet.service"
    ssh "${USER}@${node}" "rm -rf /usr/local/bin/kube*"
done

## 清理 docker flannel etcd
for node in "${NODE_IPS[@]}"
do
    ssh "${USER}@${node}" "systemctl disable docker || true"
    ssh "${USER}@${node}" "systemctl stop docker || true"
    ssh "${USER}@${node}" "rm -rf /usr/local/bin/docker && rm -rf /usr/lib/systemd/system/docker.service"
    ssh "${USER}@${node}" "systemctl disable flanneld || true"
    ssh "${USER}@${node}" "systemctl stop flanneld || true"
    ssh "${USER}@${node}" "rm -rf /usr/local/bin/flanneld && rm -rf /usr/lib/systemd/system/flanneld.service"
    ssh "${USER}@${node}" "rm -rf /usr/local/bin/mk-docker-opts.sh"
    ssh "${USER}@${node}" "systemctl disable etcd || true"
    ssh "${USER}@${node}" "systemctl stop etcd || true"
    ssh "${USER}@${node}" "rm -rf /var/lib/etcd && rm -rf /usr/lib/systemd/system/etcd.service"
    ssh "${USER}@${node}" "rm -rf /usr/local/bin/etcd"
done

## 清理自签证书
for node in "${NODE_IPS[@]}"
do
    ssh "${USER}@${node}" "rm -rf /etc/kubernetes"
done
