#!/bin/bash
# Test read bandwidth using a mounted network fs


# Get IRQ numbers
function get_iface_irqs
{
	iface=$1
	device_msi_irqs_path="/sys/class/net/${iface}/device/msi_irqs"
	if [ -d $device_msi_irqs_path ]; then
		iface_irqs=$(ls $device_msi_irqs_path)
	else
		echo "Error - could not find ${device_msi_irqs_path}"
		exit 1
	fi
	echo $iface_irqs
}

function get_cpulist_by_node
{
	node=$1
	raw_cpulist=$(cat /sys/devices/system/node/node${node}/cpulist)
	if [ "$(echo $?)" != "0" ]; then
		echo "Node id '${node}' does not exists."
		exit 1
	fi
	ranges=$( echo "${raw_cpulist}" | sed 's/,/ /g' )
	cpulist=""
	# a range can just be one cpu (3) or an actual range (0-6)
	for range in ${ranges}
	do
		seq_arg=$(echo "${range}" | sed 's/-/ /')
		if [ "$(echo "${seq_arg}" | wc -w)" != "1" ]; then
			cpulist="${cpulist} $(seq ${seq_arg})"
		else
			cpulist="${cpulist} ${range}"
		fi
	done
	echo $cpulist
}

function add_comma_every_eight
{
	echo " $1 " | sed -r ':L;s=\b([0-9]+)([0-9]{8})\b=\1,\2=g;t L'
}

function int2hex
{
	chunks=$(( $1/64 ))
	coreid=$1
	hex=""
	for (( chunk=0; chunk<${chunks} ; chunk++ ))
	do
		hex=$hex"0000000000000000"
		coreid=$((coreid-64))
	done
	printf "%x$hex" $(echo $((2**$coreid)) )
}


function core_to_affinity
{
	echo $( add_comma_every_eight $( int2hex $1) )
}

function set_irq_affinity
{

	irq_num=$1
	affinity_mask=$2
	smp_affinity_path="/proc/irq/$irq_num/smp_affinity"
	# not all msi_irqs for the device are available in /proc/irq!
	if [ -f $smp_affinity_path ]; then
		echo $affinity_mask > $smp_affinity_path
	fi
}

function set_irq_affinity_by_node
{
	node=$1
	iface=$2
	iface_irqs=$(get_iface_irqs ${iface})
	cpulist=$(get_cpulist_by_node ${node})
	#echo "${cpulist}"
	num_cores=$(echo "${cpulist}" | wc -w)
	core_i=1
	# Assign irqs to cores round robin
	for irq in $iface_irqs
	do
		core_id=$(echo $cpulist | cut -d " " -f $core_i)
		#echo Assign irq $irq core_id $core_id
		affinity=$( core_to_affinity $core_id )
		set_irq_affinity $irq $affinity
		core_i=$(( (core_i%num_cores) + 1 ))
	done
}

echo $1
if [ -z $1 ]; then
	echo "usage: $0 <FILE>"
	echo "This script will:"
	echo " - Create <FILE> 2GiB in size, or use existing file (<FILE> should be in a network mount)"
	echo " - Find first network interface with a mellanox driver (accelerated networking in Azure)"
	echo " - Test each NUMA node's affinity with the network card by testing read speed from <FILE>"
	echo " - After testing, set the best NUMA node affinity for the network card"
	exit 1
fi

file_path=$1

# 8GiB
target_file_size=8589934592
# 64 MiB
dd_block_size=$(( 1048576 * 64 ))
dd_count=$(( ${target_file_size} / ${dd_block_size} ))

# Create a file or use existing if big enough
touch "${file_path}" || ( echo "Failed to create ${file_path}" && exit 1 )
file_size="$(ls -l "${file_path}" | cut -d ' ' -f 5)"
if [ 1 -eq "$(echo "${file_size} >= ${target_file_size}" | bc -l)" ]; then
	echo "Using existing file"
else
	echo -n "Creating 8GiB file ${file_path}..."
	dd if=/dev/urandom of="${file_path}" iflag=fullblock bs=${dd_block_size} count=${dd_count} >/dev/null 2>&1
	echo "done"
	# Clear slab + pagecache
	echo 3 > /proc/sys/vm/drop_caches
fi

# Find mellanox device interface
#sys_class_net_path="/sys/class/net"
#for i in $(ls ${sys_class_net_path});
#do
#	if $(readlink "${sys_class_net_path}/${i}/device/driver" | grep -q mlx); then
#		interface=$i
#		break
#	fi
#done
local_ip=`ss -n | grep 2049 | awk '{print $5}' | cut -d: -f1 | sort | uniq`
local_nic=`ip a | grep -B 2 $local_ip | grep mtu | awk -F: '{print $2}' | awk '{print $1}'`
interface=`ls /sys/class/net/${local_nic}/ | grep lower | cut -d_ -f2`

