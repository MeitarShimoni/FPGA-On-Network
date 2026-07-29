transcript off
onbreak {quit -force}
onerror {quit -force}
transcript on

asim +access +r +m+Chip_Top_DSP_ETH  -L xil_defaultlib -L xpm -L unisims_ver -L unimacro_ver -L secureip -O5 xil_defaultlib.Chip_Top_DSP_ETH xil_defaultlib.glbl

do {Chip_Top_DSP_ETH.udo}

run 1000ns

endsim

quit -force
