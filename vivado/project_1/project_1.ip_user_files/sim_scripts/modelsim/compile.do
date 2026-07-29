vlib modelsim_lib/work
vlib modelsim_lib/msim

vlib modelsim_lib/msim/xpm
vlib modelsim_lib/msim/xil_defaultlib

vmap xpm modelsim_lib/msim/xpm
vmap xil_defaultlib modelsim_lib/msim/xil_defaultlib

vlog -work xpm  -incr -mfcu  -sv "+incdir+../../../../../../../../../../AMDDesignTools/2026.1/Vivado/data/rsb/busdef" "+incdir+../../../project_1.gen/sources_1/ip/clk_wiz_0" \
"C:/AMDDesignTools/2026.1/Vivado/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" \

vcom -work xpm  -93  \
"C:/AMDDesignTools/2026.1/Vivado/data/ip/xpm/xpm_VCOMP.vhd" \

vlog -work xil_defaultlib  -incr -mfcu  "+incdir+../../../../../../../../../../AMDDesignTools/2026.1/Vivado/data/rsb/busdef" "+incdir+../../../project_1.gen/sources_1/ip/clk_wiz_0" \
"../../../project_1.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_clk_wiz.v" \
"../../../project_1.gen/sources_1/ip/clk_wiz_0/clk_wiz_0.v" \

vlog -work xil_defaultlib  -incr -mfcu  -sv "+incdir+../../../../../../../../../../AMDDesignTools/2026.1/Vivado/data/rsb/busdef" "+incdir+../../../project_1.gen/sources_1/ip/clk_wiz_0" \
"../../../../../designs/display/clock_divider32.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/eth_frame_rx.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/eth_frame_tx.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/eth_packet_fifo.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/ethernet_mac.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/mac_filter.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/rmii_rx.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/rmii_tx.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/rx_ethernet.sv" \
"../../../../../designs/display/seven_segmnet.sv" \
"../../../../../../MyIPs/Ethernet_MAC/src/tx_ethernet.sv" \
"../../../../../designs/Chip_Top_DSP_ETH.sv" \

vlog -work xil_defaultlib \
"glbl.v"

