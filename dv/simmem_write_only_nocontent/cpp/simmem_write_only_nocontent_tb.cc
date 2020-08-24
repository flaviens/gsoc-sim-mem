// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "Vsimmem_write_only_nocontent.h"
#include "simmem_axi_structures.h"
#include "verilated.h"
#include <cassert>
#include <iostream>
#include <memory>
#include <queue>
#include <stdlib.h>
#include <unordered_map>
#include <vector>
#include <verilated_fst_c.h>

const bool kIterationVerbose = false;
const bool kTransactionVerbose = true;

const int kResetLength = 5;
const int kTraceLevel = 6;
const int kIdWidth = 4;

const size_t kMinDelay = 3;
const size_t kMaxDelay = 10;
const size_t kNbLocalIdentifiers = 32;
const size_t kAdjustmentDelay = 1;  // Cycles to subtract to the actual delay

typedef Vsimmem_write_only_nocontent Module;

typedef std::map<uint64_t, std::queue<WriteResponse>> wrsp_queue_map_t;
// Maps mapping AXI identifiers to queues of pairs (timestamp, response)
typedef std::map<uint64_t, std::queue<std::pair<size_t, WriteAddress>>>
    waddr_time_queue_map_t;
typedef std::map<uint64_t, std::queue<std::pair<size_t, WriteResponse>>>
    wrsp_time_queue_map_t;

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
  void simmem_requester_waddr_apply(WriteAddress waddr_req) {
    module_->waddr_data_i = waddr_req.to_packed();
    module_->waddr_in_valid_i = 1;
  }

  /**
   * Checks whether the input request has been accepted.
   */
  bool simmem_requester_waddr_check() {
    module_->eval();
    return (bool)(module_->waddr_in_ready_o);
  }

  /**
   * Stops applying a valid input write address request as the requester.
   */
  void simmem_requester_waddr_stop(void) { module_->waddr_in_valid_i = 0; }

  /**
   * Sets the ready signal to one on the DUT output side for the write response.
   */
  void simmem_requester_wrsp_request(void) { module_->wrsp_out_ready_i = 1; }

  /**
   * Fetches a write response as the requester. Requires the ready signal to be
   * one at the DUT output.
   *
   * @param out_data the output write response from the DUT
   *
   * @return true iff the data is valid
   */
  bool simmem_requester_wrsp_fetch(WriteResponse &out_data) {
    module_->eval();
    assert(module_->wrsp_out_ready_i);

    out_data.from_packed(module_->wrsp_data_o);
    return (bool)(module_->wrsp_out_valid_o);
  }

  /**
   * Sets the ready signal to zero on the DUT output side for the write
   * response.
   */
  void simmem_requester_wrsp_stop(void) { module_->wrsp_out_ready_i = 0; }

  /**
   * Applies a valid write response the real memory controller.
   *
   * @param wresp the input write response
   */
  void simmem_realmem_wrsp_apply(WriteResponse wresp) {
    module_->wrsp_data_i = wresp.to_packed();

    module_->wrsp_in_valid_i = 1;
  }

  /**
   * Checks whether the input request has been accepted.
   */
  bool simmem_realmem_wrsp_check() {
    module_->eval();
    return (bool)(module_->wrsp_in_ready_o);
  }

  /**
   * Stops applying a valid input write response as the real memory controller.
   */
  void simmem_realmem_wrsp_stop(void) { module_->wrsp_in_valid_i = 0; }

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
  bool simmem_realmem_waddr_fetch(WriteAddress &out_data) {
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
      wrsp_out_queues.insert(std::pair<uint64_t, std::queue<WriteResponse>>(
          identifiers[i], std::queue<WriteResponse>()));
    }
  }

  /**
   * Adds a new write address to the received list.
   */
  void add_waddr(WriteAddress waddr) {
    WriteResponse newrsp;
    newrsp.id = waddr.id;
    newrsp.rsp =  // Copy the low order rsp of the incoming waddr in
                  // the corresponding wresp
        (waddr.to_packed() >> WriteAddress::id_w) &
        ~((1L << (PackedW - 1)) >> (PackedW - WriteResponse::rsp_w));

    wrsp_out_queues[waddr.id].push(newrsp);
  }

  /**
   * Simulates immediate operation of the real memory controller.
   * The messages are arbitrarily issued by lowest AXI identifier first.
   *
   * @return 1 iff the real controller holds a valid write response.
   */
  bool has_wrsp_to_input() {
    wrsp_queue_map_t::iterator it;
    for (it = wrsp_out_queues.begin(); it != wrsp_out_queues.end(); it++) {
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
    wrsp_queue_map_t::iterator it;
    for (it = wrsp_out_queues.begin(); it != wrsp_out_queues.end(); it++) {
      if (it->second.size()) {
        return it->second.front();
      }
    }
    assert(false);
  }

  /**
   * Pops the next write response. Assumes there is one ready.
   *
   */
  void pop_next_wresp() {
    wrsp_queue_map_t::iterator it;
    for (it = wrsp_out_queues.begin(); it != wrsp_out_queues.end(); it++) {
      if (it->second.size()) {
        it->second.pop();
        return;
      }
    }
    assert(false);
  }

 private:
  wrsp_queue_map_t wrsp_out_queues;
};

