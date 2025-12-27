#!/bin/bash
set -euo pipefail

# -------- LOCK --------

LOCK_FILE=/tmp/my.lock
PID_FILE=/tmp/my.lock.pid
exec 200>"$LOCK_FILE"
flock -n 200 || {
    pid=$(cat "$PID_FILE" 2>/dev/null)
    echo "Script already running${pid:+ (PID $pid)}"
    exit 1
}
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

# -------- CONFIGURATION --------

DATA=""
BACKUP_ROOT=""                            
PATH_BACKUP_DIR="$HOME"    
MODE="incremental"                    
ARCHIVE=false                          
COMPRESS_FLAG=""
COMPRESS_LEVEL=""
RETENTION_DAYS=14

HOST="$(hostname)"
DATE="$(date +"%Y-%m-%d_%H-%M-%S")"

LOG_DIR=""
CUR_BACKUP=""
LATEST_LINK=""
LOG_FILE=""

# -------- FUNCTIONS --------

usage() {
cat << EOF
Usage:
  $(basename "$0") [OPTIONS] <DATA>

Arguments:
  DATA                     File or directory to back up

Options:
  -h, --help               Show this help message and exit

  -dDIR
  -d DIR
  -d=DIR
  --directory DIR
  --directory=DIR          Base directory where backups will be stored
                           (default: \$HOME)
  -mMODE
  -m MODE
  -m=MODE
  --mode MODE
  --mode=MODE              Backup mode (default: incremental)
                             full          – full copy
                             incremental   – incremental backup (rsync --link-dest)
                             mirror        – mirror source (rsync --delete)

Compression:
  -c                       Enable compression (tar only)
  -cj[1-9]                 Compress using bzip2 (optional level 1–9)
  -cz[1-9]                 Compress using gzip  (optional level 1–9)
  -cJ[1-9]                 Compress using xz    (optional level 1–9)

Examples:
  Backup directory incrementally (default):
    $(basename "$0") -d ~/Documents some_dir

  Full backup to custom directory:
    $(basename "$0") -m full -d /mnt/backups /etc

  Incremental backup with gzip compression:
    $(basename "$0") -cz6 /var/www

  Mirror backup (DANGEROUS: deletes removed files):
    $(basename "$0") --mode mirror /srv/data

Notes:
  • 'incremental' mode uses hard links via rsync --link-dest
  • 'mirror' mode will DELETE files not present in source
  • Compression is applied after rsync completes
  • Old backups are removed after $RETENTION_DAYS days

EOF
}

log() { echo "[$(date '+%F %T')] $1" | tee -a "$LOG_FILE"; }
fatal() { log "ERROR: $1"; exit 1; }

validate_directory() {
    local dir="$1"

    [[ "$dir" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo "Directory path format specified is incorrect"; return 1; }
    [[ -d "$dir" ]] || { echo "Such directory does not exist"; return 1; }
    [[ -w "$dir" ]] || { echo "No write permission for directory"; return 1; }
    return 0
}

validate_data() {
    local f="$1"
    [[ -e "$f" ]] || { echo "The data '$f' does not exist"; return 1; }
    [[ -r "$f" ]] || { echo "No read permissions"; return 1; }
    return 0
}

init_directories() {
    mkdir -p "$PATH_BACKUP_DIR/$BACKUP_ROOT" || { echo "$PATH_BACKUP_DIR/$BACKUP_ROOT"; return 1; }
    mkdir -p "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" || { echo "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST"; return 1; }
    mkdir "$CUR_BACKUP" || { echo "$CUR_BACKUP"; return 1; }
    mkdir -p "$LOG_DIR" || { echo "$LOG_DIR"; return 1; }
    return 0
}   

check_requirements() {
    for cmd in rsync tar find mkdir ln rm hostname date; do
        command -v "$cmd" >/dev/null 2>&1 || fatal "Required command not found: $cmd"
    done
}

backup_rsync() {
    case "$MODE" in
        full) rsync -a "$DATA" "$CUR_BACKUP" ;;
        mirror) rsync -a --delete "$DATA" "$CUR_BACKUP" ;;
        incremental)
            if [[ -d "$LATEST_LINK" ]]; then
                rsync -a --link-dest="$LATEST_LINK" "$DATA" "$CUR_BACKUP"
            else
                rsync -a "$DATA" "$CUR_BACKUP"
            fi
            ;;
    esac
}

