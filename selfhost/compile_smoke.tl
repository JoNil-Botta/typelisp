;; compile_smoke.tl - Tiny file-to-file selfhost assembly emitter.

;;

;; This is not the full self-hosted compiler. It proves the current TypeLisp

;; selfhost slice can act like a compiler driver for its supported expression

;; subset: read source text from argv, emit deterministic `.s`, and write it.

(import "parse_core.tl")

(define (compile-smoke [input-path : String] [output-path : String]) : i64
  (let
    [source : String (read-file input-path)]
    (match (parse-program (lex source))
      [(OkParsedProgram program)
        (match program
          [(PProgram defs expr)
            (let
              [asm : String (emit-program-with-defs defs expr)]
              (begin
                (write-file output-path asm)
                0))])]
      [(ErrParsedProgram message)
        (begin
          (print-error message)
          1)])))

(define (main) : i64
  (if (< (arg-count) 3)
    (begin
      (print-error "compile-smoke: expected input and output paths")
      1)
    (compile-smoke (arg 1) (arg 2))))