
set DESIGN cache_dm
sh mkdir -p work
sh mkdir -p report

define_design_lib WORK -path work


analyze -format verilog "$DESIGN.v"
elaborate cache
current_design cache

source -echo -verbose cache_syn.sdc 
compile_ultra

write_sdf -version 2.1  -context verilog -load_delay cell "${DESIGN}_syn.sdf"
write -format verilog -hierarchy -output "./${DESIGN}_syn.v"
write -format ddc -hierarchy -output "${DESIGN}_syn.ddc"

report_area -hierarchy > "report/$DESIGN.area"
report_timing > "report/$DESIGN.timing"
check_design