update_latest() {
    ln -nsf "$CUR_BACKUP" "$LATEST_LINK" || fatal "Failed to update latest symlink"
}

archive_backup() {
    if [[ "$COMPRESS_FLAG" == "j" ]]; then 
        if [[ "$COMPRESS_LEVEL" != "" ]]; then 
            BZIP2="-$COMPRESS_LEVEL" tar -c"${COMPRESS_FLAG}"f "$CUR_BACKUP.tar.bz2" -C "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" "$(basename "$CUR_BACKUP")" || return 1
        else 
            tar -c"${COMPRESS_FLAG}"f "$CUR_BACKUP.tar.bz2" -C "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" "$(basename "$CUR_BACKUP")" || return 1
        fi
    elif [[ "$COMPRESS_FLAG" == "z" ]]; then 
        if [[ "$COMPRESS_LEVEL" != "" ]]; then 
            GZIP="-$COMPRESS_LEVEL" tar -c"${COMPRESS_FLAG}"f "$CUR_BACKUP.tar.gz" -C "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" "$(basename "$CUR_BACKUP")" || return 1
        else 
            tar -c"${COMPRESS_FLAG}"f "$CUR_BACKUP.tar.gz" -C "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" "$(basename "$CUR_BACKUP")" || return 1
        fi
    elif [[ "$COMPRESS_FLAG" == "J" ]]; then 
        if [[ "$COMPRESS_LEVEL" != "" ]]; then 
            XZ_OPT="-$COMPRESS_LEVEL" tar -c"${COMPRESS_FLAG}"f "$CUR_BACKUP.tar.xz" -C "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" "$(basename "$CUR_BACKUP")" || return 1
        else 
            tar -c"${COMPRESS_FLAG}"f "$CUR_BACKUP.tar.xz" -C "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" "$(basename "$CUR_BACKUP")" || return 1
        fi
    else 
        tar -cf "$CUR_BACKUP.tar" -C "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" "$(basename "$CUR_BACKUP")" || return 1
    fi
    return 0
}

cleanup_old() {
    find "$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST" -mindepth 1 -maxdepth 1 -type d -mtime +$RETENTION_DAYS -exec rm -rf {} \;
}

summary() {
    log "Backup completed successfully"
    log "Source: $DATA"
    log "Destination: $CUR_BACKUP"
    log "Mode: $MODE"
    log "Compression: ${COMPRESS_FLAG:-none}${COMPRESS_LEVEL:+ (level $COMPRESS_LEVEL)}"
    log "Retention policy: $RETENTION_DAYS days"
}

# -------- PREPARATION_AND_VERIFICATION_OF_DEPENDENCIES --------

