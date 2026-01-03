.PHONY: help
help: ## Show this help message
	@echo "Usage: make <target>"
	@echo "Targets:"
	@echo "  help - Show this help message"
	@echo "  build - Build rule-set"
	@echo "  fmt - Format code"
	@echo "  fetch - Fetch upstream sources"
	@echo "  normalize - Normalize rules"
	@echo "  compile - Compile rule-set"
	@echo "  publish - Prepare publish"
	@echo "  release - Publish to release branch"
	@echo "  clean - Clean build and publish"

.PHONY: build
build: ## Build rule-set
	make fetch
	make normalize
	make compile
	make publish

.PHONY: fmt
fmt: ## Format code
	find . -name "*.sh" -exec shfmt -i 2 -ci -w {} \;
	prettier --write .

.PHONY: fetch
fetch: ## Fetch upstream sources
	bash scripts/fetch.sh

.PHONY: normalize
normalize: ## Normalize rules
	bash scripts/normalize.sh

.PHONY: compile
compile: ## Compile rule-set
	bash scripts/compile.sh

.PHONY: publish
publish: ## Prepare publish
	bash scripts/publish.sh

.PHONY: release
release: ## Publish to release branch
	bash scripts/release.sh

.PHONY: clean
clean: ## Clean build and publish
	rm -rf source/upstream build publish 
