# Core-level timing constraints (sys/sys_top.sdc holds the framework ones).

# hps_io video_calc: the video measurements (clk_vid = clk64) are copied to
# the HPS register file 'dout' in clk_sys. They change once per frame and the
# HPS only reads them occasionally, so the clk64 -> clk_sys transfer is not
# a synchronous path. As a timed path it sometimes failed hold by 0.33 ns
# (coincident clk64/clk_sys edges, 0.8 ns clock skew between the PLL outputs)
# depending on placement.
set_false_path -from [get_registers {*|video_calc:video_calc|vid_*}] -to [get_registers {*|video_calc:video_calc|dout[*]}]
