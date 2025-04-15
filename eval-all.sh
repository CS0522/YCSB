#!/bin/bash
set -x

if [ $# != 5 ]; then
    echo "Usage: bash eval-all.sh client_num shard_num replication_factor is_mlnx(0/1) suffix"
    exit
fi

client_num=$1
shard_num=$2
rf=$3
is_mlnx=$4
suffix=$5

workload=("a" "b" "c" "d" "e" "f" "g")

# optane nodes
if [ $rf -eq 2 ]; then
    if [ $shard_num -eq 2 ]; then
       # 2 shard 2 replica
        load_rate=90000
        rate=(90000 170000 210000 240000)
    elif [ $shard_num -eq 4 ]; then
        # 4 shard 2 replica
        load_rate=110000
        rate=(100000 180000 220000 240000 40000 00000 70000)
    else
        echo "No rate found: $shard_num $rf"
        exit
    fi
fi

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

# no use
ip_to_nid() {
    local ip=$1
    local digit=${ip: -1}
    local nid=$(( digit - 1 ))
    echo $nid
}

# no use
change_offload()
{
    local ip=$1
    local code=$2
    local nid=$( ip_to_nid $ip )
    local subsystem="subsystem${nid}"
    ssh ${USER}@${ip} "rm /sys/kernel/config/nvmet/ports/1/subsystems/${subsystem}; sleep 1; echo ${code} > /sys/kernel/config/nvmet/subsystems/${subsystem}/attr_offload; sleep 1; ln -s /sys/kernel/config/nvmet/subsystems/${subsystem}/ /sys/kernel/config/nvmet/ports/1/subsystems/${subsystem}"
}

# no use
enable_offload()
{
    for (( i=0; i<${rf}; i++ )); do
        local ip="10.10.1."$(($i + 2))
        change_offload $ip 1
    done
}

# no use
disable_offload()
{
    for (( i=0; i<${rf}; i++ )); do
        local ip="10.10.1."$(($i + 2))
        change_offload $ip 0
    done
}

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

recover_all_nodes()
{
    # 1. reboot
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        ssh ${USER}@${ip} "reboot"
    done
    check_connectivity 255
    check_connectivity 0

    # 2. reconfigure NVMeoF
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        ssh_with_retry ${ip} "bash setup-nvmeof.sh target $is_mlnx $rf" > recover-$i.log 2>&1 &
    done

    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        local nvme_id=1;
        for (( j=0; j<${rf}; j++ ))
        do
            if [ $i -ne $j ]
            then
                local target_ip="10.10.1."$(($j + 2))
                ssh_with_retry ${ip} "bash setup-nvmeof.sh host $target_ip $nvme_id" >> recover-$i.log 2>&1
                nvme_id=$(( nvme_id + 1 ))
            fi
        done
    done

    # 3. recreate sst pool
    local pid=()
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        ssh_with_retry ${ip} "cd $rubble_dir; bash verify-sst-pool.sh 16777216 1 5000 $shard_num $rf 1" >> recover-$i.log 2>&1 &
        pid[$i]=$!
    done
    for i in ${pid[@]}
    do
        wait $i
    done
}

eval_with_recovery()
{
    local phase=$1
    local workload=$2
    local rate=$3
    local suffix=$4
    local client_num=$5
    local shard_num=$6
    local rf=$7
    local finish=0

    while [ $finish -ne 1 ]; do
        bash eval.sh $phase $workload $rate $suffix $client_num rubble $shard_num $rf
        local unchange_sec=0
        local ops_done=0
        while [ $unchange_sec -lt 30 ]; do
            local num=`grep Throughput ycsb.out | wc -l`
            if [ "$phase" == "load" ]; then
                if [ $num -eq 1 ]; then
                    cp ycsb.out ycsb.backup
                    finish=1
                    break
                fi
            else
                if [ $num -eq 2 ]; then
                    cp ycsb.out ycsb.backup
                    finish=1
                    break
                fi
            fi

            local line=`tail -n 1 ycsb.out`
            local word=($line)
            if [ "${word[3]}" == "sec:" ] && [ "${word[5]}" == "operations;" ]; then
                if [ ${word[4]} -eq $ops_done ]; then
                    unchange_sec=$(( unchange_sec + 1 ))
                else
                    ops_done=${word[4]}
                    unchange_sec=0
                fi
            fi

            sleep 1
        done

        if [ $finish -ne 1 ]; then
            killall java
            recover_all_nodes
        fi
    done
}

for idx in $(seq 0 6)
do
    cnt=$(( $shard_num * 10000000 ))
    sed -i "s/recordcount=[0-9]\+/recordcount=${cnt}/g" workloads/workload${workload[$idx]}
    sed -i "s/operationcount=[0-9]\+/operationcount=${cnt}/g" workloads/workload${workload[$idx]}
done

# disable_offload
# enable_offload
eval_with_recovery load a $load_rate rubble-offload-load-$suffix 4 $shard_num $rf
bash eval.sh load a $load_rate baseline-load-$suffix 4 baseline $shard_num $rf

for idx in $(seq 0 6)
do
    echo workload ${workload[$idx]} rate ${rate[$idx]} op/sec
    # disable_offload
    # enable_offload
    eval_with_recovery run ${workload[$idx]} ${rate[$idx]} rubble-offload-${workload[$idx]}-$suffix 4 $shard_num $rf
    bash eval.sh run ${workload[$idx]} ${rate[$idx]} baseline-${workload[$idx]}-$suffix 4 baseline $shard_num $rf
done
