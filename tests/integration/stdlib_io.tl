;; stdlib_io.tl - integration smoke for stdlib/io.tl helpers (#702).

;; Exercises read-file-or (present + missing fallback), append-file

;; (read-modify-write), and file-nonempty? (present + missing) end-to-end,

;; returning 42 only when every helper behaves as expected. Scratch files live

;; under the gitignored target/ directory (the program runs with the repo root

;; as its working directory).

(import "stdlib/io.tl")

(define (main) : i64
  (begin
    (write-file "target/stdlib_io_smoke.txt" "alpha")
    (if (string-eq (read-file-or "target/stdlib_io_smoke.txt" "MISS") "alpha")
      (if (string-eq (read-file-or "target/stdlib_io_absent.txt" "MISS") "MISS")
        (begin
          (append-file "target/stdlib_io_smoke.txt" "-beta")
          (if (string-eq (read-file "target/stdlib_io_smoke.txt") "alpha-beta")
            (if (file-nonempty? "target/stdlib_io_smoke.txt")
              (if (file-nonempty? "target/stdlib_io_absent.txt")
                10
                42)
              20)
            30))
        40)
      50)))