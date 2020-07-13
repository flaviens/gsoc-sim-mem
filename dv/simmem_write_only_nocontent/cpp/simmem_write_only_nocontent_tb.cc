// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "Vsimmem_write_only_nocontent.h"
#include "simmem_axi_structures.h"
#include "verilated.h"
#include <cassert>
#include <iostream>
#include <memory>
#include <stdlib.h>
#include <unordered_map>
#include <vector>
#include <verilated_fst_c.h>

const bool kIterationVerbose = false;
const bool kPairsVerbose = false;
const bool kTransactionVerbose = false;

const int kResetLength = 5;
const int kTraceLevel = 6;
const int kIdWidth = 4;

const size_t kMinDelay = 3;
const size_t kMaxDelay = 10;
const size_t kNbLocalIdentifiers = 32;
const size_t kAdjustmentDelay = 1;  // Cycles to subtract to the actual delay

typedef Vsimmem_write_only_nocontent Module;
typedef std::map<uint64_t, std::queue<WriteAddressRequest>> waddr_queue_map_t;
typedef std::map<uint64_t, std::queue<WriteResponse>> wresp_queue_map_t;

// This class implements elementary operations for the testbench
class SimmemWriteOnlyNoBurstTestbench {
 public:
  /**
   * @param record_trace set to false to skip trace recording
   */
  SimmemWriteOnlyNoBurstTestbench(vluint32_t trailing_clock_cycles = 0,
                                  bool record_trace = true,
                                  const std::string &trace_filename = "sim.fst")
      : tick_count_(0l),
        trailing_clock_cycles_(trailing_clock_cycles),
        record_trace_(record_trace),
        module_(new Module) {
    if (record_trace) {
      trace_ = new VerilatedFstC;
      module_->trace(trace_, kTraceLevel);
      trace_->open(trace_filename.c_str());
    }
  }

  ~SimmemWriteOnlyNoBurstTestbench() { simmem_close_trace(); }

  void simmem_reset(void) {
    module_->rst_ni = 0;
    this->simmem_tick(kResetLength);
    module_->rst_ni = 1;
  }

  void simmem_close_trace(void) { trace_->close(); }

  /**
   * Performs one or multiple clock cycles.
   *
   * @param nb_ticks the number of ticks to perform at once
   */
  void simmem_tick(int nbTicks = 1) {
    for (size_t i = 0; i < nbTicks; i++) {
      if (kIterationVerbose) {
        std::cout << "Running iteration " << tick_count_ << std::endl;
      }

      tick_count_++;

      module_->clk_i = 0;
      module_->eval();

      if (record_trace_) {
        trace_->dump(5 * tick_count_ - 1);
      }
      module_->clk_i = 1;
      module_->eval();

      if (record_trace_) {
        trace_->dump(5 * tick_count_);
      }
      module_->clk_i = 0;
      module_->eval();

      if (record_trace_) {
        trace_->dump(5 * tick_count_ + 2);
        trace_->flush();
      }
    }
  }

  /**
   * Applies a valid input address request as the requester.
   *
   * @param waddr_req the input address request
   */
  void simmem_requester_waddr_apply(WriteAddressRequest waddr_req) {
    module_->waddr_data_i = waddr_req.to_packed();
    module_->waddr_in_valid_i = 1;
  }

  /**
   * Stops feeding a valid input write address request as the requester.
   */
  void simmem_requester_waddr_stop(void) { module_->waddr_in_valid_i = 0; }

  /**
   * Sets the ready signal to one on the DUT output side for the write response.
   */
  void simmem_requester_wresp_request(void) { module_->wresp_out_ready_i = 1; }

  /**
   * Fetches a write response as the requester. Requires the ready signal to be
   * one at the DUT output.
   *
   * @param out_data the output write response from the DUT
   *
   * @return true iff the data is valid
   */
  bool simmem_requester_wresp_fetch(WriteResponse &out_data) {
    module_->eval();
    assert(module_->wresp_out_ready_i);

    out_data.from_packed(module_->wresp_data_o);
    return (bool)(module_->wresp_out_valid_o);
  }

  /**
   * Sets the ready signal to zero on the DUT output side for the write
   * response.
   */
  void simmem_requester_wresp_stop(void) { module_->wresp_out_ready_i = 0; }

  /**
   * Applies a valid write response the real memory controller.
   *
   * @param wresp the input write response
   */
  void simmem_realmem_wresp_apply(WriteResponse wresp) {
    module_->wresp_data_i = wresp.to_packed();
    module_->wresp_in_valid_i = 1;
  }

  /**
   * Stops feeding a valid input write response as the real memory controller.
   */
  void simmem_realmem_wresp_stop(void) { module_->wresp_in_valid_i = 0; }

