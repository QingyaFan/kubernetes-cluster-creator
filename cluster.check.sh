#!/bin/bash

set -exo pipefail

# config master can access node without auth
ssh-keygen
for node in "${ALL_SERVER_IPS[@]}"
do
ssh-copy-id -i ~/.ssh/id_rsa.pub "${node}"
ssh "${USER}@${node}" "systemctl stop firewalld && systemctl disable firewalld"
ssh "${USER}@${node}" "setenforce 0 | true && sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config"
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