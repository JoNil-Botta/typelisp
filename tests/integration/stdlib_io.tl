;; stdlib_io.tl - integration smoke for stdlib/io.tl helpers (#702).
;; Exercises recoverable Result-style helpers plus read-file-or, append-file,
;; and file-nonempty? end-to-end, returning 42 only when
;; every helper behaves as expected. Scratch files live under the gitignored
;; target/ directory (the program runs with the repo root as its working
;; directory).
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

(define (main) : i64
  (begin
    (write-file io-smoke-path "alpha")
    (if (= (read-result-score (try-read-file io-smoke-path)) 1)
      (if (= (read-result-score (try-read-file io-absent-path)) 2)
        (if (= (write-result-score (try-write-file "" "bad")) 4)
          (if (=
            (write-result-score (try-write-file io-missing-parent-path "bad"))
            5)
            (if (= (bool-result-score (try-file-exists? io-smoke-path)) 6)
              (if (= (bool-result-score (try-file-exists? io-absent-path)) 7)
                (if (string-eq (read-file-or io-smoke-path "MISS") "alpha")
                  (if (string-eq (read-file-or io-absent-path "MISS") "MISS")
                    (begin
                      (append-file io-smoke-path "-beta")
                      (if (string-eq (read-file io-smoke-path) "alpha-beta")
                        (if (file-nonempty? io-smoke-path)
                          (if (file-nonempty? io-absent-path)
                            10
                            42)
                          20)
                        30))
                    40)
                  50)
                55)
              56)
            57)
          60)
        70)
      80)))