  /**
   * Sets the ready signal to one on the DUT output side for the write address.
   */
  void simmem_realmem_waddr_request(void) { module_->waddr_out_ready_i = 1; }

  /**
   * Fetches a write address as the real memory controller. Requires the ready
   * signal to be one at the DUT output.
   *
   * @param out_data the output write address request from the DUT
   *
   * @return true iff the data is valid
   */
  bool simmem_realmem_waddr_fetch(WriteAddressRequest &out_data) {
    module_->eval();
    assert(module_->waddr_out_ready_i);

    out_data.from_packed(module_->waddr_data_o);
    return (bool)(module_->waddr_out_valid_o);
  }

  /**
   * Sets the ready signal to zero on the DUT output side for the write
   * address.
   */
  void simmem_realmem_waddr_stop(void) { module_->waddr_out_ready_i = 0; }

  /**
   * Informs the testbench that all the requests have been performed and
   * therefore that the trailing cycles phase should start.
   */
  void simmem_requests_complete(void) { tick_count_ = 0; }

  /**
   * Checks whether the testbench completed the trailing cycles phase.
   */
  bool simmem_is_done(void) {
    return (
        Verilated::gotFinish() ||
        (trailing_clock_cycles_ && (tick_count_ >= trailing_clock_cycles_)));
  }

 private:
  vluint32_t tick_count_;
  vluint32_t trailing_clock_cycles_;
  bool record_trace_;
  std::unique_ptr<Module> module_;
  VerilatedFstC *trace_;
};

class RealMemoryController {
 public:
  RealMemoryController(std::vector<uint64_t> identifiers) {
    for (size_t i = 0; i < identifiers.size(); i++) {
      wresp_queues.insert(std::pair<uint64_t, std::queue<WriteResponse>>(
          identifiers[i], std::queue<WriteResponse>()));
    }
  }

  /**
   * Simulates immediate operation of the real memory controller.
   * The messages are arbitrarily issued by lowest AXI identifier first.
   *
   * @return 1 iff the real controller holds a valid write response.
   */
  bool has_wresp_to_input() {
    queue_map_t::iterator it;
    for (it = wresp_queues.begin(); it != wresp_queues.end(); it++) {
      if (it->second.size()) {
        return true;
      }
    }
    return false;
  }

  /**
   * Gets the next write response. Assumes there is one ready.
   * This function is not destructive: the write response is not popped.
   *
   * @return the write response.
   */
  WriteResponse get_next_wresp() {
    queue_map_t::iterator it;
    for (it = wresp_queues.begin(); it != wresp_queues.end(); it++) {
      if (it->second.size()) {
        return it->second.front();
      }
    }
    assert(true);
  }

  /**
   * Gets the next write response. Assumes there is one ready.
   * This function is destructive: the write response is popped.
   *
   * @return the write response.
   */
  uint64_t pop_next_wresp() {
    queue_map_t::iterator it;
    for (it = wresp_queues.begin(); it != wresp_queues.end(); it++) {
      if (it->second.size()) {
        return it->second.pop();
      }
    }
    assert(true);
  }

 private:
  wresp_queue_map_t wresp_queues;
}

void simple_testbench(SimmemWriteOnlyNoBurstTestbench *tb) {
  tb->simmem_reset();

  tb->simmem_tick(5);

  while (!tb->simmem_is_done()) {
    tb->simmem_tick();
  }
}

