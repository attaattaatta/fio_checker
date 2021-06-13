#!/bin/bash

clear;

set -e;

export PATH=$PATH:/usr/sbin:/usr/sbin:/usr/local/sbin;

GCV="\033[0;92m";
LRV="\033[1;91m";
NCV="\033[0m";

#check free space in megabytes
current_free=$(df -Phm --sync . | tail -1 | awk '{print $4}' | grep -o "[[:digit:]|.]*");
space_need=52224
if [ "$current_free" -le "$space_need" ]; then
        printf "${LRV}Free space for $PWD less than 51GB${NCV}";
        sleep 2s;
        exit 1;
fi;

#sst function (sync, sleep, trim)
sst() {
        printf "${GCV}Syncing${NCV}\n";
        sync;
        printf "${GCV}Sleeping${NCV}\n";
        sleep 5s;
        printf "${GCV}Trimming${NCV}\n";
        fstrim $PWD 2> /dev/null || true;
        echo;
}

#parse results function
parse_fio_results() {
	IOPS=$(echo ${!test_result} | grep -o "IOPS=*[[:alnum:]|.]*");
	SPEED=$(echo "${!test_result}" | grep -E "WRITE|READ" | grep -Po "(?<=\().*(?=\))" | sed "s@).*@@gi");
}

#check fio;
fio_exist=$(if ! fio -v ; then printf "${GCV}Installing FIO${NCV}\n" && apt -y install fio || yum -y install fio; fi > /dev/null 2>&1);

#FIO;
FIO_RNDNAME=$(for i in {1..3} ; do echo -n "${RANDOM%${#}:1}"; done);
FIO_PRE="fio --ioengine=libaio --buffered=0 --direct=1 --name=testio$FIO_RNDNAME";
FIO_POST="--group_reporting";

OPSTYPE=(read write randread randwrite);

f=results$FIO_RNDNAME.txt;
> $f;

f1=results_slc$FIO_RNDNAME.txt;
> $f1;

f2=results_noslc$FIO_RNDNAME.txt;
> $f2;

PWD_DEVICE=$(df -P . | sed -n '$s@[[:blank:]].*@@p');

if [[ $PWD_DEVICE == *"md"* ]]; then
        if mdadm -D $PWD_DEVICE | grep -qi "status" ;
                then printf "${LRV} RAID resync or rebuild is in progress. Aborting.${NCV}\n";
                sleep 5s;
                exit 1;
        fi;
PWD_DEVICE=$(mdadm -vQD $PWD_DEVICE | grep -o '/dev/.*'  | sed 's@:@@gi');
fi;

DEVICE_MODEL=$(fdisk -l $(echo $PWD_DEVICE | sed -E 's@p?[[:digit:]]@@g') | sed -n 's@Disk model: @@p' |  sed 's@[ \t]*$@@' | tr '\n' ',' | sed 's@,$@@g');

if [ -z "${DEVICE_MODEL}" ]; then
        DEVICE_MODEL="Unknown";
fi;

SUMMARY_DEVICE=$(echo $PWD_DEVICE | awk '{print $1}');

if [[ $PWD_DEVICE == *"nvme"* ]]; then
        printf "${GCV}Running FIO (NVME device - $DEVICE_MODEL)${NCV}\n";

                #SLC Cache
                #NVME SEQ
                for z in ${OPSTYPE[@]:0:2}; do
                        sst;
                        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}SEQ1MQ8T1 $z${NCV}\n";
                        declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=1G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync);"
                        test_result="SEQ1MQ8T1$z";
                        echo "${!test_result}";

			printf "${GCV}----------\n Sequential by 1MB block queue - 8 thread(s) - 1 operation - $z:\n${NCV}" >> $f1;
			parse_fio_results;
                        echo $IOPS >> $f1;
                        echo "SPEED=$SPEED" >> $f1;

                        sst;
                        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}SEQ128KQ32T1 $z${NCV}\n";
                        declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=1G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync);"
                        test_result="SEQ128KQ32T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n Sequential by 128KB block queue - 32 thread(s) - 1 operation - $z:\n${NCV}" >> $f1;
			parse_fio_results;
                        echo $IOPS >> $f1;
                        echo "SPEED=$SPEED" >> $f1;

                done;

                #SLC Cache
                #NVME RND
                for z in ${OPSTYPE[@]:2:3}; do
                        sst;
                        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}RND4KQ32T16 $z${NCV}\n";
                        declare "RND4KQ32T16$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=1G --rw=$z --numjobs=16 $FIO_POST ; rm -f testio$FIO_RNDNAME*);"
                        test_result="RND4KQ32T16$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n Random by 4KB block queue - 32 thread(s) - 16 operation - $z:\n${NCV}" >> $f1;
			parse_fio_results;
                        echo $IOPS >> $f1;
                        echo "SPEED=$SPEED" >> $f1;

                        sst;
                        printf "${GCV}Testing (${LRV}with SLC cache${NCV}) ${GCV}RND4KQ1T1 $z${NCV}\n";
                        declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=1G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*);"
                        test_result="RND4KQ1T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n  Random by 4KB block queue - 1 thread(s) - 1 operation - $z:\n${NCV}" >> $f1;
			parse_fio_results;
                        echo $IOPS >> $f1;
                        echo "SPEED=$SPEED" >> $f1;

                done;

                #NOT SLC Cache
                #NVME SEQ
                for z in ${OPSTYPE[@]:0:2}; do
                        sst;
                        printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}SEQ1MQ8T1 $z${NCV}\n";
                        declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync);"
                        test_result="SEQ1MQ8T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n Sequential by 1MB block queue - 8 thread(s) - 1 operation - $z:\n${NCV}" >> $f2;
			parse_fio_results;
                        echo $IOPS >> $f2;
                        echo "SPEED=$SPEED" >> $f2;

                        sst;
                        printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}SEQ128KQ32T1 $z${NCV}\n";
                        declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync);"
                        test_result="SEQ128KQ32T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n Sequential by 128KB block queue - 32 thread(s) - 1 operation - $z:\n${NCV}" >> $f2;
			parse_fio_results;
                        echo $IOPS >> $f2;
                        echo "SPEED=$SPEED" >> $f2;

                done;

                #NOT SLC Cache
                #NVME RND
                for z in ${OPSTYPE[@]:2:3}; do
                        sst;
                        printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}RND4KQ32T16 $z${NCV}\n";
                        declare "RND4KQ32T16$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=3G --rw=$z --numjobs=16 $FIO_POST ; rm -f testio$FIO_RNDNAME*);"
                        test_result="RND4KQ32T16$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n Random by 4KB block queue - 32 thread(s) - 16 operation - $z:\n${NCV}" >> $f2;
			parse_fio_results;
                        echo $IOPS >> $f2;
                        echo "SPEED=$SPEED" >> $f2;

                        sst;
                        printf "${GCV}Testing (${LRV}without SLC cache${NCV}) ${GCV}RND4KQ1T1 $z${NCV}\n";
                        declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*);"
                        test_result="RND4KQ1T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n  Random by 4KB block queue - 1 thread(s) - 1 operation - $z:\n${NCV}" >> $f2;
			parse_fio_results;
                        echo $IOPS >> $f2;
                        echo "SPEED=$SPEED" >> $f2;

                done;
        sst;

        printf "${LRV}Summary for $SUMMARY_DEVICE (NO SLC CACHE NVME - $DEVICE_MODEL) at $PWD${NCV}\n";
        cat $f2;
        echo;
        printf "${LRV}Summary for $SUMMARY_DEVICE (SLC CACHE NVME - $DEVICE_MODEL) at $PWD${NCV}\n";
        cat $f1;
        rm -f $f $f1 $f2;
        echo;

