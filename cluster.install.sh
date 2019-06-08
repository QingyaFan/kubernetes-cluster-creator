#!/bin/bash

set -x

cd "${BASE_PATH}" || return

###############################################################
#                                                             #
######                       安装 ETCD                    ######
#                                                             #
###############################################################

tar -zxvf ./bins/etcd-v3.3.8-linux-amd64.tar.gz
chmod +x ./etcd-v3.3.8-linux-amd64/etcd*

## 根据机器总数，依次生成etcd的配置文件
## 并将配置文件发送到相应服务器，安装etcd
for i in "${!ETCD_IPS[@]}"
do

scp ./etcd-v3.3.8-linux-amd64/etcd* "${USER}@${ETCD_IPS[$i]}:/usr/local/bin/"
ssh "${USER}@${ETCD_IPS[$i]}" "mkdir -p /etc/etcd"
order=$((i))
echo "etcd-node${order}"

cat > ./systemd/etcd-node"${order}".conf  << EOF
ETCD_NAME=etcd-node${order}
NODE_IP=${ETCD_IPS[$i]}
ETCD_NODES="${ETCD_NODES}"
EOF

scp ./systemd/etcd-node"${order}".conf "${USER}@${ETCD_IPS[$i]}:/etc/etcd/etcd.conf"
scp ./systemd/etcd.service "${USER}@${ETCD_IPS[$i]}:${SERVICE_UNIT_LOCATION}/etcd.service"
ssh "${USER}@${ETCD_IPS[$i]}" "rm -rf /var/lib/etcd || true && mkdir -p /var/lib/etcd && systemctl daemon-reload && systemctl enable etcd && systemctl start etcd &"

done

etcdctl \
  --ca-file=/etc/kubernetes/ssl/ca.pem \
  --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
  --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
  cluster-health

echo etcd install success



###############################################################
#                                                             #
######                     安装 FLANNEL                   ######
#                                                             #
###############################################################

cd "${BASE_DIR}" || return

tar -zxvf ./bins/flannel-v0.10.0-linux-amd64.tar.gz
chmod +x flanneld
chmod +x mk-docker-opts.sh
cat > flanneld.conf <<EOF
FLANNEL_ETCD_ENDPOINTS="${ETCD_ENDPOINTS}"
FLANNEL_ETCD_PREFIX="/kube-centos/network"
FLANNEL_OPTIONS="-etcd-cafile=/etc/kubernetes/ssl/ca.pem -etcd-certfile=/etc/kubernetes/ssl/kubernetes.pem -etcd-keyfile=/etc/kubernetes/ssl/kubernetes-key.pem"
EOF

# 在etcd中注册docker到子网络
etcdctl --endpoints="${ETCD_ENDPOINTS}" \
  --ca-file=/etc/kubernetes/ssl/ca.pem \
  --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
  --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
  mkdir /kube-centos/network || true
etcdctl --endpoints="${ETCD_ENDPOINTS}" \
  --ca-file=/etc/kubernetes/ssl/ca.pem \
  --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
  --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
  mk /kube-centos/network/config '{"Network":"172.30.0.0/16","SubnetLen":24,"Backend":{"Type":"vxlan"}}' || true

# start flanneld
systemctl daemon-reload && systemctl enable flanneld && systemctl start flanneld && systemctl status flanneld &

for node in "${NODE_IPS[@]}"
do
  scp flanneld "${USER}@${node}:/usr/local/bin/"
  scp mk-docker-opts.sh "${USER}@${node}:/usr/local/bin/"
  scp ./systemd/flanneld.service "${USER}@${node}:${SERVICE_UNIT_LOCATION}"
  scp ./flanneld.conf "${USER}@${node}:/etc/sysconfig/flanneld.conf"
  ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable flanneld && systemctl start flanneld && systemctl status flanneld &"
done

# 检查docker子网络状态
etcdctl --endpoints="${ETCD_ENDPOINTS}" \
  --ca-file=/etc/kubernetes/ssl/ca.pem \
  --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
  --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
  ls /kube-centos/network/subnets



###############################################################
#                                                             #
######                      安装 DOCKER                   ######
#                                                             #
###############################################################

