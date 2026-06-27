;; Regression for #3446: importing stdlib.process_borrowed must preserve the
;; inline payload layout for both its borrowed enum and the owned process enum it
;; returns through stdlib.process.
(import stdlib.process)
(import stdlib.process_borrowed)
(import stdlib.string)
(import stdlib.test)

(define (process-borrowed-imported-layout-score [text : String]) : i64
  (let
    [borrowed : (process_borrowed.ProcessBorrowedMaybeString text)
      (process_borrowed.process-borrowed-some-string (& text))]
    [owned : process.ProcessMaybeString
      (process_borrowed.process-borrowed-maybe-owned borrowed)]
    (+
      (match borrowed
        [(process_borrowed.ProcessBorrowedNoString) 0]
        [(process_borrowed.ProcessBorrowedSomeString view)
          (string.string-length view)])
      (match owned
        [(process.ProcessNoString) 0]
        [(process.ProcessSomeString value) (string.string-length value)]))))

(test
  process-borrowed-imported-layout
  (test.assert-i64-eq
    (process-borrowed-imported-layout-score "pipe")
    8
    "imported process_borrowed/process enum payload layouts should survive lowering"))