# Gem Grove browser build

The Web export of the demo game on the godot-cli site. It is made by
`WEB=1 site/demo/build.sh` on `main` and copied here, so the 39 MB of wasm
stays out of `main`'s history. The Pages workflow checks this branch out into
`site/demo/web` before building the site.
