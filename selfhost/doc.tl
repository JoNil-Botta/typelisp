;; doc.tl - Self-hosted documentation generator driver (#389, #391).
;;
;; Usage through the current compiler runner:
;;   typelisp run selfhost/doc.tl -- input.tl output.md
;;   typelisp run selfhost/doc.tl -- entry.tl imported.tl output.md

(import "doc_render.tl")

(define (doc-generate-file [input-path : String] [output-path : String]) : i64
  (let ([source : String (read-file input-path)])
    (let ([markdown : String (doc-render-markdown (doc-extract-source source))])
      (begin
        (write-file output-path markdown)
        0))))

(define (doc-read-modules [idx : i64] [end : i64]) : DocModuleList
  (if (>= idx end)
      DocModuleNil
      (DocModuleCons
        (DocModule (arg idx) (doc-extract-file (arg idx)))
        (doc-read-modules (+ idx 1) end))))

(define (doc-generate-module-graph [output-path : String]) : i64
  (let ([modules : DocModuleList (doc-read-modules 1 (- (arg-count) 1))])
    (begin
      (write-file output-path (doc-render-module-graph-markdown modules))
      0)))

(define (main) : i64
  (if (= (arg-count) 3)
      (doc-generate-file (arg 1) (arg 2))
      (if (> (arg-count) 3)
          (doc-generate-module-graph (arg (- (arg-count) 1)))
          (begin
            (print-error "doc: expected input and output paths")
            1))))
