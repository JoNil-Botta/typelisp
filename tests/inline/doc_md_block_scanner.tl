;; doc_md_block_scanner.tl - Inline coverage for #1276's Markdown block scanner.
(import "stdlib/test.tl")

(import "../../selfhost/doc_md.tl")

(test
  doc-md-block-scanner-smoke
  (assert-i64-eq
    (compiler-doc-md-self-test)
    42
    "doc_md scanner and inline renderer smoke should pass"))