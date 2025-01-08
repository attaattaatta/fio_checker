#!/bin/bash

# Set paths
export PATH=$PATH:/usr/sbin:/usr/local/sbin

# Clear the terminal
clear

# Define color variables
GCV="\033[0;92m"
LRV="\033[1;91m"
YCV="\033[01;33m"
NCV="\033[0m"

# Show script version
self_current_version="1.0.2"
printf "\n${YCV}Hello${NCV}, my version is ${YCV}$self_current_version\n\n${NCV}"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    printf "\n${LRV}ERROR - This script must be run as root.${NCV}"
    exit 1
fi

# Installing test software
printf "${GCV}Installing fio and smartmontools\n${NCV}"
{
yum -y install fio smartmontools || apt -y update; apt -y install fio smartmontools 
} > /dev/null 2>&1

# Check if required tools are installed
WE_NEED=('fio' 'smartctl')

for needitem in "${WE_NEED[@]}"; do
    if ! command -v $needitem &> /dev/null; then
        printf "\n${LRV}ERROR - $needitem could not be found. Please install it first or export correct \$PATH.${NCV}\n"
        printf "\n${LRV}yum -y install fio smartmontools || apt -y update; apt -y install fio smartmontools ${NCV}\n"
        exit 1
    fi
done

# Get the current device
PWD_DEVICE=$(df -P . | sed -n '$s@[[:blank:]].*@@p')

# Check if the device is a RAID
if [[ $PWD_DEVICE == *"md"* ]]; then
    if mdadm -D $PWD_DEVICE | grep -qi "status"; then
        printf "${LRV} RAID resync or rebuild is in progress. Aborting.${NCV}\n"
        sleep 3s
        exit 1
    fi
    PWD_DEVICE=$(mdadm -vQD $PWD_DEVICE | grep -v md | grep -o '/dev/.*' | sed 's@:@@gi' | head -n 1)
fi

# Get device model and firmware
DEVICE_MODEL=$(smartctl -a $(echo $PWD_DEVICE | sed -E 's@p[[:digit:]]@@g') | grep -E "Model Number|Device Model" | awk -F':' '{print $2}' | sed 's@^[ \t]*@@gi')
DEVICE_FIRMWARE=$(smartctl -a $(echo $PWD_DEVICE | sed -E 's@p[[:digit:]]@@g') | grep -E "Firmware Version" | awk -F':' '{print $2}' | sed 's@^[ \t]*@@gi')

# Set default values if not found
DEVICE_MODEL=${DEVICE_MODEL:-"Unknown"}
DEVICE_FIRMWARE=${DEVICE_FIRMWARE:-"Unknown"}

SUMMARY_DEVICE=$(echo $PWD_DEVICE | awk '{print $1}')

# Check free space in gigabytes
printf "${GCV}Checking free space${NCV}\n\n"
current_free=$(df -PhBG --sync . | tail -1 | awk '{print $4}' | grep -o "[[:digit:]|.]*")

printf "${GCV}Enter size in GB for run tests.\nThe more the better, to check SLC cache enter minimum 50GB, but it should be free space\nAfter test will finish all temporary files will be removed.${NCV}\n"
printf "${GCV}\nCurrent free space on the drive I run:${NCV} ${current_free}GB\n"

# Function to get size to check
sizetocheck() {
    read -p "Enter one file size in GB should I use in tests: " sizetocheck
}

sizetocheck

# Validate input
while ! [[ $sizetocheck =~ ^[0-9]+$ ]]; do
    printf "\n${LRV}ERROR - enter only digits${NCV}\n"
    sleep 1s
    sizetocheck
done

needfreegb=$((${sizetocheck}*16))

# Check if there is enough free space
while [[ "$current_free" -le "$needfreegb" ]]; do
    printf "${LRV}\nERROR - Free space needed is ${needfreegb}GB ( ${sizetocheck} * numjobs is 16 ) \n${NCV}"
    sleep 2s
    sizetocheck
done

# Check if enough space for SLC cache testing
if [[ "$current_free" -gt 51 ]]; then
    WITHOUT_SLC_CHECK=1
else
    printf "\n${YCV}Not enough free space for testing over SLC cache\nSkipping no SLC tests\n\n${NCV}"
    WITHOUT_SLC_CHECK=0
fi

# Function to sync, sleep, and trim
sst() {
    printf "${GCV}Syncing${NCV}\n"
    sync
    printf "${GCV}Sleeping${NCV}\n"
    sleep 5s
    printf "${GCV}Trimming${NCV}\n"
    fstrim $PWD 2> /dev/null || true
    echo
}

# Function to parse FIO results
parse_fio_results() {
    IOPS=$(echo ${!test_result} | grep -o "IOPS=*[[:alnum:]|.]*")
    SPEED=$(echo "${!test_result}" | grep -E "WRITE|READ" | grep -Po "(?<=\().*(?=\))" | sed "s@).*@@gi")
}

RESULTS_FILENAME=fio_tests_$(date '+%d-%b-%Y-%H-%M-%Z')_$RANDOM.txt

# FIO command setup
FIO_RNDNAME=$(for i in {1..3} ; do echo -n "${RANDOM%${#}:1}"; done)
FIO_PRE="fio --ioengine=libaio --buffered=0 --direct=1 --name=testio$FIO_RNDNAME"
FIO_POST="--group_reporting"

OPSTYPE=(read write randread randwrite)

f=results$FIO_RNDNAME.txt
> $f

f1=results_slc$FIO_RNDNAME.txt
> $f1

