;; format_cli_core.tl - Self-hosted `fmt` command logic (#522).
;;
;; The formatter CLI logic, factored out of `format.tl` so both the standalone
;; `format.tl` driver and the unified `cli.tl` dispatcher can run the `fmt`
;; command without duplicating a `main`.
(import "../stdlib/io.tl")

(import "format_rules.tl")

(define (fmt-format-file [check : bool] [path : String]) : i64
  (let
    [source : String (read-file path)]
    [formatted : String (format-rules-render-source-width source 80)]
    (if check
      (if (string-eq source formatted)
        0
        (begin
          (print-error
            (string-append "fmt: would reformat " (string-append path "\n")))
          1))
      (if (string-eq source formatted)
        0
        (begin
          (write-file path formatted)
          0)))))

(define (fmt-files [check : bool] [index : i64] [count : i64] [status : i64]) : i64
  (if (< index count)
    (let
      [file-status : i64 (fmt-format-file check (arg index))]
      (fmt-files
        check
        (+ index 1)
        count
        (if (= status 0)
          file-status
          status)))
    status))

;; Run the `fmt` command over arguments starting at `start` (the index of the
;; first argument after any subcommand name); `count` is `(arg-count)`.
(define (fmt-run-from [start : i64] [count : i64]) : i64
  (if (< count (+ start 1))
    (begin
      (print-error "fmt: expected one or more input paths\n")
      1)
    (if (string-eq (arg start) "--check")
      (if (< count (+ start 2))
        (begin
          (print-error "fmt: expected one or more input paths\n")
          1)
        (fmt-files true (+ start 1) count 0))
      (fmt-files false start count 0))))