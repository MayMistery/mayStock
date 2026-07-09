SCRIPT := ./Scripts/make.sh

.PHONY: build test e2e verify install run uninstall clean

build test e2e verify install run uninstall:
	$(SCRIPT) $@

clean:
	swift package clean
	rm -rf /Applications/MayStock.app dist
