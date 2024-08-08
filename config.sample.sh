## zfs-replicate sample configuration file - edit as needed
## config.sample.sh

## ip address or hostname of a remote server
## comment out for local only replication
REMOTE_SERVER="192.168.1.250"

## set replication mode, PUSH or PULL
## PULL replicates from remote to local
## PUSH replicates from local to remote
## default is PULL
MODE="PULL"

## set pipes depending on MODE
if [ ${MODE} = PUSH ]; then
    RECEIVE_PIPE="ssh ${REMOTE_SERVER} zfs receive -vFd"
    SEND_PIPE="zfs send"
elif [ ${MODE} = PULL ]; then
    RECEIVE_PIPE="zfs receive -vFd"
    SEND_PIPE="ssh ${REMOTE_SERVER} zfs send"
fi

## datasets to replicate - use zfs paths not mount points...
## format is localpool/localdataset:remotepool or
## localpool/localdataset:remotepool/remotedataset
## can include multiple strings separated by a "space"
REPLICATE_SETS="localpool/localdataset:remotepool/remotedataset"

## Allow replication of root datasets
## if you specify root datasets above and do not toggle this setting the
## script will generate a warning and skip replicating root datasets
## 0 - disable (default)
## 1 - enable (use at your own risk)
ALLOW_ROOT_DATASETS=0

## option to recursively snapshot children of all datasets listed above
## 0 - disable (default)
## 1 - enable
RECURSE_CHILDREN=0

## number of snapshots to keep of each dataset
## older snapshots will be deleted
SNAP_KEEP=2

## number of logs to keep
## older logs will be deleted
LOG_KEEP=5

## log files directory (defaults to script path)
SCRIPT=$(readlink -f "$0")
SCRIPTPATH=$(dirname "${SCRIPT}")
LOGBASE="${SCRIPTPATH}/logs"

## command to check health of remote host
## a return code of 0 will be considered OK
## comment out for local only replication
REMOTE_CHECK="ping -c1 -q -W2 ${REMOTE_SERVER}"

## path to zfs binary (only command for now)
ZFS=zfs

## path to GNU find binary
## solaris `find` does not support the -maxdepth option, which is required
## on solaris 11, GNU find is typically located at /usr/bin/gfind
FIND=/usr/bin/find

## get the current date info
DOW=$(date "+%a")
MOY=$(date "+%m")
DOM=$(date "+%d")
NOW=$(date "+%s")
CYR=$(date "+%Y")

## snapshot and log name tags
## ie: pool0/someplace@autorep-${NAMETAG}
NAMETAG="${MOY}${DOM}${CYR}_${NOW}"

## the log file needs to start with
## autorep- in order for log cleanup to work
## using the default below is strongly suggested
LOGFILE="${LOGBASE}/autorep-${NAMETAG}.log"
