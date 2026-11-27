#!/bin/bash
# =============================================================================
# File: hdl/particle/boards/panog2/ise_build.sh
# Description: Runs in the ISE 14.7 VM (make pano-blink copies it there): the
#              command-line ISE flow from Verilog to a bitstream.
#
# usage: bash ise_build.sh TOP PART UCF VERILOG...
#   run in the directory holding the files; PANO_ISE is ISE's directory
#   (default /opt/Xilinx/14.7/ISE_DS). Leaves TOP.bit, and the reports
#   TOP.syr (XST), TOP_map.mrp (map), TOP.par (place and route) and TOP.twr
#   (timing), here.
#
# The bitstream starts on the JTAG clock (StartupClk:JtagClk), for loading
# over JTAG with make pano-prog. Unused pins are pulled down (bitgen's
# default).
# =============================================================================
set -e
ISE=${PANO_ISE:-/opt/Xilinx/14.7/ISE_DS}
if [ $# -lt 4 ]; then
    echo "usage: bash ise_build.sh TOP PART UCF VERILOG..." >&2
    exit 2
fi
top=$1
part=$2
ucf=$3
shift 3
if [ ! -f "$ISE/settings64.sh" ]; then
    echo "[FAIL] $ISE/settings64.sh not found (set PANO_ISE)" >&2
    exit 1
fi
# (its own commands may return non-zero: not a failure)
set +e
. "$ISE/settings64.sh" > /dev/null
set -e

rm -rf xst _ngo "$top".bit "$top".ncd "${top}"_map.ncd
mkdir -p xst/tmp
: > "$top.prj"
for f in "$@"; do
    echo "verilog work \"$f\"" >> "$top.prj"
done
cat > "$top.xst" <<EOF
set -tmpdir "xst/tmp"
set -xsthdpdir "xst"
run
-ifn $top.prj
-ifmt mixed
-ofn $top
-ofmt NGC
-p $part
-top $top
-opt_mode Speed
-opt_level 1
EOF

echo "==> XST (log: $top.syr)"
xst -intstyle silent -ifn "$top.xst" -ofn "$top.syr"
echo "==> ngdbuild"
ngdbuild -intstyle silent -dd _ngo -uc "$ucf" -p "$part" "$top.ngc" "$top.ngd" > ngdbuild.log
echo "==> map (report: ${top}_map.mrp)"
map -intstyle silent -w -p "$part" -o "${top}_map.ncd" "$top.ngd" "$top.pcf" > map.log
echo "==> par (report: $top.par)"
par -intstyle silent -w "${top}_map.ncd" "$top.ncd" "$top.pcf" > par.log
echo "==> trce (report: $top.twr)"
trce -intstyle silent -v 3 -o "$top.twr" "$top.ncd" "$top.pcf" > trce.log
echo "==> bitgen"
bitgen -intstyle silent -w -g StartupClk:JtagClk "$top.ncd" "$top.bit" "$top.pcf" > bitgen.log

echo "==> Summary"
grep -E "Number of Slice LUTs|Number of occupied Slices" "${top}_map.mrp" || true
grep -E "Timing Score|All constraints were met|constraints? (was|were) not met" "$top.par" || true
grep -E "Minimum period" "$top.twr" || true
ls -l "$top.bit"
