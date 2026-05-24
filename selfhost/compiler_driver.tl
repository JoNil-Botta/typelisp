;; compiler_driver.tl - File-to-file selfhost compiler driver (#448).

(import "compiler_driver_core.tl")

(define (main) : i64
  (if (< (arg-count) 3)
      (begin
        (print-error "compiler-driver: expected input and output paths")
        1)
      (compiler-driver-compile-file (arg 1) (arg 2))))
