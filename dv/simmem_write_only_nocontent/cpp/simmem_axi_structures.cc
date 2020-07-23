// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "simmem_axi_structures.h"

///////////////////////////
// Write address request //
///////////////////////////

// Static constant definition (widths)
const uint64_t WriteAddressRequest::id_w = IDWidth;
const uint64_t WriteAddressRequest::addr_w = AxAddrWidth;
const uint64_t WriteAddressRequest::burst_len_w = AxLenWidth;
const uint64_t WriteAddressRequest::burst_size_w = AxSizeWidth;
const uint64_t WriteAddressRequest::burst_type_w = AxBurstWidth;
const uint64_t WriteAddressRequest::lock_type_w = AxLockWidth;
const uint64_t WriteAddressRequest::memtype_w = AxCacheWidth;
const uint64_t WriteAddressRequest::prot_w = AxProtWidth;
const uint64_t WriteAddressRequest::qos_w = AxQoSWidth;

// Static constant definition (offsets)
const uint64_t WriteAddressRequest::id_off = 0UL;
const uint64_t WriteAddressRequest::addr_off =
    WriteAddressRequest::id_off + WriteAddressRequest::id_w;
const uint64_t WriteAddressRequest::burst_len_off =
    WriteAddressRequest::addr_off + WriteAddressRequest::addr_w;
const uint64_t WriteAddressRequest::burst_size_off =
    WriteAddressRequest::burst_len_off + WriteAddressRequest::burst_len_w;
const uint64_t WriteAddressRequest::burst_type_off =
    WriteAddressRequest::burst_size_off + WriteAddressRequest::burst_size_w;
const uint64_t WriteAddressRequest::lock_type_off =
    WriteAddressRequest::burst_type_off + WriteAddressRequest::burst_type_w;
const uint64_t WriteAddressRequest::memtype_off =
    WriteAddressRequest::lock_type_off + WriteAddressRequest::lock_type_w;
const uint64_t WriteAddressRequest::prot_off =
    WriteAddressRequest::memtype_off + WriteAddressRequest::memtype_w;
const uint64_t WriteAddressRequest::qos_off =
    WriteAddressRequest::prot_off + WriteAddressRequest::prot_w;

/**
 * Helper function to parse a packed structure representation
 *
 * @param packed the packed structure representation
 * @param field_w the field representation width (bits)
 * @param field_off the field representation offset (bits)
 * @return the field value read from the packed representation
 */
uint64_t single_from_packed(uint64_t packed, uint64_t field_w,
                            uint64_t field_off) {
  uint64_t low_mask;

  if (field_w) {
    low_mask = ~(1L << (PackedW - 1)) >> (PackedW - 1 - field_w);
    return low_mask & ((packed & (low_mask << field_off)) >> field_off);
  }
  return 0;
}

/**
 * Helper function that fills a partial packed structure representation from
 * a single field.
 *
 * @param packed the partial packed structure representation, modified in place
 * @param field the field value
 * @param field_w the field representation width (bits)
 * @param field_off the field representation offset (bits)
 */
void single_to_packed(uint64_t &packed, uint64_t field, uint64_t field_w,
                      uint64_t field_off) {
  uint64_t low_mask;

  if (field_w) {
    low_mask = ~((1L << (PackedW - 1)) >> (PackedW - 1 - field_w));
    // Clean the space dedicated to the field
    packed &= ~(low_mask << field_off);
    // Populate the space dedicated to the field
    packed |= (low_mask & field) << field_off;
  }
}

void WriteAddressRequest::from_packed(uint64_t packed) {
  id = single_from_packed(packed, id_w, id_off);
  addr = single_from_packed(packed, addr_w, addr_off);
  burst_len = single_from_packed(packed, burst_len_w, burst_len_off);
  burst_size = single_from_packed(packed, burst_size_w, burst_size_off);
  burst_type = single_from_packed(packed, burst_type_w, burst_type_off);
  lock_type = single_from_packed(packed, lock_type_w, lock_type_off);
  memtype = single_from_packed(packed, memtype_w, memtype_off);
  prot = single_from_packed(packed, prot_w, prot_off);
  qos = single_from_packed(packed, qos_w, qos_off);
}

uint64_t WriteAddressRequest::to_packed() {
  uint64_t packed = 0UL;

  single_to_packed(packed, id, id_w, id_off);
  single_to_packed(packed, addr, addr_w, addr_off);
  single_to_packed(packed, burst_len, burst_len_w, burst_len_off);
  single_to_packed(packed, burst_size, burst_size_w, burst_size_off);
  single_to_packed(packed, burst_type, burst_type_w, burst_type_off);
  single_to_packed(packed, lock_type, lock_type_w, lock_type_off);
  single_to_packed(packed, memtype, memtype_w, memtype_off);
  single_to_packed(packed, prot, prot_w, prot_off);
  single_to_packed(packed, qos, qos_w, qos_off);

  return packed;
}

////////////////////
// Write response //
////////////////////

// Static constant definition (widths)
const uint64_t WriteResponse::id_w = IDWidth;
const uint64_t WriteResponse::payload_w = XRespWidth;

// Static constant definition (offsets)
const uint64_t WriteResponse::id_off = 0UL;
const uint64_t WriteResponse::payload_off =
    WriteResponse::id_off + WriteResponse::id_w;

void WriteResponse::from_packed(uint64_t packed) {
  uint64_t low_mask;

  id = single_from_packed(packed, id_w, id_off);
  payload = single_from_packed(packed, payload_w, payload_off);
}

uint64_t WriteResponse::to_packed() {
  uint64_t packed = 0UL;

  single_to_packed(packed, id, id_w, id_off);
  single_to_packed(packed, payload, payload_w, payload_off);

  return packed;
}