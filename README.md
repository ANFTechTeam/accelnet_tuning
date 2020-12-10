# accelnet_tuning
Network interface cards deliver the best performance when associated with the lowest
number set of physical cores on a compute instance. As physical cores are bundled by
NUMA node, it is best to associate the network interface with the lowest numbered NUMA
node.  Hypervisors cannot always be counted on to perform NUMA node mapping in physical
order, this tool was developed with the cooperation of both the Azure Linux User
Experience team and the Azure NetApp Files team to identify and set the accelerated
networking interface on the best possible NUMA node for a given compute instance.

Note: This tool should be run each time that a machine is started as NUMA mapping is only
consistant while a machine is powered up.

What it does:
1) The tool will take as input a file name placed on an NFS mounted filesystem:
   1a) ./set_best_affinity.sh  /SASDATA/testfile
   

2) The file /SASDATA/testfile is created 8GiB in size if it does not already exist


3) The tool will on its own identify the accelerated network interface through
   which the NFS mount is accessed, let us say for example eth3


4) The tool will set the number of tx/rx queues associated with the <eth3> to
   which ever is less, the number of cores on a single NUMA node or nic maximum.


5) The tool will associate eth3 one by one with each of the NUMA nodes on the
    system and run 5 sets of dd read commands tabulating the throughput of each run
    as well as the series average per NUMA node.


6) After all tests are done, the tool will associate the accelerated
   networking interface with the most optimal NUMA node.
