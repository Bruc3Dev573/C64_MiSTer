// tb_savestates: test chain layout. Included before savestates.sv, it keeps
// the generated map (tags, sizes) and replaces only the chain description:
//   segment A, 70 bits, words 0-3  -> word 0: 64 bits, word 1: 6 bits
//   segment B,  0 bits, words 4-9  (reservation)
//   segment C,  5 bits, word 10
// The engine is instantiated with LIVE = 3'b111 (all three on the chain);
// tb_savestates_dead uses LIVE = 3'b101 (B dead, no bits anyway) and
// 3'b001 (C dead: its word is written as 0, the chain is A only).
`include "c64_savestates.vh"
`undef SS_CHAIN_BITS
`undef SS_WORD_NBITS
`undef SS_WORD_SEG
`undef SS_CHAIN_WORDS
`define SS_CHAIN_WORDS 128
`define SS_CHAIN_BITS 75
`define SS_WORD_NBITS {{117{7'd0}}, 7'd5, {8{7'd0}}, 7'd6, 7'd64}
`define SS_WORD_SEG   {{117{5'd31}}, 5'd2, {6{5'd1}}, {4{5'd0}}}
