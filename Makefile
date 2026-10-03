ODIN ?= odin
ODIN_FLAGS := -collection:barev=.
BUILD_DIR := build
CLI := $(BUILD_DIR)/barev-cli
BASIC_EXAMPLE := $(BUILD_DIR)/barev-basic-client

.PHONY: build check style vet run fmt clean release-check

build:
	mkdir -p $(BUILD_DIR)
	$(ODIN) build cmd/barev-cli $(ODIN_FLAGS) -out:$(CLI)

check:
	$(ODIN) check barev $(ODIN_FLAGS) -no-entry-point
	$(ODIN) check cmd/barev-cli $(ODIN_FLAGS)

style:
	$(ODIN) check barev $(ODIN_FLAGS) -no-entry-point -vet-style -vet-tabs -vet-semicolon -warnings-as-errors
	$(ODIN) check cmd/barev-cli $(ODIN_FLAGS) -vet-style -vet-tabs -vet-semicolon -warnings-as-errors

vet:
	$(ODIN) check barev $(ODIN_FLAGS) -no-entry-point -vet -warnings-as-errors
	$(ODIN) check cmd/barev-cli $(ODIN_FLAGS) -vet -warnings-as-errors

run:
	$(ODIN) run cmd/barev-cli $(ODIN_FLAGS)

fmt:
	command -v odinfmt >/dev/null
	odinfmt -w barev internal cmd

clean:
	rm -f $(CLI) $(BASIC_EXAMPLE)

release-check: style vet check build
