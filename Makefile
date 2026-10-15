# Everything here runs offline except docs. No test in this repository touches
# a network.

BIN := bin/zc-workstation
# local builds carry the git version with a -dev suffix
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null | sed 's/^v//')-dev
LDFLAGS := -X main.version=$(VERSION)

.PHONY: all build run ui test test-unit race cover lint fmt install app app-icon app-test app-install evals docs docs-serve clean

all: lint test build

build:
	go build -ldflags "$(LDFLAGS)" -o $(BIN) ./cmd/zc-workstation

run: build
	$(BIN) $(ARGS)

ui: build
	$(BIN) ui

test:
	go test ./...

test-unit:
	go test -short ./...

race:
	go test -race ./...

# -coverpkg: most code is exercised through the CLI tests in cmd/, which
# per-package counting would not credit.
cover:
	go test -coverpkg=./... -coverprofile=coverage.out ./...
	go tool cover -func=coverage.out | tail -1

lint:
	@test -z "$$(gofmt -l .)" || { gofmt -l .; echo "not gofmt-clean"; exit 1; }
	go vet ./...
	@if command -v golangci-lint >/dev/null 2>&1; then golangci-lint run; else echo "golangci-lint not installed, go vet only"; fi

fmt:
	gofmt -w .

install: build
	mkdir -p $(HOME)/.local/bin
	cp $(BIN) $(HOME)/.local/bin/zc-workstation.new
	mv $(HOME)/.local/bin/zc-workstation.new $(HOME)/.local/bin/zc-workstation
	@echo "installed $(VERSION) to ~/.local/bin/zc-workstation (add to PATH if needed)"

# The menu bar app, apps/menubar: a SwiftPM package, macOS only.
APP := bin/ZCBar.app

app:
	VERSION=$(VERSION) apps/menubar/package.sh $(APP)

# Redraws the app's icons from apps/menubar/icon/mark.svg.
app-icon:
	swift apps/menubar/icon/make-icon.swift apps/menubar/Resources

app-test:
	swift test --package-path apps/menubar

# A Finder-opened app gets no shell environment, so the config the shell
# names is handed to it once; the app's Choose Config changes it later.
app-install: app
	rm -rf $(HOME)/Applications/ZCBar.app
	mkdir -p $(HOME)/Applications
	cp -R $(APP) $(HOME)/Applications/ZCBar.app
	@if [ -n "$$ZC_WORKSTATION_CONFIG" ]; then defaults write dev.zoolcoder.zcbar configPath "$$ZC_WORKSTATION_CONFIG"; fi
	@echo "installed ~/Applications/ZCBar.app; open it once, then tick Open at login"

evals: ## run the plugin eval suite (evals/), needs the claude CLI
	claude plugin eval . --no-publish --threshold 0.8

docs:
	[ -d node_modules ] || npm ci
	npm run docs

docs-serve: docs
	npx --yes http-server build/site -p 8080 -c-1

clean:
	rm -rf bin dist build coverage.out
