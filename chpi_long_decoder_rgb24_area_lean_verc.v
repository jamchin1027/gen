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
  // Synthesis-intended area-lean RTL.
  // CHPI[19:0] enters LSB first. Each 420b packet is:
  //   7b header {H, Label[5:0]} + 59 payload groups of 7b = 420b.
  // The header group updates label state and is not sent to the RGB packer.

  assign useful20_valid = 1'b0;
  assign useful20_data  = 20'd0;

  localparam [4:0] RAW_GROUP_BITS = 5'd7;
  localparam [4:0] CHPI_BUS_BITS  = 5'd20;
  localparam [4:0] RGB_WORD_BITS  = 5'd24;
  localparam [5:0] LAST_GROUP     = 6'd59;

  // Registered residue only. The wide 26b aligner exists only as
  // combinational temporary logic after appending the new 20b word.
  reg [5:0] raw_residue;
  reg [2:0] raw_bit_count;

  // 420b packet group counter:
  //   0      : header group
  //   1..59  : 59 decoded 7b payload groups
  reg [5:0] packet_group_count;
  reg [5:0] active_label;
  reg       restore_enable;

  // Registered RGB residue only. At clock edge this holds at most 23 bits.
  // The 30b packer is a combinational temporary for 23 old bits + 7 new bits.
  reg [22:0] rgb_residue;
  reg [4:0]  rgb_bit_count;

  reg [25:0] append_raw_shift;
  reg [4:0]  append_raw_count;
  reg [5:0]  raw_residue_next;
  reg [2:0]  raw_bit_count_next;

  wire        group0_valid;
  wire        group1_valid;
  wire        group2_valid;
  wire [6:0]  group0_bits;
  wire [6:0]  group1_bits;
  wire [6:0]  group2_bits;

  reg [5:0] st0_packet_group_count;
  reg [5:0] st0_label;
  reg       st0_restore_enable;
  reg       st0_payload_valid;
  reg [6:0] st0_payload_bits;

  reg [5:0] st1_packet_group_count;
  reg [5:0] st1_label;
  reg       st1_restore_enable;
  reg       st1_payload_valid;
  reg [6:0] st1_payload_bits;

  reg [5:0] st2_packet_group_count;
  reg [5:0] st2_label;
  reg       st2_restore_enable;
  reg       st2_payload_valid;
  reg [6:0] st2_payload_bits;

  reg [29:0] pack_shift;
  reg [4:0]  pack_count;
  reg [22:0] rgb_residue_next;
  reg [4:0]  rgb_bit_count_next;
  reg        pack_emit_valid;
  reg [23:0] pack_emit_data;

  assign group0_valid = (append_raw_count >= 5'd7);
  assign group1_valid = (append_raw_count >= 5'd14);
  assign group2_valid = (append_raw_count >= 5'd21);

  assign group0_bits = append_raw_shift[6:0];
  assign group1_bits = append_raw_shift[13:7];
  assign group2_bits = append_raw_shift[20:14];

  function [5:0] next_packet_group;
    input [5:0] group_now;
    begin
      if (group_now == LAST_GROUP) begin
        next_packet_group = 6'd0;
      end else begin
        next_packet_group = group_now + 6'd1;
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

  function [29:0] insert_rgb_group;
    input [29:0] shift_in;
    input [4:0]  count_in;
    input [6:0]  group_bits;
    reg   [29:0] shift_tmp;
    begin
      shift_tmp = shift_in;
      case (count_in)
        5'd0:  shift_tmp[6:0]   = group_bits;
        5'd1:  shift_tmp[7:1]   = group_bits;
        5'd2:  shift_tmp[8:2]   = group_bits;
        5'd3:  shift_tmp[9:3]   = group_bits;
        5'd4:  shift_tmp[10:4]  = group_bits;
        5'd5:  shift_tmp[11:5]  = group_bits;
        5'd6:  shift_tmp[12:6]  = group_bits;
        5'd7:  shift_tmp[13:7]  = group_bits;
        5'd8:  shift_tmp[14:8]  = group_bits;
        5'd9:  shift_tmp[15:9]  = group_bits;
        5'd10: shift_tmp[16:10] = group_bits;
        5'd11: shift_tmp[17:11] = group_bits;
        5'd12: shift_tmp[18:12] = group_bits;
        5'd13: shift_tmp[19:13] = group_bits;
        5'd14: shift_tmp[20:14] = group_bits;
        5'd15: shift_tmp[21:15] = group_bits;
        5'd16: shift_tmp[22:16] = group_bits;
        5'd17: shift_tmp[23:17] = group_bits;
        5'd18: shift_tmp[24:18] = group_bits;
        5'd19: shift_tmp[25:19] = group_bits;
        5'd20: shift_tmp[26:20] = group_bits;
        5'd21: shift_tmp[27:21] = group_bits;
        5'd22: shift_tmp[28:22] = group_bits;
        5'd23: shift_tmp[29:23] = group_bits;
        default: shift_tmp = shift_in;
      endcase
      insert_rgb_group = shift_tmp;
    end
  endfunction

  // Append the new 20b word with a 7-case mux instead of a generic barrel
  // shifter. raw_bit_count is a registered residue and can only be 0..6.
  always @* begin
    append_raw_shift = {20'd0, raw_residue};
    append_raw_count = {2'd0, raw_bit_count};

    if (valid_i) begin
      append_raw_count = {2'd0, raw_bit_count} + CHPI_BUS_BITS;
      case (raw_bit_count)
        3'd0: append_raw_shift = {6'd0, chpi_in};
        3'd1: append_raw_shift = {5'd0, chpi_in, raw_residue[0]};
        3'd2: append_raw_shift = {4'd0, chpi_in, raw_residue[1:0]};
        3'd3: append_raw_shift = {3'd0, chpi_in, raw_residue[2:0]};
        3'd4: append_raw_shift = {2'd0, chpi_in, raw_residue[3:0]};
        3'd5: append_raw_shift = {1'd0, chpi_in, raw_residue[4:0]};
        3'd6: append_raw_shift = {chpi_in, raw_residue[5:0]};
        default: append_raw_shift = {6'd0, chpi_in};
      endcase
    end
  end

  // Keep only the post-parser residue in flops.
  always @* begin
    raw_residue_next   = append_raw_shift[5:0];
    raw_bit_count_next = append_raw_count[2:0];

    if (append_raw_count >= 5'd21) begin
      raw_residue_next   = {1'b0, append_raw_shift[25:21]};
      raw_bit_count_next = append_raw_count - 5'd21;
    end else if (append_raw_count >= 5'd14) begin
      raw_residue_next   = append_raw_shift[19:14];
      raw_bit_count_next = append_raw_count - 5'd14;
    end else if (append_raw_count >= 5'd7) begin
      raw_residue_next   = append_raw_shift[12:7];
      raw_bit_count_next = append_raw_count - 5'd7;
    end
  end

  // Stage 0: first possible 7b group in this clock.
  always @* begin
    st0_packet_group_count = packet_group_count;
    st0_label              = active_label;
    st0_restore_enable     = restore_enable;
    st0_payload_valid      = 1'b0;
    st0_payload_bits       = 7'd0;

    if (group0_valid) begin
      st0_packet_group_count = next_packet_group(packet_group_count);
      if (packet_group_count == 6'd0) begin
        st0_label          = group0_bits[5:0];
        st0_restore_enable = (group0_bits[5:0] != {6{~group0_bits[6]}});
        st0_payload_valid  = 1'b0;
        st0_payload_bits   = 7'd0;
      end else begin
        st0_label          = active_label;
        st0_restore_enable = restore_enable;
        st0_payload_valid  = 1'b1;
        st0_payload_bits   = restore_payload_group(group0_bits,
                                                   active_label,
                                                   restore_enable);
      end
    end
  end

  // Stage 1: second possible 7b group in this clock.
  always @* begin
    st1_packet_group_count = st0_packet_group_count;
    st1_label              = st0_label;
    st1_restore_enable     = st0_restore_enable;
    st1_payload_valid      = 1'b0;
    st1_payload_bits       = 7'd0;

    if (group1_valid) begin
      st1_packet_group_count = next_packet_group(st0_packet_group_count);
      if (st0_packet_group_count == 6'd0) begin
        st1_label          = group1_bits[5:0];
        st1_restore_enable = (group1_bits[5:0] != {6{~group1_bits[6]}});
        st1_payload_valid  = 1'b0;
        st1_payload_bits   = 7'd0;
      end else begin
        st1_label          = st0_label;
        st1_restore_enable = st0_restore_enable;
        st1_payload_valid  = 1'b1;
        st1_payload_bits   = restore_payload_group(group1_bits,
                                                   st0_label,
                                                   st0_restore_enable);
      end
    end
  end

  // Stage 2: third possible 7b group in this clock.
  always @* begin
    st2_packet_group_count = st1_packet_group_count;
    st2_label              = st1_label;
    st2_restore_enable     = st1_restore_enable;
    st2_payload_valid      = 1'b0;
    st2_payload_bits       = 7'd0;

    if (group2_valid) begin
      st2_packet_group_count = next_packet_group(st1_packet_group_count);
      if (st1_packet_group_count == 6'd0) begin
        st2_label          = group2_bits[5:0];
        st2_restore_enable = (group2_bits[5:0] != {6{~group2_bits[6]}});
        st2_payload_valid  = 1'b0;
        st2_payload_bits   = 7'd0;
      end else begin
        st2_label          = st1_label;
        st2_restore_enable = st1_restore_enable;
        st2_payload_valid  = 1'b1;
        st2_payload_bits   = restore_payload_group(group2_bits,
                                                   st1_label,
                                                   st1_restore_enable);
      end
    end
  end

  // RGB24 packer. The insert function is case-based, so synthesis sees a
  // bounded placement mux instead of a generic variable barrel shifter.
  always @* begin
    pack_shift         = {7'd0, rgb_residue};
    pack_count         = rgb_bit_count;
    pack_emit_valid    = 1'b0;
    pack_emit_data     = 24'd0;
    rgb_residue_next   = rgb_residue;
    rgb_bit_count_next = rgb_bit_count;

    if (st0_payload_valid) begin
      pack_shift = insert_rgb_group(pack_shift, pack_count, st0_payload_bits);
      pack_count = pack_count + RAW_GROUP_BITS;
      if (pack_count >= RGB_WORD_BITS) begin
        pack_emit_data  = pack_shift[23:0];
        pack_emit_valid = 1'b1;
        pack_shift      = pack_shift >> RGB_WORD_BITS;
        pack_count      = pack_count - RGB_WORD_BITS;
      end
    end

    if (st1_payload_valid) begin
      pack_shift = insert_rgb_group(pack_shift, pack_count, st1_payload_bits);
      pack_count = pack_count + RAW_GROUP_BITS;
      if (!pack_emit_valid && (pack_count >= RGB_WORD_BITS)) begin
        pack_emit_data  = pack_shift[23:0];
        pack_emit_valid = 1'b1;
        pack_shift      = pack_shift >> RGB_WORD_BITS;
        pack_count      = pack_count - RGB_WORD_BITS;
      end
    end

    if (st2_payload_valid) begin
      pack_shift = insert_rgb_group(pack_shift, pack_count, st2_payload_bits);
      pack_count = pack_count + RAW_GROUP_BITS;
      if (!pack_emit_valid && (pack_count >= RGB_WORD_BITS)) begin
        pack_emit_data  = pack_shift[23:0];
        pack_emit_valid = 1'b1;
        pack_shift      = pack_shift >> RGB_WORD_BITS;
        pack_count      = pack_count - RGB_WORD_BITS;
      end
    end

    rgb_residue_next   = pack_shift[22:0];
    rgb_bit_count_next = pack_count;
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      raw_residue   <= 6'd0;
      raw_bit_count <= 3'd0;
    end else begin
      raw_residue   <= raw_residue_next;
      raw_bit_count <= raw_bit_count_next;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      packet_group_count <= 6'd0;
    end else begin
      packet_group_count <= st2_packet_group_count;
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
      rgb_residue   <= 23'd0;
      rgb_bit_count <= 5'd0;
    end else begin
      rgb_residue   <= rgb_residue_next;
      rgb_bit_count <= rgb_bit_count_next;
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
