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
      (process_borrowed.some-string (& text))]
    [owned : process.ProcessMaybeString (process_borrowed.maybe-owned borrowed)]
    (+
      (match borrowed
        [(process_borrowed.ProcessBorrowedNoString) 0]
        [(process_borrowed.ProcessBorrowedSomeString view)
          (string.string-length view)])
      (match owned
        [(process.ProcessNoString) 0]
        [(process.ProcessSomeString value) (string.string-length value)]))))

(define (process-borrowed-imported-dense-score [text : String]) : i64
  (let
    [empty-argv : (process_borrowed.ProcessBorrowedStringList text)
      (process_borrowed.args-empty-like (& text))]
    [empty-env : (process_borrowed.ProcessBorrowedEnvList text)
      (process_borrowed.env-empty-like (& text))]
    [argv : (process_borrowed.ProcessBorrowedStringList text)
      (process_borrowed.args-single (& text))]
    [env : (process_borrowed.ProcessBorrowedEnvList text)
      (process_borrowed.env-single (& text) (& text))]
    [owned-argv : process.ProcessStringList (process_borrowed.args-owned argv)]
    [owned-env : process.ProcessEnvList (process_borrowed.env-owned env)]
    (if (and
      (= (process_borrowed.args-count empty-argv) 0)
      (= (process_borrowed.env-count empty-env) 0)
      (= (process_borrowed.args-count argv) 1)
      (= (process_borrowed.env-count env) 1)
      (= (process.args-count owned-argv) 1)
      (= (process.env-count owned-env) 1)
      (string.eq (process_borrowed.args-ref argv 0) (& text))
      (string.eq (process_borrowed.env-name-ref env 0) (& text))
      (string.eq (process_borrowed.env-value-ref env 0) (& text)))
      42
      1)))

(test
  process-borrowed-imported-layout
  (test.assert-i64-eq
    (process-borrowed-imported-layout-score "pipe")
    8
    "imported process_borrowed/process enum payload layouts should survive lowering"))

(test
  process-borrowed-imported-dense-layout
  (test.assert-i64-eq
    (process-borrowed-imported-dense-score "pipe")
    42
    "imported lifetime-parameterized dense process fields should preserve layout"))