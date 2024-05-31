#!/bin/bash

# IMPORTANT: The below MAY NOT WORK effectively if you're running a
# database (eg. Postgres, MySQL, MongoDB, etc.) or if you're using
# ZFS (how does the ARC cache factor in?  Use htop to view ZFS ARC Cache).
# (Well, at least on LinuxMint, initramfs+tmpfs+ZFS seem to work together OK!)

# NOTE: To enhance this, if the user runs the script without any options,
# check to see if zram swap is enabled or not (lsblk command).
# If Enabled, prompt user if they want to disable and proceed accordingly.
# If Disabled, prompt user if they want to enable and, if yes, prompt
# them for the size.
#
# If size is NOT specified and the user is trying to enable swap on zram,
# determine the recommended size of the zram drive:
#   If RAM <= 8GiB, size=0.90*RAM
#   If RAM > 8GiB, size=8GiB

# To set up one zstd compressed zram device with 8GiB capacity and a 
# higher-than-normal priority (only for the current session):
#   modprobe zram
#   # We may want to use lz4 instead of zstd
#   zramctl /dev/zram0 --algorithm zstd --size 8G
#   mkswap -U clear /dev/zram0
#   echo 0 > /sys/module/zswap/parameters/enabled
#   swapon -d --priority 100 /dev/zram0
#
# To disable it again, either reboot or run:
#   swapoff /dev/zram0
#   modprobe -r zram
#   echo 1 > /sys/module/zswap/parameters/enabled

# set -x

script_name=`basename $0`
default_algorithm=zstd
default_op=status
default_swap_priority=100
default_swap_size=""  # Auto detect
default_vm_swapiness=200  # Aggressive swapping - used for test mode only!
algorithm=$default_algorithm
interactive=false
swap_enabled=false
swap_priority=$default_swap_priority
swap_priority_min=-1
swap_priority_max=32767
swap_size=$default_swap_size  # Auto detect
swap_size_auto=""
swap_size_min=500MiB
swap_size_max=16000MiB  # NOTE: Should never need more than 8GiB of swap
let physmem=0
valid_algorithms=("zstd" "lz4" "lz4hc" "lzo" "deflate" "842")
# NOTE: Do we want to actually test if zram on swap is working correctly?
valid_ops=("status" "enable" "disable" "test")
let verbose=0


function usage()
{
  local algos=""
  for a in ${valid_algorithms[@]}; do algos="${algos} ${a}"; done
  echo """
Usage:  $script_name [-v][-i][-a algorithm][-s size] command
Where:
  -i             Interactive mode.
  -a algorithm   Compression algorithm to use.  Default: zstd
  -p priority    Swap device priority.  Default: $default_swap_priority
  -s size        Size of swap to enable in MiB.
  -v             Verbose mode. Multiple options increase verbosity.

Compression Algorithms:${algos}
Commands:
  status  - Display status of swap on zram.
  enable  - Enable swap on zram.
  disable - Disable swap on zram.
  test    - Test swap on zram is operation [DANGER: Proceed at your own risk!]

The script $script_name is used to enable and disable swap on a zram device.
A zram device, created using zramctl, is a memory device that supports
compression of pages of memory.  By using a zram device for swap, you can
reduce the memory footprint of your system by more efficiently using memory.
And, because the zram swap device is a memory device, it is *much faster* than
a regular swap device hence will have very little impact on performance.

Currently, the following is recommened:
* If system memory < 8GiB, set zram set to 0.90 * system memory.
  * Manually tune this setting if using a database(Postgres) or 
  * caching file system(ZFS).
* If system memory > 8GiB, set zram size to 8GiB.
  * Allocating additional memory to zram device provides no benefit.

Examples:
  $script_name enable
  $script_name -s 12000 enable
  $script_name disable
"""
  exit 1
}


