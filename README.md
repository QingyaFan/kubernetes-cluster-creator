# kubernetes-cluster-creator

The script was totally implemented using bash shell, mainly foucus on the offline installation of the kubernetes cluster. As oppose to other tools, it has some main advantage:

- can work in offline environment;
- can automatically shutdown firewall;
- shutdown swap to ensure kubelet working;
- No dependencies, the script was tested on centos minimal installation and ubuntu minimal installation.

## Conponents

The result cluster contains flowing components:

- ETCD 3.4.0
- Flannel 0.11.0
- Docker 18.09.6
- Kubernetes 1.15.3

And in addition, coredns 1.6.2 will be added soon.

## Usage

1. Config server ips in the `cluster.conf.sh`
2. Run `./cluster.install.sh` on centos cluster or `./cluster.install.sh --system ubuntu` on ubuntu cluster.
