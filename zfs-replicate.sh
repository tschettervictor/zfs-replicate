#!/usr/bin/env bash
## zfs-replicate.sh

############################################
##### warning gremlins live below here #####
############################################

## check log count and delete old
check_old_log() {
    ## declare log array
    declare -a logs=()
    ## initialize index
    local index=0
    ## find existing logs
    for log in $(${FIND} ${LOGBASE} -maxdepth 1 -type f -name autorep-\*); do
        ## get file change time via stat (platform specific)
        case "$(uname -s)" in
            Linux|SunOS)
                local fstat=$(stat -c %Z ${log})
            ;;
            *)
                local fstat=$(stat -f %c ${log})
            ;;
        esac
        ## append logs to array with creation time
        logs[$index]="${fstat}\t${log}\n"
        ## increase index
        let "index += 1"
    done
    ## set log count
    local lcount=${#logs[@]}
    ## check count ... if greater than keep loop and delete
    if [ $lcount -gt ${LOG_KEEP} ]; then
        ## build new array in descending age order and reset index
        declare -a slogs=(); local index=0
        ## loop through existing array
        for log in $(echo -e ${logs[@]:0} | sort -rn | cut -f2); do
            ## append log to array
            slogs[$index]=${log}
            ## increase index
            let "index += 1"
        done
        ## delete excess logs
        printf "deleting old logs: %s ...\n" "${slogs[@]:${LOG_KEEP}}"
        rm -rf ${slogs[@]:${LOG_KEEP}}
    fi
}

## exit 0 and delete old log files
exit_clean () {
    ## print errors
    if [ "${1}x" != "x" ] && [ ${1} != 0 ]; then
        printf "Last operation returned error code: %s\n" "${1}"
    fi
    ## check log files
    check_old_log
    clear_lock "${LOGBASE}"/.push.lock
    clear_lock "${LOGBASE}"/.pull.lock
    clear_lock "${LOGBASE}"/.snapshot.lock
    ## always exit 0
    printf "SUCCESS\n"
    exit 0 
}

exit_error () {
    ## print errors
    if [ "${1}x" != "x" ] && [ ${1} != 0 ]; then
        printf "Last operation returned error code: %s\n" "${1}"
    fi
    ## check log files
    check_old_log
    clear_lock "${LOGBASE}"/.push.lock
    clear_lock "${LOGBASE}"/.pull.lock
    clear_lock "${LOGBASE}"/.snapshot.lock
    printf "FAILED\n"
    exit 0
}

## lockfile creation and maintenance
check_lock() {
    ## check our lockfile status
    if [ -f "${1}" ]; then
        ## get lockfile contents
        local lpid=$(cat "${1}")
        ## see if this pid is still running
        local ps=$(ps auxww|grep $lpid|grep -v grep)
        if [ "${ps}x" != 'x' ]; then
            ## looks like it's still running
            printf "ERROR: This script is already running as: %s\n" "${ps}"
        else
            ## well the lockfile is there...stale?
            printf "ERROR: Lockfile exists: %s\n" "${1}"
            printf "However, the contents do not match any "
            printf "currently running process...stale lockfile?\n"
        fi
        ## tell em what to do...
        printf "To run script please delete: %s\n" "${1}"
        ## compress log and exit...
        exit_error
    else
        ## well no lockfile..let's make a new one
        printf "Creating lockfile: %s\n" "${1}"
        echo $$ > "${1}"
    fi
}

## delete lockfiles
clear_lock() {
    ## delete lockfiles...and that's all we do here
    if [ -f "${1}" ]; then
        printf "Deleting lockfile: %s\n" "${1}"
        rm "${1}"
    fi
}

## check remote system health
check_remote() {
    ## do we have a remote check defined
    if [ "${REMOTE_CHECK}x" != 'x' ]; then
        ## run the check
        $REMOTE_CHECK > /dev/null 2>&1
        ## exit if above returned non-zero
        if [ $? != 0 ]; then
            printf "ERROR: Remote health check '%s' failed!\n" "${REMOTE_CHECK}"
            exit_error
        fi
    fi
}

