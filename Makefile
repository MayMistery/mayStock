SCRIPT := ./Scripts/make.sh

.PHONY: build test e2e verify install run uninstall clean lab kernel

build test e2e verify install run uninstall:
	$(SCRIPT) $@

# Rust trading kernel (indicators, DSL, backtest engine, live decision).
kernel:
	./Scripts/build-kernel.sh release

# Strategy research bench. `make lab ARGS="backtest ema-trend --days 365"`
lab: kernel
	swift build --product maystock-lab
	.build/debug/maystock-lab $(ARGS)

clean:
	swift package clean
	cd kernel && cargo clean
	rm -rf /Applications/MayStock.app dist .build/kernel
