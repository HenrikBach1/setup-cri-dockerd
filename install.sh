#!/usr/bin/env bash

# Copyright 2022 The KTLS Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

ARCH=$(arch)
if [[ "${ARCH}" =~ "x86_64" ]]; then
    ARCH="amd64"
elif [[ "${ARCH}" =~ "aarch64" ]]; then
    ARCH="arm64"
else
    echo "${ARCH} is not supported"
    exit 1
fi

BIN_NAME="cri-dockerd"
TAR_EXT="tgz"
VERSION=$(curl -s https://api.github.com/repos/Mirantis/${BIN_NAME}/releases/latest | grep tag_name | cut -d '"' -f 4 | sed 's/v//')
BIN_URL="https://github.com/Mirantis/${BIN_NAME}/releases/download/v${VERSION}/${BIN_NAME}-${VERSION}.${ARCH}.${TAR_EXT}"
TAR_NAME="${BIN_NAME}.${TAR_EXT}"

SERVICE_NAME="${BIN_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
TAR_PATH="${TMPDIR:-/tmp}/install-${BIN_NAME}"
BIN_PATH="/usr/local/bin"

FORCE=${FORCE:-n}
CRI_SOCK="unix:///var/run/${BIN_NAME}.sock"
KUBEADM_FLAGS_ENV="/var/lib/kubelet/kubeadm-flags.env"
if [[ ! -v KUBELET_KUBEADM_ARGS ]]; then
    KUBELET_KUBEADM_ARGS=""
fi

function check_container_runtime_of_kubelet() {
    if [[ -f "${KUBEADM_FLAGS_ENV}" ]]; then
        OLD_FLAGS=$(cat "${KUBEADM_FLAGS_ENV}")
        if [[ "${OLD_FLAGS}" =~ "--container-runtime=remote" ]]; then
            echo cat "${KUBEADM_FLAGS_ENV}"
            cat "${KUBEADM_FLAGS_ENV}"
            echo "The container runtime is already set to remote"
            echo "Please check the container runtime of kubelet"
            exit 1
        fi
    fi
}

function install_cri_dockerd() {
    if [[ ! -s "${BIN_PATH}/${BIN_NAME}" \
            && ! -s "${TAR_PATH}/${TAR_NAME}" \
        ]]; then
        echo "Installing ${BIN_NAME}"
        if [[ ! -s "${TAR_PATH}/${TAR_NAME}" ]]; then
            echo "Downloading binary of ${BIN_NAME}"
            mkdir -p "${TAR_PATH}" && wget -O "${TAR_PATH}/${TAR_NAME}" "${BIN_URL}"
        fi
        if [[ "${TAR_EXT}" == "tar.gz" ]]; then
            set -vx
            sudo tar -xzvf "${TAR_PATH}/${TAR_NAME}" -C "${BIN_PATH}" "${BIN_NAME}"
            if [[ $? -ne 0 ]]; then
                set +vx
                exit 1
            fi
        elif [[ "${TAR_EXT}" == "tgz" ]]; then
            set -vx
            sudo tar -xzOf "${TAR_PATH}/${TAR_NAME}" | sudo tee "${BIN_PATH}/${BIN_NAME}" > /dev/null
            if [[ $? -ne 0 ]]; then
                set +vx
                exit 1
            fi
        else
            echo "Unknown archive format..."
            exit 1
        fi
        set +vx
        echo "Binary of ${BIN_NAME} is installed"
        sudo chmod +x "${BIN_PATH}/${BIN_NAME}"
        rm "${TAR_PATH}/${TAR_NAME}"
    else
        echo "Binary of ${BIN_NAME} already installed in either or both places:"
        echo "${TAR_PATH}/${TAR_NAME}"
        echo "${BIN_PATH}/${BIN_NAME}"
        echo "Run ./uninstall.sh"
        exit 1
    fi

    echo "${BIN_PATH}/${BIN_NAME}" --version
    "${BIN_PATH}/${BIN_NAME}" --version || {
        echo "Failed to install ${BIN_NAME}"
        exit 1
    }
}

function start_cri_dockerd() {
    if [[ -f "${KUBEADM_FLAGS_ENV}" ]]; then
        source "${KUBEADM_FLAGS_ENV}"
    fi

    sudo tee "${SERVICE_PATH}" > /dev/null <<EOF
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target

[Service]
Type=notify
ExecStart=/usr/local/bin/${BIN_NAME} --${BIN_NAME}-root-directory=/var/lib/dockershim --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin --container-runtime-endpoint ${CRI_SOCK} ${KUBELET_KUBEADM_ARGS}
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always

StartLimitBurst=3

StartLimitInterval=60s

LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity

TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
    systemctl status --no-pager "${SERVICE_NAME}" || {
        echo "Failed to start ${BIN_NAME}"
        exit 1
    }

    echo "crictl --runtime-endpoint "${CRI_SOCK}" ps"
    crictl --runtime-endpoint "${CRI_SOCK}" ps
}

function configure_kubelet() {
    NEW_FLAGS=$(echo "${OLD_FLAGS%\"*} --container-runtime=remote --container-runtime-endpoint=${CRI_SOCK}\"")

    case "${FORCE}" in
    [yY][eE][sS] | [yY])
        : # Skip
        ;;
    *)
        echo "============== The original kubeadm-flags.env =============="
        echo cat "${KUBEADM_FLAGS_ENV}"
        # cat "${KUBEADM_FLAGS_ENV}"
        echo "================ Configure kubelet ========================="
        echo "sudo cp ${KUBEADM_FLAGS_ENV} ${KUBEADM_FLAGS_ENV}.bak"
        echo "cat <<EOF > ${KUBEADM_FLAGS_ENV}"
        echo "${NEW_FLAGS}"
        echo "EOF"
        echo "sudo systemctl daemon-reload"
        echo "sudo systemctl restart kubelet"
        echo "============================================================"
        echo "Please double check the configuration of kubelet"
        echo "Next will execute the that command"
        echo "If you don't need this prompt process, please run:"
        echo "    FORCE=y $0"
        echo "============================================================"

        read -r -p "Are you sure? [y/n] " response
        case "$response" in
        [yY][eE][sS] | [yY])
            : # Skip
            ;;
        *)
            echo "You no enter 'y', so abort install now"
            echo "but the ${BIN_NAME} is installed and running"
            echo "if need to uninstall the ${BIN_NAME}, please run:"
            echo "   sudo systemctl stop ${SERVICE_NAME}"
            echo "   sudo systemctl disable ${SERVICE_NAME}"
            echo "   sudo rm ${SERVICE_PATH}"
            echo "   sudo rm ${BIN_PATH}/${BIN_NAME}"
            exit 1
            ;;
        esac
        ;;
    esac

    cp "${KUBEADM_FLAGS_ENV}" "${KUBEADM_FLAGS_ENV}.bak"
    cat <<EOF >${KUBEADM_FLAGS_ENV}
${NEW_FLAGS}
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart kubelet
}

function main() {
    check_container_runtime_of_kubelet
    install_cri_dockerd
    start_cri_dockerd
    configure_kubelet
}

main