## push replication function
do_push() {
    ## check our push lockfile
    check_lock "${LOGBASE}/.push.lock"
    ## create initial push command based on arguments
    ## if first snapname is NULL we do not generate an inremental
    local source_snap="$($ZFS list -t snapshot -o name | grep autorep- | awk -F'@' '{print $2}' | tail -n 2 | head -n 1)"
    local dest_snap="$(ssh ${REMOTE_SERVER} $ZFS list -t snapshot -o name | grep autorep- | awk -F'@' '{print $2}' | tail -n 1)"
    if [ "${1}" = "NULL" ]; then
        local pushargs="-R"
    elif [ "${dest_snap}" == "${source_snap}" ]; then
        local pushargs="-R -I ${1}"
    else
	printf "Replication is set to do incrmental replication, but no commmon snapshots\n"
	printf "have been found. Please delete all snapshots from the source and destination\n"
	printf "and try running the script again. Be warned, this will reinitiate the replication\n"
	exit_error
    fi		
    printf "Sending snapshots...\n"
    printf "RUNNING: %s %s %s | %s %s\n" "${SEND_PIPE}" "${pushargs}" "${2}" "${RECEIVE_PIPE}" "${3}"
    if ! ${SEND_PIPE} ${pushargs} ${2} | ${RECEIVE_PIPE} ${3}; then
        exit_error
    fi
    ## get status
    local push_status=$?
    ## clear lockfile
    clear_lock "${LOGBASE}/.push.lock"
    ## return status
    return ${push_status}
}

# pull replication function
do_pull() {
    ## check our pull lockfile
    check_lock "${LOGBASE}/.pull.lock"
    ## create initial receive command based on arguments
    ## if first snapname is NULL we do not generate an inremental
    local source_snap="$(ssh ${REMOTE_SERVER} $ZFS list -t snapshot -o name | grep autorep- | awk -F'@' '{print $2}' | tail -n 2 | head -n 1)"
    local dest_snap="$($ZFS list -t snapshot -o name | grep autorep- | awk -F'@' '{print $2}' | tail -n 1)"
    if [ "${1}" == "NULL" ]; then
        local pullargs="-R"
    elif [ "${dest_snap}" == "${source_snap}" ]; then
	local pullargs="-R -I ${1}"
    else
	printf "Replication is set to do incrmental replication, but no commmon snapshots\n"
	printf "have been found. Please delete all snapshots from the source and destination\n"
	printf "and try running the script again. Be warned, this will reinitiate the replication\n"
	exit_error
    fi
    printf "Sending snapshots...\n"
    printf "RUNNING: %s %s %s | %s %s\n" "${SEND_PIPE}" "${pullargs}" "${2}" "${RECEIVE_PIPE}" "${3}"
    if ! ${SEND_PIPE} ${pullargs} ${2} | ${RECEIVE_PIPE} ${3}; then
        exit_error
    fi
    ## get status
    local pull_status=$?
    ## clear lockfile
    clear_lock "${LOGBASE}/.pull.lock"
    ## return status
    return ${pull_status}
}

## small wrapper around zfs destroy
do_destroy() {
    ## get file set argument
    local snapshot="${1}"
    ## check settings
    if [ $RECURSE_CHILDREN -ne 1 ]; then
        local destroyargs=""
    else
        local destroyargs="-r"
    fi
    ## call zfs destroy
    if [ ${MODE} = PUSH ]; then
        ${ZFS} destroy ${destroyargs} ${snapshot}
    elif [ ${MODE} = PULL ]; then
        ssh ${REMOTE_SERVER} ${ZFS} destroy ${destroyargs} ${snapshot}
    fi
}

