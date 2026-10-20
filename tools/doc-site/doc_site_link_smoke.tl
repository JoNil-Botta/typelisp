(import doc_site_core as site)
(import doc_md)
(import stdlib.string)
(import stdlib.io)
(import stdlib.str_cat)

(defenum LinkCase
  (Case String String String))

(define (doc-site-link-smoke) : unit
  (let
    [sections (site.doc-site-typelisp-sections)]
    [root-url : String
      (str_cat.str-cat
        (site.doc-site-repo-tree-root)
        (site.doc-site-source-identity)
        "/")]
    [cases : (Array LinkCase 20)
      (array
        (Case
          "docs/guide.md"
          "compiler-invariants.md"
          "compiler-invariants.html")
        (Case "docs/guide.md" "../SPEC.md" "spec.html")
        (Case "docs/nested/guide.md" "../../README.md" "readme.html")
        (Case
          "docs/guide.md"
          "./../docs/./compiler-invariants.md#cli"
          "compiler-invariants.html#cli")
        (Case
          "docs/guide.md"
          "nested/../compiler-invariants.md#tl-CLI"
          "compiler-invariants.html#tl-CLI")
        (Case "README.md" "SPEC.md#syntax" "spec.html#syntax")
        (Case "README.md" "SPEC.md#" "spec.html#")
        (Case "docs/guide.md" "../stdlib/io.tl#L1" "stdlib-io.html#L1")
        (Case
          "docs/guide.md"
          "compiler-x64-executable-templates.md"
          (site.doc-site-repo-source-url
            "docs/compiler-x64-executable-templates.md"))
        (Case
          "docs/nested/guide.md"
          "../../src/TESTING.md#compiler-arena-ownership"
          (site.doc-site-repo-source-url
            "src/TESTING.md#compiler-arena-ownership"))
        (Case
          "docs/guide.md"
          "../scripts"
          (site.doc-site-repo-source-url "scripts"))
        (Case "docs/guide.md" ".." (string.copy (& root-url)))
        (Case "README.md" "." (string.copy (& root-url)))
        (Case
          "docs/guide.md"
          "missing.md#anchor"
          (site.doc-site-repo-source-url "docs/missing.md#anchor"))
        (Case "docs/guide.md" "#cli" "#cli")
        (Case "docs/guide.md" "" "")
        (Case
          "docs/guide.md"
          "SPEC.md#"
          (site.doc-site-repo-source-url "docs/SPEC.md#"))
        (Case
          "docs/guide.md"
          "https://example.com/a/../b#anchor"
          "https://example.com/a/../b#anchor")
        (Case "docs/guide.md" "//example.com/a#anchor" "//example.com/a#anchor")
        (Case "docs/guide.md" "mailto:a@example.com" "mailto:a@example.com"))]
    (for [case cases]
      (match case
        [(Case source target expected)
          (unless
            (string.eq
              (site.doc-site-rewrite-language-link-target
                (& sections)
                (& source)
                (string.copy (& target)))
              expected)
            (io.panic
              (str_cat.str-cat "doc-site link mismatch: " source " -> " target)))]))
    (let
      [html
        (doc_md.md-render-html
          "# CLI\n\n# CLI!\n\n# CLI-1\n\n# tl-CLI\n\n# foo\n\n# tl-foo\n\n# `x` & y\n")]
      (for [anchor
        (array
          "id=\"tl-CLI\""
          "id=\"cli\""
          "id=\"cli-1\""
          "id=\"cli-1-1\""
          "id=\"tl-cli\""
          "id=\"tl-foo-1\""
          "id=\"x--y\"")]
        (unless
          (string.contains (& html) (& anchor))
          (io.panic (str_cat.str-cat "doc-site heading alias missing: " anchor)))))))