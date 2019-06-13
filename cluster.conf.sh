#!/bin/bash

set -exo pipefail

# 配置集群中Master节点可以无需验证访问各个服务器节点
ssh-keygen
for node in "${ALL_SERVER_IPS[@]}"
do
ssh-copy-id -i ~/.ssh/id_rsa.pub "${node}"
ssh "${USER}@${node}" "systemctl stop firewalld && systemctl disable firewalld"
ssh "${USER}@${node}" "setenforce 0 && sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config"
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