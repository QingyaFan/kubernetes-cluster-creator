#!/bin/bash

set -exo pipefail

BASE_PATH="$(pwd)"
USER=root
ETCD_IPS=("${ALL_SERVER_IPS[@]:0:3}")
ETCD_ENDPOINTS="https://${ALL_SERVER_IPS[0]}:2379,https://${ALL_SERVER_IPS[1]}:2379,https://${ALL_SERVER_IPS[2]}:2379"
ETCD_NODES="etcd-node0=https://${ALL_SERVER_IPS[0]}:2380,etcd-node1=https://${ALL_SERVER_IPS[1]}:2380,etcd-node2=https://${ALL_SERVER_IPS[2]}:2380"

# shellcheck disable=SC1091
. ./cluster.conf.sh

# create a temp directory, put temp file in this, 
# so we can clear it after the installation is over
rm -rf tmp && mkdir tmp

# stopFirewall shutdown the firewall
function stopFirewall {
  ssh "$1@$2" "systemctl stop firewalld && systemctl disable firewalld && setenforce 0 | true && sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config"
}

# shutdownSWAP shot down swap
function shutdownSWAP {
  local nodeIP=$1
  scp ./utils/shutdown_swap.sh "${USER}@${nodeIP}:~/"
  ssh "${USER}@${nodeIP}" "bash ~/shutdown_swap.sh"
}

# installSSLTools install ssl tools
function installSSLTools {
  chmod +x ./bins/cfssl*
  cp -rf ./bins/cfssl_linux-amd64 /usr/local/bin/cfssl
  cp -rf ./bins/cfssl-certinfo_linux-amd64 /usr/local/bin/cfssl-certinfo
  cp -rf ./bins/cfssljson_linux-amd64 /usr/local/bin/cfssljson
}

# generateCerts generate the certs
function generateCerts {
  cfssl print-defaults config > ./config.json
  cfssl print-defaults csr > ./csr.json
  cfssl gencert -initca ./ssl/ca-csr.json | cfssljson -bare ca

  cp ./ssl/kubernetes-csr.json ./tmp/kubernetes-csr.json
  for node in "${ALL_SERVER_IPS[@]}"; do
    sed -i "/\"127\.0\.0\.1\"\,/a \"${node}\"\," ./tmp/kubernetes-csr.json
  done

  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ssl/ca-config.json -profile=kubernetes ./tmp/kubernetes-csr.json | cfssljson -bare kubernetes
  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ssl/ca-config.json -profile=kubernetes ./ssl/admin-csr.json | cfssljson -bare admin
  cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=ssl/ca-config.json -profile=kubernetes ./ssl/kube-proxy-csr.json | cfssljson -bare kube-proxy
}

