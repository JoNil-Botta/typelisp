;; format.tl - Self-hosted formatter CLI driver (#522).

;;

;; Usage through the Rust CLI:

;;   typelisp fmt [--check] input.tl...

(import "format_rules.tl")

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let ([source : String (read-file path)])
    (let ([formatted : String (format-rules-render-source-width source 80)])
      (if check
        (if (string-eq source formatted)
          0
          (begin
            (print-error
              (string-append "fmt: would reformat " (string-append path "\n")))
            1))
        (begin
          (write-file path formatted)
          0)))))

(define (fmt-files [check : bool] [index : i64] [count : i64] [status : i64]) : i64
  (if (< index count)
    (let ([file-status : i64 (fmt-format-file check (arg index))])
      (fmt-files
        check
        (+ index 1)
        count
        (if (= status 0)
          file-status
          status)))
    status))

(define (main) : i64
  (if (< (arg-count) 2)
    (begin
      (print-error "fmt: expected one or more input paths\n")
      1)
    (if (string-eq (arg 1) "--check")
      (if (< (arg-count) 3)
        (begin
          (print-error "fmt: expected one or more input paths\n")
          1)
        (fmt-files true 2 (arg-count) 0))
      (fmt-files false 1 (arg-count) 0))))