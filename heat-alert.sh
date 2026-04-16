#!/bin/bash

# ==========================================================
# CONFIGURATION
# ==========================================================
MAIL_TO="m.amin.zaag@hotmail.com"
TEMP_THRESHOLD="${TEMP_THRESHOLD:-70}"
REPORT="/root/proxmox_health_report.txt"
NOW="$(date '+%F %T')"
HOSTNAME_NOW="$(hostname)"
NODE_NAME="$(hostname)"
MSG="${msg:-PROXMOX HEAT ALERT}"

# ==========================================================
# 1) TEMPERATURES
# ==========================================================
# Read sensors output once and reuse it in the report
SENSORS_OUTPUT="$(sensors 2>/dev/null)"

# Try to get the main CPU package temperature
CPU_TEMP_RAW="$(echo "$SENSORS_OUTPUT" | awk -F'[+°C ]+' '/Package id 0:/ {print $4; exit}')"
CPU_TEMP="${CPU_TEMP_RAW:-0}"
CPU_TEMP_INT="${CPU_TEMP%%.*}"
[ -z "$CPU_TEMP_INT" ] && CPU_TEMP_INT=0

# ==========================================================
# 2) HOST CPU / RAM / DISK
# ==========================================================
# Estimate host CPU usage from top output
HOST_CPU_USED="$(top -bn1 | awk -F',' '
/^%Cpu|^Cpu\(s\)/ {
    idle=""
    for (i=1; i<=NF; i++) {
        if ($i ~ /id/) {
            gsub(/[^0-9.]/, "", $i)
            idle=$i
        }
    }
    if (idle == "") idle=0
    printf "%.0f", 100-idle
}')"
[ -z "$HOST_CPU_USED" ] && HOST_CPU_USED=0

# Read RAM usage
MEM_LINE="$(free -m | awk '/^Mem:/ {print $2" "$3" "$4}')"
MEM_TOTAL="$(echo "$MEM_LINE" | awk '{print $1}')"
MEM_USED="$(echo "$MEM_LINE" | awk '{print $2}')"
MEM_FREE="$(echo "$MEM_LINE" | awk '{print $3}')"

if [ -n "$MEM_TOTAL" ] && [ "$MEM_TOTAL" -gt 0 ] 2>/dev/null; then
    HOST_MEM_USED_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
else
    HOST_MEM_USED_PCT=0
fi

# Root filesystem summary
DISK_ROOT="$(df -h / | awk 'NR==2 {print $1" total="$2" used="$3" avail="$4" use="$5" mounted="$6}')"

# ==========================================================
# 3) VM / CT COUNTERS
# ==========================================================
VM_TOTAL="$(qm list 2>/dev/null | awk 'NR>1 {c++} END{print c+0}')"
VM_RUNNING="$(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {c++} END{print c+0}')"

CT_TOTAL="$(pct list 2>/dev/null | awk 'NR>1 {c++} END{print c+0}')"
CT_RUNNING="$(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {c++} END{print c+0}')"

# ==========================================================
# FUNCTIONS
# ==========================================================

# Return VM name from qm config
get_vm_name() {
    local vmid="$1"
    qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/ {print $2; exit}'
}

# Return CT hostname from pct config
get_ct_name() {
    local ctid="$1"
    pct config "$ctid" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2; exit}'
}

# Read VM CPU usage twice and calculate a small average
get_vm_cpu_avg() {
    local vmid="$1"
    local s1 s2 avg

    s1="$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/status/current" --output-format json 2>/dev/null | \
        python3 -c 'import sys,json; d=json.load(sys.stdin); print(float(d.get("cpu",0) or 0)*100)' 2>/dev/null)"

    sleep 1

    s2="$(pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/status/current" --output-format json 2>/dev/null | \
        python3 -c 'import sys,json; d=json.load(sys.stdin); print(float(d.get("cpu",0) or 0)*100)' 2>/dev/null)"

    avg="$(python3 -c "
s1=float('${s1:-0}')
s2=float('${s2:-0}')
print(f'{(s1+s2)/2:.2f}')
" 2>/dev/null)"

    echo "${avg:-0.00}"
}

# Return the current VM runtime JSON
get_vm_runtime_current() {
    local vmid="$1"
    pvesh get "/nodes/${NODE_NAME}/qemu/${vmid}/status/current" --output-format json 2>/dev/null
}

# Read guest disk usage using qemu guest agent
# Output: \"used total\" in bytes
# Output: NOAGENT if unavailable
get_vm_disk_guest_agent() {
    local vmid="$1"

    qm guest cmd "$vmid" get-fsinfo 2>/dev/null | python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
except Exception:
    print("NOAGENT")
    raise SystemExit(0)

total = 0
used = 0
found = False

if isinstance(data, list):
    for fs in data:
        mountpoint = fs.get("mountpoint")
        if not mountpoint:
            continue

        total_bytes = fs.get("total-bytes")
        used_bytes = fs.get("used-bytes")

        if isinstance(total_bytes, int) and isinstance(used_bytes, int) and total_bytes > 0:
            total += total_bytes
            used += used_bytes
            found = True

if not found:
    print("NOAGENT")
else:
    print(f"{used} {total}")
' 2>/dev/null
}

