#!/bin/bash
# This script is used to create a Linux loop device to host a filesystem.
#
# Command 'create': Create and mount a loop file device
#   eg.  $0 [-l loopfile] [-m mountpt] [-s size] [-t fstype] create
#   eg.  $0 -l /loopfile -s 100 -t fat32 create
# Command 'start': Mounts preexisting loopfile
#   eg.  $0 [-l loopfile] [-m mountpt] [-s size] [-t fstype] start
#   eg.  $0 -l /loopfile -m /mnt/loopfs start
# Command 'stop' : Unmounts loop device and deletes it, keeps loopfile
#   eg.  $0 [-l loopfile] [-m mountpt]  stop
#   eg.  $0 -m /mnt/myloopfs stop   <-- DOES NOT DELETE loop file!
# Command 'delete' : Unmounts loop device, deletes it, and deletes loopfile
#   eg.  $0 [-l loopfile] [-m mountpt] delete
#   eg.  $0 -l /loopfile delete
# Command 'status' : default
#   eg.  $0 [-l loopfile] [-m mountpt] status
#   eg.  $0 -m /mnt/myloopfs status

#set -x

script_name=`basename $0`
default_op=status
default_fstype=ext4
default_loopfile=loopfile
default_mountpt=/mnt/loopfs
op=$default_op
fstype=$default_fstype
has_loopdev=false
has_mountpt=false
loopdev=""    # Determined at runtime using 'losetup' utility. 
loopdev_mountpt=""
loopfile=""
looppath=""   # Full path to loopfile
mountdev=""
mountpt=""
mount_loopfile=""
mount_looppath=""
# Filesystem size in MB
let loopfile_size_min=50
let loopfile_size_max=1000
default_loopfile_size=$loopfile_size_min
loopfile_size=$default_loopfile_size
valid_fstypes=("ext2" "ext3" "ext4" "msdos" "vfat" "xfs")
tune2fs_fstypes=("ext2" "ext3" "ext4")
valid_ops=("status" "create" "delete" "start" "stop")
let verbose=0