void simple_testbench(SimmemWriteOnlyNoBurstTestbench *tb) {
  tb->simmem_reset();

  tb->simmem_tick(5);

  while (!tb->simmem_is_done()) {
    tb->simmem_tick();
  }
}

void randomized_testbench(SimmemWriteOnlyNoBurstTestbench *tb,
                          size_t num_ids, unsigned int seed) {
  srand(seed);

  size_t nb_iterations = 1000;

  std::vector<uint64_t> identifiers;

  for (size_t i = 0; i < num_ids; i++) {
    identifiers.push_back(i);
  }

  RealMemoryController realmem(identifiers);

  waddr_time_queue_map_t waddr_in_queues;
  waddr_time_queue_map_t waddr_out_queues;
  wrsp_time_queue_map_t wrsp_in_queues;
  wrsp_time_queue_map_t wrsp_out_queues;

  for (size_t i = 0; i < num_ids; i++) {
    waddr_in_queues.insert(
        std::pair<uint64_t, std::queue<std::pair<size_t, WriteAddress>>>(
            identifiers[i], std::queue<std::pair<size_t, WriteAddress>>()));
    waddr_out_queues.insert(
        std::pair<uint64_t, std::queue<std::pair<size_t, WriteAddress>>>(
            identifiers[i], std::queue<std::pair<size_t, WriteAddress>>()));
    wrsp_in_queues.insert(
        std::pair<uint64_t, std::queue<std::pair<size_t, WriteResponse>>>(
            identifiers[i], std::queue<std::pair<size_t, WriteResponse>>()));
    wrsp_out_queues.insert(
        std::pair<uint64_t, std::queue<std::pair<size_t, WriteResponse>>>(
            identifiers[i], std::queue<std::pair<size_t, WriteResponse>>()));
  }

  bool requester_apply_waddr_input_data;
  bool realmem_apply_wrsp_input_data;
  bool requester_req_wrsp_output_data;
  bool realmem_req_waddr_output_data;

  bool iteration_announced;  // Variable only used for display

  WriteAddress requester_current_input;  // Input from the requester
  requester_current_input.from_packed(rand());
  requester_current_input.id = identifiers[rand() % num_ids];
  WriteResponse requester_current_output;  // Output to the requester

  WriteResponse realmem_current_input;  // Input from the realmem
  WriteAddress realmem_current_output;  // Output to the realmem

  tb->simmem_reset();

  for (size_t curr_itern = 0; curr_itern < nb_iterations; curr_itern++) {
    iteration_announced = false;

    // Randomize the boolean signals deciding which interactions will take place
    // in this cycle
    requester_apply_waddr_input_data = (bool)(rand() & 1);
    requester_req_wrsp_output_data = true;
    // The requester is supposedly always ready to get data, for precise delay
    // calculation
    realmem_apply_wrsp_input_data = realmem.has_wrsp_to_input();
    // The real memory controller is supposedly always ready to get data, for
    // precise delay calculation
    realmem_req_waddr_output_data = 1;

    if (requester_apply_waddr_input_data) {
      // Apply a given input
      tb->simmem_requester_waddr_apply(requester_current_input);
    }
    if (requester_req_wrsp_output_data) {
      // Express readiness
      tb->simmem_requester_wrsp_request();
    }
    if (realmem_apply_wrsp_input_data) {
      // Apply the next available wresp from the real memory controller
      tb->simmem_realmem_wrsp_apply(realmem.get_next_wresp());
    }
    if (realmem_req_waddr_output_data) {
      // Express readiness
      tb->simmem_realmem_waddr_request();
    }

    // Input handshakes
    if (requester_apply_waddr_input_data &&
        tb->simmem_requester_waddr_check()) {
      // If the input handshake between the requester and the simmem has been
      // successful, then accept the input

      waddr_in_queues[requester_current_input.id].push(
          std::pair<size_t, WriteAddress>(curr_itern, requester_current_input));
      if (kTransactionVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl
                    << "Step " << std::dec << curr_itern << std::endl;
        }
        std::cout << "Requester inputted " << std::hex
                  << requester_current_input.to_packed() << std::endl;
      }

      // Renew the input data if the input handshake has been successful
      requester_current_input.from_packed(rand());
      requester_current_input.id = identifiers[rand() % num_ids];
    }
    if (realmem_apply_wrsp_input_data && tb->simmem_realmem_wrsp_check()) {
      // If the input handshake between the realmem and the simmem has been
      // successful, then accept the input

      realmem_current_input = realmem.get_next_wresp();
      realmem.pop_next_wresp();

      wrsp_in_queues[realmem_current_input.id].push(
          std::pair<size_t, WriteResponse>(curr_itern, realmem_current_input));
      if (kTransactionVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl
                    << "Step " << std::dec << curr_itern << std::endl;
        }
        std::cout << "Realmem inputted " << std::hex
                  << realmem_current_input.to_packed() << std::endl;
      }

      // Renew the input data if the input handshake has been successful
      realmem_current_input.from_packed(rand());
      realmem_current_input.id = identifiers[rand() % num_ids];
    }

    // Output handshakes
    if (requester_req_wrsp_output_data &&
        tb->simmem_requester_wrsp_fetch(requester_current_output)) {
      // If the output handshake between the requester and the simmem has been
      // successful, then accept the output
      wrsp_out_queues[identifiers[requester_current_output.id]].push(
          std::pair<size_t, WriteResponse>(curr_itern,
                                           requester_current_output));

      if (kTransactionVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl
                    << "Step " << std::dec << curr_itern << std::endl;
        }
        std::cout << "Requester received wresp " << std::hex
                  << requester_current_output.to_packed() << std::endl;
      }
    }
    if (realmem_req_waddr_output_data &&
        tb->simmem_realmem_waddr_fetch(realmem_current_output)) {
      // If the output handshake between the realmem and the simmem has been
      // successful, then accept the output
      waddr_out_queues[identifiers[realmem_current_output.id]].push(
          std::pair<size_t, WriteAddress>(curr_itern, realmem_current_output));

      // Let the realmem treat the freshly received waddr
      realmem.add_waddr(realmem_current_output);

      if (kTransactionVerbose) {
        if (!iteration_announced) {
          iteration_announced = true;
          std::cout << std::endl
                    << "Step " << std::dec << curr_itern << std::endl;
        }
        std::cout << "Realmem received waddr " << std::hex
                  << realmem_current_output.to_packed() << std::endl;
      }
    }

    tb->simmem_tick();

    // Reset all signals after tick (they may be set again before the next DUT
    // evaluation during the beginning of the next iteration)

    if (requester_apply_waddr_input_data) {
      tb->simmem_requester_waddr_stop();
    }
    if (requester_req_wrsp_output_data) {
      tb->simmem_requester_wrsp_stop();
    }
    if (realmem_apply_wrsp_input_data) {
      tb->simmem_realmem_wrsp_stop();
    }
    if (realmem_req_waddr_output_data) {
      tb->simmem_realmem_waddr_stop();
    }
  }

  tb->simmem_requests_complete();
  while (!tb->simmem_is_done()) {
    tb->simmem_tick();
  }

  // Time of response entrance and output
  size_t in_time, out_time;
  WriteAddress in_req;
  WriteResponse out_res;

  for (size_t curr_id = 0; curr_id < num_ids; curr_id++) {
    std::cout << "\n--- AXI ID " << std::dec << curr_id << " ---" << std::endl;

    while (!waddr_in_queues[curr_id].empty() &&
           !wrsp_out_queues[curr_id].empty()) {
      in_time = waddr_in_queues[curr_id].front().first;
      out_time = wrsp_out_queues[curr_id].front().first;

      in_req = waddr_in_queues[curr_id].front().second;
      out_res = wrsp_out_queues[curr_id].front().second;

      waddr_in_queues[curr_id].pop();
      wrsp_out_queues[curr_id].pop();
      std::cout << "Delay: " << std::dec << out_time - in_time << std::hex
                << " (waddr: " << in_req.to_packed()
                << ", wresp: " << out_res.to_packed() << ")." << std::endl;
    }
  }
}

int main(int argc, char **argv, char **env) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

  SimmemWriteOnlyNoBurstTestbench *tb = new SimmemWriteOnlyNoBurstTestbench(
      100, true, "write_only_nocontent.fst");

  // Choose testbench type
  // simple_testbench(tb);
  randomized_testbench(tb, 1, 0);

  delete tb;

  // std::cout << nb_errors << " errors uncovered." << std::endl;
  std::cout << "Testbench complete!" << std::endl;

  exit(0);
}
