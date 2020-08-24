// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// The constants in this header must be identical to the ones defined in rtl/simmem_pkg.sv

#ifndef SIMMEM_DV_AXI_DIMENSIONS
#define SIMMEM_DV_AXI_DIMENSIONS

#include <stdint.h>

// TODO Harmonize with simmem_pkg

// TODO: Change the const names to fit with the C++ coding style

const uint64_t GlobalMemCapaW = 19;

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

const uint64_t XLastWidth = 1;
// TODO: Set XRespWidth to 3 when all tests are passed
const uint64_t XRespWidth = 10;
const uint64_t WUserWidth = 0;
const uint64_t RUserWidth = 0;
const uint64_t BUserWidth = 0;

const uint64_t WStrbWidth = MaxBurstEffSizeBytes;

// Burst length constants

// Maximal allowed burst length field value, must be positive.
const uint64_t MaxBurstLenField = 2;

// Effective max burst length (in number of elements)
const uint64_t MaxBurstEffLen = 1 << MaxBurstLenField;


////////////////////////////
// Dimensions for modules //
////////////////////////////

// Capacities in extended cells (number of outstanding bursts).
const uint64_t WRspBankCapa = 32;
const uint64_t RDataBankCapa = 16;

const uint64_t WRspBankAddrW = $clog2(WRspBankCapa);
const uint64_t RDataBankAddrW = $clog2(RDataBankCapa);

////////////////////////////
// Dimensions for modules //
////////////////////////////

const uint64_t WRspBankCapa = 32;
const uint64_t RDataBankCapa = 16;

///////////////////////
// Auxiliary signals //
///////////////////////

const unsigned int PackedW = 64;
const unsigned int MaxPendingWData = WRspBankCapa * MaxBurstEffLen / 2;

#endif  // SIMMEM_DV_AXI_DIMENSIONS
