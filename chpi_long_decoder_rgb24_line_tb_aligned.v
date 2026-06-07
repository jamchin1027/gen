`timescale 1ns/1ps

module chpi_long_decoder_rgb24_line_tb;
  localparam integer CTRL_BYTES   = 5;
  localparam integer RGB_BYTES    = 960;
  localparam integer LINE_BYTES   = CTRL_BYTES + RGB_BYTES;
  localparam integer LINE_BITS    = LINE_BYTES * 8;
  localparam integer BLOCKS       = (LINE_BITS + 412) / 413;
  localparam integer USEFUL_BITS  = BLOCKS * 413;
  localparam integer ENCODED_BITS = BLOCKS * 420;
  localparam integer RAW_WORDS    = ENCODED_BITS / 20;
  localparam integer OUT_RGB_WORDS = USEFUL_BITS / 24;
  localparam integer OUT_BYTES    = OUT_RGB_WORDS * 3;

  reg clk;
  reg rst_n;
  reg valid_i;
  reg [19:0] chpi_in;
  wire rgb_valid;
  wire [23:0] rgb_data;
  wire useful20_valid;
  wire [19:0] useful20_data;

  reg useful_bits [0:USEFUL_BITS-1];
  reg encoded_bits [0:ENCODED_BITS-1];
  reg used_label [0:63];

  integer i, j, blk, gi, bi, wi;
  integer enc_ptr;
  integer expected_byte_idx;
  integer mismatch_count;
  integer rgb_count;
  integer ctrl_ok_count;
  integer rgb_ok_count;
  integer done_count;
  reg [6:0] group;
  reg [6:0] enc_group;
  reg [6:0] header_group;
  reg [5:0] label;
  integer label_int;
  reg [7:0] value;
  reg [19:0] drive_word;

  chpi_decode_20b_stream_top dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .valid_i        (valid_i),
    .chpi_in        (chpi_in),
    .rgb_valid      (rgb_valid),
    .rgb_data       (rgb_data),
    .useful20_valid (useful20_valid),
    .useful20_data  (useful20_data)
  );

  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk; // 100 MHz
  end

  function [7:0] line_byte;
    input integer idx;
    begin
      case (idx)
        0: line_byte = 8'hc1;
        1: line_byte = 8'h7e;
        2: line_byte = 8'h55;
        3: line_byte = 8'haa;
        4: line_byte = 8'h5a;
        default: line_byte = (idx - CTRL_BYTES) & 8'hff;
      endcase
    end
  endfunction

  task append_group;
    input [6:0] g;
    integer n;
    begin
      for (n = 0; n < 7; n = n + 1) begin
        encoded_bits[enc_ptr] = g[n];
        enc_ptr = enc_ptr + 1;
      end
    end
  endtask

  task check_byte;
    input [7:0] got;
    reg [7:0] exp;
    begin
      if (expected_byte_idx < LINE_BYTES) begin
        exp = line_byte(expected_byte_idx);
        if (got !== exp) begin
          $display("ERROR line_byte[%0d] got=%02x exp=%02x time=%0t",
                   expected_byte_idx, got, exp, $time);
          mismatch_count = mismatch_count + 1;
        end else if (expected_byte_idx < CTRL_BYTES) begin
          ctrl_ok_count = ctrl_ok_count + 1;
          $display("CTRL PASS byte[%0d] = %02x time=%0t",
                   expected_byte_idx, got, $time);
        end else begin
          rgb_ok_count = rgb_ok_count + 1;
          if ((expected_byte_idx == CTRL_BYTES) ||
              (expected_byte_idx == CTRL_BYTES + RGB_BYTES - 1)) begin
            $display("RGB PASS byte[%0d] = %02x time=%0t",
                     expected_byte_idx - CTRL_BYTES, got, $time);
          end
        end
      end else if (got !== 8'h00) begin
        $display("ERROR padding_byte[%0d] got=%02x exp=00 time=%0t",
                 expected_byte_idx - LINE_BYTES, got, $time);
        mismatch_count = mismatch_count + 1;
      end
      expected_byte_idx = expected_byte_idx + 1;
    end
  endtask

  always @(posedge clk) begin
    if (!rst_n) begin
      expected_byte_idx <= 0;
      mismatch_count    <= 0;
      rgb_count         <= 0;
      ctrl_ok_count     <= 0;
      rgb_ok_count      <= 0;
      done_count        <= 0;
    end else if (rgb_valid) begin
      if (!done_count) begin
        rgb_count <= rgb_count + 1;
        check_byte(rgb_data[7:0]);
        if (expected_byte_idx >= LINE_BYTES) begin
          done_count <= 1;
        end else begin
          check_byte(rgb_data[15:8]);
          if (expected_byte_idx >= LINE_BYTES) begin
            done_count <= 1;
          end else begin
            check_byte(rgb_data[23:16]);
            if (expected_byte_idx >= LINE_BYTES) begin
              done_count <= 1;
            end
          end
        end
      end
    end
  end

  initial begin
    $dumpfile("chpi_long_decoder_rgb24_line_tb.vcd");
    $dumpvars(0, chpi_long_decoder_rgb24_line_tb);

    for (i = 0; i < USEFUL_BITS; i = i + 1) useful_bits[i] = 1'b0;
    for (i = 0; i < ENCODED_BITS; i = i + 1) encoded_bits[i] = 1'b0;

    for (i = 0; i < LINE_BYTES; i = i + 1) begin
      value = line_byte(i);
      for (j = 0; j < 8; j = j + 1) begin
        useful_bits[i*8 + j] = value[j];
      end
    end

    enc_ptr = 0;
    for (blk = 0; blk < BLOCKS; blk = blk + 1) begin
      for (i = 0; i < 64; i = i + 1) used_label[i] = 1'b0;

      for (gi = 0; gi < 59; gi = gi + 1) begin
        group = 7'd0;
        for (bi = 0; bi < 7; bi = bi + 1) begin
          group[bi] = useful_bits[blk*413 + gi*7 + bi];
        end
        if ((group != 7'b0000000) && (group != 7'b1111111)) begin
          used_label[group[6:1]] = 1'b1;
        end
      end

      label_int = 1;
      while ((label_int < 63) && used_label[label_int]) label_int = label_int + 1;
      label = label_int[5:0];
      header_group = {1'b1, label};
      append_group(header_group);

      for (gi = 0; gi < 59; gi = gi + 1) begin
        group = 7'd0;
        for (bi = 0; bi < 7; bi = bi + 1) begin
          group[bi] = useful_bits[blk*413 + gi*7 + bi];
        end

        if (group == 7'b0000000) enc_group = {label, 1'b0};
        else if (group == 7'b1111111) enc_group = {label, 1'b1};
        else enc_group = group;
        append_group(enc_group);
      end
    end

    $display("One-line test: CTRL_L=%0d bytes, RGB=%0d bytes, total=%0d bytes",
             CTRL_BYTES, RGB_BYTES, LINE_BYTES);
    $display("Line bits=%0d, CHPI blocks=%0d, encoded bits=%0d, raw 20b clocks=%0d",
             LINE_BITS, BLOCKS, ENCODED_BITS, RAW_WORDS);
    $display("Decoder can emit %0d RGB24 words = %0d bytes; padding bytes checked as zero",
             OUT_RGB_WORDS, OUT_BYTES);

    rst_n = 1'b0;
    valid_i = 1'b0;
    chpi_in = 20'd0;
    repeat (5) @(negedge clk);

    drive_word = 20'd0;
    for (bi = 0; bi < 20; bi = bi + 1) begin
      drive_word[bi] = encoded_bits[bi];
    end
    chpi_in = drive_word;
    valid_i = 1'b1;
    rst_n = 1'b1;

    for (wi = 1; wi < RAW_WORDS; wi = wi + 1) begin
      drive_word = 20'd0;
      for (bi = 0; bi < 20; bi = bi + 1) begin
        drive_word[bi] = encoded_bits[wi*20 + bi];
      end
      @(negedge clk);
      valid_i = 1'b1;
      chpi_in = drive_word;
    end

    @(negedge clk);
    valid_i = 1'b0;
    chpi_in = 20'd0;

    wait (done_count == 1);
    repeat (4) @(posedge clk);

    if ((mismatch_count == 0) &&
        (ctrl_ok_count == CTRL_BYTES) &&
        (rgb_ok_count == RGB_BYTES) &&
        (expected_byte_idx >= LINE_BYTES)) begin
      $display("PASS: complete line matched: %0d CTRL_L bytes + %0d RGB bytes",
               ctrl_ok_count, rgb_ok_count);
      $display("Output RGB24 words=%0d, checked bytes=%0d", rgb_count, expected_byte_idx);
    end else begin
      $display("FAIL: mismatches=%0d ctrl_ok=%0d/%0d rgb_ok=%0d/%0d checked=%0d",
               mismatch_count, ctrl_ok_count, CTRL_BYTES,
               rgb_ok_count, RGB_BYTES, expected_byte_idx);
    end
    $finish;
  end
endmodule