function usage()
{
  local fstypes=""
  local statuses=""
  for t in ${valid_fstypes[@]}; do fstypes="${fstypes} ${t}"; done
  for s in ${valid_ops[@]}; do statuses="${statuses} ${s}"; done
  echo "
Usage: $script_name [options] operation
Where:
  -l loopfile     Loop file to use for loop device:  Default: $default_loopfile
  -m mountpoint   Loop file mount point.  Default: $default_mountpt
  -s size_in_mb   Loop file size in megabytes.  Default: $default_loopfile_size
  -t fstype       Type of filesystem.  Default: $default_fstype
  operation       Operation to perform.  Default: $default_op

Operations:${statuses}
Filesystem types are any of the following:
 ${fstypes}
Valid loop file size range is ${loopfile_size_min}MB <= size <= ${loopfile_size_max}MB.

IMPORTANT:
  'create' operation will fail if loopfile already exists or if the target 
  mount point is already in use.
  'delete' operation will fail if mountpoint does not exist or isn't a loopfile. 
  'start' operation will fail if loopfile does not exist or is not a loopfile
  or if the target mount point is already in use.
  'stop' operation will fail if mountpoint does not exist or isn't a loopfile.


Examples:
  $script_name status  # Returns current status of default mount point
  $script_name create  # Creates loop device using defaults.
  $script_name -m /mnt/myloopfs -l /tmp/loopfile -t fat32 -s 100 create
  $script_name delete  # Deletes loop device using default settings.
  $script_name -t msdos -l /tmp/loopfile.msdos start
  $script_name -m /mnt/myloopfs stop
"

  if [ $# -gt 0 ]; then
    exit $1
  else
    exit 1
  fi
}


function verify_fstype()
{
  local valid=false

  for t in ${valid_fstypes[@]}; do
    if [ $t == $fstype ]; then valid=true; break; fi
  done

  if [ $verbose -gt 0 ]; then
    if [ $valid = true ]; then status=VALID; else status=INVALID; fi
    echo "Verifying loop file system type of \"$fstype\"...$status"
  fi

  if [ $valid = true ]; then return 0; else return -1; fi
}


function verify_loopfile()
{
  # NOTE: Loop file does not have to exist.  Juse needs to contain 'loop' in the filename to prevent issues.
  local lf=`basename $loopfile`
  local match=${lf/loop/MaTcHeD}
  if [ "$match" = "$lf" ]; then
    if [ $verbose -gt 0 ]; then echo "User-specified loop file \"$loopfile\" filename does not contain 'loop'."; fi
    echo "Invalid loop file \"$loopfile\". Exiting.";
    exit 1
  else
    if [ $verbose -gt 0 ]; then echo "User-specified loop file \"$loopfile\" is valid..."; fi
  fi
}


function verify_loopfile_size()
{
  local valid=false
  
  # Arbitrarily pick size limit range from 50-1000MB
  if [ $loopfile_size -ge $loopfile_size_min -a $loopfile_size -le $loopfile_size_max ]; then
    valid=true
  fi
  if [ $verbose -gt 0 ]; then
    if [ $valid = true ]; then status=VALID; else status=INVALID; fi
    echo "Verifying loop file size of $loopfile_size MB...$status"
  fi

  if [ $valid = true ]; then return 0; else return -1; fi
}


function verify_mountpt()
{
  # NOTE: Mount point MUST begin with /mnt/
  local mp=${mountpt#"/mnt/"}
  if [ -z "$mp" ]; then
    if [ $verbose -gt 0 ]; then echo "User-specified mount point \"$mountpt\" does not begin with '/mnt/"; fi
    echo "Invalid mount point \"$mountpt\". Exiting.";
    exit 1
  else
    if [ $verbose -gt 2 ]; then echo "User-specified mount point \"$mountpt\" is valid..."; fi
  fi
}


function verify_op()
{
  local valid=false
  if [ $verbose -gt 3 ]; then echo "Verify operation \"${op}\"...verbose=${verbose}"; fi
  for o in ${valid_ops[@]}; do
    if [ $o == $op ]; then valid=true; break; fi
  done
  if [ $verbose -gt 0 ]; then
    if [ $valid = true ]; then status="yes."; else status="NOT SUPPORTED!"; fi
    echo "Verifying if operation \"$op\" is supported...${status}"
  fi

  if [ $valid = true ]; then return 0; else return -1; fi
}


function make_looppath()
{
  # Determine full path to loopfile using realpath utility.
  if [ -z $loopfile ]; then 
    looppath=`/bin/realpath -q $default_loopfile`
  else
    looppath=`/bin/realpath -q $loopfile`
  fi
  if [ $verbose -gt 0 ]; then 
    echo "Loop file path is \"$looppath\"."
  fi
  if [ $? -eq 0 ]; then
    return 0
  else
    echo "Unable to determine real path to \"$loopfile\". Exiting."
    exit 1  #return -1
  fi
}


function find_loopdevice()
{
  # Determine the loop device from the looppath using losetup utility
  # ie.  sudo losetup | grep $looppath | cut -d' ' -f1
  local rv=-1
  has_loopdev=false
  make_looppath
  if [ $? -eq 0 ]; then
    local ldev=`sudo losetup | grep $looppath | cut -d' ' -f1`
    if [ $? -eq 0 ]; then
      if [ ! -z "$ldev" ]; then
        # Double check that mountpoint's device matches the loop device if it exists.
        if [ -z "$loopdev" -o "$loopdev" = "$ldev" ]; then
          has_loopdev=true
          loopdev=$ldev
          # Now try to find the mountpoint, if any...
          echo "sudo mount | grep $ldev | cut -d' ' -f3"
          local mp=`sudo mount | grep $ldev | cut -d' ' -f3`
          if [ $? -eq 0 ]; then
            loopdev_mountpt=$mp
          else
            if [ $verbose -gt 0 ]; then
              echo "Unable to find mountpoint for loop device \"$ldev\". Exiting."
              exit 1  # Hard exit
            fi
          fi
          rv=0
        else
          # mountpoint's device and loop device do not match!
          echo "Mountpoint \"$mountpt\" mounted on \"$loopdev\" does not match $ldev!  Exiting."
          exit 1  # Hard exit due to conflict
        fi
      else
        rv=0  # No loop device found.
      fi
    else
      rv=0  # No loop device found
    fi
    if [ -z "$loopdev" ]; then
      loopdev=`sudo losetup -f`
      if [ $? -ne 0 ]; then
        echo "Unable to determine next available loop device. Exiting."
        exit 1  # Hard exit due to failure
      fi
    fi
  fi
  if [ $verbose -gt 0 -a $rv -eq 0 -a $has_loopdev = true ]; then
    echo "Mountpoint \"$loopdev_mountpt\" mounted on \"$loopdev\"."
  fi
  return $rv
}


# mount | grep /dev/loop0 | cut -d' ' -f3
# OR
# mount | grep /mnt/loopfs | cut -d' ' -f1

function has_mountpoint()
{
  # Determine if loopdev exists for the specified mount point
  # mount | grep $mountpt | cut -d' ' -f1
  local rv=-1

  has_mountpt=false
  if [ -z $mountpt ]; then 
    mountdev=`mount | grep $default_mountpt | cut -d' ' -f1`
  else
    mountdev=`mount | grep $mountpt | cut -d' ' -f1`
  fi
  if [ $? -eq 0 ]; then
    if [ ! -z $mountdev ]; then
      has_mountpt=true;
      if [ -z $mountpt ]; then mountpt=$default_mountpt; fi
      # sudo losetup -nl -OBACK-FILE /dev/loop0
      local out=`sudo losetup -nl -OBACK-FILE $mountdev`
      if [ $? -eq 0 ]; then
        mount_loopfile=$out
        mount_looppath=$mount_loopfile
      else
        # mountpoint is not a loop device
        echo "Mountpoint \"$mountpt\" is not a loop device!  Exiting."
        exit 1  # Hard exit due to conflict
      fi
      rv=0
    else
      rv=0  # No mount device detected - return 0.
    fi
  else
    rv=0  # No mount point detected so has_mountpt=false, return 0``
  fi
  if [ $verbose -gt 3 ]; then
    echo "has_mountpoint: has_mountpt=$has_mountpt, return:$rv";
  fi
  return $rv
}


function has_loopfile()
{
  local rv=-1
  if [ ! -z $loopfile ]; then
    make_looppath
    if [ $? -eq 0 -a -f $looppath ]; then
      rv = 0
    fi
    if [ $verbose -gt 0 ]; then
      local status=""
      if [ $rv -eq 0 ]; then status="true"; else status="false"; fi
      echo "has_loopfile=$status";
    fi
  fi

  return $rv
}


# Get the filesystem type from mountpoint using `mount | grep $mountpt | cut -d' ' -f5`
function get_fstype()
{
  local _fstype=`mount | grep $mountpt | cut -d' ' -f5`
  if [ $? -eq 0 ]; then
    fstype=$_fstype
    return 0
  else
    return -1
  fi
}


function use_tune2fs()
{
  local valid=false
  get_fstype
  if [ $? -eq 0 ]; then
    echo "use_tune2fs: $fstype"
    for t in ${tune2fs_fstypes[@]}; do
      if [ "$t" = "$fstype" ]; then valid=true; break; fi
    done
    if [ $verbose -gt 0 ]; then
      local status=""
      if [ $valid = true ]; then status="yes"; else status="SKIP"; fi
      echo "Use tune2fs on loop device file system type of \"$fstype\"...$status"
    fi
  fi
  if [ $valid = true ]; then return 0; else return -1; fi
}


function mount_loopdevice()
{
  # Mount loop device
  if [ ! -d "$mountpt" ]; then
    if [ -e "$mountpt" ]; then
      echo "Mount point \"$mountpt\" is not a directory. Exiting."
      exit 1  # Hard exit due to failure
    else
      sudo mkdir "$mountpt" >/dev/null
      if [ $? -eq 0 ]; then
        if [ $verbose -gt 0 ]; then
          echo "Successfully created directory \"$mountpt\" to be used for mount point."
        fi
      else
        echo "Failing creating directory \"$mountpt\". Exiting."
        exit 1 # Hard exit due to failure
      fi
    fi
  fi
  sudo mount -t "$fstype" "$loopdev" "$mountpt"  # >/dev/null
  if [ $? -ne 0 ]; then
    echo "Failed mounting loop file \"$loopath\"($loopdev) on \"mountpt\"($fstype). Exiting."
    exit 1  # Hard exit due to failure
  fi
  if [ $verbose -gt 0 ]; then echo "Mountpoint \"$mountpt\" created."; fi
}


function loopfile_status()
{
  local do_status=false

  # Check for user-specified mountpoint first...
  if [ ! -z "$mountpt" ]; then 
    echo "Checking for user-specified mountpoint..."
    has_mountpoint
    if [ $? -eq 0 ]; then
      if [ $has_mountpt = true ]; then 
        # NOTE: At this point, we have the mountdev, mount_loopfile, and mount_looppath.
        loopdev=$mountdev
        if [ -z "$loopfile" ]; then
          loopfile=$mount_loopfile
          looppath=$mount_looppath
          do_status=true
        else
          make_looppath
          if [ $? -eq 0 ]; then
            if [ "$looppath" != "$mount_looppath" ]; then
              echo "Loop file path \"$looppath\" does not match \"$mount_looppath\". Exiting."
              exit 1  # Hard exit due to conflict
            fi
            # NOTE: This point, we have the loopdev, loopfile, and looppath.
            do_status=true
          else
            exit 1  # make_looppath failed
          fi
        fi
      else
        if [ $verbose -gt 0 ]; then
          echo "User-specified mountpoint \"$mountpt\" does not exist.  Exiting."
        fi
        exit 1  # Hard exit due to user error
      fi
    else
      exit 1  # has_mountpoint call failed.
    fi
  fi

  # Next, check for user-specified loop file...
  if [ $do_status = false -a "$loopfile" != "" ]; then
    find_loopdevice
    if [ $? -eq 0 ]; then
      if [ $has_loopdev = true ]; then 
        do_status=true
        if [ -z "$mountpt" -a "$loopdev_mountpt" != "" ]; then 
          mountpt=$loopdev_mountpt
        fi
        # NOTE: At this point, we already have the loopdev, looppath, and mountpoint
      else
        echo "Unable to find loop device for \"$loopfile\". Exiting."
        exit 1
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "User-specified loopfile \"$loopfile\" does not exist.  Exiting."
      fi
      exit 1  # Hard exit due to user error
    fi
  fi

  # Next, check for default mount point.  If this doesn't work, then there's no matching loop device.
  if [ $do_status = false ]; then
    # Now try to determine loop device from default mountpoint
    if [ -z $mountpt ]; then
      mountpt=$default_mountpt
      if [ $verbose -gt 0 ]; then echo "Using default mount point \"$mountpt\""; fi
    fi
    has_mountpoint
    if [ $? -eq 0 ]; then
      if [ $has_mountpt = true ]; then 
        do_status=true
        loopdev=$mountdev
        loopfile=$mount_loopfile
        looppath=$mount_looppath
        # NOTE: At this point, we already have the loopdev, loopfile, and looppath.
      else
        if [ $verbose -gt 0 ]; then
          echo "Unble to determine loop device from default mountpoint. Exiting."
        fi
        exit 1
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "Mountpoint \"$mountpt\" does not exist.  Exiting."
      fi
      exit 1  # Hard exit due to user error
    fi
  fi

  if [ $do_status = true ]; then
    sudo df -h $looppath
    use_tune2fs
    if [ $? -eq 0 ]; then
      sudo tune2fs -l $loopdev   # Does not work for non-ext file systems
    fi
  else
    echo "Loop device: $loopdev doesn't exist"
  fi
}


function loopfile_create()
{
  # Check for user-specified mountpoint first...
  if [ ! -z "$mountpt" ]; then 
    has_mountpoint
    if [ $? -eq 0 -a $has_mountpt = true ]; then 
      echo "User-specifed mount \"$mountpt\" already in use.  Exiting."
      exit 1  # Hard exit due to user error
    else
      if [ $verbose -gt 0 ]; then
        echo "User-specified mountpoint \"$mountpt\" does not exist..."
      fi
    fi
  fi

  # Next, check for user-specified loop file...
  if [ ! -z "$loopfile" ]; then
    has_loopfile
    if [ $? -eq 0 ]; then 
      echo "User-specified loop file \"$loopfile\" already exists. Exiting."
      exit 1  # Hard exit due to user error
    else
      if [ $verbose -gt 0 ]; then
        echo "User-specified loop file \"$loopfile\" does not exist..."
      fi
    fi
  fi

  if [ -z "$mountpt" ]; then
    mountpt=$default_mountpt
    if [ $verbose -gt 0 ]; then
      echo "Using default mountpoint \"$mountpt\"..."
    fi
  fi

  # NOTE: At this point, the loop file doesn't exist and the mount point is availabe.
  # Use dd command to create the loop file, trusting that the loop file size is already vetted.
  find_loopdevice
  if [ $? -eq 0 ]; then
    # Add check for available space on the file system?
    # Create loopfile...
    sudo dd if=/dev/zero of=$looppath bs=1M count=$loopfile_size #> /dev/null
    if [ $? -eq 0 ]; then
      if [ $verbose -gt 0 ]; then echo "Loop file \"$looppath\" created."; fi
    else
      echo "Failed creating file \"$looppath\". Exiting."
      exit 1  # Hard exit due to failure
    fi
    # Create loop device using loop file...
    echo "sudo losetup $loopdev $looppath"
    sudo losetup $loopdev $looppath  #>/dev/null
    if [ $? -eq 0 ]; then
      if [ $verbose -gt 0 ]; then
        echo "Successfully created loop device \"$loopdev\" using loop file \"$looppath\"."
      fi
    else
      echo "Failed creating loop device \"$loopdev\". Exiting."
      sudo rm -f $looppath >/dev/null
      #echo "rm -f $looppath [SKIPPED]"
      exit 1  # Hard exit due to failure
    fi
    # Create file system on loop device
    sudo mkfs -t $fstype $loopdev #>/dev/null
    if [ $? -eq 0 ]; then
      if [ $verbose -gt 0 ]; then echo "File system type \"$fstype\" create on \"$loopdev\"."; fi
    else
      echo "Failed creating file system \"$fstype\" on loop device \"$loopdev\". Exiting."
      exit 1  # Hard exit due to failure
    fi
    mount_loopdevice
    if [ $? -eq 0 ]; then
      sudo df -h $mountpt
      use_tune2fs
      if [ $? -eq 0 ]; then
        sudo tune2fs -l $loopdev   # Does not work for non-ext file systems
      fi
    else
      exit 1 # Hard exit due to failure
    fi
  else
    echo "find_loopdevice returned ${?}. Exiting."
    exit 1  # Hard exit due to failure
  fi
}


function loopfile_delete()
{
  local do_delete=false

  # Check for user-specified mountpoint first...
  if [ ! -z "$mountpt" ]; then 
    has_mountpoint
    if [ $? -eq 0 ]; then
      if [ $has_mountpt = true ]; then 
        do_delete=true
        loopdev=$mountdev
        loopfile=$mount_loopfile
        looppath=$mount_looppath
      else
        echo "User-specified mountpoint \"$mountpt\" does not exist. Exiting..."
        exit 1  # Hard exit due to user error
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "has_mountpoint returned ${?}. Exiting."
      fi
      exit 1
    fi
  fi

  # Next, check for user-specified loop file...
  if [ $do_delete = false -a "$loopfile" != "" ]; then
    find_loopdevice
    if [ $? -eq 0 ]; then
      if [ $has_loopdev = true ]; then 
        do_delete=true
        if [ -z "$mountpt" -a "$loopdev_mountpt" != "" ]; then
          mountpt=$loopdev_mountpt
          if [ $verbose -gt 0 ]; then
            echo "Using existing mount point \"$mountpt\" to unmount loop device \"$loopdev\"."
          fi
        fi
        # NOTE: At this point, we already have the loopdev, looppath, and mountpoint
      else
        echo "User-specified loopfile \"$loopfile\" does not exist. Exiting..."
        exit 1  # Hard exit due to user error
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "find_loopdevice returned ${?}. Exiting."
      fi
      exit 1  # Hard exit due to user error
    fi
  fi

  # Next, check for default mount point.  If this doesn't work, then there's no matching loop device.
  if [ $do_delete = false ]; then
    # Now try to determine loop device from default mountpoint
    if [ -z $mountpt ]; then
      mountpt=$default_mountpt;
      if [ $verbose -gt 0 ]; then echo "Using default mount point \"$mountpt\""; fi
    fi
    has_mountpoint
    if [ $? -eq 0 ]; then
      if [ $has_mountpt = true ]; then 
        do_delete=true
        loopdev=$mountdev
        loopfile=$mount_loopfile
        looppath=$mount_looppath
      else
        echo "Unable to determine loop device from default mountpoint. Exiting..."
        exit 1
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "User-specified mountpoint \"$mountpt\" does not exist.  Exiting."
      fi
      exit 1  # Hard exit due to user error
    fi
  fi

  if [ $do_delete = true ]; then
    sudo umount $mountpt  #>/dev/null
    if [ $? -ne 0 ]; then
      echo "Unable to unmount \"$mountpt\". Exiting."
      exit 1  # Hard exit due to failure
    fi
    sudo losetup -d $loopdev #>/dev/null
    if [ $? -ne 0 ]; then
      echo "Unable to detach loop device \"$loopdev\". Exiting."
      exit 1  # Hard exit due to failure
    fi
    #echo "rm -f $looppath [SKIPPING]" 
    sudo rm -f $looppath #> /dev/null
    if [ $? -ne 0 ]; then
      echo "Unable to remove loop file \"$looppath\". Exiting."
      exit 1  # Hard exit due to failure
    fi
  else
    echo "Unable to delete loop device: \"$loopdev\" doesn't exist"
  fi
}


function loopfile_start()
{
  # Check for user-specified mountpoint first...
  if [ ! -z $mountpt ]; then 
    has_mountpoint
    if [ $? -eq 0 ]; then
      if [ $has_mountpt = true ]; then 
        if [ $verbose -gt 0 ]; then
          echo "User-specified mountpoint \"$mountpt\" already exists. Exiting."
        fi
        exit 1  # Hard exit due to user error - mountpoint in use already
      else
        if [ $verbose -gt 0 ]; then
          echo "User-specified mountpoint \"$mountpt\" doesn't exist..." # Good!
        fi
        # Continue with operation...
      fi
    else
      echo "has_mountpoint returned ${?}. Exiting."
      exit 1  # Hard exit due to failure
    fi
  fi

  # Next, check for user-specified loop file...
  if [ ! -z "$loopfile" ]; then
    find_loopdevice
    if [ $? -eq 0 ]; then
      if [ $has_loopdev = true ]; then 
        # NOTE: There is already a loop device, exit immediately
        if [ $verbose -gt 0 ]; then
          echo "Loop device already exists for \"$looppath\". Exiting."
        fi
        exit 1  # Hard exit due to user error - loop device already exists
      else
        # NOTE: Loop device doesn't exist...check that loop file exists...
        if [ -f "$looppath" ]; then
          # NOTE: Loop file exists...proceed.
          if [ $verbose -gt 0 ]; then
            echo "User-specified loop file \"$looppath\" exists..."
          fi
          # No loop device, determine what it will be...
          loopdev=`sudo losetup -f`
          if [ $? -ne 0 ]; then
            echo "Failed determining next loop device. Exiting."
            exit 1 # Hard exit due to failure
          fi
          # Continue with operation...
        else
          if [ $verbose -gt 0 ]; then
            echo "User-specified loop file \"$looppath\" does not exist. Exiting."
          fi
          exit 1  # Hard exit due to user error - loop file does not exist.
        fi
      fi
    # else no loop device - Good! Continue with operation...
    fi
  fi

  # Next, check for default mount point.  If this doesn't work, then there's no matching loop device.
  if [ -z $mountpt ]; then
    # Now try to determine loop device from default mountpoint
    mountpt=$default_mountpt
    has_mountpoint
    if [ $? -eq 0 ]; then 
      if [ $has_mountpt = true ]; then 
        if [ $verbose -gt 0 ]; then
          echo "Default mountpoint \"$mountpt\" already exists. Exiting."
        fi
        exit 1  # Hard exit due to user error
      else
        if [ $verbose -gt 0 ]; then
          echo "Default mountpoint \"$mountpt\" doesn't exist..." # Good!
        fi
        # Continue with operation...
      fi
    # else no default mountpoint - Good!  We can continue.
    fi
  fi

  # Now, verify that we have the default loop file...
  if [ -z $loopfile ]; then
    find_loopdevice
    if [ $? -eq 0 ]; then
      if [ $has_loopdev = true ]; then
        echo "Loop file \"$loopfile\" already in use. Exiting."
        exit 1  # Hard exit due to user error
      else
        if [ $verbose -gt 0 ]; then
          echo "Using loop device \"$loopdev\"..."
        fi
        # Continue with operation...
      fi
    else 
      echo "find_loopdevice returned ${?}. Exiting."
      exit 1  # Hard exit due to failure
    fi
  fi

  if [ ! -f "$looppath" ]; then
    echo "Loop file \"$looppath\" does not exist. Exiting."
    exit 1  # Hard exit due to failure
  fi

  if [ has_mountpt = true ]; then
    echo "Mountpoint \"$mountpt\" already exists. Exiting."
    exit 1  # Hard exit due to user error
  fi

  # All right.  If got here, we're good to go.
  sudo losetup $loopdev $looppath #>/dev/null
  if [ $? -eq 0 ]; then
    # Loop file is already assumed to have file system
    # Mount the loop device...
    mount_loopdevice
    if [ $? -eq 0 ]; then
      sudo df -h $mountpt
      use_tune2fs
      if [ $? -eq 0 ]; then
        sudo tune2fs -l $loopdev   # Does not work for non-ext file systems
      fi
    else
      exit 1 # Hard exit due to failure
    fi
  else
    echo "Failed creating loop device \"$loopdev\". Exiting."
    exit 1 # Hard exit due to failure
  fi
}


function loopfile_stop()
{
  local do_stop=false

  # Check for user-specified mountpoint first...
  if [ ! -z $mountpt ]; then 
    has_mountpoint
    if [ $? -eq 0 ]; then
      if [ $has_mountpt = true ]; then 
        do_stop=true
        loopdev=$mountdev
        loopfile=$mount_loopfile
        looppath=$mount_looppath
      else
        echo "User-specified mountpoint \"$mountpt\" does not exist. Exiting..."
        exit 1  # Hard exit due to user error
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "has_mountpoint returned ${?}. Exiting."
      fi
      exit 1
    fi
  fi

  # Next, check for user-specified loop fil`e...
  if [ $do_stop = false -a "$loopfile" != "" ]; then
    find_loopdevice
    if [ $? -eq 0 ]; then
      if [ $has_loopdev = true ]; then 
        do_stop=true
        if [ -z "$mountpt" -a "$loopdev_mountpt" != "" ]; then
          mountpt=$loopdev_mountpt
          if [ $verbose -gt 0 ]; then
            echo "Using existing mount point \"$mountpt\" to unmount loop device \"$loopdev\"."
          fi
        fi
        # NOTE: At this point, we already have the loopdev, looppath, and mountpoint
      else
        echo "User-specified loopfile \"$loopfile\" does not exist. Exiting..."
        exit 1  # Hard exit due to user error
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "find_loopdevice return ${?}. Exiting."
      fi
      exit 1  # Hard exit due to user error
    fi
  fi

  # Next, check for default mount point.  If this doesn't work, then there's no matching loop device.
  if [ $do_stop = false ]; then
    # Now try to determine loop device from default mountpoint
    has_mountpoint
    if [ $? -eq 0 ]; then
      if [ $has_mountpt = true ]; then 
        do_stop=true
        loopdev=$mountdev
        loopfile=$mount_loopfile
        looppath=$mount_looppath
      else
        echo "Unable to determine loop device from default mountpoint. Exiting..."
        exit 1
      fi
    else
      if [ $verbose -gt 0 ]; then
        echo "User-specified mountpoint \"$mountpt\" does not exist.  Exiting."
      fi
      exit 1  # Hard exit due to user error
    fi
  fi

  if [ $do_stop = true ]; then
    # NOTE: Only unmount the loop device if it is currently mounted.
    if [ ! -z "$mountpt" ]; then
      sudo umount $mountpt  >/dev/null
      if [ $? -eq 0 ]; then
        if [ $verbose -gt 0 ]; then
          echo "Successfully unmounted loop file \"$looppath\" on \"$mountpt\"."
        fi
      else
        exit 1 # Hard exit due to failure
      fi
    fi
    sudo losetup -d $loopdev #>/dev/null
  else
    echo "Unable to delete loop device: \"$loopdev\" doesn't exist"
  fi
}

OPTSTRING=":l:m:s:t:hv"

# Now, parse out the various options
while getopts ${OPTSTRING} opt; do
  case ${opt} in
    h)
      usage 0
      ;;
    l)
      loopfile=`/bin/realpath -q ${OPTARG}`
      if [ $? -eq 0 ]; then 
        verify_loopfile 
        if [ $verbose -gt 0 ]; then echo "Loop file set to \"$loopfile\""; fi
      else
        echo "Invalid loop file \"${OPTARG}\" specified...exiting."
        exit 1
      fi
      ;;
    m)
      mountpt=`/bin/realpath -q ${OPTARG}`
      if [ $? -eq 0 ]; then
        verify_mountpt
        if [ $verbose -gt 0 ]; then echo "Mount point set to \"$mountpt\""; fi
      else
        echo "Invalid mount point \"${OPTARG}\" specified...exiting."
        exit 1
      fi
      ;;
    s)
      let loopfile_size=${OPTARG}
      if [ $? -ne 0 ]; then
        # The 'let' failed - couldn't parse as a number
        echo "Invalid loop file size \"${OPTARG}\" specified...exiting."
        exit 1
      fi
      verify_loopfile_size
      if [ $? -ne 0 ]; then 
        echo "Invalid loop file size ${OPTARG}MB specified [${loopfile_size_min}MB <= size <= ${loopfile_size_max}MB]...exiting."
        exit 1;
      fi
      if [ $verbose -gt 0 ]; then echo "Loop file size set to \"$loopfile_size MB\""; fi
      ;;
    t)
      fstype=${OPTARG}
      verify_fstype
      if [ $? -ne 0 ]; then
        echo "Invalid loop file system type \"$fstype\" specified...exiting."
        exit 1;
      fi
      if [ $verbose -gt 0 ]; then echo "Loop file system type set to \"$fstype\""; fi
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
fi

case ${op} in
  status)
    loopfile_status
    ;;
  create)
    loopfile_create
    ;;
  delete)
    loopfile_delete
    ;;
  start)
    loopfile_start
    ;;
  stop)
    loopfile_stop
    ;;
  ?)
    echo "Unknown operation \"${op}\" specified."
    ;;
esac
