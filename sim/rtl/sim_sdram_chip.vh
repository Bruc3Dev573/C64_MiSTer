// Included only in the generated emu copy for SDRAM=real.
sim_mt48lc16m16 sdram_chip (
	.clk(SDRAM_CLK), .cke(SDRAM_CKE), .cs_n(SDRAM_nCS),
	.ras_n(SDRAM_nRAS), .cas_n(SDRAM_nCAS), .we_n(SDRAM_nWE),
	.addr(SDRAM_A), .ba(SDRAM_BA), .dqm({SDRAM_DQMH, SDRAM_DQML}),
	.dq(SDRAM_DQ), .ss_own(ss_sd_own)
);
