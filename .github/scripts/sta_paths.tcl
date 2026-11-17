# Failing timing paths of a compiled revision, every corner, setup and hold.
#   quartus_sta -t sta_paths.tcl <project> <revision> <out file>
# Run by the CI after the compile; quartus_report.sh adds the result to the
# report, so a failing build says which clocks and registers to look at.
set project [lindex $quartus(args) 0]
set rev     [lindex $quartus(args) 1]
set out     [lindex $quartus(args) 2]
project_open $project -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist
file delete -force $out
foreach_in_collection op [get_available_operating_conditions] {
	set_operating_conditions $op
	update_timing_netlist
	foreach kind {setup hold} {
		report_timing -$kind -npaths 15 -less_than_slack 0.0 -detail summary \
			-panel_name "$kind $op" -file $out -append
	}
}
delete_timing_netlist
project_close
