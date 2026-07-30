;; stdlib_io.tl - integration smoke for stdlib/io.tl helpers (#702).
;; Exercises recoverable Result-style helpers plus read-file-or, append-file,
;; and file-nonempty? end-to-end, returning 42 only when
;; every helper behaves as expected. Scratch files live under the gitignored
;; target/ directory (the program runs with the repo root as its working
;; directory).
(import stdlib.string)
(import stdlib.byte_buf)
(import stdlib.io)

(define io-smoke-path : String
  "target/stdlib_io_smoke_long_path_copy_helper_payload_alpha_beta_gamma_delta.txt")
(define io-absent-path : String
  "target/stdlib_io_absent_long_path_copy_helper_payload_alpha_beta_gamma_delta.txt")
(define io-missing-parent-path : String
  "target/stdlib_io_missing_parent_long_path_copy_helper_payload/out.txt")
(define io-binary-path : String
  "target/stdlib_io_binary_round_trip.bin")

(define (read-result-score [result : ResultIoBytes]) : i64
  (match result
    [(OkIoBytes value)
      (if (string.eq (byte_buf.to-string value) "alpha")
        1
        100)]
    [(ErrIoBytes error)
      (if (io.error-not-found? error)
        2
        200)]))

(define (write-result-score [result : ResultIoUnit]) : i64
  (match result
    [(OkIoUnit) 3]
    [(ErrIoUnit error)
      (if (io.error-invalid-path? error)
        4
        5)]))

(define (bool-result-score [result : ResultIoBool]) : i64
  (match result
    [(OkIoBool exists)
      (if exists
        6
        7)]
    [(ErrIoBool _) 400]))

(define (test-try-read-file [path : String]) : ResultIoBytes
  (io.try-read-file (& path)))

(define (test-try-write-file [path : String] [contents : String]) : ResultIoUnit
  (io.try-write-file (& path) (byte_buf.str-as-bytes (& contents))))

(define (test-try-file-exists? [path : String]) : ResultIoBool
  (io.try-file-exists? (& path)))

(define (test-read-file-or [path : String] [fallback : String]) : String
  (byte_buf.to-string
    (io.read-file-or (& path) (byte_buf.from-string fallback))))

(define (test-append-file [path : String] [contents : String]) : unit
  (io.append-file (& path) (byte_buf.str-as-bytes (& contents))))

(define (test-file-nonempty? [path : String]) : bool
  (io.file-nonempty? (& path)))

(define (make-u8 [value : i64]) : u8
  (cast value : u8))

(define (binary-round-trip-ok?) : bool
  (let
    [payload : byte_buf.ByteBuf
      (byte_buf.push
        (byte_buf.push
          (byte_buf.push
            (byte_buf.push (byte_buf.new) (make-u8 65))
            (make-u8 0))
          (make-u8 128))
        (make-u8 255))]
    (begin
      (io.write-file io-binary-path (byte_buf.as-bytes (& payload)))
      (let
        [readback : byte_buf.ByteBuf (io.read-file io-binary-path)]
        (and
          (= (byte_buf.len readback) 4)
          (= (byte_buf.ref readback 0) (make-u8 65))
          (= (byte_buf.ref readback 1) (make-u8 0))
          (= (byte_buf.ref readback 2) (make-u8 128))
          (= (byte_buf.ref readback 3) (make-u8 255)))))))

(define (main) : i64
  (begin
    (test-try-write-file io-smoke-path "alpha")
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
      (string.eq (test-read-file-or io-smoke-path "MISS") "alpha")
      (return 50))
    (unless
      (string.eq (test-read-file-or io-absent-path "MISS") "MISS")
      (return 40))
    (test-append-file io-smoke-path "-beta")
    (unless
      (string.eq (byte_buf.to-string (io.read-file io-smoke-path)) "alpha-beta")
      (return 30))
    (unless (test-file-nonempty? io-smoke-path) (return 20))
    (when (test-file-nonempty? io-absent-path) (return 10))
    (unless (binary-round-trip-ok?) (return 9))
    42))