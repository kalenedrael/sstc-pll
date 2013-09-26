`timescale 1ns / 1ps

////////////////////////////////////////////////////////////////////////////////
// Company:  Emarhavil Heavy Industries
// Engineer: Wat
//
// Create Date:   19:13:13 04/07/2013
// Design Name:   pll
// Module Name:   /var/home/lu/projects/ise/sstc/tester.v
// Project Name:  sstc
// Target Device:  
// Tool versions:  
// Description: 
//
// Verilog Test Fixture created by ISE for module: pll
//
// Dependencies:
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
////////////////////////////////////////////////////////////////////////////////

`define CLK_PER_HALF 5
`define OSC_PERIOD 6000
`define FB_DELAY 10
`define OSC_PER_CLK (`OSC_PERIOD / (`CLK_PER_HALF * 2))
`define STARTUP_CYCLES 50

`define TRANSITIONS_MAX 10
`define STFU_MIN 3
`define STFU_RANGE 10
`define ERROR_PCT 2

/* I guess it doesn't work without feed-forward anymore - SSTC use only! */
`define USE_FEEDFWD

module tester;
	function [31:0] gen_rnd;
	input [31:0] max;
	reg [31:0] bs;
	begin
		bs = $random();
		gen_rnd = bs % max;
	end
	endfunction

	// Inputs
	reg clk, reset, sig_in_reg;
	reg [6:0] phase_adj;
	reg [11:0] delay_adj;
	reg [15:0] default_freq;
	wire sig_in = sig_in_reg;

	// Outputs
	wire osc_out, sig_bad;
	wire [13:0] per_avg;

	reg [31:0] start_ctr, trn, i, osc_period;

	/* IN REAL LIFE, PASS sig_in THROUGH A SYNCHRONIZER FIRST
	 * set delay_adj to the delay of the synchronizer if you're bent out of shape about it
	 */
	pll uut (
		.clk(clk), 
		.reset(reset), 
		.sig_in(sig_in), 
		.phase_adj(phase_adj), 
		.delay_adj(delay_adj), 
		.default_freq(default_freq), 
		.osc_out(osc_out),
		.sig_bad(sig_bad),
		.per_avg(per_avg)
	);

	initial begin
		// Initialize Inputs
		trn = $random(0);
		clk = 1'b1;
		reset = 1'b0;
		sig_in_reg = 1'b0;
		/* 3/4 cycle */
		phase_adj = 7'b1100000;
		delay_adj = `FB_DELAY;
		default_freq = 16'd38000;
		osc_period = 32'b0;

		// Wait freaking forever global reset to finish
		#12000;
		// Add stimulus here
		reset = 1'b1;
		start_ctr = 0;
	end

	always
		#(`CLK_PER_HALF) clk = !clk;

`ifdef USE_FEEDFWD
	always @(osc_out)
		sig_in_reg <= #(`OSC_PERIOD / 4 + `FB_DELAY * `CLK_PER_HALF * 2) osc_out;
`else
	always begin
		#(`OSC_PERIOD / 2);
		sig_in_reg <= ~sig_in_reg;
	end
`endif

	/* inject off time */
	always @(posedge sig_in) begin
		start_ctr = start_ctr + 1;
		if(gen_rnd(20) == 0) begin
			/* shut off signal for a certain number of clocks */
			$display("(%t) stfu!", $time);
			force sig_in = 1'b0;
			#((gen_rnd(`STFU_RANGE) + `STFU_MIN) * `OSC_PERIOD - `OSC_PERIOD / 4);
			release sig_in;
		end
	end

	/* inject glitches */
	always begin
		#5;
		if(gen_rnd(2000) == 0) begin
			$display("(%t) noisy noisy", $time);
			trn = gen_rnd(`TRANSITIONS_MAX);
			for(i = 0; i < trn + 2; i = i + 1) begin
				/* is multiple of clock period */
				#((gen_rnd(40) + 1) * `CLK_PER_HALF * 2);
				force sig_in = ~sig_in;
			end
			release sig_in;
		end
		#45;
	end

	always @(posedge clk)
		osc_period = osc_period + 1;

	/* monitor osc_out for BS */
	always @(posedge osc_out) begin
		if(start_ctr > `STARTUP_CYCLES) begin
			if(osc_period > (`OSC_PER_CLK * (100 + `ERROR_PCT) / 100) ||
			   osc_period < (`OSC_PER_CLK * (100 - `ERROR_PCT) / 100))
				$display("(%t) ========= PLL went A! =========", $time);
		end
		osc_period = 32'b0;
	end
endmodule
