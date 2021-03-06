 #
 # Accretio is an API, a sandbox and a runtime for social playbooks
 #
 # Copyright (C) 2015 William Le Ferrand
 #
 # This program is free software: you can redistribute it and/or modify
 # it under the terms of the GNU Affero General Public License as
 # published by the Free Software Foundation, either version 3 of the
 # License, or (at your option) any later version.
 #
 # This program is distributed in the hope that it will be useful,
 # but WITHOUT ANY WARRANTY; without even the implied warranty of
 # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 # GNU Affero General Public License for more details.
 #
 # You should have received a copy of the GNU Affero General Public License
 # along with this program.  If not, see <http://www.gnu.org/licenses/>.
 #

GETVERSION_BUILD=@cat _build/VERSION_NUM _build/VERSION | xargs echo | sed 's/ /_/'


NOW := $(shell date +"%c" | tr ' :' '__')

all: server client

clean:
	ocamlbuild -clean

client:
	ocamlbuild -use-menhir app/client/mu.js
	@$(GETVERSION_BUILD) | xargs -I '{}' cp _build/app/client/mu.js static/mu_'{}'.js

jsstatic:
	cat static/js-map.js static/js-autolink.js static/js-misc.js > static/js-static.js
	yuicompressor static/js-static.js -o static/js-static.min.js

server:
	ocamlbuild -use-menhir app/server/mu_server.cma

native:
	ocamlbuild -use-menhir app/server/mu_server_native.cmxs

all: client server

run:
	ocsigenserver -c resources/node.xml

run-native:
	ocsigenserver.opt -c resources/node-native.xml

run-prod:
	ocsigenserver -c resources/prod-nginx.xml

run-prod-native:
	ocsigenserver.opt -c resources/prod-nginx-native.xml

debug:
	ocsigenserver -c resources/node.xml -V


cleardb:
	rm -rf db/*
	rm -rf log/*

css:
	compass compile style
	@$(GETVERSION_BUILD) | xargs -I '{}' cp style/stylesheets/style.css static/style_'{}'.css

relink-css:
	@$(GETVERSION_BUILD) | xargs -I '{}' cp style/stylesheets/style.css static/style_'{}'.css

relink-js:
	@$(GETVERSION_BUILD) | xargs -I '{}' cp static/js-static.min.js static/js-static_'{}'.min.js

relink-manifest:
	@$(GETVERSION_BUILD) | xargs -I '{}' cp static/manifest.manifest static/manifest_'{}'.manifest

relink: relink-css relink-js relink-manifest

sphinx:
	searchd --console -c resources/sphinx.conf

dev: all css run

snapshot:
	mkdir -p db_snapshots
	mkdir -p db_snapshots/db_${NOW}
	cp -r db/* db_snapshots/db_${NOW}


rebuild: clean all relink

check:
	rm -f test_cron.byte && ocamlbuild test/test_cron.byte && ./test_cron.byte && rm -f test_cron.byte


learn:
	cd _build && camlp4o `ocamlfind query lwt.syntax`/lwt-syntax-options.cma  `ocamlfind query lwt.syntax`/lwt-syntax.cma  `ocamlfind query type_conv`/pa_type_conv.cma `ocamlfind query deriving`/pa_deriving_common.cma `ocamlfind query deriving-yojson`/syntax.cma`ocamlfind query ocamlgraph`/graph.cma library/syntax/pa_operators.cma ../playbooks/children_schoolbus.ml -printer o -o app/server/children_schoolbus.pp.ml

learn2:
	cd _build && camlp4o `ocamlfind query deriving`/pa_deriving_common.cma `ocamlfind query deriving`/pa_deriving_std.cma `ocamlfind query deriving-yojson`/syntax.cma ../playbooks/children_schoolbus.ml -printer o -o app/server/children_schoolbus.pp.ml

learn3:
	cd _build && camlp4o `ocamlfind query lwt.syntax`/lwt-syntax-options.cma  `ocamlfind query lwt.syntax`/lwt-syntax.cma  `ocamlfind query type_conv`/pa_type_conv.cma `ocamlfind query deriving`/pa_deriving_common.cma `ocamlfind query deriving`/pa_deriving_std.cma `ocamlfind query deriving-yojson`/syntax.cma  ../playbooks/children_schoolbus.ml -printer o -o app/server/children_schoolbus.pp.ml


dot:
	dot -Tpng ./_build/app/server/bakers.ml.dot -o bakers.png

neato:
	neato -Tpng -Gstart=rand ./_build/app/server/bakers.ml.dot -o bakers.png

dot_%:
	dot -Tpng _build/app/server/$@.dot -o$@.png

bakers:
	ocamlbuild -use-menhir app/server/bakers.cmo
