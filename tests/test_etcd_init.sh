#!/bin/bash

set -exo pipefail

cd "${BASE_PATH}" || return

export ALL_SERVER_IPS=("10.10.0.82" "10.10.0.83" "10.10.0.84")
export MASTER_IP=10.10.0.82
export NODE_IPS=("10.10.0.82" "10.10.0.83" "10.10.0.84")
export DOCKER_LOCATION=/home/docker
export SERVICE_UNIT_LOCATION=/usr/lib/systemd/system

# 用于存放临时文件，方便追溯安装过程
mkdir ./tmp

#-------------------------------------------------------------#
#                                                             #
#      生成集群通信证书，保证集群内使用加密通信                      #
#                                                             #
#-------------------------------------------------------------#

## 安装CFSSL证书工具
chmod +x ../bins/cfssl*
cp -rf ../bins/cfssl_linux-amd64 /usr/local/bin/cfssl
cp -rf ../bins/cfssl-certinfo_linux-amd64 /usr/local/bin/cfssl-certinfo
cp -rf ../bins/cfssljson_linux-amd64 /usr/local/bin/cfssljson

## 在master节点生成证书，并分发到各个node节点
### 创建CA证书
cd ../ssl && rm -rf ./* || return
cfssl print-defaults config > config.json
cfssl print-defaults csr > csr.json
cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "87600h"
    },
    "profiles": {
      "kubernetes": {
        "usages": [
            "signing",
            "key encipherment",
            "server auth",
            "client auth"
        ],
        "expiry": "87600h"
      }
    }
  }
}
EOF
cat > ca-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "k8s",
      "OU": "System"
    }
  ],
    "ca": {
       "expiry": "87600h"
    }
}
EOF
cfssl gencert -initca ca-csr.json | cfssljson -bare ca

### 创建Kubernetes证书
cat > kubernetes-csr.json <<EOF
{
    "CN": "kubernetes",
    "hosts": [
      "127.0.0.1",
      "10.254.0.1",
      "kubernetes",
      "kubernetes.default",
      "kubernetes.default.svc",
      "kubernetes.default.svc.cluster",
      "kubernetes.default.svc.cluster.local"
    ],
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "ST": "BeiJing",
            "L": "BeiJing",
            "O": "k8s",
            "OU": "System"
        }
    ]
}
EOF
## 将集群配置的服务器IP添加到kubernetes-csr.json中
for node in "${ALL_SERVER_IPS[@]}"
do
sed -i "/\"127\.0\.0\.1\"\,/a \"${node}\"\," kubernetes-csr.json
done
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kubernetes-csr.json | cfssljson -bare kubernetes

### 创建admin证书
cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "system:masters",
      "OU": "System"
    }
  ]
}
EOF
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes admin-csr.json | cfssljson -bare admin

### 创建kube-proxy证书
cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "k8s",
      "OU": "System"
    }
  ]
}
EOF
cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ca-config.json -profile=kubernetes kube-proxy-csr.json | cfssljson -bare kube-proxy

## 分发证书
mkdir -p /etc/kubernetes/ssl
cp -rf ./*.pem /etc/kubernetes/ssl/
for node in "${ALL_SERVER_IPS[@]}"
do
  ssh "${USER}@${node}" "mkdir -p /etc/kubernetes/ssl"
  scp -r ./*.pem "${USER}@${node}:/etc/kubernetes/ssl/"
done

## 创建TLS Bootstrapping Token
cd .. || return
tar -C ../bins -zxvf ../bins/kubernetes-server-linux-amd64.tar.gz
chmod +x ../bins/kubernetes/server/bin/kubectl
cp -f ../bins/kubernetes/server/bin/kubectl /usr/local/bin/kubectl

### 创建kubectl kubeconfig文件
export KUBE_APISERVER="https://${MASTER_IP}:6443"
# 设置集群参数
cd /etc/kubernetes || return
kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server="${KUBE_APISERVER}"
# 设置客户端认证参数
kubectl config set-credentials admin \
  --client-certificate=/etc/kubernetes/ssl/admin.pem \
  --embed-certs=true \
  --client-key=/etc/kubernetes/ssl/admin-key.pem
# 设置上下文参数
kubectl config set-context kubernetes \
  --cluster=kubernetes \
  --user=admin
# 设置默认上下文
kubectl config use-context kubernetes

BOOTSTRAP_TOKEN=$(head -c 16 /dev/urandom | od -An -t x | tr -d ' ')
export BOOTSTRAP_TOKEN
cat > token.csv <<EOF
${BOOTSTRAP_TOKEN},kubelet-bootstrap,10001,"system:kubelet-bootstrap"
EOF

export KUBE_APISERVER="https://${MASTER_IP}:6443"

### 创建kubelet bootstrapping kubeconfig
# 设置集群参数
cd /etc/kubernetes || return
kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server="${KUBE_APISERVER}" \
  --kubeconfig=bootstrap.kubeconfig
# 设置客户端认证参数
kubectl config set-credentials kubelet-bootstrap \
  --token="${BOOTSTRAP_TOKEN}" \
  --kubeconfig=bootstrap.kubeconfig
# 设置上下文参数
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kubelet-bootstrap \
  --kubeconfig=bootstrap.kubeconfig
# 设置默认上下文
kubectl config use-context default --kubeconfig=bootstrap.kubeconfig

export KUBE_APISERVER="https://${MASTER_IP}:6443"

### 创建kube-proxy kubeconfig文件
# 设置集群参数
cd /etc/kubernetes || return
kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server="${KUBE_APISERVER}" \
  --kubeconfig=kube-proxy.kubeconfig
# 设置客户端认证参数
kubectl config set-credentials kubelet-proxy \
  --client-certificate=/etc/kubernetes/ssl/kube-proxy.pem \
  --client-key=/etc/kubernetes/ssl/kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig
# 设置上下文参数
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig
# 设置默认上下文
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

### 分发文件
for node in "${ALL_SERVER_IPS[@]}"
do
  scp token.csv bootstrap.kubeconfig kube-proxy.kubeconfig "${USER}@${node}:/etc/kubernetes/"
done

#-------------------------------------------------------------#
#                                                             #
#                           安装 ETCD                          #
#                                                             #
#-------------------------------------------------------------#

cd "${BASE_PATH}" || return

export ETCD_IPS=("${ALL_SERVER_IPS[@]:0:3}")
export ETCD_ENDPOINTS="https://${ALL_SERVER_IPS[0]}:2379,https://${ALL_SERVER_IPS[1]}:2379,https://${ALL_SERVER_IPS[2]}:2379"
export ETCD_NODES="etcd-node0=https://${ALL_SERVER_IPS[0]}:2380,etcd-node1=https://${ALL_SERVER_IPS[1]}:2380,etcd-node2=https://${ALL_SERVER_IPS[2]}:2380"

tar -C ../bins -zxvf ../bins/etcd-v3.3.13-linux-amd64.tar.gz
chmod +x ../bins/etcd-v3.3.13-linux-amd64/etcd*
chmod 644 ../systemd/etcd.service

## 同步时间
for node in "${ETCD_IPS[@]}"
do
  ssh "${USER}@${node}" "rm -f /etc/localtime && ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime"
done


## 根据机器总数，依次生成etcd的配置文件
## 并将配置文件发送到相应服务器，安装etcd
for i in "${!ETCD_IPS[@]}"
do
scp ../bins/etcd-v3.3.13-linux-amd64/etcd* "${USER}@${ETCD_IPS[$i]}:/usr/local/bin"
ssh "${USER}@${ETCD_IPS[$i]}" "mkdir -p /etc/etcd && mkdir -p /var/lib/etcd"
order=$((i))
echo "etcd-node${order}"

cat > ../systemd/etcd-node"${order}".conf  << EOF
ETCD_NAME=etcd-node${order}
NODE_IP=${ETCD_IPS[$i]}
ETCD_NODES="${ETCD_NODES}"
EOF

scp ../systemd/etcd-node"${order}".conf "${USER}@${ETCD_IPS[$i]}:/etc/etcd/etcd.conf"
scp ../systemd/etcd.service "${USER}@${ETCD_IPS[$i]}:${SERVICE_UNIT_LOCATION}/etcd.service"
done

sleep 5

printf "starting etcd cluster ··· \n\n"
for node in "${ETCD_IPS[@]}"
do
  ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable etcd && systemctl start etcd &"
done


sleep 10  # 保证etcd集群已经启动

etcdctl \
  --ca-file=/etc/kubernetes/ssl/ca.pem \
  --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
  --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
  cluster-health

printf "etcd cluster started! \n \n"