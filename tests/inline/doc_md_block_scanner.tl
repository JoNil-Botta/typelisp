;; doc_md_block_scanner.tl - Inline coverage for #1276's Markdown block scanner.
(import "../../selfhost/doc_md.tl")

(define (doc-md-assert-i64-eq
  [actual : i64]
  [expected : i64]
  [message : String]) : unit
  (if (= actual expected)
    unit
    (panic message)))

(test
  doc-md-block-scanner-smoke
  (doc-md-assert-i64-eq
    (compiler-doc-md-self-test)
    42
    "doc_md scanner and inline renderer smoke should pass"))