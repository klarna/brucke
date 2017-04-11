PROJECT = brucke
PROJECT_DESCRIPTION = Inter-cluster bridge of kafka topics
PROJECT_VERSION = $(shell cat VSN)

DEPS = lager brod yamerl graphiter cowboy jsone

dep_lager = hex 3.2.4
dep_brod = hex 2.3.5
dep_yamerl = hex 0.4.0
dep_graphiter = hex 1.0.5
dep_jsone = hex 1.4.3
dep_cowboy = hex 1.1.2

TEST_DEPS = meck

EUNIT_OPTS = verbose
ERLC_OPTS = -Werror +warn_unused_vars +warn_shadow_vars +warn_unused_import +warn_obsolete_guard +debug_info
CT_OPTS = -ct_use_short_names true
COVER = true

include erlang.mk

rel:: rel/sys.config

rel/sys.config: | rel/sys.config.example
	cp $| $@

ERL_LIBS := $(ERL_LIBS):$(CURDIR)

MORE_ERLC_OPTS = +'{parse_transform, lager_transform}'

ERLC_OPTS += $(MORE_ERLC_OPTS)
TEST_ERLC_OPTS += $(MORE_ERLC_OPTS)

t: eunit ct
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
	$(verbose) rebar3 hex publish

