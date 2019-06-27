#!/bin/bash

set -exo pipefail

export ALL_SERVER_IPS=("192.168.31.81" "192.168.31.82" "192.168.31.83")
export MASTER_IP=192.168.31.81
export NODE_IPS=("192.168.31.81" "192.168.31.82" "192.168.31.83")
export DOCKER_LOCATION=/home/docker
export SERVICE_UNIT_LOCATION=/usr/lib/systemd/system
