#!/bin/bash
# =============================================================================
# File: hdl/particle/boards/panog2/impact_prog.sh
# Description: Runs in the ISE 14.7 VM (make pano-prog and make pano-vm-check
#              copy it there): iMPACT in batch mode over the JTAG cable.
#
# usage: bash impact_prog.sh BITFILE [POSITION]   load BITFILE into the FPGA
#        bash impact_prog.sh --identify           list the JTAG chain
#   POSITION is the FPGA's place in the chain (default 1). PANO_ISE is
#   ISE's directory (default /opt/Xilinx/14.7/ISE_DS).
#
# Loading over JTAG changes only the FPGA's configuration: the Pano's flash
# is untouched, and a power cycle brings its own firmware back.
# =============================================================================
set -e
ISE=${PANO_ISE:-/opt/Xilinx/14.7/ISE_DS}
if [ ! -f "$ISE/settings64.sh" ]; then
    echo "[FAIL] $ISE/settings64.sh not found (set PANO_ISE)" >&2
    exit 1
fi
# (its own commands may return non-zero: not a failure)
set +e
. "$ISE/settings64.sh" > /dev/null
set -e

if [ "$1" = "--identify" ]; then
    cat > impact_identify.cmd <<EOF
setMode -bs
setCable -port auto
Identify -inferir
quit
EOF
    impact -batch impact_identify.cmd > impact_identify.log 2>&1 || true
    grep -E "[Cc]able|IDCODE|Manufacturer's ID|Added Device|ERROR" impact_identify.log || true
    if grep -qE "Manufacturer's ID|Added Device" impact_identify.log; then exit 0; fi
    echo "[FAIL] no JTAG chain found (log: impact_identify.log)" >&2
    exit 1
fi

bit=$1
pos=${2:-1}
if [ ! -f "$bit" ]; then
    echo "usage: bash impact_prog.sh BITFILE [POSITION] | --identify" >&2
    exit 2
fi
cat > impact_prog.cmd <<EOF
setMode -bs
setCable -port auto
Identify -inferir
identifyMPM
assignFile -p $pos -file "$bit"
Program -p $pos
quit
EOF
impact -batch impact_prog.cmd > impact_prog.log 2>&1 || true
grep -E "Manufacturer's ID|Programmed successfully|ERROR" impact_prog.log || true
if grep -q "Programmed successfully" impact_prog.log; then exit 0; fi
echo "[FAIL] programming did not succeed (log: impact_prog.log)" >&2
exit 1
