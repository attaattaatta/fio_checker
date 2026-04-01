#!/bin/bash

# Set paths
export PATH=$PATH:/usr/sbin:/usr/local/sbin

# Clear the terminal
clear

# Define color variables
GC="\033[0;92m"
LR="\033[1;91m"
YC="\033[01;33m"
NC="\033[0m"

# Show script version
self_current_version="1.0.6"
printf "\n${YC}Hello${NC}, my version is ${YC}$self_current_version\n\n${NC}"

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
    printf "\n${LR}ERROR - This script must be run as root.${NC}"
    exit 1
fi

# one instance run lock
LOCKFILE=/run/lock/fiochk.lock
exec 9>$LOCKFILE

if ! flock -n 9; then
    echo
    if command -v lsof >/dev/null 2>&1; then
        PID=$(lsof -t "$LOCKFILE" 2>/dev/null | grep -v "^$$\$" | head -n1)
        printf "%s is ${LR}already locked${NC} by PID %s\n\n" "$LOCKFILE" "$PID"
    elif command -v fuser >/dev/null 2>&1; then
        PID=$(fuser "$LOCKFILE" 2>/dev/null | tr ' ' '\n' | grep -v "^$$\$" | head -n1)
        printf "%s is ${LR}already locked${NC} by PID %s\n\n" "$LOCKFILE" "$PID"
    else
        printf "%s ${LR}already exists${NC}\n\nInstall 'lsof -t' or 'fuser' to see the PID.\n" "$LOCKFILE"
    fi
    exit 1
fi

trap 'exec 9>&-; rm -f "$LOCKFILE"' EXIT

# Check if required tools are installed
WE_NEED=('fio' 'smartctl')

install_tools() {
	command -v apt >/dev/null 2>&1 && { apt -y update && apt -y install fio smartmontools; return; }
	command -v yum >/dev/null 2>&1 && { yum -y install fio smartmontools; return; }
	command -v dnf >/dev/null 2>&1 && { dnf -y install fio smartmontools; return; }
	return 1
}

for needitem in "${WE_NEED[@]}"; do
	command -v "$needitem" >/dev/null 2>&1 && continue

	printf "\n${LR}WARN - $needitem not found. Trying to install...${NC}\n"

	install_tools || {
		printf "\n${LR}ERROR - No supported package manager found. Install $needitem manually.${NC}\n"
		exit 1
	}

	command -v "$needitem" >/dev/null 2>&1 || {
		printf "\n${LR}ERROR - Failed to install $needitem. Please install it manually.${NC}\n"
		exit 1
	}

	printf "${LG}OK - $needitem installed successfully.${NC}\n"
done

# Get the current device
PWD_DEVICE=$(df -P . | sed -n '$s@[[:blank:]].*@@p')

# Check if the device is a RAID
if [[ $PWD_DEVICE == *"md"* ]]; then
    if mdadm -D $PWD_DEVICE | grep -qi "status"; then
        printf "${LR} RAID resync or rebuild is in progress. Aborting.${NC}\n"
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
printf "${GC}Checking free space${NC}\n\n"
current_free=$(df -PhBG --sync . | tail -1 | awk '{print $4}' | grep -o "[[:digit:]|.]*")

printf "${GC}Enter size in GB for run tests.\nThe more the better, to check SLC cache enter minimum 50GB, but it should be free space\nAfter test will finish all temporary files will be removed.${NC}\n"
printf "${GC}\nCurrent free space on the drive I run:${NC} ${current_free}GB\n"

# Function to get size to check in sequential tests
sizetocheck_seq() {
    read -p "Enter one file size in GB should I use in SEQ tests (default 1): " sizetocheck_seq
    sizetocheck_seq=${sizetocheck_seq:-1}
}

# Function to get size to check in random tests
sizetocheck_rand() {
    read -p "Enter one file size in MB should I use in RANDOM tests (default 100): " sizetocheck_rand
    sizetocheck_rand=${sizetocheck_rand:-100}
}

sizetocheck_seq

# Validate input
while ! [[ $sizetocheck_seq =~ ^[0-9]+$ ]]; do
    printf "\n${LR}ERROR - enter only digits${NC}\n"
    sleep 1s
    sizetocheck_seq
done

sizetocheck_rand

while ! [[ $sizetocheck_rand =~ ^[0-9]+$ ]]; do
    printf "\n${LR}ERROR - enter only digits${NC}\n"
    sleep 1s
    sizetocheck_seq
done

needfreegb=$((${sizetocheck_seq}*16))

# Check if there is enough free space
while [[ "$current_free" -le "$needfreegb" ]]; do
    printf "${LR}\nERROR - Free space needed is ${needfreegb}GB ( ${sizetocheck_seq} * numjobs is 16 ) \n${NC}"
    sleep 2s
    sizetocheck_seq
done

# Check if enough space for SLC cache testing
if [[ "$current_free" -gt 51 ]]; then
    WITHOUT_SLC_CHECK=1
else
    printf "\n${YC}Not enough free space for testing over SLC cache\nSkipping no SLC tests\n\n${NC}"
    WITHOUT_SLC_CHECK=0
fi