function auto_detect_swap_size()
{
  local _ifs=$IFS
  local pmem size

  let physmem=0
  while IFS=":" read -r a b
  do
    case "$a" in
      MemTotal*) pmem="$b" ;;
    esac
  done <"/proc/meminfo"
  let physmem=${pmem//[^0-9]/}
  if [ $? -ne 0 ]; then
    echo "ERROR: Failed to get physical memory info. Exiting."
    exit 1
  fi
#let physmem=7680000
  if [ $physmem -gt 8192000 ]; then  # 8GB of memory
    #size="8192MiB"  # 8GiB - technically correct.
    size="8000MiB" # 8GiB - technically desired.
  else
    let swapmem=($physmem/1024)*90/100  # MiB
    size="${swapmem}MiB"
  fi
  IFS=$_ifs
  swap_size_auto=$size
  if [ $verbose -gt 0 ]; then
    let swapmem=$physmem/1048576
    echo "Physical Memory: ${swapmem}G"
    echo "Swap(Auto Size): ${swap_size_auto}"
  fi
}


# Determine if swap on zram is enabled
function check_zram_swap_enabled()
{
  swapon | grep /dev/zram > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    swap_enabled=true
  else
    swap_enabled=false
  fi
  if [ $verbose -gt 0 ]; then
    echo "swap_enabled: $swap_enabled"
  fi
}


