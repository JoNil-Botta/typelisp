(import stdlib.format)
(import stdlib.io)

(define (main) : i64
  (begin
    ;; stdout wrappers and direct String formatting share the same precision
    ;; path; stderr consumes that returned String unchanged.
    (io.print-format "{:.3}/" "abcdef")
    (io.println "{:>5.2}" true)
    (io.print-error (format.format "{:.2}" "error"))
    (io.print-format "{:.2}/" (cast 1.25 : f64))
    (io.println "{:08.2}" (cast -0.0 : f32))
    (io.print-error (format.format "/{:.1}" (cast 1.25 : f32)))
    42))