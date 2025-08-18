#!/usr/bin/env bash

# Run this script on local machine

if [ $# != 4 ]; then
    echo "Usage: bash eval_at_local.sh shard_num rf username client_hostname"
    exit
fi

shard_num=$1
rf=$2
username=$3
client=$4

local_save_path="/home/frank/workspace/test/"

ssh_arg="-o ServerAliveInterval=30 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
scp_arg="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"

ssh ${ssh_arg} root@${client} << ENDSSH
    cd /root/YCSB
    bash eval_for_nofdb.sh ${shard_num} ${rf} ${username}
ENDSSH

scp ${scp_arg} -r root@${client}:/users/${username}/get_outputs ${local_save_path}
