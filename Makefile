# Voice — Development helpers

.PHONY: install clean

install:
	@./scripts/build-install.sh

install-keep-permissions:
	@SKIP_TCC=1 ./scripts/build-install.sh

clean:
	@rm -rf .build
