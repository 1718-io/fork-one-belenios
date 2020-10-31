#! /bin/sh

LIBDIR="/home/opam/.opam/default/lib/"
cp -R ${LIBDIR}astring \
${LIBDIR}atdgen \
${LIBDIR}atdgen-runtime \
${LIBDIR}base \
${LIBDIR}bigarray \
${LIBDIR}bigarray-compat \
${LIBDIR}biniou \
${LIBDIR}bytes \
${LIBDIR}calendar \
${LIBDIR}camomile \
${LIBDIR}cryptokit \
${LIBDIR}cstruct \
${LIBDIR}csv \
${LIBDIR}domain-name \
${LIBDIR}dynlink \
${LIBDIR}easy-format \
${LIBDIR}eliom \
${LIBDIR}fileutils \
${LIBDIR}findlib \
${LIBDIR}fmt \
${LIBDIR}gettext \
${LIBDIR}gettext-camomile \
${LIBDIR}hex \
${LIBDIR}ipaddr \
${LIBDIR}js_of_ocaml \
${LIBDIR}js_of_ocaml-ppx_deriving_json \
${LIBDIR}lwt \
${LIBDIR}lwt_log \
${LIBDIR}lwt_ppx \
${LIBDIR}lwt_react \
${LIBDIR}lwt_ssl \
${LIBDIR}macaddr \
${LIBDIR}mmap \
${LIBDIR}netstring \
${LIBDIR}netstring-pcre \
${LIBDIR}netsys \
${LIBDIR}num \
${LIBDIR}ocaml/stublibs \
${LIBDIR}ocaml/threads \
${LIBDIR}ocplib-endian \
${LIBDIR}ocsigenserver \
${LIBDIR}parsexp \
${LIBDIR}pcre \
${LIBDIR}pgocaml \
${LIBDIR}ppx_deriving \
${LIBDIR}ppx_sexp_conv \
${LIBDIR}re \
${LIBDIR}react \
${LIBDIR}reactiveData \
${LIBDIR}result \
${LIBDIR}rresult \
${LIBDIR}seq \
${LIBDIR}sexplib \
${LIBDIR}sexplib0 \
${LIBDIR}ssl \
${LIBDIR}stdlib-shims \
${LIBDIR}str \
${LIBDIR}stublibs \
${LIBDIR}threads \
${LIBDIR}tyxml \
${LIBDIR}uchar \
${LIBDIR}unix \
${LIBDIR}uuidm \
${LIBDIR}uutf \
${LIBDIR}xml-light \
${LIBDIR}yojson \
${LIBDIR}zarith \
${LIBDIR}findlib.conf \
/home/opam/deps

# Delete all .cmt and .cmti files to reduce file size
find /home/ -type f -name '*.cmti' -delete
find /home/ -type f -name '*.cmt' -delete