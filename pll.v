`define FIFO_DEPTH 768
`define PERIOD_FIFO_DEPTH 4
`define FLUSH_CYCLES 8
`define WD 14

module pll(
	input clk, 
	input reset,
	input sig_in,
	input [6:0] phase_adj,     /* in 128ths of full cycle */
	input [11:0] delay_adj,    /* in base clock cycles GOD HELP YOU IF THIS IS EVER MORE THAN HALF A CYCLE OH FUCK don't use it for that much delay you asswad */
	input [15:0] default_freq, /* x (clock freq) / 2^24 to get actual frequency */
	output reg osc_out,
	output reg sig_bad,
	output reg [`WD-1:0] per_avg);

	reg [15:0] freq, freq_nxt, diff, diff_nxt;
	reg        fb, fb_nxt, fb_buf_dly, sig, sig_dly, sig_buf_dly, osc, osc_dly;
	reg        sig_bad_nxt;

	reg [`FIFO_DEPTH - 1:0] sig_buffer, fb_buffer;
	wire fb_buf = fb_buffer[`FIFO_DEPTH - 1];
	wire sig_buf = sig_buffer[`FIFO_DEPTH - 1];

	/* ================== */
	/* oscillator control */
	/* ================== */
	reg [23:0] ctr, ctr_nxt, osc_nxt;
	reg [16:0] freq_nxt_x;

	always @(*) begin
		ctr_nxt = ctr + {8'b0, freq};
		osc_nxt = ctr_nxt + {phase_adj, 17'b0};

		freq_nxt_x = {1'b0, freq} + {diff[15], diff};
		if(!reset)
			freq_nxt = default_freq;
		else if(freq_nxt_x[16])
			freq_nxt = diff[0] ? 16'b0 : 16'hFFFF;
		else
			freq_nxt = freq_nxt_x[15:0];
	end

	always @(posedge clk or negedge reset) begin
		if(!reset) begin
			ctr     <= 24'b0;
			osc     <= 1'b0;
			osc_dly <= 1'b0;
		end else begin
			ctr     <= ctr_nxt;
			osc     <= osc_nxt[23];
			osc_dly <= osc;
		end
	end

	always @(posedge clk) begin
		osc_out <= ctr_nxt[23];
		freq <= freq_nxt;
	end

	/* ====================================== */
	/* phase detect - generate frequency diff */
	/* ====================================== */
	reg [1:0] err, err_nxt, err_dif;
	reg       pd_up, pd_up_nxt, pd_dn, pd_dn_nxt;

	wire sig_edge = sig_buf && !sig_buf_dly;
	wire fb_edge  = fb_buf && !fb_buf_dly;

	always @(*) begin
		pd_up_nxt = ((pd_up && pd_dn) || sig_bad) ? 1'b0 : pd_up | sig_edge;
		pd_dn_nxt = ((pd_up && pd_dn) || sig_bad) ? 1'b0 : pd_dn | fb_edge;

		err     = {1'b0, pd_up} - {1'b0, pd_dn};
		err_nxt = {1'b0, pd_up_nxt} - {1'b0, pd_dn_nxt};
		err_dif = err_nxt - err;
		diff_nxt = {{9{err_nxt[1]}}, err_nxt, 5'b0} + {err_dif, 14'b0};
	end

	always @(posedge clk or negedge reset) begin
		if(!reset) begin
			diff  <= 16'b0;
			pd_up <= 1'b0;
			pd_dn <= 1'b0;
		end else begin
			diff  <= diff_nxt;
			pd_up <= pd_up_nxt;
			pd_dn <= pd_dn_nxt;
		end
	end

	/* ======================================= */
	/* feedback delay and edge detection flops */
	/* ======================================= */
	reg [11:0] dly_ctr, dly_ctr_nxt, dly_ctr_max;
	reg        dly_count, dly_count_nxt;

	always @(*) begin
		/* delay feedback to create negative delay */
		dly_count_nxt = dly_count;
		dly_ctr_nxt = dly_ctr;
		fb_nxt = fb;

		if(osc ^ osc_dly) begin
			dly_ctr_nxt = dly_ctr_max;
			dly_count_nxt = 1'b1;
		end else if(!dly_ctr) begin
			dly_count_nxt = 1'b0;
			fb_nxt = osc;
		end else if(dly_count) begin
			dly_ctr_nxt = dly_ctr - 1;
		end
	end

	always @(posedge clk or negedge reset) begin
		if(!reset) begin
			dly_ctr   <= 12'b0;
			dly_count <= 1'b0;
			fb        <= 1'b0;
			sig       <= 1'b0;
		end else begin
			dly_ctr   <= dly_ctr_nxt;
			dly_count <= dly_count_nxt;
			fb        <= fb_nxt;
			sig       <= sig_in;
		end
	end

	always @(posedge clk) begin
		dly_ctr_max <= delay_adj;
		sig_dly     <= sig;
		sig_buf_dly <= sig_buf;
		fb_buf_dly  <= fb_buf;
	end

	/* ================= */
	/* badness detection */
	/* ================= */
	reg [`WD-1:0] per_buffer[`PERIOD_FIFO_DEPTH - 1:0];
	reg [`WD-1:0] per_ctr, per_ctr_nxt, bad_ctr, bad_ctr_nxt, trn_ctr, trn_ctr_nxt;
	reg [`WD-1:0] post_bad_ctr, post_bad_ctr_nxt;
	reg     [3:0] flush_ctr, flush_ctr_nxt;
	reg           per_upd, per_upd_nxt, post_bad_cnt, post_bad_cnt_nxt;

	/* average the signal period */
	wire [`WD:0] per_buf_sum00 = {1'b0, per_buffer[0]} + {1'b0, per_buffer[1]};
	wire [`WD:0] per_buf_sum01 = {1'b0, per_buffer[2]} + {1'b0, per_buffer[3]};
	wire [`WD:0] per_buf_sum10 = {1'b0, per_buf_sum00[`WD:1]} + {1'b0, per_buf_sum01[`WD:1]};

	wire not_flushed = |(flush_ctr);
	/* debugging only - transitions < 1/4 cycle or > 1 cycle count as bad */
	wire trn_bad = (trn_ctr < {2'b0, per_avg[`WD-1:2]}) || (trn_ctr > per_avg);

	always @(*) begin
		/* output period counter */
		if(per_upd)
			per_ctr_nxt = `WD'b0;
		else
			per_ctr_nxt = per_ctr + 1;

		per_upd_nxt = fb && !fb_buffer[0];
		if(per_upd_nxt && not_flushed)
			flush_ctr_nxt = flush_ctr - 1;
		else
			flush_ctr_nxt = flush_ctr;

		/* transition counter */
		if(sig ^ sig_dly)
			trn_ctr_nxt = 1'b0;
		else if(trn_ctr == `WD'hFFFF)
			trn_ctr_nxt = trn_ctr;
		else
			trn_ctr_nxt = trn_ctr + 1;

		/* mark as bad if edge is too early, edge is too late, or period fifo is not yet initialized */
		if((sig ^ sig_dly && (trn_ctr < {2'b0, per_avg[`WD-1:2]})) ||
		   (trn_ctr > per_avg) || not_flushed)
			bad_ctr_nxt = `FIFO_DEPTH;
		else if(bad_ctr == `WD'b0)
			bad_ctr_nxt = `WD'b0;
		else
			bad_ctr_nxt = bad_ctr - 1;

		/* delay un-badification until a quarter cycle past fb_edge */
		post_bad_ctr_nxt = post_bad_ctr;
		post_bad_cnt_nxt = post_bad_cnt;
		if(bad_ctr) begin
			post_bad_ctr_nxt = {2'b0, per_avg[`WD-1:2]};
		end else if(post_bad_ctr && (post_bad_cnt || fb_edge)) begin
			post_bad_ctr_nxt = post_bad_ctr - 1;
			post_bad_cnt_nxt = 1'b1;
		end else if(!post_bad_ctr) begin
			post_bad_ctr_nxt = `WD'b0;
			post_bad_cnt_nxt = 1'b0;
		end

		sig_bad_nxt = (|(bad_ctr)) || (|(post_bad_ctr));
	end

	always @(posedge clk or negedge reset) begin
		if(!reset) begin
			per_ctr      <= `WD'b0;
			trn_ctr      <= `WD'b0;
			per_avg      <= `WD'b0;
			per_upd      <= 1'b1;
			bad_ctr      <= `WD'b0;
			sig_bad      <= 1'b0;
			post_bad_ctr <= `WD'b0;
			post_bad_cnt <= 1'b0;
			flush_ctr    <= `FLUSH_CYCLES;
		end else begin
			per_ctr      <= per_ctr_nxt;
			trn_ctr      <= trn_ctr_nxt;
			per_avg      <= per_buf_sum10[`WD:1];
			per_upd      <= per_upd_nxt;
			bad_ctr      <= bad_ctr_nxt;
			sig_bad      <= sig_bad_nxt;
			post_bad_ctr <= post_bad_ctr_nxt;
			post_bad_cnt <= post_bad_cnt_nxt;
			flush_ctr    <= flush_ctr_nxt;
		end
	end

	/* gross */
	integer i;
	always @(posedge clk) begin
		if(per_upd) begin
			for(i = 0; i < `PERIOD_FIFO_DEPTH - 1; i = i + 1)
				per_buffer[i + 1] <= per_buffer[i];
			per_buffer[0] <= per_ctr;
		end
		sig_buffer <= {sig_buffer[`FIFO_DEPTH-2:0], sig_dly};
		fb_buffer  <= {fb_buffer [`FIFO_DEPTH-2:0], fb     };
	end
endmodule
