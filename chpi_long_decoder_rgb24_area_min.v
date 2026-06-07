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
  // Production candidate Ver.O/min: area-first CHPI 420b-to-RGB24 decoder.
  // External input is only CHPI[19:0], LSB first, one 20b word per clock.
  // The upstream K-code/bit-slip aligner must release this block with the
  // first active clock aligned to packet bit0. This decoder does not search
  // K-code, does not do bit-slip, and does not support valid_i bubbles.
  // valid_i is kept only for top-level interface compatibility.
  //
  // One 420b packet is 21 clocks. The first 7b group is header {H, Label};
  // it updates label state and is not sent to RGB. The remaining 59 groups
  // are restored payload groups, then packed directly into RGB24.
  //
  // Area choices:
  // - 20b-to-7b uses fixed subphase case placement, not a generic FIFO.
  // - packet position is packet_phase[1:0] + subphase[2:0], not a 5b counter.
  // - 7b payload groups first become bytes, then byte lanes form RGB24.
  // - useful20 debug output is tied off so no extra debug FIFO is synthesized.

  assign useful20_valid = 1'b0;
  assign useful20_data  = 20'd0;

  reg [5:0] raw_residue;
  reg [2:0] subphase;
  reg [1:0] packet_phase;
  wire      header_word;

  reg [5:0] active_label;
  reg       restore_enable;

  reg [6:0]  byte_residue;
  reg [2:0]  byte_bit_count;
  reg [15:0] rgb_byte_buf;
  reg [1:0]  rgb_byte_count;

  reg [6:0] group0_bits;
  reg [6:0] group1_bits;
  reg [6:0] group2_bits;
  reg       group2_valid;
  reg [5:0] raw_residue_next;

  reg [5:0] header_label;
  reg       header_restore_enable;
  reg [5:0] payload_label;
  reg       payload_restore_enable;

  reg [6:0] payload0_bits;
  reg [6:0] payload1_bits;
  reg [6:0] payload2_bits;
  reg [20:0] payload_bits;
  reg [4:0]  payload_bit_count;

  reg [27:0] byte_full;
  reg [4:0]  bit_total_count;
  reg [1:0]  new_byte_count;
  reg [7:0]  new_byte0;
  reg [7:0]  new_byte1;
  reg [7:0]  new_byte2;
  reg [6:0]  byte_residue_next;
  reg [2:0]  byte_bit_count_next;

  reg [39:0] byte_pack_full;
  reg [2:0]  total_byte_count;
  reg [15:0] rgb_byte_buf_next;
  reg [1:0]  rgb_byte_count_next;
  reg        pack_emit_valid;
  reg [23:0] pack_emit_data;

  assign header_word = (packet_phase == 2'd0) && (subphase == 3'd0);

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

  // Fixed 20b-to-7b phase. subphase advances 0..6 with each valid 20b word.
  always @* begin
    group0_bits      = 7'd0;
    group1_bits      = 7'd0;
    group2_bits      = 7'd0;
    group2_valid     = 1'b0;
    raw_residue_next = raw_residue;

    case (subphase)
      3'd0: begin
        group0_bits      = chpi_in[6:0];
        group1_bits      = chpi_in[13:7];
        group2_bits      = 7'd0;
        group2_valid     = 1'b0;
        raw_residue_next = chpi_in[19:14];
      end
      3'd1: begin
        group0_bits      = {chpi_in[0], raw_residue[5:0]};
        group1_bits      = chpi_in[7:1];
        group2_bits      = chpi_in[14:8];
        group2_valid     = 1'b1;
        raw_residue_next = {1'b0, chpi_in[19:15]};
      end
      3'd2: begin
        group0_bits      = {chpi_in[1:0], raw_residue[4:0]};
        group1_bits      = chpi_in[8:2];
        group2_bits      = chpi_in[15:9];
        group2_valid     = 1'b1;
        raw_residue_next = {2'b00, chpi_in[19:16]};
      end
      3'd3: begin
        group0_bits      = {chpi_in[2:0], raw_residue[3:0]};
        group1_bits      = chpi_in[9:3];
        group2_bits      = chpi_in[16:10];
        group2_valid     = 1'b1;
        raw_residue_next = {3'b000, chpi_in[19:17]};
      end
      3'd4: begin
        group0_bits      = {chpi_in[3:0], raw_residue[2:0]};
        group1_bits      = chpi_in[10:4];
        group2_bits      = chpi_in[17:11];
        group2_valid     = 1'b1;
        raw_residue_next = {4'b0000, chpi_in[19:18]};
      end
      3'd5: begin
        group0_bits      = {chpi_in[4:0], raw_residue[1:0]};
        group1_bits      = chpi_in[11:5];
        group2_bits      = chpi_in[18:12];
        group2_valid     = 1'b1;
        raw_residue_next = {5'b00000, chpi_in[19]};
      end
      3'd6: begin
        group0_bits      = {chpi_in[5:0], raw_residue[0]};
        group1_bits      = chpi_in[12:6];
        group2_bits      = chpi_in[19:13];
        group2_valid     = 1'b1;
        raw_residue_next = 6'd0;
      end
      default: begin
        group0_bits      = chpi_in[6:0];
        group1_bits      = chpi_in[13:7];
        group2_bits      = 7'd0;
        group2_valid     = 1'b0;
        raw_residue_next = chpi_in[19:14];
      end
    endcase
  end

  always @* begin
    header_label          = group0_bits[5:0];
    header_restore_enable = (group0_bits[5:0] != {6{~group0_bits[6]}});
    payload_label         = active_label;
    payload_restore_enable = restore_enable;

    if (header_word) begin
      payload_label          = header_label;
      payload_restore_enable = header_restore_enable;
    end
  end

  always @* begin
    payload0_bits     = 7'd0;
    payload1_bits     = 7'd0;
    payload2_bits     = 7'd0;
    payload_bits      = 21'd0;
    payload_bit_count = 5'd0;

    if (header_word) begin
      payload0_bits     = restore_payload_group(group1_bits,
                                                payload_label,
                                                payload_restore_enable);
      payload_bits[6:0] = payload0_bits;
      payload_bit_count = 5'd7;
    end else begin
      payload0_bits       = restore_payload_group(group0_bits,
                                                  payload_label,
                                                  payload_restore_enable);
      payload1_bits       = restore_payload_group(group1_bits,
                                                  payload_label,
                                                  payload_restore_enable);
      payload_bits[6:0]   = payload0_bits;
      payload_bits[13:7]  = payload1_bits;
      payload_bit_count   = 5'd14;

      if (group2_valid) begin
        payload2_bits       = restore_payload_group(group2_bits,
                                                    payload_label,
                                                    payload_restore_enable);
        payload_bits[20:14] = payload2_bits;
        payload_bit_count   = 5'd21;
      end
    end
  end

  // First pack 7b payload groups into bytes, then pack every three bytes into
  // one RGB24 word. This keeps the bit-level shifter local and only 28b wide.
  always @* begin
    byte_full            = {21'd0, byte_residue};
    bit_total_count      = {2'b00, byte_bit_count} + {1'b0, payload_bit_count};
    new_byte_count       = 2'd0;
    new_byte0            = 8'd0;
    new_byte1            = 8'd0;
    new_byte2            = 8'd0;
    byte_residue_next    = byte_residue;
    byte_bit_count_next  = byte_bit_count;

    byte_pack_full       = 40'd0;
    total_byte_count     = {1'b0, rgb_byte_count};
    rgb_byte_buf_next    = rgb_byte_buf;
    rgb_byte_count_next  = rgb_byte_count;
    pack_emit_valid      = 1'b0;
    pack_emit_data       = 24'd0;

    if (payload_bit_count != 5'd0) begin
      byte_full = byte_full | ({7'd0, payload_bits} << byte_bit_count);
      new_byte_count      = bit_total_count[4:3];
      new_byte0           = byte_full[7:0];
      new_byte1           = byte_full[15:8];
      new_byte2           = byte_full[23:16];
      byte_bit_count_next = bit_total_count[2:0];

      case (bit_total_count[4:3])
        2'd0: byte_residue_next = byte_full[6:0];
        2'd1: byte_residue_next = byte_full[14:8];
        2'd2: byte_residue_next = byte_full[22:16];
        default: byte_residue_next = {3'd0, byte_full[27:24]};
      endcase

      case (rgb_byte_count)
        2'd0: begin
          byte_pack_full[7:0]   = new_byte0;
          byte_pack_full[15:8]  = new_byte1;
          byte_pack_full[23:16] = new_byte2;
        end
        2'd1: begin
          byte_pack_full[7:0]   = rgb_byte_buf[7:0];
          byte_pack_full[15:8]  = new_byte0;
          byte_pack_full[23:16] = new_byte1;
          byte_pack_full[31:24] = new_byte2;
        end
        default: begin
          byte_pack_full[7:0]   = rgb_byte_buf[7:0];
          byte_pack_full[15:8]  = rgb_byte_buf[15:8];
          byte_pack_full[23:16] = new_byte0;
          byte_pack_full[31:24] = new_byte1;
          byte_pack_full[39:32] = new_byte2;
        end
      endcase

      total_byte_count = {1'b0, rgb_byte_count} + {1'b0, new_byte_count};

      if (total_byte_count >= 3'd3) begin
        pack_emit_valid = 1'b1;
        pack_emit_data  = byte_pack_full[23:0];
        case (total_byte_count - 3'd3)
          3'd0: begin
            rgb_byte_buf_next   = 16'd0;
            rgb_byte_count_next = 2'd0;
          end
          3'd1: begin
            rgb_byte_buf_next   = {8'd0, byte_pack_full[31:24]};
            rgb_byte_count_next = 2'd1;
          end
          default: begin
            rgb_byte_buf_next   = byte_pack_full[39:24];
            rgb_byte_count_next = 2'd2;
          end
        endcase
      end else begin
        rgb_byte_buf_next   = byte_pack_full[15:0];
        rgb_byte_count_next = total_byte_count[1:0];
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      raw_residue <= 6'd0;
    end else begin
      raw_residue <= raw_residue_next;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      subphase     <= 3'd0;
      packet_phase <= 2'd0;
    end else begin
      if (subphase == 3'd6) begin
        subphase <= 3'd0;
        if (packet_phase == 2'd2) begin
          packet_phase <= 2'd0;
        end else begin
          packet_phase <= packet_phase + 2'd1;
        end
      end else begin
        subphase <= subphase + 3'd1;
      end
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active_label   <= 6'd0;
      restore_enable <= 1'b0;
    end else if (header_word) begin
      active_label   <= header_label;
      restore_enable <= header_restore_enable;
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      byte_residue   <= 7'd0;
      byte_bit_count <= 3'd0;
      rgb_byte_buf   <= 16'd0;
      rgb_byte_count <= 2'd0;
    end else begin
      byte_residue   <= byte_residue_next;
      byte_bit_count <= byte_bit_count_next;
      rgb_byte_buf   <= rgb_byte_buf_next;
      rgb_byte_count <= rgb_byte_count_next;
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
