`timescale 1ns / 1ps
`define FB_DLY_MIN 10'd130
`define FB_DLY_MAX 10'd180
`define SELF_TEST

module fbgen(
	input       clk,
	input       fb_in,
	input [9:0] dly,
	output reg  fb_out
);

	reg [1023:0] dlyreg;
	always @(posedge clk) begin
		dlyreg <= {dlyreg[1022:0], fb_in};
		fb_out <= dlyreg[dly];
	end
endmodule

module top(
	input        xtal_clk,
	input  [7:0] switch,
	input  [3:0] button,
	output [7:0] leds,

	input  [3:0] pmod00,
	output [3:0] pmod01
);

	reg [6:0]  phase_adj;
	reg [11:0] delay_adj;
	reg [15:0] reset_ctr;
	reg        reset, sig_in_sync;

	wire [13:0] per_avg;
	wire        clk, sig_bad, osc_out, locked;
`ifdef SELF_TEST
	wire local_fb, local_fb_noise;
	wire fb = local_fb_noise;
`else
	wire fb = sig_in_sync;
`endif

	/* outputs */
	assign pmod01[0] = osc_out;
	assign pmod01[1] = !osc_out;
	assign pmod01[2] = fb;
	assign pmod01[3] = sig_bad;
	assign leds = per_avg[9:2];

	core_dcm core_dcm_inst(.CLKIN_IN(xtal_clk), .RST_IN(0), .CLK2X_OUT(clk),.LOCKED_OUT(locked));

	pll pll_inst(.clk(clk), .reset(reset), .sig_in(fb),
	             .phase_adj(phase_adj), .delay_adj(delay_adj), .default_freq(16'd28000),
	             .osc_out(osc_out), .sig_bad(sig_bad), .per_avg(per_avg));

	always @(posedge clk) begin
		if(button[3] || !locked)
			reset_ctr <= 16'hFFFF;
		else if(reset_ctr)
			reset_ctr <= reset_ctr - 1;
		else
			reset_ctr <= 16'b0;

		reset <= !reset_ctr;

		/* phase adjust probably should not be touched during operation */
		phase_adj <= {switch[1:0], 5'b0};
		delay_adj <= {5'b0, switch[7:2], 1'b1};
		sig_in_sync <= pmod00[0];
	end

`ifdef SELF_TEST
	/* feedback generation and stuff */
	reg [9:0]  fb_dly, fb_dly_nxt;
	reg [21:0] slow_ctr;
	reg        fb_dly_up, fb_dly_up_nxt;

	fbgen fbgen_inst(.clk(clk), .fb_in(osc_out), .fb_out(local_fb), .dly(fb_dly));

	always @(*) begin
		if(fb_dly == `FB_DLY_MAX)
			fb_dly_up_nxt = 1'b0;
		else if(fb_dly == `FB_DLY_MIN)
			fb_dly_up_nxt = 1'b1;
		else
			fb_dly_up_nxt = fb_dly_up;

		if(!slow_ctr && !button[1]) begin
			if(fb_dly_up)
				fb_dly_nxt = fb_dly + 1;
			else
				fb_dly_nxt = fb_dly - 1;
		end else begin
			fb_dly_nxt = fb_dly;
		end
	end

	always @(posedge clk or negedge reset) begin
		if(!reset) begin
			fb_dly <= `FB_DLY_MIN;
			fb_dly_up <= 1'b1;
			slow_ctr <= 12'b0;
		end else begin
			fb_dly <= fb_dly_nxt;
			fb_dly_up <= fb_dly_up_nxt;
			slow_ctr <= slow_ctr + 1;
		end
	end

	/* noise injection */
	wire force_bad = (slow_ctr[20:6] == 15'h5191) && button[2];
	assign local_fb_noise = button[0] ? (force_bad ? slow_ctr[3] : local_fb) : 1'b0;
`endif

endmodule
