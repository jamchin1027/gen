`timescale 1ns/1ps

module chpi_decode_20b_stream_top (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        valid_i,
  input  wire [19:0] chpi_in,
  output wire        rgb_valid,
  output wire [23:0] rgb_data,
  output wire        useful20_valid,
  output wire [19:0] useful20_data
);
  chpi_420b413b_rgb24_stream_dec u_dec (
    .clk            (clk),
    .rst_n          (rst_n),
    .valid_i        (valid_i),
    .chpi_in        (chpi_in),
    .rgb_valid      (rgb_valid),
    .rgb_data       (rgb_data),
    .useful20_valid (useful20_valid),
    .useful20_data  (useful20_data)
  );
endmodule

module chpi_420b413b_rgb24_stream_dec (
  input  wire        clk,
  input  wire        rst_n,
  input  wire        valid_i,
  input  wire [19:0] chpi_in,
  output reg         rgb_valid,
  output reg  [23:0] rgb_data,
  output wire        useful20_valid,
  output wire [19:0] useful20_data
);
  // useful20 is a debug observation path in earlier demos. Tie it off here to
  // keep the production RGB path smaller.
  assign useful20_valid = 1'b0;
  assign useful20_data  = 20'd0;

  // Small-buffer state for a continuous 20b input stream.
  // raw_cnt_q is bounded to 0..26 because each clock appends 20b and drains
  // up to three 7b groups. A slower one-group parser would require a large
  // backlog buffer when valid_i is continuous.
  reg [25:0] raw_fifo_q, raw_fifo_n;
  reg [4:0]  raw_cnt_q, raw_cnt_n;

  // RGB packer holds at most 30 valid bits: 23 old bits + one 7b group.
  reg [29:0] rgb_fifo_q, rgb_fifo_n;
  reg [4:0]  rgb_cnt_q, rgb_cnt_n;

  reg [8:0]  bit_cnt_420_q, bit_cnt_420_n;
  reg [5:0]  label_q, label_n;
  reg        replace_en_q, replace_en_n;

  reg        rgb_valid_n;
  reg [23:0] rgb_data_n;

  reg [25:0] raw_fifo_w;
  reg [4:0]  raw_cnt_w;
  reg [29:0] rgb_fifo_w;
  reg [4:0]  rgb_cnt_w;
  reg [8:0]  bit_cnt_420_w;
  reg [5:0]  label_w;
  reg        replace_en_w;
  reg        rgb_emit_seen;
  reg [6:0]  group_in_w;
  reg [6:0]  group_out_w;
  integer    k;

  always @* begin
    raw_fifo_w    = raw_fifo_q;
    raw_cnt_w     = raw_cnt_q;
    rgb_fifo_w    = rgb_fifo_q;
    rgb_cnt_w     = rgb_cnt_q;
    bit_cnt_420_w = bit_cnt_420_q;
    label_w       = label_q;
    replace_en_w  = replace_en_q;
    rgb_valid_n   = 1'b0;
    rgb_data_n    = rgb_data;
    rgb_emit_seen = 1'b0;
    group_in_w    = 7'd0;
    group_out_w   = 7'd0;

    // First drain an old RGB24 word if the packer already has enough bits.
    if (rgb_cnt_w >= 5'd24) begin
      rgb_data_n    = rgb_fifo_w[23:0];
      rgb_valid_n   = 1'b1;
      rgb_fifo_w    = rgb_fifo_w >> 24;
      rgb_cnt_w     = rgb_cnt_w - 5'd24;
      rgb_emit_seen = 1'b1;
    end

    // Append one CHPI[19:0] input word, LSB first.
    if (valid_i) begin
      raw_fifo_w = raw_fifo_w | ({{6{1'b0}}, chpi_in} << raw_cnt_w);
      raw_cnt_w  = raw_cnt_w + 5'd20;
    end

    // Throughput note:
    // Continuous 20b input needs 20/7 groups per clock on average, therefore
    // this parser must drain two or three 7b groups per clock. This keeps the
    // raw buffer small instead of storing a whole line or a large backlog.
    for (k = 0; k < 3; k = k + 1) begin
      if (raw_cnt_w >= 5'd7) begin
        group_in_w = raw_fifo_w[6:0];

        if (bit_cnt_420_w == 9'd0) begin
          // Header group: {H, Label}. It updates state and is not RGB data.
          label_w      = group_in_w[5:0];
          replace_en_w = (group_in_w[5:0] != {6{~group_in_w[6]}});
        end else begin
          // Payload group: restore the label-coded all-0/all-1 cases.
          if (replace_en_w && (group_in_w[6:1] == label_w)) begin
            group_out_w = group_in_w[0] ? 7'b1111111 : 7'b0000000;
          end else begin
            group_out_w = group_in_w;
          end

          rgb_fifo_w = rgb_fifo_w | ({{23{1'b0}}, group_out_w} << rgb_cnt_w);
          rgb_cnt_w  = rgb_cnt_w + 5'd7;

          if (!rgb_emit_seen && (rgb_cnt_w >= 5'd24)) begin
            rgb_data_n    = rgb_fifo_w[23:0];
            rgb_valid_n   = 1'b1;
            rgb_fifo_w    = rgb_fifo_w >> 24;
            rgb_cnt_w     = rgb_cnt_w - 5'd24;
            rgb_emit_seen = 1'b1;
          end
        end

        raw_fifo_w    = raw_fifo_w >> 7;
        raw_cnt_w     = raw_cnt_w - 5'd7;
        bit_cnt_420_w = (bit_cnt_420_w == 9'd413) ? 9'd0
                                                   : bit_cnt_420_w + 9'd7;
      end
    end

    raw_fifo_n    = raw_fifo_w;
    raw_cnt_n     = raw_cnt_w;
    rgb_fifo_n    = rgb_fifo_w;
    rgb_cnt_n     = rgb_cnt_w;
    bit_cnt_420_n = bit_cnt_420_w;
    label_n       = label_w;
    replace_en_n  = replace_en_w;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      raw_fifo_q    <= 26'd0;
      raw_cnt_q     <= 5'd0;
      rgb_fifo_q    <= 30'd0;
      rgb_cnt_q     <= 5'd0;
      bit_cnt_420_q <= 9'd0;
      label_q       <= 6'd0;
      replace_en_q  <= 1'b0;
      rgb_valid     <= 1'b0;
      rgb_data      <= 24'd0;
    end else begin
      raw_fifo_q    <= raw_fifo_n;
      raw_cnt_q     <= raw_cnt_n;
      rgb_fifo_q    <= rgb_fifo_n;
      rgb_cnt_q     <= rgb_cnt_n;
      bit_cnt_420_q <= bit_cnt_420_n;
      label_q       <= label_n;
      replace_en_q  <= replace_en_n;
      rgb_valid     <= rgb_valid_n;
      rgb_data      <= rgb_data_n;
    end
  end
endmodule