while [[ $# -gt 0 ]]; do
    case "$1" in 
        --*) 
            case "$1" in
                --directory=*)
                    DIR="${1#*=}"
                    [[ -z "$DIR" ]] && { echo "--directory requires argument"; exit 1; }
                    validate_directory "$DIR" || exit 1
                    PATH_BACKUP_DIR="$DIR"
                    ;;
                --directory)
                    shift
                    DIR="$1"
                    [[ -z "$DIR" ]] && { echo "--directory requires argument"; exit 1; }
                    validate_directory "$DIR" || exit 1
                    PATH_BACKUP_DIR="$DIR"
                    ;;
                --mode=*)
                    mode="${1#*=}"
                    [[ -z "$mode" ]] && { echo "--mode requires argument"; exit 1; }
                    [[ "$mode" =~ [full|incremental|mirror] ]] || { echo "Invalid mode '$mode'"; echo "usage: [full | incremental | mirror]"; exit 1; }
                    MODE="$mode"
                    ;; 
                --mode)
                    shift
                    mode="$1"
                    [[ -z "$mode" ]] && { echo "--mode requires argument"; exit 1; }
                    [[ "$mode" =~ [full|incremental|mirror] ]] || { echo "Invalid mode '$mode'"; echo "usage: [full | incremental | mirror]"; exit 1; }
                    MODE="$mode"
                    ;;
                --help) usage; exit 0 ;;
                *) echo "Unknown option: $1"; usage; exit 1 ;;
            esac
            shift
            ;;
        -?*) 
            flags="${1#-}"
            for (( i=0; i<${#flags}; i++ )); do
                case "${flags:i:1}" in
                    c)
                        ARCHIVE=true
                        if [[ "${flags:i+1:1}" =~ [jzJ] ]]; then 
                            COMPRESS_FLAG="${flags:i+1:1}"
                            i=$(( i + 1 ))
                            if [[ "${flags:i+1:2}" =~ ([0-9][0-9]) ]]; then 
                                echo "Invalid compression preset: ${flags:i+1:2}"
                                echo "-cj([0-9])? [ bzip2 ] | -cz([0-9])? [ gzip ] | -cJ([0-9])? [ xz ]"
                                exit 1
                            elif [[ "${flags:i+1:1}" =~ ([0-9]) ]]; then
                                COMPRESS_LEVEL="${flags:i+1:1}"
                                i=$(( i + 1 ))
                            fi
                        fi
                        ;;
                    d)
                        if (( i + 1 < ${#flags} )); then
                            if [[ "${flags:i+1:1}" == "=" ]]; then
                                DIR="${flags:i+2}"
                            else
                                DIR="${flags:i+1}"
                            fi
                            i=${#flags}
                        else
                            shift
                            [[ $# -gt 0 ]] || { echo "-d requires argument"; exit 1; }
                            DIR="$1"
                        fi
                        validate_directory "$DIR" || exit 1
                        PATH_BACKUP_DIR="$DIR"
                        ;;
                    m)
                        if (( i + 1 < ${#flags} )); then
                            if [[ "${flags:i+1:1}" == "=" ]]; then
                                mode="${flags:i+2}"
                            else
                                mode="${flags:i+1}"
                            fi
                            i=${#flags}
                        else
                            shift
                            [[ $# -gt 0 ]] || { echo "-m requires argument"; exit 1; }
                            mode="$1"
                        fi
                        [[ "$mode" =~ [full|incremental|mirror] ]] || { echo "Invalid mode '$mode'"; echo "usage: [full|incremental|mirror]"; exit 1; } 
                        MODE="$mode"
                        ;;
                    h) usage; exit 0 ;;
                    *) echo "Unknown flag: -${flags:i:1}"; usage; exit 1 ;;
                esac
            done
            shift
            ;;
        *)
            break
            ;;
    esac
done 

[[ $# -eq 0 ]] && { echo "No backup data specified"; exit 1; }
validate_data $1 || exit 1
DATA="$1"

BACKUP_ROOT="$(basename "$DATA")_backups"
LOG_DIR="$PATH_BACKUP_DIR/$BACKUP_ROOT/log"
CUR_BACKUP="$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST/backup_$DATE"                 
LATEST_LINK="$PATH_BACKUP_DIR/$BACKUP_ROOT/$HOST/latest"            
LOG_FILE="$LOG_DIR/backup_$DATE.log" 


# -------- MAIN --------

check_requirements

dir=$(init_directories 2>&1) || fatal "Failed to create directory: $dir"
log "Backup directory structure created under '$PATH_BACKUP_DIR/$BACKUP_ROOT'"

backup_rsync
log "Data synchronized to '$CUR_BACKUP' (mode: $MODE)"

update_latest
log "Updated symbolic link 'latest' -> '$CUR_BACKUP'"

if [[ "$ARCHIVE" == "true" ]]; then 
    archive_backup || fatal "Failed to archive backup '$CUR_BACKUP'"
    log "Backup archived successfully"
fi

cleanup_old
log "Old backups cleanup completed"

summary