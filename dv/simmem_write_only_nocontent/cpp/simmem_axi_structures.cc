// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "simmem_axi_structures.h"

///////////////////////////
// Write address request //
///////////////////////////

// Static constant definition (widths)
const uint64_t WriteAddressRequest::id_width = IDWidth;
const uint64_t WriteAddressRequest::addr_width = AxAddrWidth;
const uint64_t WriteAddressRequest::burst_length_width = AxLenWidth;
const uint64_t WriteAddressRequest::burst_size_width = AxSizeWidth;
const uint64_t WriteAddressRequest::burst_type_width = AxBurstWidth;
const uint64_t WriteAddressRequest::lock_type_width = AxLockWidth;
const uint64_t WriteAddressRequest::memory_type_width = AxCacheWidth;
const uint64_t WriteAddressRequest::protection_type_width = AxProtWidth;
const uint64_t WriteAddressRequest::qos_width = AxQoSWidth;

// Static constant definition (offsets)
const uint64_t WriteAddressRequest::id_offset = 0UL;
const uint64_t WriteAddressRequest::addr_offset =
    WriteAddressRequest::id_offset + WriteAddressRequest::id_width;
const uint64_t WriteAddressRequest::burst_length_offset =
    WriteAddressRequest::addr_offset + WriteAddressRequest::addr_width;
const uint64_t WriteAddressRequest::burst_size_offset =
    WriteAddressRequest::burst_length_offset +
    WriteAddressRequest::burst_length_width;
const uint64_t WriteAddressRequest::burst_type_offset =
    WriteAddressRequest::burst_size_offset +
    WriteAddressRequest::burst_size_width;
const uint64_t WriteAddressRequest::lock_type_offset =
    WriteAddressRequest::burst_type_offset +
    WriteAddressRequest::burst_type_width;
const uint64_t WriteAddressRequest::memory_type_offset =
    WriteAddressRequest::lock_type_offset +
    WriteAddressRequest::lock_type_width;
const uint64_t WriteAddressRequest::protection_type_offset =
    WriteAddressRequest::memory_type_offset +
    WriteAddressRequest::memory_type_width;
const uint64_t WriteAddressRequest::qos_offset =
    WriteAddressRequest::protection_type_offset +
    WriteAddressRequest::protection_type_width;

void WriteAddressRequest::from_packed(uint64_t packed) {
  uint64_t low_mask;

  if (id_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - id_width);
    id = low_mask & ((packed & (low_mask << id_offset)) >> id_offset);
  }

  if (addr_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - addr_width);
    addr = low_mask & ((packed & (low_mask << addr_offset)) >> addr_offset);
  }

  if (burst_length_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - burst_length_width);
    burst_length = low_mask & ((packed & (low_mask << burst_length_offset)) >>
                               burst_length_offset);
  }

  if (burst_size_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - burst_size_width);
    burst_size = low_mask & ((packed & (low_mask << burst_size_offset)) >>
                             burst_size_offset);
  }

  if (burst_type_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - burst_type_width);
    burst_type = low_mask & ((packed & (low_mask << burst_type_offset)) >>
                             burst_type_offset);
  }

  if (lock_type_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - lock_type_width);
    lock_type = low_mask &
                ((packed & (low_mask << lock_type_offset)) >> lock_type_offset);
  }

  if (memory_type_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - memory_type_width);
    memory_type = low_mask & ((packed & (low_mask << memory_type_offset)) >>
                              memory_type_offset);
  }

  if (!protection_type_width) {
    low_mask =
        (1UL << (PackedWidth - 1)) >> (PackedWidth - protection_type_width);
    protection_type =
        low_mask & ((packed & (low_mask << protection_type_offset)) >>
                    protection_type_offset);
  }

  if (qos_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - qos_width);
    qos = low_mask & ((packed & (low_mask << qos_offset)) >> qos_offset);
  }
}

uint64_t WriteAddressRequest::to_packed() {
  uint64_t packed = 0UL;
  uint64_t low_mask;

  if (id_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - id_width);
    packed &= low_mask << id_offset;
    packed |= (~low_mask & id) << id_offset;
  }

  if (addr_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - addr_width);
    packed &= low_mask << addr_offset;
    packed |= (~low_mask & addr) << addr_offset;
  }

  if (burst_length_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - burst_length_width);
    packed &= low_mask << burst_length_offset;
    packed |= (~low_mask & burst_length) << burst_length_offset;
  }

  if (burst_size_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - burst_size_width);
    packed &= low_mask << burst_size_offset;
    packed |= (~low_mask & burst_size) << burst_size_offset;
  }

  if (burst_type_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - burst_type_width);
    packed &= low_mask << burst_type_offset;
    packed |= (~low_mask & burst_type) << burst_type_offset;
  }

  if (lock_type_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - lock_type_width);
    packed &= low_mask << lock_type_offset;
    packed |= (~low_mask & lock_type) << lock_type_offset;
  }

  if (memory_type_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - memory_type_width);
    packed &= low_mask << memory_type_offset;
    packed |= (~low_mask & memory_type) << memory_type_offset;
  }

  if (protection_type_width) {
    low_mask =
        (1UL << (PackedWidth - 1)) >> (PackedWidth - protection_type_width);
    packed &= low_mask << protection_type_offset;
    packed |= (~low_mask & protection_type) << protection_type_offset;
  }

  if (qos_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - qos_width);
    packed &= low_mask << qos_offset;
    packed |= (~low_mask & qos) << qos_offset;
  }

  return packed;
}

////////////////////
// Write response //
////////////////////

// Static constant definition (widths)
const uint64_t WriteResponse::id_width = IDWidth;
const uint64_t WriteResponse::content_width = XRespWidth;

// Static constant definition (offsets)
const uint64_t WriteResponse::id_offset = 0UL;
const uint64_t WriteResponse::content_offset =
    WriteResponse::id_offset + WriteResponse::id_width;

void WriteResponse::from_packed(uint64_t packed) {
  uint64_t low_mask;

  if (id_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - id_width);
    id = low_mask & ((packed & (low_mask << id_offset)) >> id_offset);
  }

  if (content_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - content_width);
    content =
        low_mask & ((packed & (low_mask << content_offset)) >> content_offset);
  }
}

uint64_t WriteResponse::to_packed() {
  uint64_t packed = 0UL;
  uint64_t low_mask;
  if (!id_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - id_width);
    packed &= low_mask << id_offset;
    packed |= (~low_mask & id) << id_offset;
  }

  if (content_width) {
    low_mask = (1UL << (PackedWidth - 1)) >> (PackedWidth - content_width);
    packed &= low_mask << content_offset;
    packed |= (~low_mask & content) << content_offset;
  }

  return packed;
}