# Convert bytes to MB
bytes_to_mb() {
    echo $(( $1 / 1024 / 1024 ))
}

# Convert bytes to GB
bytes_to_gb() {
    echo $(( $1 / 1024 / 1024 / 1024 ))
}

# ==========================================================
# 4) BUILD REPORT
# ==========================================================
{
echo "=============================================================="
echo "PROXMOX HEALTH REPORT"
echo "Server           : $HOSTNAME_NOW"
echo "Date             : $NOW"
echo "=============================================================="
echo

echo "###############################"
echo "# 1. TEMPERATURES"
echo "###############################"
echo "${SENSORS_OUTPUT:-No sensors output available}"
echo

echo "###############################"
echo "# 2. HOST SUMMARY"
echo "###############################"
echo "Host CPU usage   : ${HOST_CPU_USED}%"
echo "Host RAM usage   : ${HOST_MEM_USED_PCT}% (${MEM_USED:-0}MB / ${MEM_TOTAL:-0}MB)"
echo "Host RAM free    : ${MEM_FREE:-0}MB"
echo "Root disk        : $DISK_ROOT"
echo "Uptime           : $(uptime -p 2>/dev/null)"
echo "Load average     : $(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null)"
echo

echo "###############################"
echo "# 3. TOP CPU PROCESSES"
echo "###############################"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 11
echo

echo "###############################"
echo "# 4. TOP MEMORY PROCESSES"
echo "###############################"
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -n 11
echo

echo "###############################"
echo "# 5. GLOBAL VM / CT STATUS"
echo "###############################"
echo "VM total         : $VM_TOTAL"
echo "VM running       : $VM_RUNNING"
echo "VM stopped       : $((VM_TOTAL - VM_RUNNING))"
echo
for VMID in $(qm list 2>/dev/null | awk 'NR>1 {print $1}'); do
    VM_NAME="$(get_vm_name "$VMID")"
    VM_STATUS="$(qm status "$VMID" 2>/dev/null | awk '{print $2}')"
    echo "VM  $VMID  | ${VM_NAME:-N/A} | ${VM_STATUS:-unknown}"
done
echo
echo "CT total         : $CT_TOTAL"
echo "CT running       : $CT_RUNNING"
echo "CT stopped       : $((CT_TOTAL - CT_RUNNING))"
echo
for CTID in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    CT_NAME="$(get_ct_name "$CTID")"
    CT_STATUS="$(pct status "$CTID" 2>/dev/null | awk '{print $2}')"
    echo "CT  $CTID  | ${CT_NAME:-N/A} | ${CT_STATUS:-unknown}"
done
echo

echo "###############################"
echo "# 6. RUNNING VM DETAILS"
echo "###############################"

for VMID in $(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'); do
    VM_NAME="$(get_vm_name "$VMID")"
    VM_STATUS="running"
    CUR_JSON="$(get_vm_runtime_current "$VMID")"

    read -r VM_MEM_USED VM_MEM_MAX VM_DISK_USED_ALLOC VM_DISK_MAX VM_CPUS VM_QMPSTATUS <<EOF
$(printf '%s' "$CUR_JSON" | python3 -c '
import sys, json
d=json.load(sys.stdin)
mem=int(d.get("mem",0) or 0)
maxmem=int(d.get("maxmem",0) or 0)
disk=int(d.get("disk",0) or 0)
maxdisk=int(d.get("maxdisk",0) or 0)
cpus=d.get("cpus","N/A")
qmpstatus=d.get("qmpstatus","N/A")
print(mem, maxmem, disk, maxdisk, cpus, qmpstatus)
' 2>/dev/null)
EOF

    [ -z "$VM_MEM_USED" ] && VM_MEM_USED=0
    [ -z "$VM_MEM_MAX" ] && VM_MEM_MAX=0
    [ -z "$VM_DISK_USED_ALLOC" ] && VM_DISK_USED_ALLOC=0
    [ -z "$VM_DISK_MAX" ] && VM_DISK_MAX=0
    [ -z "$VM_CPUS" ] && VM_CPUS="N/A"
    [ -z "$VM_QMPSTATUS" ] && VM_QMPSTATUS="N/A"

    VM_CPU_PCT="$(get_vm_cpu_avg "$VMID")"
    [ -z "$VM_CPU_PCT" ] && VM_CPU_PCT="0.00"

    VM_MEM_USED_MB="$(bytes_to_mb "$VM_MEM_USED")"
    VM_MEM_MAX_MB="$(bytes_to_mb "$VM_MEM_MAX")"

    if [ "$VM_MEM_MAX" -gt 0 ] 2>/dev/null; then
        VM_MEM_PCT=$((VM_MEM_USED * 100 / VM_MEM_MAX))
    else
        VM_MEM_PCT=0
    fi

    GA_DISK="$(get_vm_disk_guest_agent "$VMID")"

    echo "--------------------------------------------------------------"
    echo "VMID              : $VMID"
    echo "Name              : ${VM_NAME:-N/A}"
    echo "State             : $VM_STATUS"
    echo
    echo "[qm status]"
    qm status "$VMID" 2>/dev/null
    echo
    echo "[runtime current]"
    echo "Configured vCPU    : $VM_CPUS"
    echo "CPU usage          : ${VM_CPU_PCT}%"
    echo "Memory usage       : ${VM_MEM_USED_MB} MB / ${VM_MEM_MAX_MB} MB (${VM_MEM_PCT}%)"

    if [ "$GA_DISK" != "NOAGENT" ] && [ -n "$GA_DISK" ]; then
        GA_USED="$(echo "$GA_DISK" | awk '{print $1}')"
        GA_TOTAL="$(echo "$GA_DISK" | awk '{print $2}')"

        [ -z "$GA_USED" ] && GA_USED=0
        [ -z "$GA_TOTAL" ] && GA_TOTAL=0

        GA_USED_GB="$(bytes_to_gb "$GA_USED")"
        GA_TOTAL_GB="$(bytes_to_gb "$GA_TOTAL")"

        if [ "$GA_TOTAL" -gt 0 ] 2>/dev/null; then
            GA_DISK_PCT=$((GA_USED * 100 / GA_TOTAL))
        else
            GA_DISK_PCT=0
        fi

        echo "Disk usage         : ${GA_USED_GB} GB / ${GA_TOTAL_GB} GB (${GA_DISK_PCT}%)"
        echo "Disk source        : guest agent"
    else
        VM_DISK_USED_GB="$(bytes_to_gb "$VM_DISK_USED_ALLOC")"
        VM_DISK_MAX_GB="$(bytes_to_gb "$VM_DISK_MAX")"

        if [ "$VM_DISK_MAX" -gt 0 ] 2>/dev/null; then
            VM_DISK_PCT=$((VM_DISK_USED_ALLOC * 100 / VM_DISK_MAX))
        else
            VM_DISK_PCT=0
        fi

        echo "Disk usage         : ${VM_DISK_USED_GB} GB / ${VM_DISK_MAX_GB} GB (${VM_DISK_PCT}%)"
        echo "Disk source        : Proxmox allocated disk (guest agent missing)"
    fi

    echo "QMP status         : $VM_QMPSTATUS"
    echo
done

echo "###############################"
echo "# 7. RUNNING CT DETAILS"
echo "###############################"

for CTID in $(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}'); do
    CT_HOSTNAME="$(pct config "$CTID" 2>/dev/null | awk -F': ' '/^hostname:/ {print $2}')"
    CT_STATUS="running"

    echo "--------------------------------------------------------------"
    echo "CTID              : $CTID"
    echo "Hostname          : ${CT_HOSTNAME:-N/A}"
    echo "State             : $CT_STATUS"
    echo

    echo "[pct status]"
    pct status "$CTID" 2>/dev/null
    echo

    echo "[pct config summary]"
    pct config "$CTID" 2>/dev/null | egrep '^(hostname:|memory:|swap:|cores:|rootfs:|mp[0-9]+:)'
    echo
done

echo "###############################"
echo "# 8. FINAL SUMMARY"
echo "###############################"
echo "CPU package temp   : ${CPU_TEMP}C"
echo "Host CPU usage     : ${HOST_CPU_USED}%"
echo "Host RAM usage     : ${HOST_MEM_USED_PCT}%"
echo "VM running         : $VM_RUNNING / $VM_TOTAL"
echo "CT running         : $CT_RUNNING / $CT_TOTAL"
echo "Root disk          : $DISK_ROOT"
echo

if [ "$CPU_TEMP_INT" -ge "$TEMP_THRESHOLD" ] 2>/dev/null; then
    echo "HEAT ALERT         : YES (threshold=${TEMP_THRESHOLD}C)"
else
    echo "HEAT ALERT         : NO (threshold=${TEMP_THRESHOLD}C)"
fi

echo
echo "=============================================================="
echo "END OF REPORT"
echo "=============================================================="

} | tee "$REPORT"

# ==========================================================
# 5) SEND MAIL IF THRESHOLD IS EXCEEDED
# ==========================================================
if [ "$CPU_TEMP_INT" -ge "$TEMP_THRESHOLD" ] 2>/dev/null; then
    mail -s "${MSG}-${HOSTNAME_NOW}-${CPU_TEMP}C" "$MAIL_TO" < "$REPORT"
fi
