TARGET := 2way
syn:
	dc_shell-t -f syn_$(TARGET).tcl
run_rtl:
	vcs tb_cache.v cache_$(TARGET).v memory.v -v tsmc13.v  -full64 -R -debug_access+all +v2k +notimingcheck
run_syn:
	vcs tb_cache.v cache_$(TARGET)_syn.v memory.v -v tsmc13.v +define+SDF  -full64 -R -debug_access+all +v2k +neg_tchk