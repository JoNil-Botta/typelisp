(import stdlib.format_writer_core)

(define (main) : unit
  (ptr-write! format_writer_core.format-writer-registry-states 1))