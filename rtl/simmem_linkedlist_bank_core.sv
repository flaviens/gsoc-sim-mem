// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Linkedlist bank for messages in the simulated memory controller 

module simmem_linkedlist_bank_core #(
    parameter int StructWidth = 64,  // Width of the message including identifier
    parameter int TotalCapacity = 128,
    parameter int IDWidth = 4
) (
    input logic clk_i,
    input logic rst_ni,

    // Input from the output buffer selector, also serves as an output ready signal
    input logic [2**IDWidth-1:0] next_id_to_release_onehot_i,

    input  logic [IDWidth-1:0] data_id_i,
    input  logic [StructWidth-IDWidth-1:0] data_noid_i,

    output logic [StructWidth-IDWidth-1:0] buf_data_o[2**IDWidth-1:0],
    output logic [2**IDWidth-1:0] buf_data_valid_o,

    input  logic in_valid_i,
    output logic in_ready_o
  );

  import simmem_pkg::ram_bank_e;
  import simmem_pkg::ram_port_e;


  // Head, tail and non-empty signals
  logic [$clog2(TotalCapacity)-1:0] rsv_heads_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] rsv_heads_q[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] heads_actual[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] tails_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] tails_q[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] linkedlist_length_d[2**IDWidth-1:0];
  logic [$clog2(TotalCapacity)-1:0] linkedlist_length_q[2**IDWidth-1:0];
  logic update_heads_from_ram_d[2**IDWidth-1:0];
  logic update_heads_from_ram_q[2**IDWidth-1:0];

  // Indicates, for each ID, whether the list is not empty
  logic [2**IDWidth-1:0] id_valid_ram;

  for (genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1) begin
    assign id_valid_ram[current_id] = linkedlist_length_q[current_id] != '0;

    // Chooses of the new head should be taken from the flip-flop, or from RAM
    assign heads_actual[current_id] =
        update_heads_from_ram_q[current_id] ? data_out_next_elem_ram : rsv_heads_q[current_id];
  end

  // Output buffers, contain the next data to output
  logic [StructWidth-IDWidth-1:0]
      out_buf_id_d[2**IDWidth-1:0];  // Needs packing, since stores whole messages delivered at once
  logic [StructWidth-IDWidth-1:0] out_buf_id_q[2**IDWidth-1:0];
  logic [StructWidth-IDWidth-1:0] out_buf_id_actual_content[2**IDWidth-1:0];
  logic out_buf_id_valid_d[2**IDWidth-1:0];
  logic out_buf_id_valid_q[2**IDWidth-1:0];
  logic [2**IDWidth-1:0] out_buf_id_valid_q_packed;
  logic update_out_buf_from_ram_d[2**IDWidth-1:0];
  logic update_out_buf_from_ram_q[2**IDWidth-1:0];

  for (genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1) begin
    assign out_buf_id_valid_q_packed[current_id] = out_buf_id_valid_q[current_id];

    assign out_buf_id_actual_content[current_id] =
        update_out_buf_from_ram_q[current_id] ? data_out_struct_ram : out_buf_id_q[current_id];
  end

  // Valid bits and pointer to next arrays. Masks update the valid bits
  logic ram_valid_d[TotalCapacity-1:0];
  logic ram_valid_q[TotalCapacity-1:0];
  logic [TotalCapacity-1:0] ram_valid_q_packed;
  logic ram_valid_in_mask[TotalCapacity-1:0];
  logic ram_valid_out_mask[TotalCapacity-1:0];
  logic ram_valid_apply_in_mask_id[2**IDWidth-1:0];
  logic ram_valid_apply_out_mask_id[2**IDWidth-1:0];

  logic [2**IDWidth-1:0] ram_valid_apply_in_mask_id_packed;
  logic [2**IDWidth-1:0] ram_valid_apply_out_mask_id_packed;

  for (genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1) begin
    assign ram_valid_apply_in_mask_id_packed[current_id] = ram_valid_apply_in_mask_id[current_id];
    assign ram_valid_apply_out_mask_id_packed[current_id] = ram_valid_apply_out_mask_id[current_id];
  end

  // Prepare the next RAM valid bit array
  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign ram_valid_d[current_addr] = ram_valid_q[current_addr] ^ (
        ram_valid_in_mask[current_addr] && |ram_valid_apply_in_mask_id_packed) ^ (
        ram_valid_out_mask[current_addr] && |ram_valid_apply_out_mask_id_packed);
  end

  // Expose the payload of all the output buffers
  logic [StructWidth-IDWidth-1:0] buf_data_o[2**IDWidth-1:0];
  logic buf_data_valid[2**IDWidth-1:0];
  
  for (genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1) begin
    assign buf_data_valid_o[current_id] = buf_data_valid[current_id];
  end

  // Find the next free address and transform next free address from one-hot to binary encoding
  logic next_free_ram_entry_onehot[TotalCapacity-1:0];  // Can be full zero
  logic [$clog2(TotalCapacity)-1:0] next_free_ram_entry_binary;
  logic [$clog2(TotalCapacity)-1:0] next_free_address_binary_masks[TotalCapacity-1:0];
  logic [TotalCapacity-1:0] next_free_address_binary_masks_rot90[$clog2(TotalCapacity)-1:0];

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign next_free_address_binary_masks[current_addr] =
        next_free_ram_entry_onehot[current_addr] ? current_addr : '0;
  end
  for (genvar current_id = 0; current_id < TotalCapacity; current_id = current_id + 1) begin
    for (
        genvar current_addr_bit = 0;
        current_addr_bit < $clog2(TotalCapacity);
        current_addr_bit = current_addr_bit + 1
    ) begin
      assign next_free_address_binary_masks_rot90[current_addr_bit][current_id] =
          next_free_address_binary_masks[current_id][current_addr_bit];
    end
  end
  for (
      genvar current_addr_bit = 0;
      current_addr_bit < $clog2(TotalCapacity);
      current_addr_bit = current_addr_bit + 1
  ) begin
    assign next_free_ram_entry_binary[current_addr_bit] =
        |next_free_address_binary_masks_rot90[current_addr_bit];
  end

  // RAM instances and management signals
  logic req_ram[1:0][1:0];
  logic write_ram[1:0][1:0];
  logic req_ram_id[1:0][1:0][2**IDWidth-1:0];
  logic [2**IDWidth-1:0] req_ram_id_packed[1:0][1:0];
  logic [2**IDWidth-1:0] write_ram_id[1:0][1:0];

  logic [StructWidth-IDWidth-1:0] wmask_struct_ram;
  logic [$clog2(TotalCapacity)-1:0] wmask_next_elem_ram;

  logic [$clog2(TotalCapacity)-1:0] addr_ram[1:0][1:0];
  logic [$clog2(TotalCapacity)-1:0] addr_ram_id[1:0][1:0][2**IDWidth-1:0];
  logic [2**IDWidth-1:0] addr_ram_masks_rot90[1:0][1:0][$clog2(TotalCapacity)-1:0];

  for (genvar ram_bank = 0; ram_bank < 2; ram_bank = ram_bank + 1) begin
    for (genvar ram_port = 0; ram_port < 2; ram_port = ram_port + 1) begin
      // Aggregate the RAM requests
      assign req_ram[ram_bank][ram_port] = |req_ram_id_packed[ram_bank][ram_port];
      assign write_ram[ram_bank][ram_port] = |write_ram_id[ram_bank][ram_port];

      for (genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1) begin
        assign req_ram_id_packed[ram_bank][ram_port][current_id] =
            req_ram_id[ram_bank][ram_port][current_id];

        for (
            genvar current_addr_bit = 0;
            current_addr_bit < $clog2(TotalCapacity);
            current_addr_bit = current_addr_bit + 1
        ) begin
          assign addr_ram_masks_rot90[ram_bank][ram_port][current_addr_bit][current_id] =
              addr_ram_id[ram_bank][ram_port][current_id][current_addr_bit];
        end
      end
      for (
          genvar current_addr_bit = 0;
          current_addr_bit < $clog2(TotalCapacity);
          current_addr_bit = current_addr_bit + 1
      ) begin
        assign addr_ram[ram_bank][ram_port][current_addr_bit] =
            |addr_ram_masks_rot90[ram_bank][ram_port][current_addr_bit];
      end
    end
  end

  logic [StructWidth-IDWidth-1:0] data_noid_i;
  logic [StructWidth-IDWidth-1:0] data_out_struct_ram;
  logic [$clog2(TotalCapacity)-1:0] data_out_next_elem_ram;

  assign wmask_struct_ram = {StructWidth - IDWidth{1'b1}};
  assign wmask_next_elem_ram = {$clog2(TotalCapacity) {1'b1}};

  prim_generic_ram_2p #(
    .Width(StructWidth-IDWidth),
    .DataBitsPerMask(1),
    .Depth(TotalCapacity)
  ) struct_ram_i (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),
    
    .a_req_i     (req_ram[MESSAGE_RAM][RAM_IN]),
    .a_write_i   (write_ram[MESSAGE_RAM][RAM_IN]),
    .a_wmask_i   (wmask_struct_ram),
    .a_addr_i    (addr_ram[MESSAGE_RAM][RAM_IN]),
    .a_wdata_i   (data_noid_i),
    .a_rdata_o   (),
    
    .b_req_i     (req_ram[MESSAGE_RAM][RAM_OUT]),
    .b_write_i   (write_ram[MESSAGE_RAM][RAM_OUT]),
    .b_wmask_i   (wmask_struct_ram),
    .b_addr_i    (addr_ram[MESSAGE_RAM][RAM_OUT]),
    .b_wdata_i   (),
    .b_rdata_o   (data_out_struct_ram)
  );

  prim_generic_ram_2p #(
    .Width($clog2(TotalCapacity)),
    .DataBitsPerMask(1),
    .Depth(TotalCapacity)
  ) next_elem_ram_i (
    .clk_a_i     (clk_i),
    .clk_b_i     (clk_i),

    .a_req_i     (req_ram[NEXT_ELEM_RAM][RAM_IN]),
    .a_write_i   (write_ram[NEXT_ELEM_RAM][RAM_IN]),
    .a_wmask_i   (wmask_next_elem_ram),
    .a_addr_i    (addr_ram[NEXT_ELEM_RAM][RAM_IN]),
    .a_wdata_i   (next_free_ram_entry_binary),
    .a_rdata_o   (),
    
    .b_req_i     (req_ram[NEXT_ELEM_RAM][RAM_OUT]),
    .b_write_i   (write_ram[NEXT_ELEM_RAM][RAM_OUT]),
    .b_wmask_i   (wmask_next_elem_ram),
    .b_addr_i    (addr_ram[NEXT_ELEM_RAM][RAM_OUT]),
    .b_wdata_i   (),
    .b_rdata_o   (data_out_next_elem_ram)
  );

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign ram_valid_q_packed[current_addr] = ram_valid_q[current_addr];
  end

  assign next_free_ram_entry_onehot[0] = !ram_valid_q[0];
  for (genvar current_addr = 1; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    assign next_free_ram_entry_onehot[current_addr] =
        !ram_valid_q[current_addr] && &ram_valid_q_packed[current_addr - 1:0];
  end

  // IdValid signals, ramValid masks

  // Idea: change ram_valid_out_mask somehow directly in sequential logic 
  for (
      genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1
  ) begin : ram_valid_masks_generation
    for (genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1) begin
      always_comb begin
        if (heads_actual[current_id] == current_addr) begin
          assign ram_valid_out_mask[current_addr] = next_id_to_release_onehot_i[current_id];
        end
      end
    end

    assign ram_valid_in_mask[current_addr] = next_free_ram_entry_binary == current_addr;
  end

  // Input is ready if there is room and data is not flowing out
  assign in_ready_o = |(~ram_valid_q_packed) || |(~out_buf_id_valid_q_packed);

  for (
      genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1
  ) begin : id_isolated_comb

    always_comb begin
      // Default assignments
      rsv_heads_d[current_id] = rsv_heads_q[current_id];
      tails_d[current_id] = tails_q[current_id];
      linkedlist_length_d[current_id] = linkedlist_length_q[current_id];
      buf_data_valid[current_id] = 1'b0;
      update_heads_from_ram_d[current_id] = 1'b0;
      ram_valid_apply_in_mask_id[current_id] = 1'b0;
      ram_valid_apply_out_mask_id[current_id] = 1'b0;
      out_buf_id_d[current_id] = out_buf_id_actual_content[current_id];
      out_buf_id_valid_d[current_id] = out_buf_id_valid_q[current_id];
      update_out_buf_from_ram_d[current_id] = 1'b0;

      // Default RAM signals
      for (int ram_bank = 0; ram_bank < 2; ram_bank = ram_bank + 1) begin
        for (int ram_port = 0; ram_port < 2; ram_port = ram_port + 1) begin
          req_ram_id[ram_bank][ram_port][current_id] = 1'b0;
          write_ram_id[ram_bank][ram_port][current_id] = 1'b0;
          addr_ram_id[ram_bank][ram_port][current_id] = '0;
        end
      end

      // Expose output buffer data
      if (out_buf_id_valid_q[current_id]) begin : out_buf_valid
        buf_data_o[current_id] = out_buf_id_actual_content[current_id];
        buf_data_valid[current_id] = 1'b1;
      end else if (in_valid_i && in_ready_o && current_id == data_id_i) begin : out_buf_direct
        buf_data_o[current_id] = data_noid_i};
        buf_data_valid[current_id] = 1'b1;
      end

      // Handshakes: start by output to avoid blocking output with simultaneous inputs
      if (next_id_to_release_onehot_i[current_id] && out_buf_id_valid_q[current_id]) begin : out_handshake

        // If the RAM is not empty
        if (id_valid_ram[current_id]) begin : out_handshake_ram_valid
          update_heads_from_ram_d[current_id] = 1'b1;
          update_out_buf_from_ram_d[current_id] = 1'b1;

          req_ram_id[MESSAGE_RAM][RAM_OUT][current_id] = 1'b1;
          write_ram_id[MESSAGE_RAM][RAM_OUT][current_id] = 1'b0;
          addr_ram_id[MESSAGE_RAM][RAM_OUT][current_id] = heads_actual[current_id];

          // Free the head entry in the RAM using a XOR mask
          ram_valid_apply_out_mask_id[current_id] = 1'b1;

          linkedlist_length_d[current_id] -= 1;

          // Update the head position in the RAM
          req_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b1;
          write_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = 1'b0;
          addr_ram_id[NEXT_ELEM_RAM][RAM_OUT][current_id] = heads_actual[current_id];

        end else if (in_valid_i && in_ready_o && current_id == data_id_i
            ) begin : out_handshake_refill_buf_from_input
          out_buf_id_d[current_id] = data_noid_i;
        end else begin : out_handshake_id_now_empty
          out_buf_id_valid_d[current_id] = 1'b0;
        end

      end

      if (in_valid_i && in_ready_o && current_id == data_id_i) begin : in_handshake

        if (!out_buf_id_valid_q[current_id]) begin : in_handshake_buf_empty
          // Direct flow from input to output is already implemented in the output handshake block 
          if (!(next_id_to_release_onehot_i[current_id])
              ) begin : in_handshake_fill_buf
            out_buf_id_valid_d[current_id] = 1'b1;
            out_buf_id_d[current_id] = data_noid_i;
          end
        end else begin : in_handshake_buf_valid

          // Mark address as taken
          ram_valid_apply_in_mask_id[current_id] = 1'b1;

          linkedlist_length_d[current_id] = linkedlist_length_q[current_id] + 1;

          // Take the input data, considering cases where the RAM list is empty or not
          if (linkedlist_length_q[current_id] >= 2 || linkedlist_length_q[current_id] == 1 &&
              !(next_id_to_release_onehot_i[current_id])
              ) begin : in_handshake_ram_will_stay_valid
            tails_d[current_id] = next_free_ram_entry_binary;

            // Store into next elem RAM
            req_ram_id[NEXT_ELEM_RAM][RAM_IN][current_id] = 1'b1;
            write_ram_id[NEXT_ELEM_RAM][RAM_IN][current_id] = 1'b1;
            addr_ram_id[NEXT_ELEM_RAM][RAM_IN][current_id] = tails_q[current_id];

            // Store into struct RAM
            req_ram_id[MESSAGE_RAM][RAM_IN][current_id] = 1'b1;
            write_ram_id[MESSAGE_RAM][RAM_IN][current_id] = 1'b1;
            addr_ram_id[MESSAGE_RAM][RAM_IN][current_id] = next_free_ram_entry_binary;

          end else begin : in_handshake_initiate_ram_linkedlist
            rsv_heads_d[current_id] = next_free_ram_entry_binary;
            tails_d[current_id] = next_free_ram_entry_binary;

            // Store into struct RAM and mark address as taken
            req_ram_id[MESSAGE_RAM][RAM_IN][current_id] = 1'b1;
            write_ram_id[MESSAGE_RAM][RAM_IN][current_id] = 1'b1;
            addr_ram_id[MESSAGE_RAM][RAM_IN][current_id] = next_free_ram_entry_binary;

          end
        end
      end
    end
  end


  for (genvar current_id = 0; current_id < 2 ** IDWidth; current_id = current_id + 1) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        rsv_heads_q[current_id] <= '0;
        tails_q[current_id] <= '0;
        linkedlist_length_q[current_id] <= '0;
        update_heads_from_ram_q[current_id] <= '0;

        out_buf_id_valid_q[current_id] <= '0;
        out_buf_id_q[current_id] <= '0;
        update_out_buf_from_ram_q[current_id] <= '0;
      end else begin
        rsv_heads_q[current_id] <= rsv_heads_d[current_id];
        tails_q[current_id] <= tails_d[current_id];
        linkedlist_length_q[current_id] <= linkedlist_length_d[current_id];
        update_heads_from_ram_q[current_id] <= update_heads_from_ram_d[current_id];

        out_buf_id_q[current_id] <= out_buf_id_d[current_id];
        out_buf_id_valid_q[current_id] <= out_buf_id_valid_d[current_id];
        update_out_buf_from_ram_q[current_id] <= update_out_buf_from_ram_d[current_id];
      end
    end
  end

  for (genvar current_addr = 0; current_addr < TotalCapacity; current_addr = current_addr + 1) begin
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        ram_valid_q[current_addr] <= 1'b0;
      end else begin
        ram_valid_q[current_addr] <= ram_valid_d[current_addr];
      end
    end
  end

endmodule
