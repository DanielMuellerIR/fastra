# JavaScript license sources

The full license files under `js/` come from the exact npm archives named in
`js-licenses.lock.json`. Each archive is verified against its pinned integrity
hash before any file is copied. No package scripts are executed.

The dependency set follows the runtime graph in the Mermaid 11.16.0 release
[pnpm lock](https://github.com/mermaid-js/mermaid/blob/mermaid%4011.16.0/pnpm-lock.yaml),
including the parser's bundled Chevrotain/Langium code. It deliberately includes
type/build dependencies reachable from those declared runtime dependencies.
The standalone KaTeX 0.17.0 and highlight.js 11.11.1 archives and the explicit
versions named in the bundle notices are included as well. This yields a
conservative superset rather than dropping notices through tree-shaking guesses.

Turndown 7.2.0 adds its complete MIT license. The embedded asset is byte-identical
to `package/dist/turndown.js` from the integrity-pinned npm archive. Its browser
build excludes `@mixmark-io/domino`, as declared by the upstream browser mapping;
that Node-only dependency is not distributed in the embedded browser asset.

The original vendor license files and every preserved `/*!` copyright/license
block from the actual embedded assets are added by `stage.py`. In particular,
the complete DOMPurify Apache-2.0/MPL-2.0 license and the bundled MIT/BSD notices
remain accessible as text files. `js-assets.json` binds this reviewed inventory
to the actual asset bytes. Changed JavaScript assets require renewed review.

To reproduce the full texts with Python's standard library:

```sh
python3 tools/linux-package/collect-js-licenses.py \
  --lock tools/linux-package/js-licenses.lock.json \
  --output /tmp/new-fastra-js-licenses --cache /tmp/fastra-npm-license-cache
```

Download caches and source archives stay outside the repository. `manifest.json`
records every copied license file's SHA256 and the lock file SHA256.
