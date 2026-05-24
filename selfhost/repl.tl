;; repl.tl - First selfhost REPL command driver (#591).

;;

;; A `main`-bearing TypeLisp program that owns the REPL line loop and the

;; dot-command behavior of the Rust REPL skeleton's first slice (#458). It reads

;; lines with `read-stdin-line` until `.exit` or end of input, printing a flushed

;; `tl> ` prompt before each read so the prompt is visible in an interactive

;; session, and dispatches the dot commands:

;;

;;   - `.exit`            ends the session.

;;   - `.help`            prints the command help to stdout.

;;   - blank line         is skipped.

;;   - any other `.cmd`   reports an unknown command (to stderr).

;;   - any other input    reports that evaluation is not implemented (to stderr).

;;

;; Declaration persistence, expression evaluation, multiline input, and `.type`

;; are intentionally out of scope for this slice; they remain in the Rust REPL

;; (#461/#462) until ported separately. The Rust `typelisp repl` stays

;; authoritative until an explicit CLI handoff chooses to run this driver.

;;

;; `read-stdin-line` returns a line with its trailing newline stripped, and

;; `stdin-eof?` reports a sticky end-of-input flag set once a read passes the

;; end of stdin. The loop checks `stdin-eof?` before each read; a trailing

;; newline yields one final empty read, which is handled as a (skipped) blank

;; line.

(define (repl-banner) : String
  "TypeLisp REPL. Type .help for commands.\n")

(define (repl-help-text) : String
  "TypeLisp REPL commands:\n  .help  Show this help\n  .exit  Exit the REPL\n")

;; Print the prompt and flush stdout so it is visible before the blocking read.

(define (repl-prompt) : unit
  (begin
    (print-string "tl> ")
    (flush-stdout)))

;; `line` begins with `.` (a dot command). Only called on a non-empty line, so

;; the `string-ref` is in bounds even though `and` is not short-circuiting here.

(define (repl-dot-command? [line : String]) : bool
  (and (> (string-length line) 0) (= (string-ref line 0) #.')))

;; Handle one non-`.exit` input line, matching the Rust skeleton: blank lines are

;; skipped, `.help` prints help to stdout, any other dot command is unknown, and

;; any other input reports that evaluation is unimplemented (both to stderr).

(define (repl-handle-line [line : String]) : unit
  (if (string-eq line "")
    unit
    (if (string-eq line ".help")
      (print-string (repl-help-text))
      (if (repl-dot-command? line)
        (begin
          (print-error (string-append "Unknown REPL command: " line))
          (print-error "\nType .help for commands.\n"))
        (print-error
          "REPL evaluation is not implemented yet. Type .help for commands.\n")))))

;; The REPL loop: prompt, then read and dispatch until `.exit` or end of input.

(define (repl-loop) : unit
  (begin
    (repl-prompt)
    (if (stdin-eof?)
      unit
      (let ([line : String (read-stdin-line)])
        (if (string-eq line ".exit")
          unit
          (begin
            (repl-handle-line line)
            (repl-loop)))))))

(define (main) : i64
  (begin
    (print-string (repl-banner))
    (repl-loop)
    0))