function fix_swap_size()
{
  # Want to set to proper value with suffix - eg. 8G, 900M,...
  # NOTE: Should never need more than 8GiB of swap on zram.  If 
  # interactive mode is enabled, ask the user to confirm the swap size.
  if [ -z $swap_size ]; then
    swap_size=$swap_size_auto
  else
    if [ $interactive = "true" ]; then
      local answer size usersize
      let size=${swap_size_auto//[^0-9]/}
      let user_size=${swap_size//[^0-9]/}
      if [ $user_size -gt $size ]; then
        echo "Swap size ${user_size}MiB is larger than recommended size ${size}MiB."
        echo "Are you sure you want to continue? [y/N] "
        read answer
        if [ "$answer" = "y" ]; then
          echo "Proceeding with size $swap_size."
        else
          # swap_size=$swap_size_auto
          exit 1
        fi
      fi # else just use the user-specified size
    fi # else just use the user-specified size
  fi

  if [ $verbose -gt 0 ]; then
    echo "Using swap size ${swap_size}."
  fi
}


function verify_algorithm()
{
  local valid=false
  for a in ${valid_algorithms[@]}; do
    if [ $a == $algorithm ]; then valid=true; break; fi
  done
  if [ $verbose -gt 0 ]; then
    if [ $valid = "true" ]; then status="yes."; else status="NOT SUPPORTED!"; fi
    echo "Verifying if algorithm \"$algorithm\" is supported...${status}"
  fi

  if [ $valid = true ]; then return 0; else return -1; fi
}


function verify_op()
{
  local valid=false
  if [ $verbose -gt 3 ]; then echo "Verify operation \"${op}\"...verbose=${verbose}"; fi
  for o in ${valid_ops[@]}; do
    if [ $o == $op ]; then valid=true; break; fi
  done
  if [ $verbose -gt 0 ]; then
    if [ $valid = "true" ]; then status="yes."; else status="NOT SUPPORTED!"; fi
    echo "Verifying if operation \"$op\" is supported...${status}"
  fi

  if [ $valid = true ]; then return 0; else return -1; fi
}


function verify_swap_priority()
{
  valid=false
  if [ $swap_priority -ge $swap_priority_min -a $swap_priority -le $swap_priority_max ]; then
    valid=true
  else
    return 0
  fi
  if [ $verbose -gt 0 ]; then
    if [ $valid = "true" ]; then status="OK"; else status="INVALID"; fi
    echo "Verifying swap priority \"$swap_priority\": $status"
  fi

  if [ $valid = true ]; then return 0; else return -1; fi
}


function verify_swap_size()
{
  local size_min=${swap_size_min//[^0-9]/}
  local size_max=${swap_size_max//[^0-9]/}
  local size=${swap_size//[^0-9]/}
  if [ $size -ge $size_min -a $size -le $size_max ]; then
    return 0
  else
    return -1
  fi
}

function zram_swap_disable()
{
  if [ $swap_enabled = "true" ]; then
    sudo swapoff /dev/zram0
    sudo modprobe -r zram
    sudo sh -c "echo 1 > /sys/module/zswap/parameters/enabled"
    if [ $verbose -gt 0 ]; then
      echo "Swap DISABLED."
    fi
  else
    if [ $verbose -gt 0 ]; then
      echo "Swap is already Disabled. Skipping operation."
    fi
  fi
}


function zram_swap_enable()
{
  if [ $swap_enabled = "false" ]; then
    sudo modprobe zram
    # We may want to use lz4(faster) instead of zstd(compresses better)
    # To zramctl 8000MiB is not the same as 8GiB which is understandable.
    # Consequently, we need this workaround for the desired behavior.
    let size=${swap_size//[^0-9]/}
    if [ $size -gt 1000 ]; then
      let size=${size}/1000
      size="${size}G"
    else
      size=$swap_size
    fi
    sudo zramctl /dev/zram0 --algorithm $algorithm --size $size
    sudo mkswap /dev/zram0
    sudo sh -c "echo 0 > /sys/module/zswap/parameters/enabled"
    sudo swapon -d --priority $swap_priority /dev/zram0
    if [ $verbose -gt 0 ]; then
      echo "Swap ENABLED."
      swapon
      zramctl
    fi
  else
    if [ $verbose -gt 0 ]; then
      echo "Swap is already Enabled. Skipping operation."
    fi
  fi
}


function zram_swap_status()
{
  if [ $swap_enabled = "true" ]; then
    echo "Swap is enabled."
    swapon
    zramctl
  else
    echo "Swap is disabled."
  fi
}


function zram_swap_test()
{
  if [ $swap_enabled = "true" ]; then
    echo "zram_swap_test: ADD CODE HERE!!!"
    exit 1
  else
    if [ $verbose -gt 0 ]; then
      echo "Swap on zram is disabled. Skipping operation."
      exit 1
    fi
  fi
}


OPTSTRING="ia:p:s:hv"

# Now, parse out the various options
while getopts ${OPTSTRING} opt; do
  case ${opt} in
    h)
      usage 0
      ;;
    i)
      interactive=true
      ;;
    a)
      algorithm=${OPTARG}
      verify_algorithm
      if [ $? -ne 0 ]; then 
        echo "Invalid algorithm \"${OPTARG}\"specified...exiting."
        exit 1;
      fi
      ;;
    p)
      let swap_priority=${OPTARG}
      if [ $? -ne 0 ]; then
        # The 'let' failed - couldn't parse as a number
        echo "Invalid swap priority \"${OPTARG}\" specified...exiting."
        exit 1
      fi
      verify_swap_priority
      if [ $? -ne 0 ]; then 
        echo "Invalid swap priority specified [${swap_priority_min} <= swap_priority <= ${swap_priority_max}]...exiting."
        exit 1;
      fi
      if [ $verbose -gt 0 ]; then echo "Swap priority set to \"$swap_priority\""; fi
      ;;
    s)
      swap_size=${OPTARG}
      verify_swap_size
      if [ $? -ne 0 ]; then 
        echo "Invalid swap size ${OPTARG} specified [${swap_size_min} <= size <= ${swap_size_max}]...exiting."
        exit 1;
      fi
      if [ $verbose -gt 0 ]; then echo "Swap size set to \"$swap_size\""; fi
      ;;
    v)
      let verbose=verbose+1
      ;;
    :)
      # Add code here to be really nice to the user?
      echo "Option -${OPTARG} requires an argument."
      exit 1
      ;;
    ?)
      echo "Invalid option: -${OPTARG}."
      exit 1
      ;;
  esac
done

if [ ${OPTIND} -eq $# ]; then
  op="${@: -1}"

  verify_op
  if [ $? -ne 0 ]; then
    if [ $verbose -gt 0 ]; then
      echo "Invalid operation \"$op\" specified...exiting."
      exit 1
    fi
  fi
else
  op="status"
fi

auto_detect_swap_size
check_zram_swap_enabled
fix_swap_size


case ${op} in
  status)
    zram_swap_status
    ;;
  enable)
    zram_swap_enable
    ;;
  disable)
    zram_swap_disable
    ;;
  test)
    zram_swap_test
    ;;
  ?)
    echo "Unknown operation \"${op}\" specified."
    ;;
esac