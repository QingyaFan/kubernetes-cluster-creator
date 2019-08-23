#!/bin/bash

set -exo pipefail

function stopFirewall () {
  ssh "$1@$2" "systemctl stop firewalld && systemctl disable firewalld && setenforce 0 | true && sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config"
}

function generateCerts () {
  ## generate all certificate, then distribute to all nodes
  ### generate CA
  cd ./ssl && rm -rf ./* || return
  cfssl print-defaults config > config.json
  cfssl print-defaults csr > csr.json
  cfssl gencert -initca ssl/ca-csr.json | cfssljson -bare ca

  for node in "${ALL_SERVER_IPS[@]}"
  do
  sed "/\"127\.0\.0\.1\"\,/a \"${node}\"\," ssl/kubernetes-csr.json > ./kubernetes-csr.json
  done
  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ssl/ca-config.json -profile=kubernetes kubernetes-csr.json | cfssljson -bare kubernetes

  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ssl/ca-config.json -profile=kubernetes ssl/admin-csr.json | cfssljson -bare admin

  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ssl/ca-config.json -profile=kubernetes ssl/kube-proxy-csr.json | cfssljson -bare kube-proxy
}


# config master can access node without auth
ssh-keygen
for node in "${ALL_SERVER_IPS[@]}"
do
ssh-copy-id -i ~/.ssh/id_rsa.pub "${node}"
stopFirewall "${USER}" "$node"
done

# shutdown swap in all node
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

cd "${BASE_PATH}" || return

#----------------------------------------------#
#       generate cluster certificate           #
#----------------------------------------------#

## install CFSSL tools
chmod +x ./bins/cfssl*
cp -rf ./bins/cfssl_linux-amd64 /usr/local/bin/cfssl
cp -rf ./bins/cfssl-certinfo_linux-amd64 /usr/local/bin/cfssl-certinfo
cp -rf ./bins/cfssljson_linux-amd64 /usr/local/bin/cfssljson

generateCerts

## distribute ca
mkdir -p /etc/kubernetes/ssl
cp -rf ./*.pem /etc/kubernetes/ssl/
for node in "${ALL_SERVER_IPS[@]}"
do
  ssh "${USER}@${node}" "mkdir -p /etc/kubernetes/ssl"
  scp -r ./*.pem "${USER}@${node}:/etc/kubernetes/ssl/"
done

## create TLS Bootstrapping Token
cd .. || return
tar -C ./bins -zxvf ./bins/kubernetes-server-linux-amd64.tar.gz
chmod +x ./bins/kubernetes/server/bin/kubectl
cp -f ./bins/kubernetes/server/bin/kubectl /usr/local/bin/kubectl

### create kubectl kubeconfig
export KUBE_APISERVER="https://${MASTER_IP}:6443"

## set cluster params
cd /etc/kubernetes || return
kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server="${KUBE_APISERVER}"
kubectl config set-credentials admin \
  --client-certificate=/etc/kubernetes/ssl/admin.pem \
  --embed-certs=true \
  --client-key=/etc/kubernetes/ssl/admin-key.pem
kubectl config set-context kubernetes \
  --cluster=kubernetes \
  --user=admin
kubectl config use-context kubernetes

BOOTSTRAP_TOKEN=$(head -c 16 /dev/urandom | od -An -t x | tr -d ' ')
export BOOTSTRAP_TOKEN
cat > token.csv <<EOF
${BOOTSTRAP_TOKEN},kubelet-bootstrap,10001,"system:kubelet-bootstrap"
EOF

export KUBE_APISERVER="https://${MASTER_IP}:6443"

## create kubelet bootstrapping kubeconfig
cd /etc/kubernetes || return
kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server="${KUBE_APISERVER}" \
  --kubeconfig=bootstrap.kubeconfig
kubectl config set-credentials kubelet-bootstrap \
  --token="${BOOTSTRAP_TOKEN}" \
  --kubeconfig=bootstrap.kubeconfig
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kubelet-bootstrap \
  --kubeconfig=bootstrap.kubeconfig
kubectl config use-context default --kubeconfig=bootstrap.kubeconfig

export KUBE_APISERVER="https://${MASTER_IP}:6443"

### create kube-proxy kubeconfig
cd /etc/kubernetes || return
kubectl config set-cluster kubernetes \
  --certificate-authority=/etc/kubernetes/ssl/ca.pem \
  --embed-certs=true \
  --server="${KUBE_APISERVER}" \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config set-credentials kubelet-proxy \
  --client-certificate=/etc/kubernetes/ssl/kube-proxy.pem \
  --client-key=/etc/kubernetes/ssl/kube-proxy-key.pem \
  --embed-certs=true \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config set-context default \
  --cluster=kubernetes \
  --user=kube-proxy \
  --kubeconfig=kube-proxy.kubeconfig
kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig

### distribute files
for node in "${ALL_SERVER_IPS[@]}"
do
  scp token.csv bootstrap.kubeconfig kube-proxy.kubeconfig "${USER}@${node}:/etc/kubernetes/"
done

#-----------------------------------------------------------#
#                install etcd cluster                       #
#-----------------------------------------------------------#

cd "${BASE_PATH}" || return

export ETCD_IPS=("${ALL_SERVER_IPS[@]:0:3}")
export ETCD_ENDPOINTS="https://${ALL_SERVER_IPS[0]}:2379,https://${ALL_SERVER_IPS[1]}:2379,https://${ALL_SERVER_IPS[2]}:2379"
export ETCD_NODES="etcd-node0=https://${ALL_SERVER_IPS[0]}:2380,etcd-node1=https://${ALL_SERVER_IPS[1]}:2380,etcd-node2=https://${ALL_SERVER_IPS[2]}:2380"

tar -C ./bins -zxvf ./bins/etcd-v3.3.13-linux-amd64.tar.gz
chmod +x ./bins/etcd-v3.3.13-linux-amd64/etcd*
chmod 644 ./systemd/etcd.service

## 集群服务器若时间不同步，会导致etcd启动不正常，因此需要同步时间
## 安装环境可能离线，在线的时间服务器不可用，因此时间以 master 节点为准
yum install -y ./bins/ntpserver/* || true
sed -i '/centos.pool.ntp.org/d' /etc/ntp.conf
sed -i '/Please consider joining the pool/a server 127.127.1.0 iburst' /etc/ntp.conf
systemctl restart ntpd
for node in "${ETCD_IPS[@]}"
do
  scp -r ./bins/ntpserver "${USER}@${node}:~/"
  ssh "${USER}@${node}" "yum install -y ~/ntpserver/* || true"
  ssh "${USER}@${node}" "ntpdate ${MASTER_IP} || true"
done

## 根据机器总数，依次生成etcd的配置文件
## 并将配置文件发送到相应服务器，安装etcd
for i in "${!ETCD_IPS[@]}"
do
scp ./bins/etcd-v3.3.13-linux-amd64/etcd* "${USER}@${ETCD_IPS[$i]}:/usr/local/bin"
ssh "${USER}@${ETCD_IPS[$i]}" "mkdir -p /etc/etcd && mkdir -p /var/lib/etcd"
order=$((i))
echo "etcd-node${order}"

cat > ./systemd/etcd-node"${order}".conf  << EOF
ETCD_NAME=etcd-node${order}
NODE_IP=${ETCD_IPS[$i]}
ETCD_NODES="${ETCD_NODES}"
EOF

scp ./systemd/etcd-node"${order}".conf "${USER}@${ETCD_IPS[$i]}:/etc/etcd/etcd.conf"
scp ./systemd/etcd.service "${USER}@${ETCD_IPS[$i]}:${SERVICE_UNIT_LOCATION}/etcd.service"
done

sleep 5

printf "starting etcd cluster ··· \n\n"
for node in "${ETCD_IPS[@]}"
do
  ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable etcd && systemctl start etcd || true"
done

# ensure etcd cluster started
sleep 10

etcdctl \
  --ca-file=/etc/kubernetes/ssl/ca.pem \
  --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
  --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
  cluster-health

printf "etcd cluster started! \n \n"



#-------------------------------------------------------------#
#                                                             #
#                       install FLANNEL                       #
#                                                             #
#-------------------------------------------------------------#

printf "\n starting install flannel ... \n \n "
cd "${BASE_PATH}" || return

tar -zxvf ./bins/flannel-v0.11.0-linux-amd64.tar.gz
chmod +x flanneld
chmod +x mk-docker-opts.sh
cat > flanneld.conf <<EOF
FLANNEL_ETCD_ENDPOINTS="${ETCD_ENDPOINTS}"
FLANNEL_ETCD_PREFIX="/kube-centos/network"
FLANNEL_OPTIONS="-etcd-cafile=/etc/kubernetes/ssl/ca.pem -etcd-certfile=/etc/kubernetes/ssl/kubernetes.pem -etcd-keyfile=/etc/kubernetes/ssl/kubernetes-key.pem --iface-regex=eth*|enp*"
EOF

# register flannel subnet to etcd
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
  scp flanneld "${USER}@${node}:/usr/local/bin"
  scp mk-docker-opts.sh "${USER}@${node}:/usr/local/bin"
  scp ./systemd/flanneld.service "${USER}@${node}:${SERVICE_UNIT_LOCATION}"
  scp ./flanneld.conf "${USER}@${node}:/etc/sysconfig/flanneld.conf"
  ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable flanneld && systemctl start flanneld"
done

# ensure flanneld cluster started
sleep 10

# output flanneld subnet
etcdctl --endpoints="${ETCD_ENDPOINTS}" \
  --ca-file=/etc/kubernetes/ssl/ca.pem \
  --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
  --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
  ls /kube-centos/network/subnets



#-------------------------------------------------------------#
#                                                             #
#                       install DOCKER                        #
#                                                             #
#-------------------------------------------------------------#

cd "${BASE_PATH}" || return
tar zxvf ./bins/docker-18.09.6.tgz
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


#-------------------------------------------------------------#
#                                                             #
#                  install K8S components                     #
#                                                             #
#-------------------------------------------------------------#

cd "${BASE_PATH}" || return
cp -rf ./bins/kubernetes/server/bin/* /usr/local/bin/

cat > ./systemd/kube-config.conf <<EOF
KUBE_LOGTOSTDERR="--logtostderr=true"
KUBE_LOG_LEVEL="--v=0"
KUBE_ALLOW_PRIV="--allow-privileged=true"
KUBE_MASTER="--master=http://${MASTER_IP}:8080"
EOF
cp -f ./systemd/kube-config.conf /etc/kubernetes/

## install k8s components in the master
### kube-apiserver
cp -f ./systemd/kube-apiserver.service /usr/lib/systemd/system/
cat > ./systemd/kube-apiserver.conf <<EOF
KUBE_API_ADDRESS="--advertise-address=${MASTER_IP} --bind-address=${MASTER_IP} --insecure-bind-address=${MASTER_IP}"
KUBE_ETCD_SERVERS="--etcd-servers=${ETCD_ENDPOINTS}"
KUBE_SERVICE_ADDRESSES="--service-cluster-ip-range=10.254.0.0/16"
KUBE_ADMISSION_CONTROL="--admission-control=ServiceAccount,NamespaceLifecycle,LimitRanger,ResourceQuota"
KUBE_API_ARGS="--authorization-mode=RBAC --runtime-config=rbac.authorization.k8s.io/v1beta1 --kubelet-https=true --enable-bootstrap-token-auth --token-auth-file=/etc/kubernetes/token.csv --service-node-port-range=30000-32767 --tls-cert-file=/etc/kubernetes/ssl/kubernetes.pem --tls-private-key-file=/etc/kubernetes/ssl/kubernetes-key.pem --client-ca-file=/etc/kubernetes/ssl/ca.pem --service-account-key-file=/etc/kubernetes/ssl/ca-key.pem --etcd-cafile=/etc/kubernetes/ssl/ca.pem --etcd-certfile=/etc/kubernetes/ssl/kubernetes.pem --etcd-keyfile=/etc/kubernetes/ssl/kubernetes-key.pem --enable-swagger-ui=true --apiserver-count=3 --audit-log-maxage=30 --audit-log-maxbackup=3 --audit-log-maxsize=100 --audit-log-path=/var/lib/audit.log --event-ttl=1h"
EOF
cp -f ./systemd/kube-apiserver.conf /etc/kubernetes/
systemctl daemon-reload && systemctl enable kube-apiserver && systemctl start kube-apiserver && systemctl status kube-apiserver

### kube-controller-manager
cp -f ./systemd/kube-controller-manager.service /usr/lib/systemd/system/
cp -f ./systemd/kube-controller-manager.conf /etc/kubernetes/
systemctl daemon-reload && systemctl enable kube-controller-manager && systemctl start kube-controller-manager && systemctl status kube-controller-manager

### kube-scheduler
cp -f ./systemd/kube-scheduler.service /usr/lib/systemd/system/
cp -f ./systemd/kube-scheduler.conf /etc/kubernetes/
systemctl daemon-reload && systemctl enable kube-scheduler && systemctl start kube-scheduler && systemctl status kube-scheduler

## confirm master is healthy
kubectl get componentstatuses

### give kubelet-bootstrap user system:node-bootstrapper cluster role
### so kubelet can create certificate signing requests
cd /etc/kubernetes || return 
kubectl delete clusterrolebinding kubelet-bootstrap || true
kubectl create clusterrolebinding kubelet-bootstrap \
  --clusterrole=system:node-bootstrapper \
  --user=kubelet-bootstrap


## install k8s components in every node
###### kubelet and kube-proxy ######
cd "${BASE_PATH}" || return
for node in "${NODE_IPS[@]}"
do

### copy ~/.kube/config in the master to /etc/kubernetes/kubelet.kubeconfig
### in the node, so node can join in the cluster without master approvment
scp ~/.kube/config "${USER}@${node}:/etc/kubernetes/kubelet.kubeconfig"

scp ./bins/kubernetes/server/bin/kubelet "${USER}@${node}:/usr/local/bin/"
scp ./bins/kubernetes/server/bin/kube-proxy "${USER}@${node}:/usr/local/bin/"

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
ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable kubelet && systemctl start kubelet"

#### install kube-proxy
cat > ./kube-proxy.conf  << EOF
KUBE_PROXY_ARGS="--bind-address=${node} --hostname-override=${node} --kubeconfig=/etc/kubernetes/kube-proxy.kubeconfig --cluster-cidr=10.254.0.0/16"
EOF
scp ./kube-proxy.conf "${USER}@${node}:/etc/kubernetes/"
scp systemd/kube-proxy.service "${USER}@${node}:/usr/lib/systemd/system/"
ssh "${USER}@${node}" "systemctl daemon-reload && systemctl enable kube-proxy && systemctl start kube-proxy"
done
