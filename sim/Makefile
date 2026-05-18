SIM ?= xsim
TOPLEVEL_LANG ?= verilog

PWD=$(shell pwd)

# 🚨 修正：必须先编译 package 包，再编译模块文件！
VERILOG_SOURCES += $(PWD)/../rtl/include/flash_attn_pkg.sv
VERILOG_SOURCES += $(PWD)/../rtl/axi/axi_lite_regs.sv

TOPLEVEL = axi_lite_regs
MODULE ?= test_axi_lite

include $(shell cocotb-config --makefiles)/Makefile.sim

clean::
	rm -rf sim_build __pycache__ results.xml dump.vcd