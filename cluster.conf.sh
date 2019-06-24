#!/bin/bash

set -exo pipefail

ALL_SERVER_IPS=("10.10.0.82" "10.10.0.83" "10.10.0.84")
MASTER_IP=10.10.0.82
NODE_IPS=("10.10.0.82" "10.10.0.83" "10.10.0.84")

DOCKER_LOCATION=/home/docker
# SERVICE_UNIT_LOCATION=/lib/systemd/system # for ubuntu
SERVICE_UNIT_LOCATION=/usr/lib/systemd/system # for centos

export ALL_SERVER_IPS
export MASTER_IP
export NODE_IPS
export DOCKER_LOCATION
export SERVICE_UNIT_LOCATION