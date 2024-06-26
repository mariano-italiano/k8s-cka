#!/bin/bash

# Retrieve K8s version to install

if [[ $* == *-v* ]]
then
        while getopts v: flag
        do
                case "${flag}" in
                        v) k8sVersion=${OPTARG};;
                esac
        done
else
        echo "Usage:  ./deployK8s.sh -v <k8s-version> -p <proxyHost:proxyPort> <master-IP>"
        echo
        echo "Examples: ./deployK8s.sh -v 1.28.9-2.1 -p http://172.22.60.38:3128 172.22.48.200"
        exit 0
fi

echo "[TASK 1] Create module configuration file for containerd"
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

# load modules
modprobe overlay >/dev/null 2>&1
modprobe br_netfilter >/dev/null 2>&1

echo "[TASK 2] Set system configurations for Kubernetes networking"
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# apply new settings
sysctl --system >/dev/null 2>&1

echo "[TASK 3] Install containerd runtime"
apt-get update >/dev/null 2>&1
apt-get install -y containerd >/dev/null 2>&1

echo "[TASK 4] Generate default containerd configuration and save to the newly created default file"
mkdir -p /etc/containerd >/dev/null 2>&1
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null 2>&1

echo "[TASK 5] Update containerd option for System Cgroup"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml >/dev/null 2>&1

# apply new settings
systemctl restart containerd >/dev/null 2>&1

echo "[TASK 6] Disable SWAP"
swapoff -a >/dev/null 2>&1
sed -i 's/.* none.* swap.* sw.*/#&/g' /etc/fstab >/dev/null 2>&1

echo "[TASK 7] Install depencdency packages"
apt-get update >/dev/null 2>&1
apt-get install -y apt-transport-https curl >/dev/null 2>&1

echo "[TASK 8] Add GPG key for K8s repo"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
 >/dev/null 2>&1

echo "[TASK 9] Add K8s repository"
if [[ $# -gt 3 ]]; then
        curl -x $4 -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg >/dev/null 2>&1
else
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg >/dev/null 2>&1
fi

# refresh repo
apt-get update >/dev/null 2>&1

echo "[TASK 10] Install K8s in $k8sVersion version"
apt-get install -y kubelet=$k8sVersion kubeadm=$k8sVersion kubectl=$k8sVersion >/dev/null 2>&1

echo "[TASK 11] Turn off automatic updates"
apt-mark hold kubelet kubeadm kubectl >/dev/null 2>&1


if [[ $(hostname) =~ .*master.* ]]
then
        if [[ $# -gt 3 ]]; then
                echo "HTTP_PROXY=$4" >> /etc/environment
                echo "HTTPS_PROXY=$4" >> /etc/environment
                echo "http_proxy=$4" >> /etc/environment
                echo "https_proxy=$4" >> /etc/environment
                echo "NO_PROXY=10.96.0.0/12,192.168.0.0/16,$5" >> /etc/environment
                sed -i '/\[Service\]/aEnvironment="HTTP_PROXY='"$4"'"' /lib/systemd/system/containerd.service
                sed -i '/\[Service\]/aEnvironment="HTTPS_PROXY='"$4"'"' /lib/systemd/system/containerd.service
                sed -i '/\[Service\]/aEnvironment="NO_PROXY="10.96.0.0/12,192.168.0.0/16,'"$5"'"' /lib/systemd/system/containerd.service
                systemctl daemon-reload
                systemctl restart containerd.service
        fi

        echo "[TASK 12] Initialize the cluster"
        kubeadm init --pod-network-cidr 192.168.0.0/16 >/dev/null 2>&1
        sleep 10

        echo "[TASK 13] Set kubectl access"
        mkdir -p /home/student/.kube >/dev/null 2>&1
        cp -i /etc/kubernetes/admin.conf /home/student/.kube/config >/dev/null 2>&1
        chown -R student:student /home/student/.kube >/dev/null 2>&1
        #mkdir -p $HOME/.kube
        #sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        #sudo chown $(id -u):$(id -g) $HOME/.kube/config

        #################### CILIUM ###################
        if [[ $# -gt 3 ]]; then
                CILIUM_CLI_VERSION=$(curl -x $4 -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
        else
                CILIUM_CLI_VERSION=$(curl  -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
        fi
        CLI_ARCH=amd64
        if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
        if [[ $# -gt 3 ]]; then
                curl -x $4 -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        else
                curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        fi
        sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
        sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
        rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
        
        https_proxy=$4 cilium install --version 1.15.4

        #################### ANTREA ###################
        #echo "[TASK 14] Install Antrea Network Plugin"
        #if [[ $# -gt 3 ]]; then
        #       curl -x $4 -fsSL https://github.com/antrea-io/antrea/releases/download/v1.15.1/antrea.yml | sudo tee antrea.yml
        #else
        #       curl -fsSL https://github.com/antrea-io/antrea/releases/download/v1.15.1/antrea.yml | sudo tee antrea.yml
        #fi
        #kubectl apply -f antrea.yml

        #################### CALICO ###################
        #echo "[TASK 14] Install Calico networking"
        #su -c 'kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml' student >/dev/null 2>&1
        #sed -i 's/# - name: CALICO_IPV4POOL_CIDR/- name: CALICO_IPV4POOL_CIDR/g' calico.yaml >/dev/null 2>&1
        #sed -i 's|#   value: "192.168.0.0/16"|  value: "192.168.0.0/16"|g' calico.yaml >/dev/null 2>&1
        #kubectl apply -f calico.yaml >/dev/null 2>&1

fi

if [[ $(hostname) =~ .*worker.* ]]
then
        if [[ $# -gt 3 ]]; then
                echo "HTTP_PROXY=$4" >> /etc/environment
                echo "HTTPS_PROXY=$4" >> /etc/environment
                echo "http_proxy=$4" >> /etc/environment
                echo "https_proxy=$4" >> /etc/environment
                echo "NO_PROXY=10.96.0.0/12,192.168.0.0/16,$5" >> /etc/environment
                sed -i '/\[Service\]/aEnvironment="HTTP_PROXY='"$4"'"' /lib/systemd/system/containerd.service
                sed -i '/\[Service\]/aEnvironment="HTTPS_PROXY='"$4"'"' /lib/systemd/system/containerd.service
                sed -i '/\[Service\]/aEnvironment="NO_PROXY="10.96.0.0/12,192.168.0.0/16,'"$5"'"' /lib/systemd/system/containerd.service
                systemctl daemon-reload
                systemctl restart containerd.service
        fi
        echo "[TASK 12] Join node to Kubernetes cluster"
        echo ""
        echo "Please execute following command to get join command and then execute it manually on all worker nodes"
        echo "-----------------------------------------------"
        echo "kubeadm token create --print-join-command"
        echo "-----------------------------------------------"
        echo ""
fi