## create and manage our zfs snapshots
do_snap() {
    ## make sure we aren't ever creating simultaneous snapshots
    check_lock "${LOGBASE}/.snapshot.lock"
    ## set our snap name
    local sname="autorep-${NAMETAG}"
    ## generate snapshot list and cleanup old snapshots
    for foo in $REPLICATE_SETS; do
        ## split dataset into local and remote parts and trim trailing slashes
        local local_set=$(echo $foo|cut -f1 -d:|sed 's/\/*$//')
        local remote_set=$(echo $foo|cut -f2 -d:|sed 's/\/*$//')
        ## check for root datasets
        if [ $ALLOW_ROOT_DATASETS -ne 1 ]; then
            if [ "${local_set}" == $(basename "${local_set}") ] && \
                [ "${remote_set}" == $(basename "${remote_set}") ]; then
                printf "WARNING: Replicating root datasets can lead to data loss.\n"
                printf "To allow root dataset replication and disable this warning "
                printf "set ALLOW_ROOT_DATASETS=1 in this script.  Skipping: %s\n\n" "${foo}"
                ## skip this set
                continue
            fi
        fi
        ## get current existing snapshots that look like
        ## they were made by this script
        if [ ${MODE} = PUSH ]; then
            if [ $RECURSE_CHILDREN -ne 1 ]; then
                local temps=$($ZFS list -Hr -o name -s creation -t snapshot -d 1 ${local_set}|\
                    grep "${local_set}\@autorep-")
            else
                local temps=$($ZFS list -Hr -o name -s creation -t snapshot ${local_set}|\
                    grep "${local_set}\@autorep-")
            fi
        elif [ ${MODE} = PULL ]; then
            if [ $RECURSE_CHILDREN -ne 1 ]; then
                local temps=$(ssh $REMOTE_SERVER $ZFS list -Hr -o name -s creation -t snapshot -d 1 ${remote_set}|\
                    grep "${remote_set}\@autorep-")
            else
                local temps=$(ssh $REMOTE_SERVER $ZFS list -Hr -o name -s creation -t snapshot ${remote_set}|\
                    grep "${remote_set}\@autorep-")
            fi
        fi
        ## just a counter var
        local index=0
        ## our snapshot array
        declare -a snaps=()
        ## to the loop...
        for sn in $temps; do
            ## Check current snapshot name and destroy duplicates (if they exist)
            if [ ${MODE} == PUSH ]; then
                if [ "${sn}" == "${local_set}@${sname}" ]; then
                    printf "Destroying DUPLICATE snapshot %s@%s\n" "${local_set}" "${sname}"                
                    do_destroy ${local_set}@${sname}
                fi
            elif [ ${MODE} == PULL ]; then
                if [ "${sn}" == "${remote_set}@${sname}" ]; then
                    printf "Destroying DUPLICATE snapshot %s@%s\n" "${remote_set}" "${sname}"                
                    do_destroy ${remote_set}@${sname}
                fi
            fi
                ## append this snap to an array and increase count
                snaps[$index]=$sn
                let "index += 1"
        done
        ## set our snap count and reset our index
        local scount=${#snaps[@]}; local index=0
        ## set our base snap for incremental generation below
        if [ $scount -ge 1 ]; then
            local base_snap=${snaps[$scount-1]}
        fi
        ## how many snapshots did we end up with..
        if [ $scount -ge $SNAP_KEEP ]; then
            ## oops...too many snapshots laying around
            ## we need to destroy some of these
            while [ $scount -ge $SNAP_KEEP ]; do
                ## snaps are sorted above by creation in
                ## ascending order
                printf "Destroying OLD snapshot %s\n" "${snaps[$index]}"
                do_destroy ${snaps[$index]}
                ## decrease scount and increase index
                let "scount -= 1"; let "index += 1"
            done
        fi
        
        ## Create snapshot and check for recursive setting
        if [ ${MODE} = PUSH ]; then
            printf "Creating ZFS snapshot %s@%s\n" "${local_set}" "${sname}"
            if [ $RECURSE_CHILDREN -ne 1 ]; then
                printf "RUNNING: %s snapshot %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
                $ZFS snapshot ${local_set}@${sname}
            else
                printf "RUNNING: %s snapshot -r %s@%s\n" "${ZFS}" "${local_set}" "${sname}"
                $ZFS snapshot -r ${local_set}@${sname}
            fi
        elif [ ${MODE} = PULL ]; then
            printf "Creating ZFS snapshot %s@%s\n" "${remote_set}" "${sname}"
            if [ $RECURSE_CHILDREN -ne 1 ]; then
                printf "RUNNING: %s snapshot %s@%s\n" "${ZFS}" "${remote_set}" "${sname}"
                ssh $REMOTE_SERVER $ZFS snapshot ${remote_set}@${sname}
            else
                printf "RUNNING: %s snapshot -r %s@%s\n" "${ZFS}" "${remote_set}" "${sname}"
                ssh $REMOTE_SERVER $ZFS snapshot -r ${remote_set}@${sname}
            fi
        fi
        ## check return
        if [ $? -ne 0 ]; then
            ## oops...that's not right
            exit_error $?
        fi
        ## Send incremental snaphot if count is 1 or more, otherwise send full snapshot
        if [ ${MODE} == PUSH ]; then    
            if [ $scount -ge 1 ]; then
                if ! do_push ${base_snap} ${local_set}@${sname} ${remote_set}; then
		do_destroy ${local_set}@${sname}
		exit_error
		fi
            else
                if ! do_push "NULL" ${local_set}@${sname} ${remote_set}; then
		do_destroy ${local_set}@${sname}
		exit_error
		fi
            fi
        elif [ ${MODE} == PULL ]; then
            if [ $scount -ge 1 ]; then
		if ! do_pull ${base_snap} ${remote_set}@${sname} ${local_set}; then
		do_destroy ${remote_set}@${sname}
		exit_error
		fi
            else
                if ! do_pull "NULL" ${remote_set}@${sname} ${local_set}; then
		do_destroy ${remote_set}@${sname}
		exit_error
		fi
            fi
        fi
        ## check return of replication
        if [ $? != 0 ]; then
            if [ ${MODE} = PUSH ]; then
                printf "ERROR: Failed to send snapshot %s@$%s\n" "${local_set}" "${sname}"
                printf "Deleting the local snapshot %s@$%s\n" "${local_set}" "${sname}"
                do_destroy ${local_set}@${sname}
                exit_error
            elif [ ${MODE} = PULL ]; then
                printf "ERROR: Failed to send snapshot %s@$%s\n" "${remote_set}" "${sname}"
                printf "Deleting the local snapshot %s@$%s\n" "${remote_set}" "${sname}"
                do_destroy ${remote_set}@${sname}
                exit_error
            fi
        fi
    done
    ## clear our lockfile
    clear_lock "${LOGBASE}/.snapshot.lock"
}

## it all starts here...
init() {
    ## sanity check
    if [ $SNAP_KEEP -lt 2 ]; then
        printf "ERROR: You must keep at least 2 snaps for incremental sending.\n"
        printf "Please check the setting of 'SNAP_KEEP' in the script.\n"
        exit_error
    fi
    ## check remote health
    printf "Checking remote system...\n"
    check_remote
    ## do snapshots and send
    printf "Creating snapshots...\n"
    do_snap
    ## that's it...sending called from do_snap
    printf "Finished all operations for...\n"
    ## show a nice message and exit...
    exit_clean
}

## attempt to load configuration
if [ "${1}x" != "x" ] && [ -f "${1}" ]; then
    ## source passed config
    printf "Sourcing configuration from %s\n" "${1}"
    . "${1}"
elif [ -f "config.sh" ]; then
    ## source default config
    printf "Sourcing configuration from config.sh\n"
    . "config.sh"
elif [ -f "$(dirname ${0})/config.sh" ]; then
    ## source script path config
    printf "Sourcing configuration from $(dirname ${0})/config.sh\n"
    . "$(dirname ${0})/config.sh"
else
    ## display error
    printf "ERROR: Cannot continue without a valid configuration file!\n"
    printf "Usage: %s <config>\n" "${0}"
    ## exit
    exit 0
fi

## Check that proper variable were set by config.sh
if [ "${MODE}" = PUSH ]; then
    printf "ZFS Replication is set to PUSH\n"
elif [ "${MODE}" = PULL ]; then
    printf "ZFS Replication is set to PULL\n"
else
    printf "ZFS Replication MODE is not set\n"
    printf "Please set to PULL or PUSH\n"
    exit 1
fi

## make sure our log dir exits
[ ! -d "${LOGBASE}" ] && mkdir -p "${LOGBASE}"

## this is where it all starts
init > "${LOGFILE}" 2>&1
