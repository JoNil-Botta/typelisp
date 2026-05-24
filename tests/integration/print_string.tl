;; print_string.tl — write a whole String's bytes to stdout via print-string.

;; `(print-string s)` / `(print-str s)` : (-> String unit) issues a single

;; write(1) syscall. The "\n" escape lexes to a real newline byte, so this

;; emits exactly "hello\nworld\n" to stdout and exits 0.

(define (main) : i64
  (begin
    (print-string "hello\n")
    (print-str "world\n")
    0))