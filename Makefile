PROJECT = brucke
PROJECT_DESCRIPTION = Inter-cluster bridge of kafka topics
PROJECT_VERSION = $(shell cat VSN)

all: compile

rebar ?= $(shell which rebar3)
rebar_cmd = $(rebar) $(profile:%=as %)

compile:
	@$(rebar_cmd) compile

xref:
	@$(rebar_cmd) xref

clean:
	@$(rebar_cmd) clean

eunit:
	@$(rebar_cmd) eunit -v

ct:
	@$(rebar_cmd) ct

edoc: profile=edown
edoc:
	@$(rebar_cmd) edoc

shell:
	-@$(rebar_cmd) shell

dialyze: compile
	@$(rebar_cmd) dialyzer

cover:
	@$(rebar_cmd) cover -v

t: eunit ct cover
	./scripts/cover-summary.escript eunit.coverdata ct.coverdata

test-env:
	./scripts/start-test-brokers.sh

TOPDIR = /tmp/brucke-rpm
PWD = $(shell pwd)

rpm: all
	@rpmbuild -v -bb \
			--define "_sourcedir $(PWD)" \
			--define "_builddir $(PWD)" \
			--define "_rpmdir $(PWD)" \
			--define "_topdir $(TOPDIR)" \
			--define "_name $(PROJECT)" \
			--define "_description $(PROJECT_DESCRIPTION)" \
			--define "_version $(PROJECT_VERSION)" \
			rpm/brucke.spec

vsn-check:
	$(verbose) ./scripts/vsn-check.sh $(PROJECT_VERSION)

hex-publish: distclean
	$(rebar) hex publish

