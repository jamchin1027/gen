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
  // This module is synthesis-intended RTL for the RGB24 path.
  // CHPI[19:0] enters LSB first. Each 420b packet is 7b header + 413b data.
  // The first 7b group is {H, Label}; it updates state and is not RGB data.

  assign useful20_valid = 1'b0;
  assign useful20_data  = 20'd0;

  localparam [4:0] RAW_GROUP_BITS = 5'd7;
  localparam [4:0] CHPI_BUS_BITS  = 5'd20;
  localparam [4:0] RGB_WORD_BITS  = 5'd24;
  localparam [8:0] LAST_413_POS   = 9'd413;

  // Raw aligner state. The registered residue is 0..6 bits after every clock.
  // After appending one 20b word, the temporary count is at most 26 bits.
  reg [25:0] raw_shift;
  reg [4:0]  raw_bit_count;

  // Packet/header state.
  reg [8:0]  packet_bit_count;
  reg [5:0]  active_label;
  reg        restore_enable;

  // RGB24 packer state. The registered residue is kept below 24 bits.
  // During one clock, 23 old bits + one 7b group needs a 30b shifter.
  reg [29:0] rgb_shift;
  reg [4:0]  rgb_bit_count;

  // Append current CHPI word before the three explicit parser stages.
  reg [25:0] append_raw_shift;
  reg [4:0]  append_raw_count;

  // Parser stage 0.
  reg [25:0] st0_raw_shift;
  reg [4:0]  st0_raw_count;
  reg [8:0]  st0_packet_bit_count;
  reg [5:0]  st0_label;
  reg        st0_restore_enable;
  reg        st0_payload_valid;
  reg [6:0]  st0_payload_bits;

  // Parser stage 1.
  reg [25:0] st1_raw_shift;
  reg [4:0]  st1_raw_count;
  reg [8:0]  st1_packet_bit_count;
  reg [5:0]  st1_label;
  reg        st1_restore_enable;
  reg        st1_payload_valid;
  reg [6:0]  st1_payload_bits;

  // Parser stage 2.
  reg [25:0] st2_raw_shift;
  reg [4:0]  st2_raw_count;
  reg [8:0]  st2_packet_bit_count;
  reg [5:0]  st2_label;
  reg        st2_restore_enable;
  reg        st2_payload_valid;
  reg [6:0]  st2_payload_bits;

  // RGB packer combinational result.
  reg [29:0] pack_shift;
  reg [4:0]  pack_count;
  reg        pack_emit_valid;
  reg [23:0] pack_emit_data;

  function [8:0] packet_count_after_group;
    input [8:0] count_now;
    begin
      if (count_now == LAST_413_POS) begin
        packet_count_after_group = 9'd0;
      end else begin
        packet_count_after_group = count_now + 9'd7;
      end
    end
  endfunction

  function [6:0] restore_payload_group;
    input [6:0] group_bits;
    input [5:0] label_bits;
    input       label_is_active;
    begin
      if (label_is_active && (group_bits[6:1] == label_bits)) begin
        if (group_bits[0]) begin
          restore_payload_group = 7'b1111111;
        end else begin
          restore_payload_group = 7'b0000000;
        end
      end else begin
        restore_payload_group = group_bits;
      end
    end
  endfunction

  always @* begin
    append_raw_shift = raw_shift;
    append_raw_count = raw_bit_count;

    if (valid_i) begin
      append_raw_shift = raw_shift | ({{6{1'b0}}, chpi_in} << raw_bit_count);
      append_raw_count = raw_bit_count + CHPI_BUS_BITS;
    end else begin
      append_raw_shift = raw_shift;
      append_raw_count = raw_bit_count;
    end
  end

  // Stage 0: first possible 7b group in this clock.
  always @* begin
    st0_raw_shift        = append_raw_shift;
    st0_raw_count        = append_raw_count;
    st0_packet_bit_count = packet_bit_count;
    st0_label            = active_label;
    st0_restore_enable   = restore_enable;
    st0_payload_valid    = 1'b0;
    st0_payload_bits     = 7'd0;

    if (append_raw_count >= RAW_GROUP_BITS) begin
      if (packet_bit_count == 9'd0) begin
        st0_label          = append_raw_shift[5:0];
        st0_restore_enable = (append_raw_shift[5:0] != {6{~append_raw_shift[6]}});
        st0_payload_valid  = 1'b0;
        st0_payload_bits   = 7'd0;
      end else begin
        st0_label          = active_label;
        st0_restore_enable = restore_enable;
        st0_payload_valid  = 1'b1;
        st0_payload_bits   = restore_payload_group(append_raw_shift[6:0],
                                                   active_label,
                                                   restore_enable);
      end

      st0_raw_shift        = append_raw_shift >> RAW_GROUP_BITS;
      st0_raw_count        = append_raw_count - RAW_GROUP_BITS;
      st0_packet_bit_count = packet_count_after_group(packet_bit_count);
    end else begin
      st0_raw_shift        = append_raw_shift;
      st0_raw_count        = append_raw_count;
      st0_packet_bit_count = packet_bit_count;
      st0_label            = active_label;
      st0_restore_enable   = restore_enable;
      st0_payload_valid    = 1'b0;
      st0_payload_bits     = 7'd0;
    end
  end

  // Stage 1: second possible 7b group in this clock.
  always @* begin
    st1_raw_shift        = st0_raw_shift;
    st1_raw_count        = st0_raw_count;
    st1_packet_bit_count = st0_packet_bit_count;
    st1_label            = st0_label;
    st1_restore_enable   = st0_restore_enable;
    st1_payload_valid    = 1'b0;
    st1_payload_bits     = 7'd0;

    if (st0_raw_count >= RAW_GROUP_BITS) begin
      if (st0_packet_bit_count == 9'd0) begin
        st1_label          = st0_raw_shift[5:0];
        st1_restore_enable = (st0_raw_shift[5:0] != {6{~st0_raw_shift[6]}});
        st1_payload_valid  = 1'b0;
        st1_payload_bits   = 7'd0;
      end else begin
        st1_label          = st0_label;
        st1_restore_enable = st0_restore_enable;
        st1_payload_valid  = 1'b1;
        st1_payload_bits   = restore_payload_group(st0_raw_shift[6:0],
                                                   st0_label,
                                                   st0_restore_enable);
      end

      st1_raw_shift        = st0_raw_shift >> RAW_GROUP_BITS;
      st1_raw_count        = st0_raw_count - RAW_GROUP_BITS;
      st1_packet_bit_count = packet_count_after_group(st0_packet_bit_count);
    end else begin
      st1_raw_shift        = st0_raw_shift;
      st1_raw_count        = st0_raw_count;
      st1_packet_bit_count = st0_packet_bit_count;
      st1_label            = st0_label;
      st1_restore_enable   = st0_restore_enable;
      st1_payload_valid    = 1'b0;
      st1_payload_bits     = 7'd0;
    end
  end

  // Stage 2: third possible 7b group in this clock.
  always @* begin
    st2_raw_shift        = st1_raw_shift;
    st2_raw_count        = st1_raw_count;
    st2_packet_bit_count = st1_packet_bit_count;
    st2_label            = st1_label;
    st2_restore_enable   = st1_restore_enable;
    st2_payload_valid    = 1'b0;
    st2_payload_bits     = 7'd0;

    if (st1_raw_count >= RAW_GROUP_BITS) begin
      if (st1_packet_bit_count == 9'd0) begin
        st2_label          = st1_raw_shift[5:0];
        st2_restore_enable = (st1_raw_shift[5:0] != {6{~st1_raw_shift[6]}});
        st2_payload_valid  = 1'b0;
        st2_payload_bits   = 7'd0;
      end else begin
        st2_label          = st1_label;
        st2_restore_enable = st1_restore_enable;
        st2_payload_valid  = 1'b1;
        st2_payload_bits   = restore_payload_group(st1_raw_shift[6:0],
                                                   st1_label,
                                                   st1_restore_enable);
      end

      st2_raw_shift        = st1_raw_shift >> RAW_GROUP_BITS;
      st2_raw_count        = st1_raw_count - RAW_GROUP_BITS;
      st2_packet_bit_count = packet_count_after_group(st1_packet_bit_count);
    end else begin
      st2_raw_shift        = st1_raw_shift;
      st2_raw_count        = st1_raw_count;
      st2_packet_bit_count = st1_packet_bit_count;
      st2_label            = st1_label;
      st2_restore_enable   = st1_restore_enable;
      st2_payload_valid    = 1'b0;
      st2_payload_bits     = 7'd0;
    end
  end

  // RGB24 packer. It appends stage0/1/2 payload groups in order and emits at
  // most one 24b RGB word per clock.
  always @* begin
    pack_shift      = rgb_shift;
    pack_count      = rgb_bit_count;
    pack_emit_valid = 1'b0;
    pack_emit_data  = 24'd0;

    if (st0_payload_valid) begin
      pack_shift = pack_shift | ({{23{1'b0}}, st0_payload_bits} << pack_count);
      pack_count = pack_count + RAW_GROUP_BITS;
      if (pack_count >= RGB_WORD_BITS) begin
        pack_emit_data  = pack_shift[23:0];
        pack_emit_valid = 1'b1;
        pack_shift      = pack_shift >> RGB_WORD_BITS;
        pack_count      = pack_count - RGB_WORD_BITS;
      end else begin
        pack_emit_data  = 24'd0;
        pack_emit_valid = 1'b0;
      end
    end else begin
      // No stage0 payload; keep defaults from the current RGB packer state.
    end

    if (st1_payload_valid) begin
      pack_shift = pack_shift | ({{23{1'b0}}, st1_payload_bits} << pack_count);
      pack_count = pack_count + RAW_GROUP_BITS;
      if (!pack_emit_valid && (pack_count >= RGB_WORD_BITS)) begin
        pack_emit_data  = pack_shift[23:0];
        pack_emit_valid = 1'b1;
        pack_shift      = pack_shift >> RGB_WORD_BITS;
        pack_count      = pack_count - RGB_WORD_BITS;
      end else begin
        // Either no RGB24 is ready yet, or this clock already emitted one.
      end
    end else begin
      // No stage1 payload; keep the result from prior packer steps.
    end

    if (st2_payload_valid) begin
      pack_shift = pack_shift | ({{23{1'b0}}, st2_payload_bits} << pack_count);
      pack_count = pack_count + RAW_GROUP_BITS;
      if (!pack_emit_valid && (pack_count >= RGB_WORD_BITS)) begin
        pack_emit_data  = pack_shift[23:0];
        pack_emit_valid = 1'b1;
        pack_shift      = pack_shift >> RGB_WORD_BITS;
        pack_count      = pack_count - RGB_WORD_BITS;
      end else begin
        // Either no RGB24 is ready yet, or this clock already emitted one.
      end
    end else begin
      // No stage2 payload; keep the result from prior packer steps.
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      raw_shift     <= 26'd0;
      raw_bit_count <= 5'd0;
    end else begin
      raw_shift     <= st2_raw_shift;
      raw_bit_count <= st2_raw_count;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      packet_bit_count <= 9'd0;
    end else begin
      packet_bit_count <= st2_packet_bit_count;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_label   <= 6'd0;
      restore_enable <= 1'b0;
    end else begin
      active_label   <= st2_label;
      restore_enable <= st2_restore_enable;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rgb_shift     <= 30'd0;
      rgb_bit_count <= 5'd0;
    end else begin
      rgb_shift     <= pack_shift;
      rgb_bit_count <= pack_count;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rgb_valid <= 1'b0;
      rgb_data  <= 24'd0;
    end else begin
      rgb_valid <= pack_emit_valid;
      if (pack_emit_valid) begin
        rgb_data <= pack_emit_data;
      end else begin
        rgb_data <= 24'd0;
      end
    end
  end
endmodule
