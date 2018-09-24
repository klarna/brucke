PROJECT = brucke
PROJECT_DESCRIPTION = Inter-cluster bridge of kafka topics
PROJECT_VERSION = $(shell cat VSN)

all: compile

rebar ?= $(shell which rebar3)
rebar_cmd = $(rebar) $(profile:%=as %)

.PHONY: compile
compile:
	@$(rebar_cmd) compile

.PHONY: xref
xref:
	@$(rebar_cmd) xref

.PHONY: clean
clean:
	@$(rebar_cmd) clean

.PHONY: distclean
distclean:
	@$(rebar_cmd) clean
	@rm -rf _build

.PHONY: eunit
eunit:
	@$(rebar_cmd) eunit -v

.PHONY: ct
ct:
	@$(rebar_cmd) ct

.PHONY: edoc
edoc: profile=edown
edoc:
	@$(rebar_cmd) edoc

.PHONY: shell
shell: profile=dev
shell:
	@$(rebar_cmd) shell --apps brod

.PHONY: dialyzer
dialyzer: compile
	@$(rebar_cmd) dialyzer

.PHONY: cover
cover:
	@$(rebar_cmd) cover -v

.PHONY: t
t: eunit ct cover

.PHONY: test-env
test-env:
	./scripts/start-test-brokers.sh

.PHONY: rel
rel: profile=prod
rel: all
	@$(rebar_cmd) release

.PHONY: run
run: profile=dev
run:
	@$(rebar_cmd) release
	@_build/dev/rel/brucke/bin/brucke console

TOPDIR = /tmp/brucke-rpm
PWD = $(shell pwd)

.PHONY: rpm
rpm: profile=prod
rpm: rel
	@rpmbuild -v -bb \
			--define "_sourcedir $(PWD)" \
			--define "_builddir $(PWD)" \
			--define "_rpmdir $(PWD)" \
			--define "_topdir $(TOPDIR)" \
			--define "_name $(PROJECT)" \
			--define "_description $(PROJECT_DESCRIPTION)" \
			--define "_version $(PROJECT_VERSION)" \
			rpm/brucke.spec

.PHONY: vsn-check
vsn-check:
	@./scripts/vsn-check.sh $(PROJECT_VERSION)

.PHONY: hex-publish
hex-publish: distclean
	@$(rebar_cmd) hex publish

.PHONY: coveralls
coveralls:
	@$(rebar_cmd) coveralls send