if [ -z ${interface} ];
then
	echo "Couldn't find mellanox interface"
	exit 1
fi
echo "Found mellanox interface: ${interface}"

# estimate number of cpus per numa node
#cpus_per_node=$(( $(lscpu | grep "NUMA node0" | sed -r 's/^.*([0-9]+)$/\1/g') + 1))
cpus_per_node=$(( $(lscpu | grep "NUMA node0" | cut -d- -f2 )))
rxtx_queue_combined=`ethtool -l $interface | grep -i com | head -1 | awk '{print $2}'`
rxtx_queue_RX=`ethtool -l $interface | grep -i RX | head -1 | awk '{print $2}'`
rxtx_queue_TX=`ethtool -l $interface | grep -i TX | head -1 | awk '{print $2}'`
if [ $rxtx_queue_combined -eq 0 ]; then
    #Find the largest queue count based on tx and rx queue size
    if [ $rxtx_queue_RX -gt $rxtx_queue_TX ]; then
        tune=$rxtx_queue_RX
    else
        tune=$rxtx_queue_WX
    fi
    #Set max tx and rx queues to cpu_count per numa node or hardware max, which ever is smaller
    if [ $cpus_per_node -gt $tune ]; then
        tune=$cpus_per_node
    fi
    echo "Set number of rx, tx queues to $tune"
    ethtool -L "${interface}" rx ${tune} tx ${tune}
else
    #Set max combined queues to cpu_count per numa node or hardware max, which ever is smaller
    if [ $cpus_per_node -gt $rxtx_queue_combined ]; then
        tune=$rxtx_queue_combined
    else
        tune=$cpus_per_node
    fi
    echo "Set number of combined queues to $tune"
    ethtool -L "${interface}" combined ${tune}
fi

# Get list of numa nodes
numa_nodes="$(ls /sys/devices/system/node | grep 'node' | sed 's#node##')"

best_node="$(echo "${numa_nodes}" | head -1)"
best_speed="0.00"
num_runs="5"

for n in ${numa_nodes};
do
	total_speed="0.0"

	set_irq_affinity_by_node ${n} ${interface}
	
	# Get a cpu from this node to actually run the test on
	a_cpu="$(get_cpulist_by_node ${n} | sed 's#\s#\n#g' | tail -1)"

	echo "Testing rx throughput with node ${n}:"

	# Warmup
	echo -n "	Warming up..."
	dd_out=$(taskset -c ${a_cpu} dd if=${file_path} of=/dev/null iflag=direct bs=${dd_block_size} count=$(( 1024 / 64 )) 2>&1)
	echo "done"

	for i in $(seq ${num_runs});
	do
		dd_out=$(taskset -c ${a_cpu} dd if=${file_path} of=/dev/null iflag=direct bs=${dd_block_size} count=${dd_count} 2>&1)
		#dd_out=$(taskset -c ${a_cpu} dd if=/dev/zero of=${file_path} bs=${dd_block_size} count=${dd_count} 2>&1)
                echo $dd_out 

		if [ "$(echo $?)" != "0" ]; then
			echo "Error - reading from ${file_path}"
			exit
		fi

		# echo "$dd_out"
		dd_out="$(echo "${dd_out}" | head -3 | tail -1)"
		speed="$(echo "${dd_out}" | sed -r 's#^.*, ([0-9]+(\.[0-9]+)?) [GMk]B\/s$#\1#')"
		unit="$(echo "${dd_out}" | sed -r 's#^.* ([GMk]B\/s)$#\1#')"

		#echo "$speed $unit"
		# convert MB to GB, ignore smaller units
		if [ "${unit}" == "MB/s" ]; then
			speed="$(echo "${speed}/1024" | bc -l)"
		elif [ "${unit}" != "GB/s" ]; then
			speed="0.0"
		fi

		echo "	Run ${i}: ${speed} GB/s"
		total_speed=$(echo "${total_speed} + ${speed}" | bc -l)
	done
	avg_speed=$(echo "${total_speed} / ${num_runs}" | bc -l)
	echo "	Avg speed: ${avg_speed} GB/s"

	if [ 1 -eq "$(echo "${avg_speed} > ${best_speed}" | bc -l)" ];
	then
		best_speed=${avg_speed}
		best_node=${n}
	fi
done

echo "Best avg rx throughput was on node ${best_node}: ${best_speed} GB/s"

set_irq_affinity_by_node ${best_node} ${interface}
echo "Set irq affinity for interface ${interface} to NUMA node ${best_node}"
