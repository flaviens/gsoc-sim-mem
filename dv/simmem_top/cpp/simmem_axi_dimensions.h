// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// The constants in this header must be identical to the ones defined in rtl/simmem_pkg.sv

#ifndef SIMMEM_DV_AXI_DIMENSIONS
#define SIMMEM_DV_AXI_DIMENSIONS

#include <stdint.h>

  // The capacity of the global memory
  const uint64_t GlobalMemCapaW = 19;
  const uint64_t GlobalMemCapa = 1 << GlobalMemCapaW;  // Bytes.

  // The log2 of the width of a bank row.
  const uint64_t RowBufLenW = 10;
  // The number of MSBs that uniquely define a bank row in an address.
  const uint64_t RowIdWidth = GlobalMemCapaW - RowBufLenW;

  const uint64_t RowHitCost = 4;  // Cycles (must be at least 3)
  const uint64_t PrechargeCost = 2;  // Cycles
  const uint64_t ActivationCost = 1;  // Cycles

  // Log2 of the boundary that cannot be crossed by bursts.
  const uint64_t BurstAddrLSBs = 12;


  /////////////////
  // AXI signals //
  /////////////////

  const uint64_t IDWidth = 2;
  const uint64_t NumIds = 1 << IDWidth;

  // Address field widths
  const uint64_t AxAddrWidth = GlobalMemCapaW;
  const uint64_t AxLenWidth = 8;
  const uint64_t AxSizeWidth = 3;
  const uint64_t AxBurstWidth = 2;
  const uint64_t AxLockWidth = 2;
  const uint64_t AxCacheWidth = 4;
  const uint64_t AxProtWidth = 4;
  const uint64_t AxQoSWidth = 4;
  const uint64_t AxRegionWidth = 4;
  const uint64_t AwUserWidth = 0;
  const uint64_t ArUserWidth = 0;

  // Data & response field widths
  const uint64_t XLastWidth = 1;
  // XReespWidth should be increased to 10 when testing, to have wider patterns to compare.
  const uint64_t XRespWidth = 10; // TODO
  const uint64_t WUserWidth = 0;
  const uint64_t RUserWidth = 0;
  const uint64_t BUserWidth = 0;

  // Burst size constants

  // Maximal value of any burst_size field, must be positive.
  const uint64_t MaxBurstSizeField = 2;

  // Effective max burst size (in number of elements)
  const uint64_t MaxBurstEffSizeBytes = 1 << MaxBurstSizeField;
  const uint64_t MaxBurstEffSizeBits = MaxBurstEffSizeBytes * 8;

  const uint64_t WStrbWidth = MaxBurstEffSizeBytes;


  // Burst length constants

  // Maximal allowed burst length field value, must be positive.
  const uint64_t MaxBurstLenField = 2;

  // Effective max burst length (in number of elements)
  const uint64_t MaxBurstEffLen = 1 << MaxBurstLenField;

  const uint64_t PackedW = 64;


  typedef enum {
    BURST_FIXED = 0,
    BURST_INCR = 1,
    BURST_WRAP = 2,
    BURST_RESERVED = 3
  } burst_type_e;

#endif  // SIMMEM_DV_AXI_DIMENSIONS