tar zxvf ./bins/docker-17.12.1-ce.tgz
cat > ./daemon.json << EOF
{
  "graph": "${DOCKER_LOCATION}"
}
EOF

for node in "${ALL_SERVER_IPS[@]}"
do
  ssh "${USER}@${node}" "mkdir -p /etc/docker/"
  scp ./daemon.json "${USER}@${node}:/etc/docker/"
  scp docker/* "${USER}@${node}:/usr/local/bin/"
  scp ./systemd/docker.service "${USER}@${node}:${SERVICE_UNIT_LOCATION}/"
  ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable docker.service &&systemctl start docker.service"
done
chmod +x ./bins/docker-compose-Linux-x86_64
scp ./bins/docker-compose-Linux-x86_64 "${USER}@${PG_SERVER}:/usr/local/bin/docker-compose"


###############################################################
#                                                             #
######                   安装 K8S 各个组件                 ######
#                                                             #
###############################################################

cd "${BASE_DIR}" || return

cp -rf kubernetes/server/bin/* /usr/local/bin/

cat > ./systemd/kube-config.conf <<EOF
KUBE_LOGTOSTDERR="--logtostderr=true"
KUBE_LOG_LEVEL="--v=0"
KUBE_ALLOW_PRIV="--allow-privileged=true"
KUBE_MASTER="--master=http://${MASTER_IP}:8080"
EOF
cp -f ./systemd/kube-config.conf /etc/kubernetes/

## 主节点安装k8s组件
### 安装kube-apiserver
cp -f ./systemd/kube-apiserver.service /usr/lib/systemd/system/
cat > ./systemd/kube-apiserver.conf <<EOF
KUBE_API_ADDRESS="--advertise-address=${MASTER_IP} --bind-address=${MASTER_IP} --insecure-bind-address=${MASTER_IP}"
KUBE_ETCD_SERVERS="--etcd-servers=${ETCD_ENDPOINTS}"
KUBE_SERVICE_ADDRESSES="--service-cluster-ip-range=10.254.0.0/16"
KUBE_ADMISSION_CONTROL="--admission-control=ServiceAccount,NamespaceLifecycle,LimitRanger,ResourceQuota"
KUBE_API_ARGS="--authorization-mode=RBAC --runtime-config=rbac.authorization.k8s.io/v1beta1 --kubelet-https=true --enable-bootstrap-token-auth --token-auth-file=/etc/kubernetes/token.csv --service-node-port-range=30000-32767 --tls-cert-file=/etc/kubernetes/ssl/kubernetes.pem --tls-private-key-file=/etc/kubernetes/ssl/kubernetes-key.pem --client-ca-file=/etc/kubernetes/ssl/ca.pem --service-account-key-file=/etc/kubernetes/ssl/ca-key.pem --etcd-cafile=/etc/kubernetes/ssl/ca.pem --etcd-certfile=/etc/kubernetes/ssl/kubernetes.pem --etcd-keyfile=/etc/kubernetes/ssl/kubernetes-key.pem --enable-swagger-ui=true --apiserver-count=3 --audit-log-maxage=30 --audit-log-maxbackup=3 --audit-log-maxsize=100 --audit-log-path=/var/lib/audit.log --event-ttl=1h"
EOF
cp -f ./systemd/kube-apiserver.conf /etc/kubernetes/
systemctl daemon-reload
systemctl enable kube-apiserver
systemctl start kube-apiserver
systemctl status kube-apiserver

### 安装kube-controller-manager
cp -f systemd/kube-controller-manager.service /usr/lib/systemd/system/
cp -f systemd/kube-controller-manager.conf /etc/kubernetes/
systemctl daemon-reload
systemctl enable kube-controller-manager
systemctl start kube-controller-manager
systemctl status kube-controller-manager

## 安装kube-scheduler
cp -f systemd/kube-scheduler.service /usr/lib/systemd/system/
cp -f systemd/kube-scheduler.conf /etc/kubernetes/
systemctl daemon-reload
systemctl enable kube-scheduler
systemctl start kube-scheduler
systemctl status kube-scheduler

## confirm master is healthy
kubectl get componentstatuses

## 建立拉取镜像凭证，在线部署使用
# kubectl create secret docker-registry regsecret --namespace=default --docker-server=registry.cn-beijing.aliyuncs.com --docker-username=admin@geohey.com --docker-password= --docker-email=fanqy@geohey.com || true
# kubectl create secret docker-registry regsecret --namespace=kube-public --docker-server=registry.cn-beijing.aliyuncs.com --docker-username=admin@geohey.com --docker-password= --docker-email=fanqy@geohey.com || true
# kubectl create secret docker-registry regsecret --namespace=kube-system --docker-server=registry.cn-beijing.aliyuncs.com --docker-username=admin@geohey.com --docker-password= --docker-email=fanqy@geohey.com || true

### 将 bootstrap token 文件中的 kubelet-bootstrap 用户赋予 system:node-bootstrapper cluster 角色(role)
### kubelet 才能有权限创建认证请求(certificate signing requests)
cd /etc/kubernetes || return 
kubectl delete clusterrolebinding kubelet-bootstrap || true
kubectl create clusterrolebinding kubelet-bootstrap \
  --clusterrole=system:node-bootstrapper \
  --user=kubelet-bootstrap


## 子节点安装k8s各个组件
###### 部署kubelet和kube-proxy ######
cd "${BASE_DIR}" || return
for node in "${NODE_IPS[@]}"
do

### 将master节点上的~/.kube/config文件（该文件在安装kubectl命令行工具这一步中将会自动生成）
### 拷贝到node节点的/etc/kubernetes/kubelet.kubeconfig位置，这样就不需要通过CSR，
### 当kubelet启动后就会自动加入的集群中
scp ~/.kube/config "${USER}@${node}:/etc/kubernetes/kubelet.kubeconfig"

scp kubernetes/server/bin/kubelet kubernetes/server/bin/kube-proxy "${USER}@${node}:/usr/local/bin/"

#### install kubelet
cat > ./systemd/kubelet.conf  << EOF
KUBELET_ADDRESS="--address=${node}"
KUBELET_HOSTNAME="--hostname-override=${node}"
KUBELET_POD_INFRA_CONTAINER="--pod-infra-container-image=registry.cn-beijing.aliyuncs.com/geohey/pause:latest"
KUBELET_ARGS="--cluster-dns=10.254.0.2 --bootstrap-kubeconfig=/etc/kubernetes/bootstrap.kubeconfig --kubeconfig=/etc/kubernetes/kubelet.kubeconfig --cert-dir=/etc/kubernetes/ssl --cluster-domain=cluster.local --hairpin-mode promiscuous-bridge --serialize-image-pulls=false"
EOF
scp ./systemd/kube-config.conf "${USER}@${node}:/etc/kubernetes/"
scp ./systemd/kubelet.conf "${USER}@${node}:/etc/kubernetes/"
scp systemd/kubelet.service "${USER}@${node}:/usr/lib/systemd/system/"
ssh "${USER}@${node}" "mkdir -p /var/lib/kubelet"
ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable kubelet && systemctl start kubelet &"

#### install kube-proxy
cat > ./kube-proxy.conf  << EOF
KUBE_PROXY_ARGS="--bind-address=${node} --hostname-override=${node} --kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig --cluster-cidr=10.254.0.0/16"
EOF
scp ./kube-proxy.conf "${USER}@${node}:/etc/kubernetes/"
scp systemd/kube-proxy.service "${USER}@${node}:/usr/lib/systemd/system/"
ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable kube-proxy && systemctl start kube-proxy &"
done


## 安装集群基础服务 DNS & INGRESS-CONTROLLER
for node in "${NODE_IPS[@]}"
do
scp -r ./images/common "${USER}@${node}:~/"
ssh "${USER}@${node}" "cd ~/common && ls | xargs -n 1 docker load -i"
done
kubectl apply -f apps/common/rbac-config.yaml
kubectl apply -f apps/common/kube-dns.yaml
kubectl apply -f apps/common/nginx-ingress.yaml

echo "kubernetes cluster installed and actived successfully!"