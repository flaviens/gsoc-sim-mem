// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "Vsimmem_delay_bank.h"
#include "verilated.h"
#include <cassert>
#include <iostream>
#include <memory>
#include <stdlib.h>
#include <verilated_fst_c.h>

const bool kIterationVerbose = false;

const int kResetLength = 5;
const int kTraceLevel = 6;
const int kIdWidth = 4;

typedef Vsimmem_delay_bank Module;

// This class implements elementary operations for the testbench
class DelayBankTestbench {
 public:
  // @param max_clock_cycles set to 0 to disable interruption after a given
  // number of clock cycles
  // @param record_trace set to false to skip trace recording
  DelayBankTestbench(vluint32_t max_clock_cycles = 0, bool record_trace = true,
                     const std::string &trace_filename = "sim.fst")
      : tick_count_(0l),
        max_clock_cycles_(max_clock_cycles),
        record_trace_(record_trace),
        module_(new Module) {
    if (record_trace) {
      trace_ = new VerilatedFstC;
      module_->trace(trace_, kTraceLevel);
      trace_->open(trace_filename.c_str());
    }
  }

  ~DelayBankTestbench() { close_trace(); }

  void reset(void) {
    module_->rst_ni = 0;
    for (size_t i = 0; i < kResetLength; i++) {
      this->tick();
    }
    module_->rst_ni = 1;
  }

  void close_trace(void) { trace_->close(); }

  void tick(int nbTicks = 1) {
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

  bool is_done(void) {
    return (Verilated::gotFinish() ||
            (max_clock_cycles_ && (tick_count_ >= max_clock_cycles_)));
  }

  void apply_input_data(u_int32_t local_identifier, u_int32_t delay,
                        bool is_write_response) {
    module_->local_identifier_i = local_identifier;
    module_->delay_i = delay;
    module_->is_write_resp_i = is_write_response;
    module_->in_valid_i = 1;
  }

  bool is_input_data_accepted() {
    module_->eval();
    return (bool)(module_->in_ready_o);
  }

  void stop_input_data() { module_->in_valid_i = 0; }

 private:
  vluint32_t tick_count_;
  vluint32_t max_clock_cycles_;
  bool record_trace_;
  std::unique_ptr<Module> module_;
  VerilatedFstC *trace_;
};

void sequential_test(DelayBankTestbench *tb) {
  tb->reset();

  tb->tick(4);

  // Apply inputs for 6 ticks
  tb->apply_input_data(7, 5, 1);
  tb->tick(1);
  tb->stop_input_data();

  tb->tick(7);

  // while (!tb->is_done()) {
  //   tb->tick();
  // }
}

int main(int argc, char **argv, char **env) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

  DelayBankTestbench *tb = new DelayBankTestbench(100, true, "delay_bank.fst");

  // Choose testbench type
  sequential_test(tb);
  delete tb;

  std::cout << "Testbench complete!" << std::endl;

  exit(0);
}
