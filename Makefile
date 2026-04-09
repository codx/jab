.PHONY: help build test check fix release clean fmt

# Default target
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'

build: ## Build jab (debug)
	zig build

test: ## Run all tests
	zig build test --summary all

check: build ## Run jab on its own source (dogfood)
	./zig-out/bin/jab test/fixtures/

fix: build ## Run jab fix on its own source (dogfood)
	./zig-out/bin/jab -f test/fixtures/

fmt: ## Format all Zig source with zig fmt
	zig fmt src/ build.zig

release: ## Build release binary (ReleaseSafe, stripped)
	zig build -Doptimize=ReleaseSafe
	@ls -lh zig-out/bin/jab
	@echo "Binary size: $$(du -h zig-out/bin/jab | cut -f1)"

release-all: ## Cross-compile for all targets
	@echo "Building x86_64-linux-musl..."
	zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
	@mkdir -p dist
	@cp zig-out/bin/jab dist/jab-linux-amd64
	@echo "Building aarch64-linux-musl..."
	zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
	@cp zig-out/bin/jab dist/jab-linux-arm64
	@echo "Building x86_64-macos..."
	zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
	@cp zig-out/bin/jab dist/jab-darwin-amd64
	@echo "Building aarch64-macos..."
	zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
	@cp zig-out/bin/jab dist/jab-darwin-arm64
	@echo "Building x86_64-windows..."
	zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
	@cp zig-out/bin/jab.exe dist/jab-windows-amd64.exe
	@echo ""
	@echo "All binaries:"
	@ls -lh dist/

bench: build ## Benchmark: time jab on test fixtures
	@echo "Timing 10 runs..."
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		/usr/bin/time -p ./zig-out/bin/jab test/fixtures/ 2>&1 | grep real; \
	done

baseline-shellcheck: ## Generate shellcheck baseline for bash fixtures
	@echo "Generating shellcheck baseline..."
	@for f in test/fixtures/bash/*.sh; do \
		echo "--- $$f ---"; \
		shellcheck -f json "$$f" 2>/dev/null || true; \
	done > test/fixtures/bash/shellcheck-baseline.json
	@echo "Written to test/fixtures/bash/shellcheck-baseline.json"

baseline-yamllint: ## Generate yamllint baseline for YAML fixtures
	@echo "Generating yamllint baseline..."
	@for f in test/fixtures/yaml/*.yaml test/fixtures/yaml/*.yml; do \
		echo "--- $$f ---"; \
		yamllint -f parsable "$$f" 2>/dev/null || true; \
	done > test/fixtures/yaml/yamllint-baseline.txt
	@echo "Written to test/fixtures/yaml/yamllint-baseline.txt"

baseline-terraform: ## Generate terraform fmt baseline for HCL fixtures
	@echo "Generating terraform fmt baseline..."
	@for f in test/fixtures/hcl/*.tf; do \
		echo "--- $$f ---"; \
		terraform fmt -check -diff "$$f" 2>/dev/null || true; \
	done > test/fixtures/hcl/terraform-baseline.txt
	@echo "Written to test/fixtures/hcl/terraform-baseline.txt"

baselines: baseline-shellcheck baseline-yamllint baseline-terraform ## Generate all baselines

install-hook: build ## Install jab as a git pre-commit hook
	@git_dir=$$(git rev-parse --git-dir 2>/dev/null) || { echo "Not a git repo"; exit 1; }; \
	mkdir -p "$$git_dir/hooks"; \
	printf '#!/bin/sh\nzig-out/bin/jab --staged\n' > "$$git_dir/hooks/pre-commit"; \
	chmod +x "$$git_dir/hooks/pre-commit"; \
	echo "Installed pre-commit hook"

checksums: release-all ## Generate SHA256 checksums for release binaries
	@cd dist && sha256sum jab-* > checksums.sha256 2>/dev/null || shasum -a 256 jab-* > checksums.sha256
	@echo "Written to dist/checksums.sha256"
	@cat dist/checksums.sha256

clean: ## Remove build artifacts
	rm -rf zig-out .zig-cache dist
