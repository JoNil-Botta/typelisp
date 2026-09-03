;; Borrowed process storage accepts only typed references with the declared
;; lifetime; a raw machine word cannot be injected through a public variant.
(import stdlib.process_borrowed)

(define (forge [text : (& text str)]) : (process_borrowed.ProcessBorrowedStringList
    text)
  (let
    [raw : u64 0]
    (process_borrowed.ProcessBorrowedStringCons
      (& raw)
      (box (process_borrowed.args-empty-like text)))))

(define (main) : i64
  0)