# Function to sync, sleep, and trim
sst() {
    printf "${GC}Syncing${NC}\n"
    sync
    printf "${GC}Sleeping${NC}\n"
    sleep 5s
    printf "${GC}Trimming${NC}\n"
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
    printf "${GC}Running FIO (NVME device - ${DEVICE_MODEL} / firmware - ${DEVICE_FIRMWARE})${NC}\n"

    # SLC Cache NVME SEQ
    for z in ${OPSTYPE[@]:0:2}; do
        sst
        printf "${GC}Testing (${LR}with SLC cache${NC}) ${GC}SEQ1MQ8T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=${sizetocheck_seq}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ1MQ8T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GC}----------\n Sequential by 1MB block queue - 8 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        sst
        printf "${GC}Testing (${LR}with SLC cache${NC}) ${GC}SEQ128KQ32T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=${sizetocheck_seq}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ128KQ32T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GC}----------\n Sequential by 128KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        rm -f testio*
    done

    # SLC Cache NVME RND
    for z in ${OPSTYPE[@]:2:3}; do
        sst
        printf "${GC}Testing (${LR}with SLC cache${NC}) ${GC}RND4KQ32T16 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ32T16$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=${sizetocheck_rand}M --rw=$z --numjobs=16 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ32T16$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GC}----------\n Random by 4KB block queue - 32 queue(s) deep - 16 thread(s) - $z:\n${NC}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        sst
        printf "${GC}Testing (${LR}with SLC cache${NC}) ${GC}RND4KQ1T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=${sizetocheck_rand}M --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ1T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GC}----------\n  Random by 4KB block queue - 1 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f1
        parse_fio_results
        echo $IOPS >> $f1
        echo "SPEED=$SPEED" >> $f1

        rm -f testio*
    done

    if [[ $WITHOUT_SLC_CHECK == "1" ]]; then
        # NOT SLC Cache NVME SEQ
        for z in ${OPSTYPE[@]:0:2}; do
            sst
            printf "${GC}Testing (${LR}without SLC cache${NC}) ${GC}SEQ1MQ8T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
            declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
            test_result="SEQ1MQ8T1$z"
            echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

            printf "${GC}----------\n Sequential by 1MB block queue - 8 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f2
            parse_fio_results
            echo $IOPS >> $f2
            echo "SPEED=$SPEED" >> $f2

            sst
            printf "${GC}Testing (${LR}without SLC cache${NC}) ${GC}SEQ128KQ32T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
            declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
            test_result="SEQ128KQ32T1$z"
            echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

            printf "${GC}----------\n Sequential by 128KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f2
            parse_fio_results
            echo $IOPS >> $f2
            echo "SPEED=$SPEED" >> $f2

            rm -f testio*
        done
    fi

    sst

    printf "${LR}Summary${NC} for $SUMMARY_DEVICE (NO SLC CACHE NVME - $DEVICE_MODEL) at $PWD\n" | tee -a $PWD/${RESULTS_FILENAME}
    cat $f2 | tee -a $PWD/${RESULTS_FILENAME}
    echo
    printf "${LR}Summary${NC} for $SUMMARY_DEVICE (SLC CACHE NVME - $DEVICE_MODEL) at $PWD\n" | tee -a $PWD/${RESULTS_FILENAME}
    cat $f1 | tee -a $PWD/${RESULTS_FILENAME}
    rm -f $f $f1 $f2
    echo

else
    printf "${GC}Running FIO (${LR}NOT${GC} NVME device - ${DEVICE_MODEL} / firmware - ${DEVICE_FIRMWARE}) ${NC}\n"

    # NOT_NVME SEQ
    for z in ${OPSTYPE[@]:0:2}; do
        sst
        printf "${GC}Testing SEQ1MQ8T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=${sizetocheck_seq}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ1MQ8T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GC}----------\n Sequential by 1MB block queue - 8 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        sst
        printf "${GC}Testing SEQ128KQ32T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=${sizetocheck_seq}G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync)"
        test_result="SEQ128KQ32T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}
        echo

        printf "${GC}----------\n Sequential by 128KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        rm -f testio*
    done

    # NOT_NVME RND
    for z in ${OPSTYPE[@]:2:3}; do
        sst
        printf "${GC}Testing RND4KQ32T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ32T1$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=${sizetocheck_rand}M --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ32T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GC}----------\n Random by 4KB block queue - 32 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        sst
        printf "${GC}Testing RND4KQ1T1 $z${NC}\n" | tee -a $PWD/${RESULTS_FILENAME}
        declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=${sizetocheck_rand}M --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*)"
        test_result="RND4KQ1T1$z"
        echo "${!test_result}" | tee -a $PWD/${RESULTS_FILENAME}

        printf "${GC}----------\n Random by 4KB block queue - 1 queue(s) deep - 1 thread(s) - $z:\n${NC}" >> $f
        parse_fio_results
        echo $IOPS >> $f
        echo "SPEED=$SPEED" >> $f

        rm -f testio*
    done

    sst
    printf "${LR}Summary${NC} for $SUMMARY_DEVICE (NOT NVME - $DEVICE_MODEL) at $PWD\n" | tee -a $PWD/${RESULTS_FILENAME}
    cat $f | tee -a $PWD/${RESULTS_FILENAME}
    rm -f $f $f1 $f2
    echo
fi

printf "\n${GC}Full results${NC} in file - $PWD/${RESULTS_FILENAME}\n"

# Unset variables
unset current_free needfreegb sizetocheck_seq WITHOUT_SLC_CHECK fio_exist GC LR NC FIO_RNDNAME FIO_PRE FIO_POST OPSTYPE f f1 f2 PWD_DEVICE DEVICE_MODEL DEVICE_FIRMWARE IOPS SPEED SUMMARY_DEVICE test_result RESULTS_FILENAME
