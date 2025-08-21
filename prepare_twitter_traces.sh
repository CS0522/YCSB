#!/usr/bin/env bash

# Run this script one remote machine with root access

# 需要与 eval_for_nofdb.sh 中内容同步
twitter_traces_base_path="/mnt/rubbledb"
twitter_trace_base_url="https://ftp.pdl.cmu.edu/pub/datasets/twemcacheWorkload/open_source/sample100/"
twitter_traces=("cluster12.sort.sample100"
                "cluster15.sort.sample100"
                "cluster19.sort.sample100"
                "cluster27.sort.sample100"
                "cluster31.sort.sample100"
                "cluster37.sort.sample100")


function mount_device()
{
    apt update
    apt install -y nvme-cli
    rm -rf ${twitter_traces_base_path}/*
    umount ${twitter_traces_base_path}
    nvme format -s 1 /dev/nvme0n1
    parted -s /dev/nvme0n1 mklabel gpt
    parted -s /dev/nvme0n1 mkpart primary 0% 100%
    sleep 1
    # force performing
    mkfs -F -t ext4 /dev/nvme0n1

    mkdir -p ${twitter_traces_base_path}
    mount /dev/nvme0n1 ${twitter_traces_base_path}
    rm -rf ${twitter_traces_base_path}/*
    chown -R CS0522:nof-rep-PG0 ${twitter_traces_base_path}
}

function download_trace_fn()
{
  cd ${twitter_traces_base_path}
  for trace in ${twitter_traces[@]}; do
      wget "${twitter_trace_base_url}${trace}.zst"
  done
}

function unpack_trace_fn()
{
  cd ${twitter_traces_base_path}
  for trace in ${twitter_traces[@]}; do
      zstd -d "${trace}.zst"
      rm -rf "${trace}.zst"
  done
}


apt update
apt install -y zstd
mount_device
download_trace_fn
unpack_trace_fn
