# TLCI native boundary manifest

`main.tl` generates the checked
[`docs/tlci-native-boundary-manifest.tsv`](../../docs/tlci-native-boundary-manifest.tsv)
artifact. It derives callback identity, implementation binding, ABI argument
shape, validation evidence, capability, producer evidence, and stable source
site from the production callback constants and host registry. Callback names
are deliberately not repeated in another input manifest.

`admission-stages.tsv` is the declarative catalog for the non-callback loader
boundary: image admission, mapping, relocation, import binding, protection,
invocation, commit, and teardown. The generator verifies every catalog row's
stable source path and site token before copying it to the output.

Run the fail-closed drift checks with:

```sh
scripts/verify-tlci-boundary-manifest.sh
```

The verifier compares a fresh self-hosted result with the checked artifact and
perturbs ABI versions, declarations, registration rows, implementation
bindings, callback guards, capability assignment, producer imports, and stage
source links. It also rejects duplicate or incomplete rows, raw addresses, and
absolute host paths.
