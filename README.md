# kubernetes-cluster-creator

该安装脚本针对纯离线环境安装kubernetes集群的情景，有如下优点：

- 纯离线环境部署kubernetes；
- 自动关闭防火墙；
- 自动关闭node节点swap，保证kubelet可用；
- 使用centos7最小化安装通过测试，因此无需担心centos不同安装版造成的差异。

## 使用方法

1. 根据服务器的角色分配，配置`cluster.conf.sh`中的IP；
2. 运行install.sh，`bash ./install.sh`。
