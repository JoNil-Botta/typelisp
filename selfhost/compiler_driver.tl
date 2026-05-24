;; compiler_driver.tl - File-to-file selfhost compiler driver (#448).

(import "compiler_backend.tl")

(define (compiler-driver-compile-file [input-path : String] [output-path : String]) : i64
  (let ([source : String (read-file input-path)])
    (match (compiler-backend-emit-source source)
      [(OkCompilerBackend asm)
       (begin
         (write-file output-path asm)
         0)]
      [(ErrCompilerBackend message)
       (begin
         (print-error message)
         1)])))

(define (main) : i64
  (if (< (arg-count) 3)
      (begin
        (print-error "compiler-driver: expected input and output paths")
        1)
      (compiler-driver-compile-file (arg 1) (arg 2))))
