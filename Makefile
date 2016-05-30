PROJECT = brucke
PROJECT_DESCRIPTION = Inter-cluster bridge of kakfa topics
PROJECT_VERSION = 0.0.1

DEPS = brod

dep_brod_commit = 2.1.2

EUNIT_OPTS = verbose
ERLC_OPTS = -Werror +warn_unused_vars +warn_shadow_vars +warn_unused_import +warn_obsolete_guard +debug_info
CT_OPTS = -ct_use_short_names true

include erlang.mk

ERL_LIBS := $(ERL_LIBS):$(CURDIR)

