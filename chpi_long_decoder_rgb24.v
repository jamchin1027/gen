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
  output reg         useful20_valid,
  output reg  [19:0] useful20_data
);
  reg [25:0] raw_fifo, raw_fifo_next;
  reg [5:0]  raw_cnt, raw_cnt_next;
  reg [31:0] rgb_fifo, rgb_fifo_next;
  reg [5:0]  rgb_cnt, rgb_cnt_next;
  reg [25:0] useful_fifo, useful_fifo_next;
  reg [5:0]  useful_cnt, useful_cnt_next;
  reg [8:0]  bit_cnt_420, bit_cnt_420_next;
  reg [5:0]  label_reg;
  reg        replace_en;
  reg        rgb_emit_done;
  reg        useful_emit_done;
  reg [6:0]  group_in, group_out;
  integer k;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rgb_valid      <= 1'b0;
      rgb_data       <= 24'd0;
      useful20_valid <= 1'b0;
      useful20_data  <= 20'd0;
      raw_fifo       <= 26'd0;
      raw_cnt        <= 6'd0;
      rgb_fifo       <= 32'd0;
      rgb_cnt        <= 6'd0;
      useful_fifo    <= 26'd0;
      useful_cnt     <= 6'd0;
      bit_cnt_420    <= 9'd0;
      label_reg      <= 6'd0;
      replace_en     <= 1'b0;
    end else begin
      rgb_valid      <= 1'b0;
      useful20_valid <= 1'b0;

      raw_fifo_next     = raw_fifo;
      raw_cnt_next      = raw_cnt;
      rgb_fifo_next     = rgb_fifo;
      rgb_cnt_next      = rgb_cnt;
      useful_fifo_next  = useful_fifo;
      useful_cnt_next   = useful_cnt;
      bit_cnt_420_next  = bit_cnt_420;
      rgb_emit_done     = 1'b0;
      useful_emit_done  = 1'b0;

      if (rgb_cnt_next >= 6'd24) begin
        rgb_data       <= rgb_fifo_next[23:0];
        rgb_valid      <= 1'b1;
        rgb_fifo_next  = rgb_fifo_next >> 24;
        rgb_cnt_next   = rgb_cnt_next - 6'd24;
        rgb_emit_done  = 1'b1;
      end

      if (useful_cnt_next >= 6'd20) begin
        useful20_data      <= useful_fifo_next[19:0];
        useful20_valid     <= 1'b1;
        useful_fifo_next   = useful_fifo_next >> 20;
        useful_cnt_next    = useful_cnt_next - 6'd20;
        useful_emit_done   = 1'b1;
      end

      if (valid_i) begin
        raw_fifo_next = raw_fifo_next | ({{6{1'b0}}, chpi_in} << raw_cnt_next);
        raw_cnt_next  = raw_cnt_next + 6'd20;
      end

      for (k = 0; k < 3; k = k + 1) begin
        if (raw_cnt_next >= 6'd7) begin
          group_in = raw_fifo_next[6:0];

          if (bit_cnt_420_next == 9'd0) begin
            label_reg  = group_in[5:0];
            replace_en = (group_in[5:0] != {6{~group_in[6]}});
          end else begin
            if (replace_en && (group_in[6:1] == label_reg)) begin
              group_out = group_in[0] ? 7'b1111111 : 7'b0000000;
            end else begin
              group_out = group_in;
            end

            rgb_fifo_next = rgb_fifo_next | ({{25{1'b0}}, group_out} << rgb_cnt_next);
            rgb_cnt_next  = rgb_cnt_next + 6'd7;

            useful_fifo_next = useful_fifo_next | ({{19{1'b0}}, group_out} << useful_cnt_next);
            useful_cnt_next  = useful_cnt_next + 6'd7;

            if (!rgb_emit_done && (rgb_cnt_next >= 6'd24)) begin
              rgb_data       <= rgb_fifo_next[23:0];
              rgb_valid      <= 1'b1;
              rgb_fifo_next  = rgb_fifo_next >> 24;
              rgb_cnt_next   = rgb_cnt_next - 6'd24;
              rgb_emit_done  = 1'b1;
            end

            if (!useful_emit_done && (useful_cnt_next >= 6'd20)) begin
              useful20_data      <= useful_fifo_next[19:0];
              useful20_valid     <= 1'b1;
              useful_fifo_next   = useful_fifo_next >> 20;
              useful_cnt_next    = useful_cnt_next - 6'd20;
              useful_emit_done   = 1'b1;
            end
          end

          raw_fifo_next    = raw_fifo_next >> 7;
          raw_cnt_next     = raw_cnt_next - 6'd7;
          bit_cnt_420_next = (bit_cnt_420_next == 9'd413) ? 9'd0
                                                          : bit_cnt_420_next + 9'd7;
        end
      end

      raw_fifo    <= raw_fifo_next;
      raw_cnt     <= raw_cnt_next;
      rgb_fifo    <= rgb_fifo_next;
      rgb_cnt     <= rgb_cnt_next;
      useful_fifo <= useful_fifo_next;
      useful_cnt  <= useful_cnt_next;
      bit_cnt_420 <= bit_cnt_420_next;
    end
  end
endmodule
