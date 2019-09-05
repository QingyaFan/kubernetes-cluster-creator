# kubernetes-cluster-creator

The script mainly foucus on the offline installation of the kubernetes cluster. As oppose to other tools, it has some main advantage:

- can work in offline environment；
- can automatically shutdown firewall；
- shutdown swap to ensure kubelet working；
- test on centos minimal installation.

## Usage

1. config every server ip in the `cluster.conf.sh`
2. run `bash ./cluster.install.sh`
