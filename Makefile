PROJECT = brucke
PROJECT_DESCRIPTION = Inter-cluster bridge of kakfa topics
PROJECT_VERSION = $(shell cat VSN)

DEPS = lager brod yamerl graphiter cowboy jsone

dep_brod_commit = 2.3.1
dep_yamler = git https://github.com/yakaz/yamerl.git
dep_yamerl_commit = v0.3.2-1
dep_graphiter = git https://github.com/klarna/graphite-erlang.git
dep_graphiter_commit = 1.0.4
dep_cowboy = git https://github.com/ninenines/cowboy.git 2.0.0-pre.7
dep_jsone = git https://github.com/sile/jsone.git 1.4.3

TEST_DEPS = meck

EUNIT_OPTS = verbose
ERLC_OPTS = -Werror +warn_unused_vars +warn_shadow_vars +warn_unused_import +warn_obsolete_guard +debug_info
CT_OPTS = -ct_use_short_names true
COVER = true

rel:: rel/sys.config

rel/sys.config: | rel/sys.config.example
	cp $| $@

include erlang.mk

ERL_LIBS := $(ERL_LIBS):$(CURDIR)

MORE_ERLC_OPTS = +'{parse_transform, lager_transform}' -DAPPLICATION=brucke

ERLC_OPTS += $(MORE_ERLC_OPTS)
TEST_ERLC_OPTS += $(MORE_ERLC_OPTS)

tdir:
	mkdir -p test

t: tdir eunit
	./scripts/cover-summary.escript eunit.coverdata

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

