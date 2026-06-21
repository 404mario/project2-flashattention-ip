+incdir+rtl/include

rtl/include/flash_attn_pkg.sv
rtl/include/fp8_e4m3_pkg.sv
rtl/include/bf16_pkg.sv

rtl/core/dot_product_engine.sv
rtl/core/dot_stream.sv
rtl/core/block_quant_dot.sv
rtl/core/softmax_combine.sv
rtl/core/fp_softmax_unit.sv
rtl/core/fp_recip.sv
rtl/core/fp_exp.sv
rtl/core/causal_mask_unit.sv
rtl/core/online_softmax_engine.sv
rtl/core/normalizer.sv
rtl/core/quantize_saturate.sv
rtl/core/value_accumulator.sv
rtl/core/tile_scheduler.sv
rtl/core/flash_core.sv

rtl/mem/row_buffer.sv
rtl/mem/tile_buffer.sv

rtl/axi/axi_lite_regs.sv
rtl/axi/axi_master_read.sv
rtl/axi/axi_master_write.sv
rtl/axi/dma_controller.sv
rtl/axi/dma_controller_fp8.sv
rtl/axi/dma_controller_bf16.sv

rtl/top/flash_attn_top.sv
