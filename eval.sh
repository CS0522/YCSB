#!/bin/bash

# set -x

if [ $# != 8 ]; then
    echo "Usage: bash eval.sh phase workload rate suffix client_num mode shard_num replication_factor"
    echo "Got: $@"
    exit
fi

phase=$1
workload=$2
rate=$3
suffix=$4
client_num=$5
mode=$6
shard_num=$7
rf=$8
cpu_num=$(( 1 * client_num ))

echo -e "\033[0;32m ${phase} ${workload} ${mode} \033[0m"

replicator_port=50040
shard_port=50050
rubble_dir="/mnt/data/rocksdb/rubble"
# add ssh args
ssh_arg="-o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -Tq"

# 添加 outputs 目录
output_dir="/users/CS0522/outputs"

# monitor 相关
cpu_monitor_pid="${rubble_dir}/cpu_monitor.pid"
sample_interval=3

ssh_with_retry()
{
    local ip=$1
    local cmd=$2
    until ssh ${USER}@${ip} "$cmd exit 0"
    do
        sleep 1
    done
}

start_server_cpu_monitor()
{
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        echo "Starting monitor for ${ip}"
        ssh_with_retry ${ip} "rm -rf ${cpu_monitor_pid}; cd ${rubble_dir}; nohup bash server_start_monitor.sh "${sample_interval}" "${output_dir}/monitor-${suffix}.log" >/dev/null 2>&1 & echo \$! > ${cpu_monitor_pid};"
    done
}

kill_server_cpu_monitor()
{
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        echo "Killing monitor for ${ip}"
        ssh_with_retry ${ip} "cd ${rubble_dir}; bash server_kill_monitor.sh ${cpu_monitor_pid};"
    done
}

launch_node()
{
    local ip=$1
    local port=$2
    local addr=$3
    local sid=$4
    local rid=$5
    local primary_ip=$6
    

    local cgroup_opts="cgexec -g cpuset:rubble-cpu -g memory:rubble-mem"
    # gprof_opts="env HEAPPROFILE=${rubble_dir}/shard-${sid}.hprof LD_PRELOAD=/usr/local/lib/libtcmalloc.so"
    local log="shard-${sid}.out"
    
    ssh_with_retry ${ip} "cd ${rubble_dir}; \
        ulimit -n 999999; ulimit -c unlimited; \
        nohup sudo ${cgroup_opts} ${gprof_opts} ./db_node ${port} ${addr} ${sid} ${rid} ${rf} ${primary_ip} > ${log} 2>&1 &"
}

set_cgroups()
{
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        ssh_with_retry ${ip} "cd ${rubble_dir}; sudo bash create_cgroups.sh ${cpu_num} > /dev/null 2>&1;"
    done
}

launch_all_nodes()
{
    # 1. prepare the environment
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        # ssh_with_retry ${ip} "cd ${rubble_dir}; sudo pkill -f server_start_monitor; sudo pkill -f server_kill_monitor;"
        ssh_with_retry ${ip} "rm -rf ${output_dir}; mkdir -p ${output_dir}; mkdir -p ${output_dir}/figures;"
        ssh_with_retry ${ip} "cd ${rubble_dir}; sudo killall db_node dstat iostat perf > /dev/null 2>&1;"
        ssh_with_retry ${ip} "cd ${rubble_dir}; sudo bash clean.sh ${shard_num} > /dev/null 2>&1;"
        ssh_with_retry ${ip} "cd ${rubble_dir}; sudo bash change-mode.sh ${mode} 1 4;"
    done
    set_cgroups

    # 开启远端 monitor
    start_server_cpu_monitor

    # 2. launch DB instances on the server
    for (( i=0; i<${shard_num}; i++ ))
    do
        local port=$(($shard_port + $i))
	local primary_ip="10.10.1."$(($i % $rf + 2))":"$port

        for (( j=0; j<${rf}; j++ ))
        do
            local ip="10.10.1."$((($i + $j) % $rf + 2))
            if [ $j -eq $(($rf - 1)) ]
            then
                local next_ip="10.10.1.1:"$replicator_port
            else
                local next_ip="10.10.1."$((($i + $j + 1) % $rf + 2))":"$port
            fi
            launch_node $ip $port ${next_ip} $i $j $primary_ip
        done
    done
}

record_stats()
{
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        ssh_with_retry ${ip} "cd ${rubble_dir}; nohup sudo bash dstat.sh ${cpu_num} > /dev/null 2>&1 &"
        ssh_with_retry ${ip} "cd ${rubble_dir}; nohup sudo bash iostat.sh > /dev/null 2>&1 &"
        ssh_with_retry ${ip} "cd ${rubble_dir}; ps aux | grep -E './db_node' > pids.out;"
        ssh_with_retry ${ip} "cd ${rubble_dir}; nohup top -H -b -d 1 -w 512 > top.out 2>&1 &"
        # ssh_with_retry ${ip} "cd ${rubble_dir}; nohup bash perf.sh ${suffix} 0,2,4,6 600 > /dev/null 2>&1 &"
        ssh_with_retry ${ip} "cd ${rubble_dir}; nohup nethogs -t -a -v 3 > nethogs.out 2>&1 &"
        ssh_with_retry ${ip} "cd ${rubble_dir}; bash mark-load-end.sh ${shard_num} ${suffix};"
    done
}

assemble_args()
{
    local arg="-p shard=${shard_num} -p client=${client_num} "
    for (( i=0; i<${shard_num}; i++ ))
    do
        local port=$(($shard_port + $i))
        local head_ip="10.10.1."$(($i % $rf + 2))
        local tail_ip="10.10.1."$((($i + $rf - 1) % rf + 2))
        arg=$arg"-p head${i}=${head_ip}:${port} -p tail${i}=${tail_ip}:${port} "
    done

    echo $arg
}

relax_cpu()
{
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        local cpu=`ssh_with_retry ${ip} "lscpu;" | grep "NUMA node0 CPU(s)" | awk '{print $(NF)}'`
        ssh_with_retry ${ip} "sudo cgset -r cpuset.cpus=${cpu} rubble-cpu;"
    done
}

wait_pending_jobs()
{
    local pid=()

    for (( i=0; i<${shard_num}; i++ ))
    do
        local db_dir="/mnt/data/db/shard-${i}/db/LOG"

        for (( j=0; j<${rf}; j++ ))
        do
            local ip="10.10.1."$((($i + $j) % $rf + 2))
            ssh_with_retry ${ip} "cd ${rubble_dir}; bash wait-pending-jobs.sh ${db_dir};" &
            pid[$(($i * $rf + $j))]=$!
        done
    done

    for i in ${pid[@]}
    do
        wait $i
    done
}

massacre()
{
    sudo killall java
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        ssh_with_retry ${ip} "sudo killall db_node dstat iostat perf top python3 nethogs;"
    done
}

process_results()
{
	start_cut=$1
	end_cut=$2

    grep Throughput ycsb.out
    cp ycsb.out ${output_dir}/ycsb-${suffix}.out
    cp replicator.out ${output_dir}/replicator-${suffix}.out
    python3 plot-thru.py ${output_dir}/ycsb-${suffix}.out 10 ${start_cut} ${end_cut}

    runtime=`grep "RunTime(ms)" ycsb.out | tail -1 | cut -d ',' -f 3`

    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        ssh_with_retry ${ip} "cd ${rubble_dir}; bash save-result.sh ${shard_num} ${suffix};"
        ssh_with_retry ${ip} "cd ${rubble_dir}; python3 plot-dstat.py ${output_dir}/dstat-${suffix}.csv 10 ${cpu_num};"
        ssh_with_retry ${ip} "cd ${rubble_dir}; python3 plot-iostat.py ${output_dir}/iostat-${suffix}.out 10;"
        ssh_with_retry ${ip} "cd ${rubble_dir}; python3 network-breakdown.py ${suffix} ${shard_num} ${runtime} > ${output_dir}/network_breakdown_${suffix}.out;"
    done
}

get_results()
{
    for (( i=0; i<${rf}; i++ ))
    do
        local ip="10.10.1."$(($i + 2))
        scp -o StrictHostKeyChecking=no -r ${USER}@${ip}:${output_dir} ${output_dir}/
        mv ${output_dir}/outputs ${output_dir}/server_$(($i + 1))-${phase}-workload${workload}-clientthreads_${client_num}
        # 删除 top 文件
        sudo rm -rf ${output_dir}/server_$(($i + 1))-${phase}-workload${workload}-clientthreads_${client_num}/top*
    done
}

# 修改 recordcount，operationcount 的值
update_workload_file() {
    # local shard_num=$1
    # 30M
    local cnt=30000000
    for wl in "a" "b" "c" "d" "f" "g"
    do
        sed -i "s/recordcount=[0-9]\+/recordcount=${cnt}/g" workloads/workload${wl}
        sed -i "s/operationcount=[0-9]\+/operationcount=${cnt}/g" workloads/workload${wl}
    done
}


# 0. clean the environment
massacre

# make output dir
mkdir -p "${output_dir}"
mkdir -p "${output_dir}/figures"

# 开启远端 monitor
# start_server_cpu_monitor
# 放在 launch_all_nodes 中

# 1. start db instances
launch_all_nodes

# 2. start the replicator
sudo killall java
replicator_args=$(assemble_args)
./bin/ycsb.sh replicator rocksdb -s -P workloads/workload${workload} \
    -p port=$replicator_port $replicator_args -p replica=$rf > replicator.out 2>&1 &

# 3. load the database
update_workload_file
sleep_ms=1000
echo "" > ycsb.out
if [ $phase != load ]; then
    relax_cpu

    # bash load.sh $workload localhost:$replicator_port $shard_num $sleep_ms 120000 $client_num > ycsb.out 2>&1

    wait_pending_jobs

    set_cgroups
fi

# 4. record performance metrics
record_stats

# 5. run YCSB
bash $phase.sh $workload localhost:$replicator_port $shard_num $sleep_ms $rate $client_num >> ycsb.out 2>&1

# 6. kill all processes
massacre

# 关闭远端 monitor
kill_server_cpu_monitor

# 7. save results and plot figures
start_cut=1000
end_cut=300
process_results ${start_cut} ${end_cut}

# 8. get remote node's result
get_results