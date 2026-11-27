#!/bin/bash
# =============================================================================
# File: hdl/particle/boards/panog2/vm_check.sh
# Description: Runs in the ISE 14.7 VM (make pano-vm-check copies it there):
#              checks that ISE's command-line tools are there, then lists the
#              JTAG chain with impact_prog.sh --identify.
#
# usage: bash vm_check.sh   (PANO_ISE: ISE's directory, default
#                           /opt/Xilinx/14.7/ISE_DS)
# =============================================================================
ISE=${PANO_ISE:-/opt/Xilinx/14.7/ISE_DS}
if [ ! -f "$ISE/settings64.sh" ]; then
    echo "[FAIL] $ISE/settings64.sh not found (set PANO_ISE)" >&2
    exit 1
fi
. "$ISE/settings64.sh" > /dev/null
status=0
for t in xst ngdbuild map par trce bitgen impact; do
    if command -v "$t" > /dev/null; then
        echo "  $t: $(command -v "$t")"
    else
        echo "[FAIL] $t not found" >&2
        status=1
    fi
done
[ $status -eq 0 ] || exit 1
echo "==> JTAG chain"
bash "$(dirname "$0")/impact_prog.sh" --identify