# makeClusterTimeSync make the cluster time sync
function makeClusterTimeSync {
  yum install -y ./bins/ntpserver/centos/* || true
  sed -i '/centos.pool.ntp.org/d' /etc/ntp.conf
  sed -i '/Please consider joining the pool/a server 127.127.1.0 iburst' /etc/ntp.conf
  systemctl restart ntpd
  for node in "${ETCD_IPS[@]}"
  do
    scp -r ./bins/ntpserver/centos "${USER}@${node}:~/"
    ssh "${USER}@${node}" "yum install -y ~/centos/* || true"
    ssh "${USER}@${node}" "ntpdate ${MASTER_IP} || true"
  done
}

# makeClusterTimeSyncUbuntu makethe cluster time sync
# on ubuntu system
function makeClusterTimeSyncUbuntu {
  apt install -y ./bins/ntpserver/ubuntu/* || true
  sed -i '/centos.pool.ntp.org/d' /etc/ntp.conf
  sed -i '/Please consider joining the pool/a server 127.127.1.0 iburst' /etc/ntp.conf
  systemctl restart ntpd
  for node in "${ETCD_IPS[@]}"
  do
    scp -r ./bins/ntpserver/ubuntu "${USER}@${node}:~/"
    ssh "${USER}@${node}" "yum install -y ~/ubuntu/* || true"
    ssh "${USER}@${node}" "ntpdate ${MASTER_IP} || true"
  done
}

# installETCD install a etcd instance on an node
function installETCD {
  local nodeIP=$1
  scp ./tmp/etcd-v3.3.13-linux-amd64/etcd* "${USER}@${nodeIP}:/usr/local/bin"
  ssh "${USER}@${nodeIP}" "mkdir -p /etc/etcd && mkdir -p /var/lib/etcd"
  order=$((i))
  scp ./tmp/etcd-node"${order}".conf "${USER}@${nodeIP}:/etc/etcd/etcd.conf"
  scp ./systemd/etcd.service "${USER}@${nodeIP}:${SERVICE_UNIT_LOCATION}/"
  ssh "${USER}@${nodeIP}" "systemctl daemon-reload && systemctl enable etcd && systemctl start etcd || true"
}

# installFlannel install a flannel instance on an node
# to ensure container ip does not conflict
function installFlannel {
  local nodeIP=$1
  scp tmp/flanneld "${USER}@${nodeIP}:/usr/local/bin"
  scp tmp/mk-docker-opts.sh "${USER}@${nodeIP}:/usr/local/bin"
  scp ./systemd/flanneld.service "${USER}@${nodeIP}:${SERVICE_UNIT_LOCATION}"
  scp ./tmp/flanneld.conf "${USER}@${nodeIP}:/etc/sysconfig/flanneld.conf"
  ssh "${USER}@${nodeIP}" "systemctl daemon-reload && systemctl enable flanneld && systemctl start flanneld"
}

# installDocker install docker instance on a specified machine
function installDocker {
  local nodeIP=$1
  ssh "${USER}@${nodeIP}" "mkdir -p /etc/docker/"
  scp ./tmp/daemon.json "${USER}@${nodeIP}:/etc/docker/"
  scp ./tmp/docker/* "${USER}@${nodeIP}:/usr/local/bin/"
  scp ./systemd/docker.service "${USER}@${nodeIP}:${SERVICE_UNIT_LOCATION}/"
  ssh "${USER}@${nodeIP}" "systemctl daemon-reload && systemctl enable docker.service && systemctl start docker.service"
}

# installKubernetesMaster install k8s components in master 
function installKubernetesMaster {
  cp -rf ./tmp/kubernetes/server/bin/* /usr/local/bin/
  sed "s@MASTER_IP@${MASTER_IP}@" ./systemd/kube-config.conf > ./tmp/kube-config.conf
  cp -f ./tmp/kube-config.conf /etc/kubernetes/

  ## kube-apiserver
  sed "s@MASTER_IP@${MASTER_IP}@g ; s@ETCD_ENDPOINTS@${ETCD_ENDPOINTS}@" ./systemd/kube-apiserver.conf > ./tmp/kube-apiserver.conf
  cp -f ./systemd/kube-apiserver.service "${SERVICE_UNIT_LOCATION}/"
  cp -f ./tmp/kube-apiserver.conf /etc/kubernetes/
  systemctl daemon-reload && systemctl enable kube-apiserver && systemctl start kube-apiserver && systemctl status kube-apiserver

  ## kube-controller-manager
  cp -f ./systemd/kube-controller-manager.service "${SERVICE_UNIT_LOCATION}/"
  cp -f ./systemd/kube-controller-manager.conf /etc/kubernetes/
  systemctl daemon-reload && systemctl enable kube-controller-manager && systemctl start kube-controller-manager && systemctl status kube-controller-manager

  ## kube-scheduler
  cp -f ./systemd/kube-scheduler.service "${SERVICE_UNIT_LOCATION}/"
  cp -f ./systemd/kube-scheduler.conf /etc/kubernetes/
  systemctl daemon-reload && systemctl enable kube-scheduler && systemctl start kube-scheduler && systemctl status kube-scheduler
}

# installKubernetsNode install k8s components in node
function installKubernetsNode {
  local nodeIP=$1
  ## copy ~/.kube/config in the master to /etc/kubernetes/kubelet.kubeconfig
  ## in the node, so node can join in the cluster without master approvment
  scp ~/.kube/config "${USER}@${nodeIP}:/etc/kubernetes/kubelet.kubeconfig"
  scp ./tmp/kubernetes/server/bin/kubelet "${USER}@${nodeIP}:/usr/local/bin/"
  scp ./tmp/kubernetes/server/bin/kube-proxy "${USER}@${nodeIP}:/usr/local/bin/"

  ## install kubelet
  sed "s@NODE_IP@${nodeIP}@g" ./systemd/kubelet.conf > ./tmp/kubelet.conf
  scp ./tmp/kube-config.conf "${USER}@${nodeIP}:/etc/kubernetes/"
  scp ./tmp/kubelet.conf "${USER}@${nodeIP}:/etc/kubernetes/"
  scp ./systemd/kubelet.service "${USER}@${nodeIP}:${SERVICE_UNIT_LOCATION}/"
  ## install kube-proxy
  sed "s@NODE_IP@${nodeIP}@g" ./systemd/kube-proxy.conf > ./tmp/kube-proxy.conf
  scp ./tmp/kube-proxy.conf "${USER}@${nodeIP}:/etc/kubernetes/"
  scp ./systemd/kube-proxy.service "${USER}@${nodeIP}:${SERVICE_UNIT_LOCATION}/"

  ssh "${USER}@${nodeIP}" "mkdir -p /var/lib/kubelet && systemctl daemon-reload && systemctl enable kubelet && systemctl enable kube-proxy && systemctl start kubelet && systemctl start kube-proxy"
}

function main {
  # config master can access node without auth
  # and stop firewall
  # and shutdown swap in all node
  ssh-keygen
  chmod +x ./utils/shutdown_swap.sh
  for node in "${ALL_SERVER_IPS[@]}"; do
    ssh-copy-id -i ~/.ssh/id_rsa.pub "${node}"
    stopFirewall "${USER}" "$node"
    shutdownSWAP "$node"
  done


  # install ssl tools and generate certs
  installSSLTools
  generateCerts


  # distribute ca
  mkdir -p /etc/kubernetes/ssl
  cp -rf ./*.pem /etc/kubernetes/ssl/
  for node in "${ALL_SERVER_IPS[@]}"; do
    ssh "${USER}@${node}" "mkdir -p /etc/kubernetes/ssl"
    scp -r ./*.pem "${USER}@${node}:/etc/kubernetes/ssl/"
  done

  ## create TLS Bootstrapping Token
  tar -C ./tmp -zxvf ./bins/kubernetes-server-linux-amd64.tar.gz
  chmod +x ./tmp/kubernetes/server/bin/kubectl
  cp -f ./tmp/kubernetes/server/bin/kubectl /usr/local/bin/kubectl

  ## set cluster params
  KUBE_APISERVER="https://${MASTER_IP}:6443"
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
  sed "s/BOOTSTRAP_TOKEN/${BOOTSTRAP_TOKEN}/" ./ssl/token.csv > ./tmp/token.csv

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
  for node in "${ALL_SERVER_IPS[@]}"; do
    scp ./tmp/token.csv bootstrap.kubeconfig kube-proxy.kubeconfig "${USER}@${node}:/etc/kubernetes/"
  done

  # install etcd cluster
  cd "${BASE_PATH}" || return

  # etcd cluster need cluster time sync
  # so we make an ntp server on the master node 
  # and node sync time according to master
  if [[ $HOST_SYSTEM == "centos" ]]; then
    makeClusterTimeSync
  elif [[ $HOST_SYSTEM == "ubuntu" ]]; then 
    makeClusterTimeSyncUbuntu
  fi
  

  # generate etcd env file
  for i in "${!ETCD_IPS[@]}"; do
    order=$((i))
    sed "s/ETCD_NAME_VAL/${order}/; s/NODE_IP_VAL/${ETCD_IPS[$i]}/; s/ETCD_NODES_VAL/${ETCD_NODES}/" ./systemd/etcd.conf > ./tmp/etcd-node"${order}".conf
  done

  tar -C ./tmp -zxvf ./bins/etcd-v3.3.13-linux-amd64.tar.gz
  chmod +x ./tmp/etcd-v3.3.13-linux-amd64/etcd*
  chmod 644 ./systemd/etcd.service
  for i in "${!ETCD_IPS[@]}"; do
    installETCD "${ETCD_IPS[$i]}"
  done

  sleep 10
  etcdctl \
    --ca-file=/etc/kubernetes/ssl/ca.pem \
    --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
    --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
    cluster-health

  printf "etcd cluster started! \n \n"

  # install FLANNEL
  tar -C tmp -zxvf ./bins/flannel-v0.11.0-linux-amd64.tar.gz
  chmod u+x tmp/flanneld
  chmod u+x tmp/mk-docker-opts.sh
  sed "s@ETCD_ENDPOINTS_VAL@${ETCD_ENDPOINTS}@" ./systemd/flannel.conf > ./tmp/flannel.conf


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

  for node in "${NODE_IPS[@]}"; do
    installFlannel "$node"
  done

  # ensure flanneld cluster started
  sleep 5

  # output flanneld subnet
  etcdctl --endpoints="${ETCD_ENDPOINTS}" \
    --ca-file=/etc/kubernetes/ssl/ca.pem \
    --cert-file=/etc/kubernetes/ssl/kubernetes.pem \
    --key-file=/etc/kubernetes/ssl/kubernetes-key.pem \
    ls /kube-centos/network/subnets

  # install DOCKER
  cd "${BASE_PATH}" || return
  tar -C ./tmp -zxvf ./bins/docker-18.09.6.tgz
  sed "s/DOCKER_LOCATION/${DOCKER_LOCATION}/" ./systemd/docker-daemon.json > ./tmp/daemon.json

  for node in "${ALL_SERVER_IPS[@]}"; do
    installDocker "$node"
  done


  # install K8S components in master
  installKubernetesMaster
  # give kubelet-bootstrap user system:node-bootstrapper cluster role
  # so kubelet can create certificate signing requests
  kubectl delete clusterrolebinding kubelet-bootstrap || true
  kubectl create clusterrolebinding kubelet-bootstrap \
    --clusterrole=system:node-bootstrapper \
    --user=kubelet-bootstrap || true
  kubectl get componentstatuses


  ## install k8s components in every node
  for node in "${NODE_IPS[@]}"; do
    installKubernetsNode "${node}"
  done
}


# get system params to init some env
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -s|--system) HOST_SYSTEM="$2"
    shift
    shift
    ;;
    *) shift
    ;;
  esac
  
done

## default host system is centos
SERVICE_UNIT_LOCATION="/usr/lib/systemd/system"
if [ "$HOST_SYSTEM" == "ubuntu" ]; then
  SERVICE_UNIT_LOCATION="/lib/systemd/system"
fi

# start main install process
main
