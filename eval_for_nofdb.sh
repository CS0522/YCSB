#!/bin/env bash

if [ $# != 3 ]; then
    echo "Usage: bash eval_for_nofdb.sh client_num shard_num replication_factor"
    exit
fi

# 50
client_num=$1
# 3
shard_num=$2
# 3
rf=$3

workloads=("a" "b" "c" "d" "e" "f" "g")

# r6525 nodes
if [ $rf -eq 2 ]; then
    if [ $shard_num -eq 2 ]; then
       # 2 shard 2 replica
        load_rate=90000
        rate=(80000 90000 90000 160000 11000 70000 50000)
    elif [ $shard_num -eq 4 ]; then
        # 4 shard 2 replica
        load_rate=100000
        rate=(80000 120000 140000 210000 30000 80000 60000)
    else
        echo "No rate found: $shard_num $rf"
        exit
    fi
elif [ $rf -eq 3 ]; then
    if [ $shard_num -eq 3 ]; then
        # 3 shard 3 replica
        load_rate=100000
        rate=(80000 120000 120000 230000 16000 80000 60000)
    elif [ $shard_num -eq 6 ]; then
        # 6 shard 3 replica
        load_rate=120000
        rate=(90000 170000 190000 290000 40000 90000 60000)
    else
        echo "No rate found: $shard_num $rf"
        exit
    fi
elif [ $rf -eq 4 ]; then
    if [ $shard_num -eq 4 ]; then
        # 4 shard 4 replica
        load_rate=110000
        rate=(90000 150000 160000 300000 21000 90000 60000)
    elif [ $shard_num -eq 8 ]; then
        # 8 shard 4 replica
        load_rate=120000
        rate=(90000 210000 250000 370000 50000 90000 60000)
    else
        echo "No rate found: $shard_num $rf"
        exit
    fi
else
    echo "No rate found: $shard_num $rf"
    exit
fi

ssh_with_retry()
{
    local ip=$1
    local cmd=$2
    until ssh ${USER}@${ip} "$cmd exit 0"
    do
        sleep 1
    done
}

check_connectivity() {
    local status=$1
    local ssh_arg="-o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        while true
        do
            ssh $ssh_arg -q ${USER}@${ip} exit
            if [ $? -eq $status ]
            then
                break 1
            fi
        done
    done
}

# 修改 recordcount，operationcount 的值
for idx in $(seq 0 6)
do
    # 200M
    cnt=200000000
    sed -i "s/recordcount=[0-9]\+/recordcount=${cnt}/g" workloads/workload${workloads[$idx]}
    sed -i "s/operationcount=[0-9]\+/operationcount=${cnt}/g" workloads/workload${workloads[$idx]}
done

# bash eval.sh load a $load_rate rubble-offload-load-workloada ${client_num} rubble $shard_num $rf

for idx in $(seq 0 6)
do
    # only workloadc, workloadg
    if [[ ${idx} -eq 2 || ${idx} -eq 6 ]]; then
        echo "workload: workload${workloads[$idx]}, rate: ${rate[$idx]} op/sec, client_num: ${client_num}, shard_num: ${shard_num}, rf: ${rf}"
        bash eval.sh load ${workloads[$idx]} ${rate[$idx]} load-200m-workload${workloads[$idx]}-${client_num} ${client_num} rubble $shard_num $rf
        sleep 5
        bash eval.sh run ${workloads[$idx]} ${rate[$idx]} run-200m-workload${workloads[$idx]}-${client_num} ${client_num} rubble $shard_num $rf
    else
        continue
    fi
done
