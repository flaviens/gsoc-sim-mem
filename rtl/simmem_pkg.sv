// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// simmem package

// The simmem_pkg module is structured as follows:
//  * Parameters for the AXI fields dimensions and several simulated memory controller parameters.
//  * AXI signals structure definitions
//  * Helper function definitions
//
// Only the first of the three parts should be modified for configuration.
//
// Parameters must match those in dv/simmem_top/simmem_axi_dimensions.h

package simmem_pkg;

  ///////////////////////
  // System parameters //
  ///////////////////////

  // The capacity of the global memory
  localparam int unsigned GlobalMemCapaW = 19;
  localparam int unsigned GlobalMemCapa = 1 << GlobalMemCapaW;  // Bytes.

  // The log2 of the width of a bank row.
  localparam int unsigned RowBufLenW = 10;
  // The number of MSBs that uniquely define a bank row in an address.
  localparam int unsigned RowIdWidth = GlobalMemCapaW - RowBufLenW;

  localparam int unsigned RowHitCost = 10;  // Cycles (must be at least 3)
  localparam int unsigned PrechargeCost = 50;  // Cycles
  localparam int unsigned ActivationCost = 45;  // Cycles

  // Log2 of the boundary that cannot be crossed by bursts.
  localparam int unsigned BurstAddrLSBs = 12;


  /////////////////
  // AXI signals //
  /////////////////

  localparam int unsigned IDWidth = 2;
  localparam int unsigned NumIds = 2 ** IDWidth;

  // Address field widths
  localparam int unsigned AxAddrWidth = GlobalMemCapaW;
  localparam int unsigned AxLenWidth = 8;
  localparam int unsigned AxSizeWidth = 3;
  localparam int unsigned AxBurstWidth = 2;
  localparam int unsigned AxLockWidth = 2;
  localparam int unsigned AxCacheWidth = 4;
  localparam int unsigned AxProtWidth = 4;
  localparam int unsigned AxQoSWidth = 4;
  localparam int unsigned AxRegionWidth = 4;
  localparam int unsigned AwUserWidth = 0;
  localparam int unsigned ArUserWidth = 0;

  // Data & response field widths
  localparam int unsigned XLastWidth = 1;
  localparam int unsigned XRespWidth = 3;
  localparam int unsigned WUserWidth = 0;
  localparam int unsigned RUserWidth = 0;
  localparam int unsigned BUserWidth = 0;


  // Burst size constants

  // Maximal value of any burst_size field
  localparam int unsigned MaxBurstSizeField = 2;

  // Effective max burst size (in number of elements)
  localparam int unsigned MaxBurstEffSizeBytes = 1 << MaxBurstSizeField;
  localparam int unsigned MaxBurstEffSizeBits = MaxBurstEffSizeBytes * 8;

  localparam int unsigned WStrbWidth = MaxBurstEffSizeBytes;


  // Burst length constants

  // Maximal allowed burst length field value
  localparam int unsigned MaxRBurstLenField = 3;
  localparam int unsigned MaxWBurstLenField = 2;

  // Effective max burst length (in number of elements)
  localparam int unsigned MaxRBurstEffLen = 1 << MaxRBurstLenField;
  localparam int unsigned MaxWBurstEffLen = 1 << MaxWBurstLenField;


  ////////////////////////////
  // Dimensions for modules //
  ////////////////////////////

  localparam int unsigned WRspBankCapa = 32;
  localparam int unsigned RDataBankCapa = 16;

  localparam int unsigned WRspBankAddrW = $clog2(WRspBankCapa);
  localparam int unsigned RDataBankAddrW = $clog2(RDataBankCapa);

  // Internal identifier types.
  typedef logic [WRspBankAddrW-1:0] write_iid_t;
  typedef logic [RDataBankAddrW-1:0] read_iid_t;

  // Delay calculator slot constants definition.
  localparam int unsigned NumWSlots = 6;
  localparam int unsigned NumRSlots = 3;

  // Maximal bit width on which to encode a delay.(measured in clock cycles).
  localparam int unsigned DelayW = 6;  // bits


  ///////////////////////////////////
  // End of the parameters section //
  ///////////////////////////////////

  typedef enum logic {
    WRSP_BANK = 0,
    RDATA_BANK = 1
  } rsp_bank_type_e;

  typedef enum logic [AxBurstWidth-1:0] {
    BURST_FIXED = 0,
    BURST_INCR = 1,
    BURST_WRAP = 2,
    BURST_RESERVED = 3
  } burst_type_e;

  ////////////////////////
  // Packet definitions //
  ////////////////////////

  typedef struct packed {
    // logic [AwUserWidth-1:0] user_signal;
    logic [AxQoSWidth-1:0] qos;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxLockWidth-1:0] lock_type;
    burst_type_e burst_type;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxLenWidth-1:0] burst_len;
    logic [AxAddrWidth-1:0] addr;
    logic [IDWidth-1:0] id;
  } waddr_t;

  typedef struct packed {
    // logic [ArUserWidth-1:0] user_signal;
    logic [AxQoSWidth-1:0] qos;
    logic [AxProtWidth-1:0] protection_type;
    logic [AxCacheWidth-1:0] memory_type;
    logic [AxLockWidth-1:0] lock_type;
    burst_type_e burst_type;
    logic [AxSizeWidth-1:0] burst_size;
    logic [AxLenWidth-1:0] burst_len;
    logic [AxAddrWidth-1:0] addr;
    logic [IDWidth-1:0] id;
  } raddr_t;

  typedef struct packed {
    // logic [WUserWidth-1:0] user_signal;
    logic [XLastWidth-1:0] last;
    logic [WStrbWidth-1:0] strobes;
    logic [MaxBurstEffSizeBytes-1:0] data;
  // logic [IDWidth-1:0] id; AXI4 does not allocate identifiers in write data messages
  } wdata_t;

  typedef struct packed {
    // logic [RUserWidth-1:0] user_signal;
    logic [XLastWidth-1:0] last;
    logic [WStrbWidth-1:0] response;
    logic [MaxBurstEffSizeBytes-1:0] data;
    logic [IDWidth-1:0] id;
  } rdata_all_fields_t;

  typedef struct packed {
    logic [$bits(rdata_all_fields_t)-IDWidth-1:0] payload;
    logic [IDWidth-1:0] id;
  } rdata_merged_payload_t;

  typedef union packed {
    rdata_all_fields_t all_fields;
    rdata_merged_payload_t merged_payload;
  } rdata_t;

  typedef struct packed {
    // logic [BUserWidth-1:0] user_signal;
    logic [XRespWidth-1:0] payload;
    logic [IDWidth-1:0] id;
  } wrsp_merged_payload_t;

  // For the write response, the union is only a wrapper helping generic response bank implementation
  typedef union packed {wrsp_merged_payload_t merged_payload;} wrsp_t;


  //////////////////////
  // Helper functions //
  //////////////////////

  /**
    * Determines the effective burst length from the burst length field
    *
    * @param burst_len_field the burst_length field of the AXI signal
    * @return the number of elements in the burst
    */
  function automatic logic [MaxWBurstEffLen-1:0] get_effective_wburst_len(
      logic [MaxWBurstLenField-1:0] burst_len_field);
    return 1 << burst_len_field;
  endfunction : get_effective_wburst_len

  /**
    * Determines the effective burst length from the burst length field
    *
    * @param burst_len_field the burst_length field of the AXI signal
    * @return the number of elements in the burst
    */
  function automatic logic [MaxRBurstEffLen-1:0] get_effective_rburst_len(
      logic [MaxRBurstLenField-1:0] burst_len_field);
    return 1 << burst_len_field;
  endfunction : get_effective_rburst_len

  /**
    * Determines the effective burst size from the burst size field
    *
    * @param burst_len_field the burst_size field of the AXI signal
    * @return the size of the elements in the burst
    */
  function automatic logic [MaxBurstEffSizeBytes-1:0] get_effective_burst_size(
      logic [MaxBurstSizeField-1:0] burst_size_field);
    return 1 << burst_size_field;
  endfunction : get_effective_burst_size

endpackage