else printf "${GCV}Running FIO (${LRV}NOT${GCV} NVME device - $DEVICE_MODEL) ${NCV}\n";

                #NOT_NVME SEQ
                for z in ${OPSTYPE[@]:0:2}; do
                        sst;
                        printf "${GCV}Testing SEQ1MQ8T1 $z${NCV}\n";
                        declare "SEQ1MQ8T1$z=$($FIO_PRE --blocksize=1m --iodepth=8 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync);"
                        test_result="SEQ1MQ8T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n Sequential by 1MB block queue - 8 thread(s) - 1 operation - $z:\n${NCV}" >> $f;
			parse_fio_results;
                        echo $IOPS >> $f;
                        echo "SPEED=$SPEED" >> $f;

                        sst;
                        printf "${GCV}Testing SEQ128KQ32T1 $z${NCV}\n";
                        declare "SEQ128KQ32T1$z=$($FIO_PRE --blocksize=128k --iodepth=32 --size=50G --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*; sync);"
                        test_result="SEQ128KQ32T1$z";
                        echo "${!test_result}";
                        echo;

                        printf "${GCV}----------\n Sequential by 128KB block queue - 32 thread(s) - 1 operation - $z:\n${NCV}" >> $f;
			parse_fio_results;
                        echo $IOPS >> $f;
                        echo "SPEED=$SPEED" >> $f;

                done;

                #NOT_NVME RND
                for z in ${OPSTYPE[@]:2:3}; do
                        sst;
                        printf "${GCV}Testing RND4KQ32T1 $z${NCV}\n";
                        declare "RND4KQ32T1$z=$($FIO_PRE --blocksize=4k --iodepth=32 --size=500M --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*);"
                        test_result="RND4KQ32T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n Random by 4KB block queue - 32 thread(s) - 1 operation - $z:\n${NCV}" >> $f;
			parse_fio_results;
                        echo $IOPS >> $f;
                        echo "SPEED=$SPEED" >> $f;

                        sst;
                        printf "${GCV}Testing RND4KQ1T1 $z${NCV}\n";
                        declare "RND4KQ1T1$z=$($FIO_PRE --blocksize=4k --iodepth=1 --size=500M --rw=$z --numjobs=1 $FIO_POST ; rm -f testio$FIO_RNDNAME*);"
                        test_result="RND4KQ1T1$z";
                        echo "${!test_result}";

                        printf "${GCV}----------\n  Random by 4KB block queue - 1 thread(s) - 1 operation - $z:\n${NCV}" >> $f;
			parse_fio_results;
                        echo $IOPS >> $f;
                        echo "SPEED=$SPEED" >> $f;

                done;

        sst;
        printf "${LRV}Summary for $SUMMARY_DEVICE (NOT NVME - $DEVICE_MODEL) at $PWD${NCV}\n";
        cat $f;
        rm -f $f $f1 $f2;
        echo;
fi;

unset fio_exist GCV LRV NCV FIO_RNDNAME FIO_PRE FIO_POST OPSTYPE f f1 f2 PWD_DEVICE DEVICE_MODEL IOPS SPEED SUMMARY_DEVICE test_result;
