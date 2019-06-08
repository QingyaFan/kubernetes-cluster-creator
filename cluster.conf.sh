#!/bin/bash

set -x

# 根据集群服务器实际分配情况配置环境变量，包括Master、Nodes、NFS、Postgres、Redis服务器
USER=root
ALL_SERVER_IPS=("192.168.31.186" "192.168.31.82" "192.168.31.215" "192.168.31.168")
MASTER_IP=192.168.31.186
NODE_IPS=("192.168.31.186" "192.168.31.82" "192.168.31.215")

# 目前 PG_SERVER、REDIS_SERVER、NFS_SERVER 都放于数据库服务器
PG_SERVER=192.168.31.168
REDIS_SERVER=192.168.31.168
NFS_SERVER=192.168.31.168

ETCD_IPS=("192.168.31.186" "192.168.31.82" "192.168.31.215") # 选择 ALL_SERVER_IPS 前三个
ETCD_ENDPOINTS="https://192.168.31.186:2379,https://192.168.31.82:2379,https://192.168.31.215:2379"
ETCD_NODES="etcd-node0=https://192.168.31.186:2380,etcd-node1=https://192.168.31.82:2380,etcd-node2=https://192.168.31.215:2380"


DOCKER_LOCATION=/home/docker
BASE_PATH="$(pwd)"
# SERVICE_UNIT_LOCATION=/lib/systemd/system # for ubuntu
SERVICE_UNIT_LOCATION=/usr/lib/systemd/system # for centos

export USER
export ALL_SERVER_IPS
export MASTER_IP
export NODE_IPS
export ETCD_IPS
export ETCD_NODES
export ETCD_ENDPOINTS
export DOCKER_LOCATION
export NFS_SERVER
export PG_SERVER
export REDIS_SERVER
export BASE_PATH
export SERVICE_UNIT_LOCATION

# 配置集群中Master节点可以无需验证访问各个服务器节点
ssh-keygen
for node in "${ALL_SERVER_IPS[@]}"
do
ssh-copy-id -i ~/.ssh/id_rsa.pub "${node}"
ssh "${USER}@${node}" "systemctl stop firewalld && systemctl disable firewalld"
done

# 检查集群中所有Node是否开启了swap，若开启，则需要关闭，并禁止swap功能
cat > ./shutdown_swap.sh <<'EOF'
#!/bin/sh

set -x

export SWAPFILELINE=$(cat < /proc/swaps | wc -l)
if [[ "$SWAPFILELINE" -gt 1 ]]
then
    echo "swap exist, removing swaps"
    swapoff -a
    sed -i '/swap/d' /etc/fstab
fi
EOF
chmod +x ./shutdown_swap.sh

for node in "${ALL_SERVER_IPS[@]}"
do
scp ./shutdown_swap.sh "${USER}@${node}:~/"
ssh "${USER}@${node}" "bash ~/shutdown_swap.sh"
done