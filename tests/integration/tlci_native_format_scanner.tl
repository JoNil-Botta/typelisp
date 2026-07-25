;; tlci_native_format_scanner.tl - drive the comptime format template scanner
;; through whichever macro route the compiler selects, so the embedded (native)
;; and comment-modified-root (interpreted) routes can be compared for
;; byte-identical assembly.
;;
;; `stdlib.io/format-with` guards the literal template and `stdlib.io/format-from`
;; walks it one byte at a time, re-invoking itself at the next offset. Every
;; piece of that walk is arithmetic on a comptime string index: a scanner that
;; mis-indexes by one, drops the byte after a `{{` escape, consumes the wrong
;; positional argument, or stops one byte early still compiles and still runs --
;; it just formats the wrong text. Nothing but a route differential catches
;; that, so the assertions compare exact strings rather than lengths, and the
;; templates cover an empty template, adjacent placeholders, a placeholder at
;; each end, both brace escapes, and a brace escape adjacent to a placeholder.
;; Refs #5701, #5596.
;; Exit code: 42
(import stdlib.format)
(import stdlib.io)
(import stdlib.string)

(define (scanner-checks-ok?) : bool
  (let
    [one : i64 1]
    [two : i64 2]
    [three : i64 3]
    [four : i64 4]
    [five : i64 5]
    [seven : i64 7]
    [eight : i64 8]
    [nine : i64 9]
    [empty-template : String (format.format "")]
    [no-holes : String (format.format "plain text")]
    [one-hole : String (format.format "n={}" seven)]
    [leading-hole : String (format.format "{} trails" one)]
    [adjacent-holes : String (format.format "{}{}" four five)]
    [three-holes : String (format.format "{}-{}-{}" one two three)]
    [open-escape : String (format.format "{{")]
    [close-escape : String (format.format "}}")]
    [both-escapes : String (format.format "{{{}}}" nine)]
    [escape-then-hole : String (format.format "{{{}" eight)]
    [mixed : String (format.format "{{{}}} and {} at {}" one two three)]
    [typed : String (format.format "{} {} {}" true 'z' "tail")]
    (and
      (string.eq empty-template "")
      (string.eq no-holes "plain text")
      (string.eq one-hole "n=7")
      (string.eq leading-hole "1 trails")
      (string.eq adjacent-holes "45")
      (string.eq three-holes "1-2-3")
      (string.eq open-escape "{")
      (string.eq close-escape "}")
      (string.eq both-escapes "{9}")
      (string.eq escape-then-hole "{8")
      (string.eq mixed "{1} and 2 at 3")
      (string.eq typed "true z tail"))))

;; The same scanner drives `println`/`print-format`, which reach it through
;; different wrapper macros; a wrapper that passed the wrong initial offset or
;; argument index would leave the checks above intact.
(define (print-checks-ok?) : bool
  (let
    [one : i64 1]
    [two : i64 2]
    (begin
      (io.println "scanner: {} {{}} {}" one two)
      (io.print-format "done\n")
      true)))

(define (main) : i64
  (if (and (scanner-checks-ok?) (print-checks-ok?))
    42
    1))