;; tlci_native_format_scanner.tl - drive the comptime format template scanner
;; through whichever macro route the compiler selects, so the embedded (native)
;; and comment-modified-root (interpreted) routes can be compared for
;; byte-identical assembly.
;;
;; `stdlib.format/format` guards the literal template, parses a dense plan, and
;; expands that plan through generated bindings. Every piece of the parse is
;; arithmetic on a comptime string index: a scanner that
;; mis-indexes by one, drops the byte after a `{{` escape, consumes the wrong
;; positional/named argument, loses call-site capture, or stops one byte early
;; still compiles and still runs -- it just formats the wrong text. Nothing but
;; a route differential catches that, so the assertions compare exact strings.
;; Refs #5701, #5596.
;; Exit code: 42
(import stdlib.format)
(import stdlib.io)
(import stdlib.string)

(defstruct ScannerEvalState
  (value i64))

(define (scanner-counted [state : (&mut state ScannerEvalState)] [digit : i64]) : i64
  (begin
    (set! state.value (+ (* state.value 10) digit))
    digit))

(define (scanner-checks-ok?) : bool
  (let
    [state : ScannerEvalState (ScannerEvalState 0)]
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
    [indexed : String (format.format "{2}/{0}/{1}/{2}" one two three)]
    [mixed-selection : String (format.format "{1} {} {0} {}" one two)]
    [named : String
      (format.format
        "{left}:{right}:{left}"
        (format.named left "L")
        (format.named right "R"))]
    [capture : String "captured"]
    [captured : String
      (if (string.eq capture "captured")
        (format.format "{capture}:{seven   }")
        "wrong")]
    [ordered : String
      (format.format
        "{2}:{0}:{1}:{2}"
        (scanner-counted (&mut state) 1)
        (scanner-counted (&mut state) 2)
        (scanner-counted (&mut state) 3))]
    [aligned : String (format.format "{:-<5}|{:^5}|{:>5}" "a" "b" "c")]
    [integer-exponent : String (format.format "{:+010.2E}" (cast 1250 : i64))]
    [dynamic-width : String
      (format.format
        "{0:1$}:{2:width$}"
        "a"
        (cast 4 : i64)
        "b"
        (format.named width (cast 3 : i64)))]
    [inline-precision : String (format.format "{:.3}" seven)]
    [dollar-precision : String (format.format "{0:.1$}:{1}" seven two)]
    [star-precision : String (format.format "{:.*}:{0}" two seven)]
    [named-precision : String
      (format.format
        "{value:.precision$}"
        (format.named value seven)
        (format.named precision two))]
    [text-inline-precision : String (format.format "{:.3}" "seven")]
    [text-dollar-precision : String (format.format "{0:.1$}:{1}" "seven" two)]
    [text-star-precision : String (format.format "{:.*}" two "seven")]
    [bool-precision : String (format.format "{:.3}" true)]
    [char-zero-precision : String (format.format "{:.0}" 'x')]
    [integer-radix : String (format.format "{:+#010X}" (cast -1 : i8))]
    [null-pointer : (Ptr i64) (ptr-null : (Ptr i64))]
    [pointer-text : String
      (unsafe
        (format.format "{:p}" null-pointer))]
    [pointer-alternate : String
      (unsafe
        (format.format "{:#p}" null-pointer))]
    [rust-counter-one : String
      (format.format "Hello {} is {:.*}" "world" two seven)]
    [rust-counter-two : String
      (format.format "Hello {1} is {2:.*}" two "world" seven)]
    [rust-counter-three : String
      (format.format "Hello {} is {2:.*}" "world" two seven)]
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
      (string.eq typed "true z tail")
      (string.eq indexed "3/1/2/3")
      (string.eq mixed-selection "2 1 1 2")
      (string.eq named "L:R:L")
      (string.eq captured "captured:7")
      (string.eq ordered "3:1:2:3")
      (string.eq aligned "a----|  b  |    c")
      (string.eq integer-exponent "+0001.25E3")
      (string.eq dynamic-width "a   :b  ")
      (string.eq inline-precision "7")
      (string.eq dollar-precision "7:2")
      (string.eq star-precision "7:2")
      (string.eq named-precision "7")
      (string.eq text-inline-precision "sev")
      (string.eq text-dollar-precision "se:2")
      (string.eq text-star-precision "se")
      (string.eq bool-precision "tru")
      (string.eq char-zero-precision "")
      (string.eq integer-radix "+0x00000FF")
      (string.eq pointer-text "0x0")
      (string.eq pointer-alternate "0x0000000000000000")
      (string.eq rust-counter-one "Hello world is 7")
      (string.eq rust-counter-two "Hello world is 7")
      (string.eq rust-counter-three "Hello world is 7")
      (= state.value 123))))

;; The same scanner drives `println`/`print-format`, which reach it through
;; different wrapper macros; a wrapper that passed the wrong initial offset or
;; argument index would leave the checks above intact.
(define (print-checks-ok?) : bool
  (let
    [one : i64 1]
    [two : i64 2]
    ;; Referenced by generated call-site capture syntax.
    ;; lint-allow: unused-variable
    [label : String "scanner"]
    (begin
      (io.println "{label:.3}: {1:#x} {{}} {0:b}" two one)
      (io.print-format "{word:.2}\n" (format.named word "done"))
      true)))

(define (main) : i64
  (if (and (scanner-checks-ok?) (print-checks-ok?))
    42
    1))