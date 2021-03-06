
DEV ?= --dev
PACKAGES:=$(patsubst %.opam,%,$(notdir $(shell find . -name *.opam -print)))

current_ocaml_version := $(shell ocamlc -version)
include scripts/version.sh

ifneq (${current_ocaml_version},${ocaml_version})
$(error Unexpected ocaml version (found: ${current_ocaml_version}, expected: ${ocaml_version}))
endif

all:
	@jbuilder build ${DEV} \
		src/bin_node/main.exe \
		src/bin_client/main_client.exe \
		src/bin_client/main_admin.exe \
		src/bin_signer/main_signer.exe \
		src/lib_protocol_compiler/main_native.exe \
		src/proto_alpha/bin_baker/main_baker_alpha.exe \
		src/proto_alpha/bin_endorser/main_endorser_alpha.exe \
		src/proto_alpha/bin_accuser/main_accuser_alpha.exe
	@cp _build/default/src/bin_node/main.exe tezos-node
	@cp _build/default/src/bin_client/main_client.exe tezos-client
	@cp _build/default/src/bin_client/main_admin.exe tezos-admin-client
	@cp _build/default/src/bin_signer/main_signer.exe tezos-signer
	@cp _build/default/src/lib_protocol_compiler/main_native.exe tezos-protocol-compiler
	@cp _build/default/src/proto_alpha/bin_baker/main_baker_alpha.exe tezos-alpha-baker
	@cp _build/default/src/proto_alpha/bin_endorser/main_endorser_alpha.exe tezos-alpha-endorser
	@cp _build/default/src/proto_alpha/bin_accuser/main_accuser_alpha.exe tezos-alpha-accuser

all.pkg:
	@jbuilder build ${DEV} \
	    $(patsubst %.opam,%.install, $(shell find . -name \*.opam -print))

$(addsuffix .pkg,${PACKAGES}): %.pkg:
	@jbuilder build ${DEV} \
	    $(patsubst %.opam,%.install, $(shell find . -name $*.opam -print))

$(addsuffix .test,${PACKAGES}): %.test:
	@jbuilder build ${DEV} \
	    @$(patsubst %/$*.opam,%,$(shell find -name $*.opam))/runtest

doc-html: all
	@jbuilder build @doc ${DEV}
	@./tezos-client -protocol ProtoALphaALph man -verbosity 3 -format html | sed "s/$HOME/\$HOME/g" > docs/api/tezos-client.html
	@./tezos-admin-client man -verbosity 3 -format html | sed "s/$HOME/\$HOME/g" > docs/api/tezos-admin-client.html
	@mkdir -p $$(pwd)/docs/_build/api/odoc
	@rm -rf $$(pwd)/docs/_build/api/odoc/*
	@cp -r $$(pwd)/_build/default/_doc/* $$(pwd)/docs/_build/api/odoc/
	@${MAKE} -C docs

build-test:
	@jbuilder build @buildtest ${DEV}

test:
	@jbuilder runtest ${DEV}
	@./scripts/check_opam_test.sh

test-indent:
	@jbuilder build @runtest_indent ${DEV}

fix-indent:
	@src/lib_stdlib/test-ocp-indent.sh fix

build-deps:
	@./scripts/install_build_deps.sh

docker-image:
	@./scripts/create_docker_image.sh

install:
	@jbuilder build @install
	@jbuilder install

uninstall:
	@jbuilder uninstall

clean:
	@-jbuilder clean
	@-rm -f \
		tezos-node \
		tezos-client \
		tezos-admin-client \
		tezos-protocol-compiler \
		tezos-alpha-baker \
		tezos-alpha-endorser \
		tezos-alpha-accuser
	@-${MAKE} -C docs clean

.PHONY: all test build-deps docker-image clean
