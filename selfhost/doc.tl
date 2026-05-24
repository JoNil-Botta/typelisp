;; doc.tl - Single-file self-hosted documentation generator driver (#389).
;;
;; Usage through the current compiler runner:
;;   typelisp run selfhost/doc.tl -- input.tl output.md

(import "doc_render.tl")

(define (doc-generate-file [input-path : String] [output-path : String]) : i64
  (let ([source : String (read-file input-path)])
    (let ([markdown : String (doc-render-markdown (doc-extract-source source))])
      (begin
        (write-file output-path markdown)
        0))))

(define (main) : i64
  (if (= (arg-count) 3)
      (doc-generate-file (arg 1) (arg 2))
      (begin
        (print-error "doc: expected input and output paths")
        1)))
