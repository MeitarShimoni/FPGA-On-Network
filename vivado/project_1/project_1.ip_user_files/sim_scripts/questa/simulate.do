onbreak {quit -f}
onerror {quit -f}

vsim  -lib xil_defaultlib Chip_Top_DSP_ETH_opt

set NumericStdNoWarnings 1
set StdArithNoWarnings 1

do {wave.do}

view wave
view structure
view signals

do {Chip_Top_DSP_ETH.udo}

run 1000ns

quit -force