f2=results_noslc$FIO_RNDNAME.txt
> $f2

# Check if the device is NVME
if [[ $PWD_DEVICE == *"nvme"* ]]; then
    printf "${GCV}Running FIO (NVME device - ${DEVICE_MODEL} / firmware - ${DEVICE_FIRMWARE})${NCV}\n"

    # SLC Cache NVME SEQ
    for z in ${OPSTYPE[@]:0:2}; do
        sst
        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}SEQ1MQ8T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=${sizetocheck}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ1MQ8T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GCV}----------\n Sequential by 1MB block queue - 8 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        sst
        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}SEQ128KQ32T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=${sizetocheck}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ128KQ32T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GCV}----------\n Sequential by 128KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        rm -f testio*
    done

    # SLC Cache NVME RND
    for z in ${OPSTYPE[@]:2:3}; do
        sst
        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}RND4KQ32T16 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ32T16$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=${sizetocheck}G --rw=$z --numjobs=16 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ32T16$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GCV}----------\n Random by 4KB block queue - 32 queue(s) deep - 16 thread(s) - $z:\n${NCV}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        sst
        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}RND4KQ1T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=${sizetocheck}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ1T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GCV}----------\n  Random by 4KB block queue - 1 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        rm -f testio*
    done

    if [[ $WITHOUT_SLC_CHECK == "1" ]]; then
        # NOT SLC Cache NVME SEQ
        for z in ${OPSTYPE[@]:0:2}; do
            sst
            printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}SEQ1MQ8T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
            declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
            test_result="SEQ1MQ8T1$z"
            echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

            printf "${GCV}----------\n Sequential by 1MB block queue - 8 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f2
            parse_fio_results
            echo $IOPS >> $f2
            echo "SPEED=$SPEED" >> $f2

            sst
            printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}SEQ128KQ32T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
            declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
            test_result="SEQ128KQ32T1$z"
            echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

            printf "${GCV}----------\n Sequential by 128KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f2
            parse_fio_results
            echo $IOPS >> $f2
            echo "SPEED=$SPEED" >> $f2

            rm -f testio*
        done

        # NOT SLC Cache NVME RND
        for z in ${OPSTYPE[@]:2:3}; do
            sst
            printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}RND4KQ32T16 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
            declare "RND4KQ32T16$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=50G --rw=$z --numjobs=16 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
            test_result="RND4KQ32T16$z"
            echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

            printf "${GCV}----------\n Random by 4KB block queue - 32 queue(s) deep - 16 thread(s) - $z:\n${NCV}" >> $f2
            parse_fio_results
            echo $IOPS >> $f2
            echo "SPEED=$SPEED" >> $f2

            sst
            printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}RND4KQ1T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
            declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
            test_result="RND4KQ1T1$z"
            echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

            printf "${GCV}----------\n  Random by 4KB block queue - 1 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f2
            parse_fio_results
            echo $IOPS >> $f2
            echo "SPEED=$SPEED" >> $f2

            rm -f testio*
        done
    fi

    sst

    printf "${LRV}Summary for $SUMMARY_DEVICE (NO SLC CACHE NVME - $DEVICE_MODEL) at $PWD${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
    cat $f2 | tee -a $PWD/${RESULTS_FILENAME}
    echo
    printf "${LRV}Summary for $SUMMARY_DEVICE (SLC CACHE NVME - $DEVICE_MODEL) at $PWD${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
    cat $f1 | tee -a $PWD/${RESULTS_FILENAME}
    rm -f $f $f1 $f2
    echo

else
    printf "${GCV}Running FIO (${LRV}NOT${GCV} NVME device - ${DEVICE_MODEL} / firmware - ${DEVICE_FIRMWARE}) ${NCV}\n"

    # NOT_NVME SEQ
    for z in ${OPSTYPE[@]:0:2}; do
        sst
        printf "${GCV}Testing SEQ1MQ8T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=${sizetocheck}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ1MQ8T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GCV}----------\n Sequential by 1MB block queue - 8 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        sst
        printf "${GCV}Testing SEQ128KQ32T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=${sizetocheck}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ128KQ32T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}
        echo

        printf "${GCV}----------\n Sequential by 128KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        rm -f testio*
    done

    # NOT_NVME RND
    for z in ${OPSTYPE[@]:2:3}; do
        sst
        printf "${GCV}Testing RND4KQ32T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ32T1$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=${sizetocheck}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ32T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GCV}----------\n Random by 4KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        sst
        printf "${GCV}Testing RND4KQ1T1 $z${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=${sizetocheck}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ1T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GCV}----------\n Random by 4KB block queue - 1 queue(s) deep - 1 thread(s) - $z:\n${NCV}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        rm -f testio*
    done

    sst
    printf "${LRV}Summary for $SUMMARY_DEVICE (NOT NVME - $DEVICE_MODEL) at $PWD${NCV}\n" | tee -a $PWD/${RESULTS_FILENAME}
    cat $f | tee -a $PWD/${RESULTS_FILENAME}
    rm -f $f $f1 $f2
    echo
fi

printf "${GCV}\nFull results in file - $PWD/${RESULTS_FILENAME}${NCV}\n"

# Unset variables
unset current_free needfreegb sizetocheck WITHOUT_SLC_CHECK fio_exist GCV LRV NCV FIO_RNDNAME FIO_PRE FIO_POST OPSTYPE f f1 f2 PWD_DEVICE DEVICE_MODEL DEVICE_FIRMWARE IOPS SPEED SUMMARY_DEVICE test_result RESULTS_FILENAME
