;; doc.tl - Self-hosted documentation generator driver (#389, #391).
;;
;; Usage through the current compiler runner:
;;   typelisp run selfhost/doc.tl -- input.tl output.md
;;   typelisp run selfhost/doc.tl -- entry.tl imported.tl output.md
;;   typelisp run selfhost/doc.tl -- --html input.tl output.html
;;   typelisp run selfhost/doc.tl -- --html entry.tl imported.tl output.html
;;   typelisp run selfhost/doc.tl -- --test input.tl
(import "doc_render.tl")

(import "doc_html.tl")

(import "doc_test.tl")

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

(define (doc-generate-html-file [input-path : String] [output-path : String]) : i64
  (let ([source : String (read-file input-path)])
    (let ([html : String (doc-html-render-source input-path source)])
      (begin
        (write-file output-path html)
        0))))

(define (doc-generate-html-module-graph [output-path : String]) : i64
  (let ([modules : DocModuleList (doc-read-modules 2 (- (arg-count) 1))])
    (begin
      (write-file output-path (doc-html-render-module-graph modules))
      0)))

(define (doc-test-file
  [input-path : String]
  [stdlib-roots : CompilerLoadRootList]) : i64
  (let ([report : DocTestRunReport
    (doc-test-run-file-with-roots input-path stdlib-roots)])
    (begin
      (if (doc-test-run-report-ok? report)
        (print-string (string-append (doc-test-run-report-render report) "\n"))
        (print-error (doc-test-run-report-render report)))
      (doc-test-run-report-status report))))

(define (doc-stdlib-roots [idx : i64]) : CompilerLoadRootList
  (if (>= idx (arg-count))
    CompilerLoadRootNil
    (if (string-eq (arg idx) "--stdlib-root")
      (if (< (+ idx 1) (arg-count))
        (CompilerLoadRootCons (arg (+ idx 1)) (doc-stdlib-roots (+ idx 2)))
        CompilerLoadRootNil)
      (doc-stdlib-roots (+ idx 1)))))

(define (doc-invalid-args) : i64
  (begin
    (print-error "doc: expected input and output paths")
    1))

(define (doc-invalid-test-args) : i64
  (begin
    (print-error "doc: expected --test input path")
    1))

(define (doc-invalid-html-args) : i64
  (begin
    (print-error "doc: expected --html input and output paths")
    1))

(define (main) : i64
  (if (< (arg-count) 2)
    (doc-invalid-args)
    (if (or (string-eq (arg 1) "--test") (string-eq (arg 1) "test"))
      (if (>= (arg-count) 3)
        (doc-test-file (arg 2) (doc-stdlib-roots 3))
        (doc-invalid-test-args))
      (if (or (string-eq (arg 1) "--html") (string-eq (arg 1) "html"))
        (if (= (arg-count) 4)
          (doc-generate-html-file (arg 2) (arg 3))
          (if (> (arg-count) 4)
            (doc-generate-html-module-graph (arg (- (arg-count) 1)))
            (doc-invalid-html-args)))
        (if (= (arg-count) 3)
          (doc-generate-file (arg 1) (arg 2))
          (if (> (arg-count) 3)
            (doc-generate-module-graph (arg (- (arg-count) 1)))
            (doc-invalid-args)))))))