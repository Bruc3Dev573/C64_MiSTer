#!/bin/sh
# Summarize a Quartus compile of the C64 core (WP B4).
# Prints a Markdown table (ALM, block memory, M10K, DSP, Fmax per clock,
# worst setup/hold slack) and exits 1 when timing is not met.
# Usage: quartus_report.sh [output_files] [revision]
OUT=${1:-output_files}
REV=${2:-C64}
FIT="$OUT/$REV.fit.summary"
STA="$OUT/$REV.sta.rpt"
[ -f "$FIT" ] || { echo "missing $FIT"; exit 2; }
[ -f "$STA" ] || { echo "missing $STA"; exit 2; }

field() { grep -m1 "^$1" "$FIT" | sed 's/^[^:]*: *//'; }

echo "### Quartus build ($REV)"
echo
echo "| Resource | Used |"
echo "| --- | --- |"
echo "| Logic utilization (ALMs) | $(field 'Logic utilization') |"
echo "| Total registers | $(field 'Total registers') |"
echo "| Block memory bits | $(field 'Total block memory bits') |"
echo "| RAM blocks (M10K) | $(field 'Total RAM Blocks') |"
echo "| DSP blocks | $(field 'Total DSP Blocks') |"
echo "| PLLs | $(field 'Total PLLs') |"
echo

# Fmax tables of every corner: "; 98.12 MHz ; 95.00 MHz ; <clock> ; <note> ;".
# Keep the worst (lowest) restricted Fmax per clock across corners.
echo "| Clock | Fmax, worst corner (restricted) |"
echo "| --- | --- |"
FMAX=$(awk -F';' '
	/MHz/ && NF >= 5 {
		f = $2; r = $3; c = $4
		gsub(/^ +| +$/, "", f); gsub(/^ +| +$/, "", r); gsub(/^ +| +$/, "", c)
		if (c == "" || r !~ /MHz/) next
		gsub(/\|/, "\\|", c)
		v = r + 0
		if (!(c in m) || v < m[c]) { m[c] = v; fm[c] = f; rm[c] = r }
	}
	END { for (c in m) printf("| `%s` | %s (%s) |\n", c, rm[c], fm[c]) }' "$STA" | sort)
if [ -n "$FMAX" ]; then
	echo "$FMAX"
else
	echo "| (no Fmax rows found in $STA) | |"
fi
echo

SETUP=$(grep -m1 -A0 'Worst-case setup slack is' "$STA" | sed 's/.*is //')
HOLD=$(grep -m1 -A0 'Worst-case hold slack is' "$STA" | sed 's/.*is //')
[ -n "$SETUP" ] && echo "Worst-case setup slack: $SETUP  "
[ -n "$HOLD" ] && echo "Worst-case hold slack: $HOLD  "

if grep -q 'Timing requirements not met' "$STA" "$OUT/$REV.sta.summary" 2>/dev/null; then
	echo
	echo "**Timing requirements not met.**"
	# negative entries of the summary (corner, analysis, clock, slack)
	if [ -f "$OUT/$REV.sta.summary" ]; then
		echo
		echo '```'
		awk '/^Type/ { t = $0 } /^Slack/ { if ($3 + 0 < 0) print t "  " $0 }' "$OUT/$REV.sta.summary" | sed 's/^Type *: *//'
		echo '```'
	fi
	# worst failing paths (sta_paths.tcl, run by the CI after the compile)
	if [ -s "$OUT/$REV.paths.rpt" ]; then
		echo
		echo '<details><summary>Failing paths</summary>'
		echo
		echo '```'
		grep -E '^;|^\+|Report Timing|^Info' "$OUT/$REV.paths.rpt" | grep -v '^Info' | head -n 200
		echo '```'
		echo '</details>'
	fi
	exit 1
fi
echo
echo "Timing met."
