;; format.tl - Single-file self-hosted source formatter driver (#328).
;;
;; Reads a TypeLisp source file, reformats it with the self-hosted formatter
;; rules (format_rules.tl), and writes the formatted result to an output file.
;; The formatter renders at the default width (80 columns) and preserves
;; comments and delimiter shape via the comment-preserving CST.
;;
;; Usage through the current compiler runner:
;;   typelisp run selfhost/format.tl -- input.tl output.tl

(import "format_rules.tl")

(define (format-file [input-path : String] [output-path : String]) : i64
  (let ([source : String (read-file input-path)])
    (let ([formatted : String (format-rules-render-source source)])
      (begin
        (write-file output-path formatted)
        0))))

(define (main) : i64
  (if (= (arg-count) 3)
      (format-file (arg 1) (arg 2))
      (begin
        (print-error "format: expected input and output paths")
        1)))