void randomized_testbench(SimmemWriteOnlyNoBurstTestbench *tb,
                          size_t num_identifiers, unsigned int seed) {
  srand(seed);

  int nb_iterations = 1000;

  std::vector<uint64_t> identifiers;

  for (size_t i = 0; i < num_identifiers; i++) {
    identifiers.push_back(i);
  }

  RealMemoryController realmem(identifiers);

  waddr_queue_t waddr_queues;
  wresp_queue_t wresp_queues;

  for (size_t i = 0; i < num_identifiers; i++) {
    waddr_queues.insert(std::pair<uint64_t, std::queue<WriteAddressRequest>>(
        identifiers[i], std::queue<WriteAddressRequest>()));
    wresp_queues.insert(std::pair<uint64_t, std::queue<WriteResponse>>(
        identifiers[i], std::queue<WriteResponse>()));
  }

  bool requester_apply_input_data;
  bool realmem_apply_input_data;
  bool requester_req_output_data;
  bool realmem_req_output_data;

  bool iteration_announced;  // Variable only used for display

  WriteAddressRequest requester_current_input;  // Input from the requester
  requester_current_input
      .from_packed(rand() % PackedWidth)
          requester_current_input.id = identifiers[rand() % num_identifiers];

  WriteResponse requester_current_output;  // Output to the requester

  uint64_t realmem_current_input;   // Input from the real memory controller
  uint64_t realmem_current_output;  // Output to the real memory controller

  tb->simmem_reset();

  for (size_t i = 0; i < nb_iterations; i++) {
    iteration_announced = false;

    // Randomize the boolean signals deciding which interactions will take place
    // in this cycle
    requester_apply_input_data = (bool)(rand() & 1);
    requester_req_output_data = (bool)(rand() & 1);
    realmem_apply_input_data =
        realmem.has_write_data_to_input(realmem_current_output);
    // The real memory controller is supposedly always ready to get data
    realmem_req_output_data = 1;

    if (requester_apply_input_data) {
      // Apply a given input
      tb->simmem_requester_waddr_apply(current_input_id, current_content);
    }
    if (requester_req_output_data) {
      // Try to fetch an output if the handshake is successful
      tb->simmem_requester_wresp_request();
    }
    // if (simmem_apply_input_data) {
    //   // Apply a given input
    //   tb->simmem_requester_waddr_apply(current_input_id, current_content);
    // }
    // if (requester_req_output_data) {
    //   // Try to fetch an output if the handshake is successful
    //   tb->simmem_requester_wresp_request();
    // }

    // TODO: Continue here by adding the interaction with the real memory
    // controller

    // Only perform the evaluation once all the inputs have been applied
    if (reserve && tb->simmem_reservation_check()) {
      if (kTransactionsVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl << "Step " << std::dec << i << std::endl;
        }
        std::cout << current_reservation_id << " reserves "
                  << tb->simmem_reservation_get_address() << std::endl;
      }

      // Renew the reservation identifier if the reservation has been successful
      current_reservation_id = identifiers[rand() % num_identifiers];
    }
    if (tb->simmem_input_data_check()) {
      // If the input handshake has been successful, then add the input into the
      // corresponding queue

      waddr_queues[current_input_id].push(current_input);
      if (kTransactionsVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl << "Step " << std::dec << i << std::endl;
        }
        std::cout << std::dec << current_input_id << " inputs " << std::hex
                  << current_input << std::endl;
      }

      // Renew the input data if the input handshake has been successful
      current_input_id = identifiers[rand() % num_identifiers];
      current_content = (uint64_t)(rand() & tb->simmem_get_content_mask());
    }
    if (requester_req_output_data) {
      // If the output handshake has been successful, then add the output to the
      // corresponding queue
      if (tb->simmem_output_data_fetch(current_output)) {
        wresp_queues[identifiers[(current_output &
                                  tb->simmem_get_identifier_mask()) >>
                                 kMsgWidth]]
            .push(current_output);

        if (kTransactionsVerbose) {
          if (!iteration_announced) {
            iteration_announced = true;
            std::cout << std::endl << "Step " << std::dec << i << std::endl;
          }
          std::cout << std::dec
                    << (uint64_t)(current_output &
                                  ~tb->simmem_get_identifier_mask())
                    << " outputs " << std::hex << current_output << std::endl;
        }
      }
    }

    tb->simmem_tick();

    // Reset all signals after tick (they may be set again before the next DUT
    // evaluation during the beginning of the next iteration)

    if (reserve) {
      tb->simmem_reservation_stop();
    }
    if (requester_apply_input_data) {
      tb->simmem_input_data_stop();
    }
    if (requester_req_output_data) {
      tb->simmem_output_data_stop();
    }
  }

  tb->simmem_requests_complete();
  while (!tb->simmem_is_done()) {
    tb->simmem_tick();
  }

  // Check the input and output queues for mismatches
  size_t nb_mismatches = 0;
  for (size_t i = 0; i < num_identifiers; i++) {
    while (!waddr_queues[i].empty() && !wresp_queues[i].empty()) {
      current_input = waddr_queues[i].front();
      current_output = wresp_queues[i].front();

      waddr_queues[i].pop();
      wresp_queues[i].pop();
      if (kPairsVerbose) {
        std::cout << std::hex << current_input << " - " << current_output
                  << std::endl;
      }
      nb_mismatches += (size_t)(current_input != current_output);
    }
  }
  if (kPairsVerbose) {
    std::cout << std::endl
              << "Mismatches: " << std::dec << nb_mismatches << std::endl
              << std::endl;
  }

  return nb_mismatches;
}

int main(int argc, char **argv, char **env) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

  SimmemWriteOnlyNoBurstTestbench *tb = new SimmemWriteOnlyNoBurstTestbench(
      100, true, "write_only_nocontent.fst");

  // Choose testbench type
  simple_testbench(tb);
  delete tb;

  // std::cout << nb_errors << " errors uncovered." << std::endl;
  std::cout << "Testbench complete!" << std::endl;

  exit(0);
}
