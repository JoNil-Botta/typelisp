;; stdlib_io.tl - integration smoke for stdlib/io.tl helpers (#702).
;; Exercises recoverable Result-style helpers plus read-file-or, append-file,
;; and file-nonempty? end-to-end, returning 42 only when
;; every helper behaves as expected. Scratch files live under the gitignored
;; target/ directory (the program runs with the repo root as its working
;; directory).
(import "stdlib/string.tl")
(import "stdlib/io.tl")

(define io-smoke-path : String
  "target/stdlib_io_smoke_long_path_copy_helper_payload_alpha_beta_gamma_delta.txt")
(define io-absent-path : String
  "target/stdlib_io_absent_long_path_copy_helper_payload_alpha_beta_gamma_delta.txt")
(define io-missing-parent-path : String
  "target/stdlib_io_missing_parent_long_path_copy_helper_payload/out.txt")

(define (read-result-score [result : ResultIoString]) : i64
  (match result
    [(OkIoString value)
      (if (string-eq value "alpha")
        1
        100)]
    [(ErrIoString error)
      (if (io-error-not-found? error)
        2
        200)]))

(define (write-result-score [result : ResultIoUnit]) : i64
  (match result
    [(OkIoUnit) 3]
    [(ErrIoUnit error)
      (if (io-error-invalid-path? error)
        4
        5)]))

(define (bool-result-score [result : ResultIoBool]) : i64
  (match result
    [(OkIoBool exists)
      (if exists
        6
        7)]
    [(ErrIoBool _) 400]))

(define (test-try-read-file [path : String]) : ResultIoString
  (try-read-file (& path)))

(define (test-try-write-file [path : String] [contents : String]) : ResultIoUnit
  (try-write-file (& path) (& contents)))

(define (test-try-file-exists? [path : String]) : ResultIoBool
  (try-file-exists? (& path)))

(define (test-read-file-or [path : String] [fallback : String]) : String
  (read-file-or (& path) fallback))

(define (test-append-file [path : String] [contents : String]) : unit
  (append-file (& path) (& contents)))

(define (test-file-nonempty? [path : String]) : bool
  (file-nonempty? (& path)))

(define (main) : i64
  (begin
    (write-file io-smoke-path "alpha")
    (unless
      (= (read-result-score (test-try-read-file io-smoke-path)) 1)
      (return 80))
    (unless
      (= (read-result-score (test-try-read-file io-absent-path)) 2)
      (return 70))
    (unless
      (= (write-result-score (test-try-write-file "" "bad")) 4)
      (return 60))
    (unless
      (=
        (write-result-score (test-try-write-file io-missing-parent-path "bad"))
        5)
      (return 57))
    (unless
      (= (bool-result-score (test-try-file-exists? io-smoke-path)) 6)
      (return 56))
    (unless
      (= (bool-result-score (test-try-file-exists? io-absent-path)) 7)
      (return 55))
    (unless
      (string-eq (test-read-file-or io-smoke-path "MISS") "alpha")
      (return 50))
    (unless
      (string-eq (test-read-file-or io-absent-path "MISS") "MISS")
      (return 40))
    (test-append-file io-smoke-path "-beta")
    (unless (string-eq (read-file io-smoke-path) "alpha-beta") (return 30))
    (unless (test-file-nonempty? io-smoke-path) (return 20))
    (when (test-file-nonempty? io-absent-path) (return 10))
    42))