;; Assembly analyzers and windows ported 1:1 from scripts/codegen-cases-analyzers.awk.
(import stdlib.byte_buf_core as bbc)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as svec)
(import (vector.vector i64) as ivec)
(import regex)
(import util)

(defstruct AnalyzerResult
  (ok bool)
  (value String))

(define (is-label? [line : (& line str)]) : bool
  (let
    [n : i64 (string.string-length line)]
    (if (or (< n 2) (!= (util.byte-at line (- n 1)) 58))
      false
      (let
        [i : i64 0]
        [ok : bool true]
        (while (and ok (< i (- n 1)))
          (let
            [b : i64 (util.byte-at line i)]
            (if (or (util.is-blank-byte? b) (= b 58))
              (set! ok false)
              (set! i (+ i 1)))))
        ok))))

(define (label-of [line : (& line str)]) : String
  (string.substring line 0 (- (string.string-length line) 1)))

(define (svec-contains? [v : (& v svec.Vec)] [target : (& target str)]) : bool
  (let
    [n : i64 (svec.len v)]
    [i : i64 0]
    [found : bool false]
    (while (and (not found) (< i n))
      (if (string.eq (svec.get v i "") target)
        (set! found true)
        (set! i (+ i 1))))
    found))

(define (svec-add-unique! [v : (&mut v svec.Vec)] [item : (& item str)]) : unit
  (when (not (svec-contains? v item)) (svec.push-ref! v (string.copy item))))

(define (line-matches-re? [line : (& line str)] [pat : (& pat str)]) : bool
  (let
    [prog : regex.RegexProg (regex.regex-compile pat false)]
    (regex.regex-match-line? (& prog) line)))

;; Extract function slice for `in fn LABEL` or `in fn-globl LABEL`.
(define (extract-fn
  [asm : (& asm str)]
  [label : (& label str)]
  [kind : (& kind str)]) : AnalyzerResult
  (let
    [lines : svec.Vec (util.split-lines asm)]
    [n : i64 (svec.len (& lines))]
    [want-label : String (str_cat.str-cat (string.copy label) ":")]
    [is-fn : bool (string.eq kind "fn")]
    [re-globl-col0 : regex.RegexProg
      (regex.regex-compile "^\\.globl[[:space:]]" false)]
    [re-size : regex.RegexProg
      (regex.regex-compile "^[[:space:]]*\\.size[[:space:]]" false)]
    [re-globl-any : regex.RegexProg
      (regex.regex-compile "^[[:space:]]*\\.globl[[:space:]]" false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [in-fn : bool false]
    [done : bool false]
    [i : i64 0]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get (& lines) i "")]
        (cond
          [(and (not in-fn) (string.eq (& line) (& want-label)))
            (set! in-fn true)
            (bbc.byte-buf-builder-append-string (&mut out) line)
            (bbc.byte-buf-builder-push (&mut out) (cast 10 : u8))]
          [(and
              in-fn
              is-fn
              (regex.regex-match-line? (& re-globl-col0) (& line)))
            (set! done true)]
          [(and in-fn is-fn (regex.regex-match-line? (& re-size) (& line)))
            (set! done true)]
          [(and
              in-fn
              (not is-fn)
              (regex.regex-match-line? (& re-globl-any) (& line)))
            (set! done true)]
          [in-fn
            (bbc.byte-buf-builder-append-string (&mut out) line)
            (bbc.byte-buf-builder-push (&mut out) (cast 10 : u8))]
          [else unit]))
      (set! i (+ i 1)))
    (if in-fn
      (AnalyzerResult true (bbc.byte-buf-builder-finish-string (& out)))
      (AnalyzerResult false ""))))

;; ------------------------------------------------------------------ metrics
(define (metric-backward-branches [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [seen : svec.Vec (svec.new)]
    [re-jmp : regex.RegexProg
      (regex.regex-compile
        "^[[:blank:]]+j[a-z]+[[:blank:]]+[^[:blank:]*%(,]+$"
        false)]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (if (is-label? (& line))
          (begin
            (svec-add-unique! (&mut seen) (label-of (& line)))
            unit)
          (when
            (regex.regex-match-line? (& re-jmp) (& line))
            (let
              [words : svec.Vec (util.split-words-blank (& line))]
              (when
                (and
                  (>= (svec.len (& words)) 2)
                  (svec-contains? (& seen) (svec.get (& words) 1 "")))
                (set! count (+ count 1)))))))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-fallthrough-jmps [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-jmp : regex.RegexProg
      (regex.regex-compile "^    jmp [^[:blank:]*%(,]+$" false)]
    [pending : bool false]
    [target : String ""]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        [consumed : bool false]
        (when
          pending
          (if (is-label? (& line))
            (begin
              (when
                (string.eq (label-of (& line)) (& target))
                (set! count (+ count 1))
                (set! pending false))
              (set! consumed true))
            (set! pending false)))
        (when
          (and (not consumed) (regex.regex-match-line? (& re-jmp) (& line)))
          (set! pending true)
          (set!
            target
            (string.substring (& line) 8 (- (string.string-length (& line)) 8)))))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-jumps-into-jump-only-blocks [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-jmp : regex.RegexProg
      (regex.regex-compile "^    jmp [^[:blank:]*%(,]+$" false)]
    [re-jcc : regex.RegexProg
      (regex.regex-compile "^    j[a-z]+ [^[:blank:]*%(,]+$" false)]
    [re-dot : regex.RegexProg (regex.regex-compile "^[[:space:]]*\\." false)]
    [labels : svec.Vec (svec.new)]
    [at : ivec.Vec (ivec.new)]
    [solo : svec.Vec (svec.new)]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (when
          (is-label? (& line))
          (let
            [lbl : String (label-of (& line))]
            ;; Update existing or push new (matching awk at[l] = i overwrite)
            [found : bool false]
            [k : i64 0]
            [ln : i64 (svec.len (& labels))]
            (while (and (not found) (< k ln))
              (if (string.eq (svec.get (& labels) k "") (& lbl))
                (begin
                  (ivec.set-ref! (&mut at) k i)
                  (set! found true))
                (set! k (+ k 1))))
            (when
              (not found)
              (svec.push-ref! (&mut labels) lbl)
              (ivec.push-ref! (&mut at) i)))))
      (set! i (+ i 1)))
    (let
      [k : i64 0]
      [ln : i64 (svec.len (& labels))]
      (while (< k ln)
        (let
          [lbl : String (svec.get (& labels) k "")]
          [idx : i64 (+ (ivec.get (& at) k 0) 1)]
          (while (and (< idx n) (is-label? (svec.get lines idx "")))
            (set! idx (+ idx 1)))
          (when
            (and
              (< idx n)
              (regex.regex-match-line? (& re-jmp) (svec.get lines idx "")))
            (let
              [jline : String (svec.get lines idx "")]
              [target : String
                (string.substring
                  (& jline)
                  8
                  (- (string.string-length (& jline)) 8))]
              (when
                (not (string.eq (& target) (& lbl)))
                (let
                  [j : i64 (+ idx 1)]
                  (when
                    (or
                      (>= j n)
                      (is-label? (svec.get lines j ""))
                      (regex.regex-match-line? (& re-dot) (svec.get lines j "")))
                    (svec-add-unique! (&mut solo) (& lbl))
                    unit))))))
        (set! k (+ k 1))))
    (let
      [count : i64 0]
      [k : i64 0]
      (while (< k n)
        (let
          [line : String (svec.get lines k "")]
          (when
            (regex.regex-match-line? (& re-jcc) (& line))
            (let
              [sp : i64 (util.index-of-byte-from (& line) 4 32)]
              (when
                (>= sp 0)
                (let
                  [t : String
                    (string.substring
                      (& line)
                      (+ sp 1)
                      (- (string.string-length (& line)) (+ sp 1)))]
                  (when
                    (svec-contains? (& solo) (& t))
                    (set! count (+ count 1))))))))
        (set! k (+ k 1)))
      (string.int->string count))))

(define (metric-self-loop-jmps [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-jmp : regex.RegexProg
      (regex.regex-compile "^    jmp [^[:blank:]*%(,]+$" false)]
    [run : svec.Vec (svec.new)]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (if (is-label? (& line))
          (svec.push-ref! (&mut run) (label-of (& line)))
          (begin
            (when
              (regex.regex-match-line? (& re-jmp) (& line))
              (let
                [target : String
                  (string.substring
                    (& line)
                    8
                    (- (string.string-length (& line)) 8))]
                (when
                  (svec-contains? (& run) (& target))
                  (set! count (+ count 1)))))
            (set! run (svec.new)))))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-store-then-cmp-same-slot [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-store : regex.RegexProg
      (regex.regex-compile "^    movq %[a-z0-9]+, -?[0-9]+\\(%rsp\\)$" false)]
    [re-cmp : regex.RegexProg
      (regex.regex-compile "^    cmpq -?[0-9]+\\(%rsp\\), %[a-z0-9]+$" false)]
    [stored : svec.Vec (svec.new)]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (cond
          [(is-label? (& line)) (set! stored (svec.new))]
          [(regex.regex-match-line? (& re-store) (& line))
            (let
              [w : svec.Vec (util.split-words-blank (& line))]
              (when
                (>= (svec.len (& w)) 3)
                (svec-add-unique! (&mut stored) (svec.get (& w) 2 ""))
                unit))]
          [(regex.regex-match-line? (& re-cmp) (& line))
            (let
              [w : svec.Vec (util.split-words-blank (& line))]
              (when
                (>= (svec.len (& w)) 2)
                (let
                  [raw : String (svec.get (& w) 1 "")]
                  [rlen : i64 (string.string-length (& raw))]
                  [slot : String
                    (if (and
                      (> rlen 0)
                      (= (util.byte-at (& raw) (- rlen 1)) 44))
                      (string.substring (& raw) 0 (- rlen 1))
                      raw)]
                  (when
                    (svec-contains? (& stored) (& slot))
                    (set! count (+ count 1))))))]
          [else unit]))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-copy-chains-to-rax [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-mov : regex.RegexProg
      (regex.regex-compile "^    movq %[a-z0-9]+, %[a-z0-9]+$" false)]
    [prev : bool false]
    [prev-dst : String ""]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (if (regex.regex-match-line? (& re-mov) (& line))
          (let
            [w : svec.Vec (util.split-words-blank (& line))]
            [raw-src : String (svec.get (& w) 1 "")]
            [rlen : i64 (string.string-length (& raw-src))]
            [src : String
              (if (and (> rlen 0) (= (util.byte-at (& raw-src) (- rlen 1)) 44))
                (string.substring (& raw-src) 0 (- rlen 1))
                raw-src)]
            [dst : String (svec.get (& w) 2 "")]
            (when
              (and
                prev
                (string.eq (& src) (& prev-dst))
                (string.eq (& dst) "%rax"))
              (set! count (+ count 1)))
            (set! prev true)
            (set! prev-dst dst))
          (begin
            (set! prev false)
            (set! prev-dst ""))))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-abort-staging-push-from-memory [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-stage : regex.RegexProg
      (regex.regex-compile "^[[:space:]]+# tl_abort_operand_stage" false)]
    [re-push : regex.RegexProg
      (regex.regex-compile "^[[:space:]]+pushq [-0-9]*\\(%" false)]
    [count : i64 0]
    [i : i64 1]
    (while (< i n)
      (when
        (and
          (regex.regex-match-line? (& re-stage) (svec.get lines i ""))
          (regex.regex-match-line? (& re-push) (svec.get lines (- i 1) "")))
        (set! count (+ count 1)))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (norm-reg [r : (& r str)]) : String
  (let
    [n : String
      (if (and (> (string.string-length r) 0) (= (util.byte-at r 0) 37))
        (string.substring r 1 (- (string.string-length r) 1))
        (string.copy r))]
    [nlen : i64 (string.string-length (& n))]
    (cond
      [(and
          (= nlen 3)
          (= (util.byte-at (& n) 0) 101)
          (util.is-lower-byte? (util.byte-at (& n) 1))
          (util.is-lower-byte? (util.byte-at (& n) 2)))
        (str_cat.str-cat "r" (string.substring (& n) 1 2))]
      [(line-matches-re? (& n) "^r[0-9]+[bwd]$")
        (string.substring (& n) 0 (- nlen 1))]
      [(and
          (= nlen 3)
          (util.is-lower-byte? (util.byte-at (& n) 0))
          (util.is-lower-byte? (util.byte-at (& n) 1))
          (= (util.byte-at (& n) 2) 108)
          (not (string.eq (& n) "rsl")))
        (str_cat.str-cat "r" (string.substring (& n) 0 2) "x")]
      [else n])))

(define (split-comma-ws [line : (& line str)]) : svec.Vec
  (let
    [out : svec.Vec (svec.new)]
    [n : i64 (string.string-length line)]
    [i : i64 0]
    (while (< i n)
      (while (and
        (< i n)
        (or
          (util.is-blank-byte? (util.byte-at line i))
          (= (util.byte-at line i) 44)))
        (set! i (+ i 1)))
      (let
        [start : i64 i]
        (while (and
          (< i n)
          (not (util.is-blank-byte? (util.byte-at line i)))
          (!= (util.byte-at line i) 44))
          (set! i (+ i 1)))
        (when
          (> i start)
          (svec.push-ref! (&mut out) (string.substring line start (- i start))))))
    out))

(define (literal-dst
  [line : (& line str)]
  [re-mov : (& re-mov regex.RegexProg)]
  [re-xor : (& re-xor regex.RegexProg)]) : String
  (cond
    [(regex.regex-match-line? re-mov line)
      (let
        [comma : i64 (util.index-of-byte-from line 0 44)]
        [rest : String
          (util.trim-leading-blanks
            (string.substring
              line
              (+ comma 1)
              (- (string.string-length line) (+ comma 1))))]
        (norm-reg (& rest)))]
    [(regex.regex-match-line? re-xor line)
      (let
        [parts : svec.Vec (split-comma-ws line)]
        (if (>= (svec.len (& parts)) 3)
          (let
            [r1 : String (norm-reg (svec.get (& parts) 1 ""))]
            [r2 : String (norm-reg (svec.get (& parts) 2 ""))]
            (if (string.eq (& r1) (& r2))
              r1
              ""))
          ""))]
    [else ""]))

(define (test-reg [line : (& line str)] [re-test : (& re-test regex.RegexProg)]) : String
  (if (regex.regex-match-line? re-test line)
    (let
      [parts : svec.Vec (split-comma-ws line)]
      (if (>= (svec.len (& parts)) 3)
        (let
          [r1 : String (norm-reg (svec.get (& parts) 1 ""))]
          [r2 : String (norm-reg (svec.get (& parts) 2 ""))]
          (if (string.eq (& r1) (& r2))
            r1
            ""))
        ""))
    ""))

(define (metric-literal-then [lines : (& lines svec.Vec)] [want-test : bool]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-mov : regex.RegexProg
      (regex.regex-compile "^mov[lq][ \t]+\\$-?[0-9]+,[ \t]*%[a-z0-9]+$" false)]
    [re-xor : regex.RegexProg
      (regex.regex-compile "^xor[lq][ \t]+%[a-z0-9]+,[ \t]*%[a-z0-9]+$" false)]
    [re-test : regex.RegexProg
      (regex.regex-compile
        "^test[bwlq][ \t]+%[a-z0-9]+,[ \t]*%[a-z0-9]+$"
        false)]
    [pending : String ""]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (util.trim-blanks (svec.get lines i ""))]
        [got : String
          (if want-test
            (test-reg (& line) (& re-test))
            (literal-dst (& line) (& re-mov) (& re-xor)))]
        (when
          (and
            (> (string.string-length (& pending)) 0)
            (string.eq (& got) (& pending)))
          (set! count (+ count 1)))
        (set! pending (literal-dst (& line) (& re-mov) (& re-xor))))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (collect-prologue-csrs [lines : (& lines svec.Vec)]) : svec.Vec
  (let
    [n : i64 (svec.len lines)]
    [re-colon : regex.RegexProg (regex.regex-compile ":[[:space:]]*$" false)]
    [re-push : regex.RegexProg
      (regex.regex-compile "^[[:space:]]+pushq %(r1[2-5]|rbx|rbp)$" false)]
    [out : svec.Vec (svec.new)]
    [i : i64 1]
    [done : bool false]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (if (regex.regex-match-line? (& re-colon) (& line))
          (set! done true)
          (when
            (regex.regex-match-line? (& re-push) (& line))
            (let
              [pct : i64 (util.index-of-byte-from (& line) 0 37)]
              (when
                (>= pct 0)
                (svec.push-ref!
                  (&mut out)
                  (string.substring
                    (& line)
                    (+ pct 1)
                    (- (string.string-length (& line)) (+ pct 1)))))))))
      (set! i (+ i 1)))
    out))

(define (count-lines-fixed
  [lines : (& lines svec.Vec)]
  [needle : (& needle str)]) : i64
  (let
    [n : i64 (svec.len lines)]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (when
        (>= (util.index-of-str-from (svec.get lines i "") needle 0) 0)
        (set! count (+ count 1)))
      (set! i (+ i 1)))
    count))

(define (count-lines-regex [lines : (& lines svec.Vec)] [pat : (& pat str)]) : i64
  (let
    [prog : regex.RegexProg (regex.regex-compile pat false)]
    [n : i64 (svec.len lines)]
    [count : i64 0]
    [i : i64 0]
    (while (< i n)
      (when
        (regex.regex-match-line? (& prog) (svec.get lines i ""))
        (set! count (+ count 1)))
      (set! i (+ i 1)))
    count))

(define (metric-csr-pushes [lines : (& lines svec.Vec)]) : String
  (let
    [regs : svec.Vec (util.split-words-blank "r12 r13 r14 r15 rbx rbp")]
    [saved : i64 0]
    [err : String ""]
    [k : i64 0]
    (while (and (= (string.string-length (& err)) 0) (< k 6))
      (let
        [r : String (svec.get (& regs) k "")]
        [push-pat : String (str_cat.str-cat "pushq %" (string.copy (& r)))]
        [pop-pat : String (str_cat.str-cat "popq %" (string.copy (& r)))]
        [pushes : i64 (count-lines-fixed lines (& push-pat))]
        [pops : i64 (count-lines-fixed lines (& pop-pat))]
        (if (or (!= pushes pops) (> pushes 1))
          (set! err (str_cat.str-cat "unbalanced-" r))
          (set! saved (+ saved pushes))))
      (set! k (+ k 1)))
    (if (> (string.string-length (& err)) 0)
      err
      (string.int->string saved))))

(define (metric-csr-pushes-parity [lines : (& lines svec.Vec)]) : String
  (let
    [s : String (metric-csr-pushes lines)]
    [p : util.ParsedI64 (util.parse-u64-strict (& s))]
    (if (not p.ok)
      s
      (if (= (% p.value 2) 0)
        "even"
        "odd"))))

;; Strip [-0-9]*(%r[bs]p[^)]*) -> FRAME in line.
(define (strip-frame-operands [line : (& line str)]) : String
  (let
    [re : regex.RegexProg
      (regex.regex-compile "[-0-9]*\\(%r[bs]p[^)]*\\)" false)]
    [n : i64 (string.string-length line)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
    [pos : i64 0]
    [done : bool false]
    (while (and (not done) (< pos n))
      (let
        [m : regex.RegexMatch (regex.regex-find-line-from (& re) line pos)]
        (if (not m.matched)
          (begin
            (bbc.byte-buf-builder-append-string
              (&mut out)
              (string.substring line pos (- n pos)))
            (set! done true))
          (begin
            (when
              (> m.start pos)
              (bbc.byte-buf-builder-append-string
                (&mut out)
                (string.substring line pos (- m.start pos))))
            (bbc.byte-buf-builder-append-string (&mut out) "FRAME")
            (set!
              pos
              (if (> m.end m.start)
                m.end
                (+ m.start 1)))))))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (metric-unnamed-pushed-csrs [lines : (& lines svec.Vec)]) : String
  (let
    [pushed : svec.Vec (collect-prologue-csrs lines)]
    [np : i64 (svec.len (& pushed))]
    [n : i64 (svec.len lines)]
    [bad : i64 0]
    [k : i64 0]
    (while (< k np)
      (let
        [r : String (svec.get (& pushed) k "")]
        [pat-str : String
          (cond
            [(string.eq (& r) "rbx") "%rbx|%ebx|%bx|%bl"]
            [(string.eq (& r) "rbp") "%rbp|%ebp|%bp|%bpl"]
            [else (str_cat.str-cat "%" (string.copy (& r)))])]
        [pop-str : String
          (str_cat.str-cat "^[[:space:]]+popq %" (string.copy (& r)) "$")]
        [re-pat : regex.RegexProg (regex.regex-compile (& pat-str) false)]
        [re-pop : regex.RegexProg (regex.regex-compile (& pop-str) false)]
        [mentions : i64 0]
        [i : i64 0]
        (while (< i n)
          (let
            [cleaned : String (strip-frame-operands (svec.get lines i ""))]
            (when
              (and
                (regex.regex-match-line? (& re-pat) (& cleaned))
                (not (regex.regex-match-line? (& re-pop) (& cleaned))))
              (set! mentions (+ mentions 1))))
          (set! i (+ i 1)))
        (when (<= mentions 1) (set! bad (+ bad 1))))
      (set! k (+ k 1)))
    (string.int->string bad)))

(define (first-stack-sub [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re : regex.RegexProg
      (regex.regex-compile "^[[:space:]]*subq \\$[0-9]+, %rsp$" false)]
    [i : i64 0]
    [found : String ""]
    [done : bool false]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (when
          (regex.regex-match-line? (& re) (& line))
          (let
            [dlr : i64 (util.index-of-byte-from (& line) 0 36)]
            [comma : i64 (util.index-of-byte-from (& line) (+ dlr 1) 44)]
            (set!
              found
              (string.substring (& line) (+ dlr 1) (- comma (+ dlr 1))))
            (set! done true))))
      (set! i (+ i 1)))
    found))

(define (metric-call-alignment
  [lines : (& lines svec.Vec)]
  [spec : (& spec str)]) : String
  (let
    [pushes-str : String
      (cond
        [(string.eq spec "prologue")
          (string.int->string (svec.len (& (collect-prologue-csrs lines))))]
        [(string.eq spec "pushes") (metric-csr-pushes lines)]
        [else (string.copy spec)])]
    [p : util.ParsedI64 (util.parse-u64-strict (& pushes-str))]
    (if (not p.ok)
      pushes-str
      (let
        [sub-str : String (first-stack-sub lines)]
        (if (= (string.string-length (& sub-str)) 0)
          "no-stack-adjustment"
          (let
            [sub-val : i64 (util.parse-u64-strict (& sub-str)).value]
            (if (!= (% (+ (* 8 p.value) sub-val) 16) 8)
              (str_cat.str-cat
                "misaligned-"
                (string.int->string p.value)
                "-pushes-subq-"
                sub-str)
              "ok")))))))

(define (metric-dead-slot-region [lines : (& lines svec.Vec)]) : String
  (let
    [s : String (metric-csr-pushes lines)]
    [p : util.ParsedI64 (util.parse-u64-strict (& s))]
    (if (not p.ok)
      s
      (let
        [subs : i64
          (count-lines-regex lines "^[[:space:]]+subq \\$[0-9]+, %rsp$")]
        [adds : i64
          (count-lines-regex lines "^[[:space:]]+addq \\$[0-9]+, %rsp$")]
        [pad : i64 (count-lines-regex lines "^[[:space:]]+subq \\$8, %rsp$")]
        (if (= (% p.value 2) 1)
          (if (or (!= subs 0) (!= adds 0))
            (str_cat.str-cat
              "odd-pushes-with-"
              (string.int->string subs)
              "-subq-"
              (string.int->string adds)
              "-addq")
            "ok")
          (if (or (!= pad 1) (!= subs 1))
            (str_cat.str-cat
              "even-pushes-with-"
              (string.int->string subs)
              "-subq-"
              (string.int->string pad)
              "-pads")
            "ok"))))))

(define (metric-stack-frame [lines : (& lines svec.Vec)]) : String
  (let
    [subs : i64 (count-lines-regex lines "^[[:space:]]+subq \\$[0-9]+, %rsp$")]
    (str_cat.str-cat (string.int->string subs) ":" (first-stack-sub lines))))

(define (metric-frame-size [lines : (& lines svec.Vec)]) : String
  (let
    [v : String (first-stack-sub lines)]
    (if (= (string.string-length (& v)) 0)
      "0"
      v)))

(define (metric-frame-release [lines : (& lines svec.Vec)]) : String
  (let
    [sub-str : String (first-stack-sub lines)]
    [re : regex.RegexProg
      (regex.regex-compile "^[[:space:]]*addq \\$[0-9]+, %rsp$" false)]
    [n : i64 (svec.len lines)]
    [add-str : String ""]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (when
          (regex.regex-match-line? (& re) (& line))
          (let
            [dlr : i64 (util.index-of-byte-from (& line) 0 36)]
            [comma : i64 (util.index-of-byte-from (& line) (+ dlr 1) 44)]
            (set!
              add-str
              (string.substring (& line) (+ dlr 1) (- comma (+ dlr 1)))))))
      (set! i (+ i 1)))
    (if (or
      (= (string.string-length (& sub-str)) 0)
      (= (string.string-length (& add-str)) 0))
      (str_cat.str-cat "subq-" sub-str "-addq-" add-str)
      (if (string.eq (& sub-str) (& add-str))
        "ok"
        (str_cat.str-cat "subq-" sub-str "-addq-" add-str)))))

(define (metric-rmw-fold-staging
  [lines : (& lines svec.Vec)]
  [cell : (& cell str)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-rmw-str : String
      (str_cat.str-cat
        "^[[:space:]]+(addq|subq|orq|andq|xorq) ([$][0-9-]+|%r[a-z0-9]+), "
        (string.copy cell)
        "\\(%rip\\)$")]
    [re-load-str : String
      (str_cat.str-cat "^[[:space:]]+movq " (string.copy cell) "\\(%rip\\), %r")]
    [re-store-str : String
      (str_cat.str-cat
        "^[[:space:]]+movq %r[a-z0-9]+, "
        (string.copy cell)
        "\\(%rip\\)$")]
    [re-rmw : regex.RegexProg (regex.regex-compile (& re-rmw-str) false)]
    [re-load : regex.RegexProg (regex.regex-compile (& re-load-str) false)]
    [re-store : regex.RegexProg (regex.regex-compile (& re-store-str) false)]
    [count : i64 0]
    [pending : bool false]
    [prev : String ""]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (if (regex.regex-match-line? (& re-rmw) (& line))
          (begin
            (when
              (regex.regex-match-line? (& re-load) (& prev))
              (set! count (+ count 1)))
            (set! pending true)
            (set! prev line))
          (begin
            (when
              pending
              (when
                (regex.regex-match-line? (& re-store) (& line))
                (set! count (+ count 1)))
              (set! pending false))
            (set! prev line))))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-frame-homed-fold-accumulators [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-xor : regex.RegexProg
      (regex.regex-compile "^[[:space:]]+xorq %r[a-z0-9]+, %r[a-z0-9]+$" false)]
    [count : i64 0]
    [state : i64 0]
    [acc : String ""]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (cond
          [(regex.regex-match-line? (& re-xor) (& line))
            (let
              [w : svec.Vec (util.split-words-blank (& line))]
              (set! acc (svec.get (& w) 2 ""))
              (set! state 1))]
          [(and
              (= state 1)
              (line-matches-re?
                (& line)
                (str_cat.str-cat
                  "^[[:space:]]+movq "
                  (string.copy (& acc))
                  ", [0-9]+\\(%rsp\\)$")))
            (set! state 2)]
          [(and
              (= state 2)
              (line-matches-re?
                (& line)
                (str_cat.str-cat
                  "^[[:space:]]+imulq %r[a-z0-9]+, "
                  (string.copy (& acc))
                  "$")))
            (set! state 3)]
          [(and
            (= state 3)
            (line-matches-re?
              (& line)
              (str_cat.str-cat
                "^[[:space:]]+movq "
                (string.copy (& acc))
                ", [0-9]+\\(%rsp\\)$")))
            (set! count (+ count 1))
            (set! state 0)]
          [else (set! state 0)]))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-memory-order [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-load : regex.RegexProg
      (regex.regex-compile
        "^[[:space:]]+movq -?[0-9]*\\(%r[a-z0-9]+,%r[a-z0-9]+,8\\), %r[a-z0-9]+$"
        false)]
    [re-store : regex.RegexProg
      (regex.regex-compile
        "^[[:space:]]+movq %r[a-z0-9]+, -?[0-9]*\\(%r[a-z0-9]+,%r[a-z0-9]+,8\\)$"
        false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (cond
          [(regex.regex-match-line? (& re-load) (& line))
            (bbc.byte-buf-builder-push (&mut out) (cast 76 : u8))]
          [(regex.regex-match-line? (& re-store) (& line))
            (bbc.byte-buf-builder-push (&mut out) (cast 83 : u8))]
          [else unit]))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (metric-staged-index-copies [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-mov : regex.RegexProg
      (regex.regex-compile "^[[:space:]]+movq %r[a-z0-9]+, %r[a-z0-9]+$" false)]
    [count : i64 0]
    [i : i64 1]
    (while (< i n)
      (let
        [prev : String (svec.get lines (- i 1) "")]
        (when
          (regex.regex-match-line? (& re-mov) (& prev))
          (let
            [sep : i64 (util.index-of-str-from (& prev) ", " 0)]
            (when
              (>= sep 0)
              (let
                [reg : String
                  (string.substring
                    (& prev)
                    (+ sep 2)
                    (- (string.string-length (& prev)) (+ sep 2)))]
                [cur : String (svec.get lines i "")]
                (cond
                  [(line-matches-re?
                      (& cur)
                      (str_cat.str-cat
                        "^[[:space:]]+addq "
                        (string.copy (& reg))
                        ", %r"))
                    (set! count (+ count 1))]
                  [(line-matches-re?
                      (& cur)
                      (str_cat.str-cat
                        "^[[:space:]]+leaq \\(%r[a-z0-9]+,"
                        (string.copy (& reg))
                        ",[1248]\\), %r"))
                    (set! count (+ count 1))]
                  [else unit]))))))
      (set! i (+ i 1)))
    (string.int->string count)))

(define (metric-cmov-under-cmp [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-cmov : regex.RegexProg (regex.regex-compile "^[[:space:]]+cmov" false)]
    [re-cmp : regex.RegexProg
      (regex.regex-compile "^[[:space:]]+cmp[bwlq] " false)]
    [seen : i64 0]
    [bad : bool false]
    [i : i64 0]
    (while (< i n)
      (when
        (regex.regex-match-line? (& re-cmov) (svec.get lines i ""))
        (set! seen (+ seen 1))
        (when
          (or
            (= i 0)
            (not
              (regex.regex-match-line? (& re-cmp) (svec.get lines (- i 1) ""))))
          (set! bad true)))
      (set! i (+ i 1)))
    (if (or bad (= seen 0))
      "bad"
      "ok")))

(define (metric-distinct [lines : (& lines svec.Vec)] [re-pat : (& re-pat str)]) : String
  (let
    [prog : regex.RegexProg (regex.regex-compile re-pat false)]
    [n : i64 (svec.len lines)]
    [got : svec.Vec (svec.new)]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        [llen : i64 (string.string-length (& line))]
        [pos : i64 0]
        [done : bool false]
        (while (and (not done) (< pos llen))
          (let
            [m : regex.RegexMatch
              (regex.regex-find-line-from (& prog) (& line) pos)]
            (if (not m.matched)
              (set! done true)
              (if (<= m.end m.start)
                (set! pos (+ m.start 1))
                (begin
                  (svec-add-unique!
                    (&mut got)
                    (string.substring (& line) m.start (- m.end m.start)))
                  (set! pos m.end)))))))
      (set! i (+ i 1)))
    (string.int->string (svec.len (& got)))))

(define (bare-reg [text : (& text str)]) : String
  (let
    [n : i64 (string.string-length text)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (let
        [b : i64 (util.byte-at text i)]
        (when
          (and (!= b 44) (!= b 40) (!= b 41))
          (bbc.byte-buf-builder-push (&mut out) (cast b : u8))))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (offset-base [text : (& text str)]) : String
  (let
    [b : String (bare-reg text)]
    (if (util.starts-with? (& b) "16")
      (string.substring (& b) 2 (- (string.string-length (& b)) 2))
      b)))

(define (metric-copy24-sequences [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-ptr-comma : regex.RegexProg
      (regex.regex-compile "^\\(%r[a-z0-9]+\\),$" false)]
    [re-ptr : regex.RegexProg (regex.regex-compile "^\\(%r[a-z0-9]+\\)$" false)]
    [re-xmm : regex.RegexProg (regex.regex-compile "^%xmm[0-9]+$" false)]
    [re-xmm-comma : regex.RegexProg (regex.regex-compile "^%xmm[0-9]+,$" false)]
    [re-off16-comma : regex.RegexProg
      (regex.regex-compile "^16\\(%r[a-z0-9]+\\),$" false)]
    [re-off16 : regex.RegexProg
      (regex.regex-compile "^16\\(%r[a-z0-9]+\\)$" false)]
    [re-gpr : regex.RegexProg (regex.regex-compile "^%r[a-z0-9]+$" false)]
    [re-gpr-comma : regex.RegexProg
      (regex.regex-compile "^%r[a-z0-9]+,$" false)]
    [count : i64 0]
    [state : i64 0]
    [source : String ""]
    [vector : String ""]
    [dest : String ""]
    [word : String ""]
    [i : i64 0]
    (while (< i n)
      (let
        [f : svec.Vec (util.split-words-blank (svec.get lines i ""))]
        [f0 : String (svec.get (& f) 0 "")]
        [f1 : String (svec.get (& f) 1 "")]
        [f2 : String (svec.get (& f) 2 "")]
        (cond
          [(and
            (string.eq (& f0) "movups")
            (regex.regex-match-line? (& re-ptr-comma) (& f1))
            (regex.regex-match-line? (& re-xmm) (& f2)))
            (set! source (bare-reg (& f1)))
            (set! vector f2)
            (set! state 1)]
          [(and
              (= state 1)
              (string.eq (& f0) "movups")
              (regex.regex-match-line? (& re-xmm-comma) (& f1))
              (regex.regex-match-line? (& re-ptr) (& f2)))
            (if (string.eq (bare-reg (& f1)) (& vector))
              (begin
                (set! dest (bare-reg (& f2)))
                (set! state 2))
              (set! state 0))]
          [(and
              (= state 2)
              (string.eq (& f0) "movq")
              (regex.regex-match-line? (& re-off16-comma) (& f1))
              (regex.regex-match-line? (& re-gpr) (& f2)))
            (if (string.eq (offset-base (& f1)) (& source))
              (begin
                (set! word f2)
                (set! state 3))
              (set! state 0))]
          [(and
            (= state 3)
            (string.eq (& f0) "movq")
            (regex.regex-match-line? (& re-gpr-comma) (& f1))
            (regex.regex-match-line? (& re-off16) (& f2)))
            (when
              (and
                (string.eq (bare-reg (& f1)) (& word))
                (string.eq (offset-base (& f2)) (& dest)))
              (set! count (+ count 1)))
            (set! state 0)]
          [else unit]))
      (set! i (+ i 1)))
    (string.int->string count)))

;; ------------------------------------------------------------------ windows
(define (append-line! [out : (&mut out bbc.ByteBufBuilder)] [line : String]) : unit
  (bbc.byte-buf-builder-append-string out line)
  (bbc.byte-buf-builder-push out (cast 10 : u8)))

(define (window-unroll-body [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-lbl : regex.RegexProg (regex.regex-compile "^[^[:blank:]]*:$" false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [started : bool false]
    [done : bool false]
    [i : i64 0]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (cond
          [(and started (regex.regex-match-line? (& re-lbl) (& line)))
            (set! done true)]
          [started (append-line! (&mut out) line)]
          [(util.ends-with? (& line) "__unroll_body:") (set! started true)]
          [else unit]))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-labeled-block
  [lines : (& lines svec.Vec)]
  [suffix : (& suffix str)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-lbl : regex.RegexProg (regex.regex-compile "^[^[:blank:]]*:$" false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [started : bool false]
    [done : bool false]
    [i : i64 0]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (cond
          [(and started (regex.regex-match-line? (& re-lbl) (& line)))
            (set! done true)]
          [started (append-line! (&mut out) line)]
          [(and
              (util.ends-with? (& line) ":")
              (>= (util.index-of-str-from (& line) suffix 0) 0))
            (set! started true)]
          [else unit]))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-seh-endproc [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-end : regex.RegexProg
      (regex.regex-compile "^[[:space:]]*\\.seh_endproc$" false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [done : bool false]
    [i : i64 0]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (append-line! (&mut out) (string.copy (& line)))
        (when (regex.regex-match-line? (& re-end) (& line)) (set! done true)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-fast-self-loop
  [lines : (& lines svec.Vec)]
  [needle : (& needle str)]) : String
  (let
    [n : i64 (svec.len lines)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [inblk : bool false]
    [buf : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [hit : bool false]
    [lbl : String ""]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (if (util.ends-with? (& line) "__bce_fast:")
          (begin
            (set! lbl (label-of (& line)))
            (set! inblk true)
            (set! buf (bbc.byte-buf-builder-new))
            (set! hit false))
          (when
            inblk
            (append-line! (&mut buf) (string.copy (& line)))
            (when
              (>= (util.index-of-str-from (& line) needle 0) 0)
              (set! hit true))
            (cond
              [(>= (util.index-of-str-from (& line) (& lbl) 0) 0)
                (when
                  hit
                  (bbc.byte-buf-builder-append-string
                    (&mut out)
                    (bbc.byte-buf-builder-finish-string (& buf))))
                (set! inblk false)]
              [(util.starts-with? (& line) ".L") (set! inblk false)]
              [else unit]))))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-fast-region
  [lines : (& lines svec.Vec)]
  [needle : (& needle str)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-fast : regex.RegexProg (regex.regex-compile "__bce_fast[^:]*:$" false)]
    [inblk : bool false]
    [buf : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [hit : bool false]
    [result : String ""]
    [done : bool false]
    [i : i64 0]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (cond
          [(regex.regex-match-line? (& re-fast) (& line))
            (when
              (not inblk)
              (set! inblk true)
              (set! buf (bbc.byte-buf-builder-new))
              (set! hit false))]
          [(and inblk (util.starts-with? (& line) ".L"))
            (if (>= (util.index-of-str-from (& line) "__bce_fast" 0) 0)
              unit
              (if hit
                (begin
                  (set! result (bbc.byte-buf-builder-finish-string (& buf)))
                  (set! done true))
                (set! inblk false)))]
          [inblk
            (append-line! (&mut buf) (string.copy (& line)))
            (when
              (>= (util.index-of-str-from (& line) needle 0) 0)
              (set! hit true))]
          [else unit]))
      (set! i (+ i 1)))
    (if done
      result
      (if (and inblk hit)
        (bbc.byte-buf-builder-finish-string (& buf))
        ""))))

(define (window-after [lines : (& lines svec.Vec)] [re-pat : (& re-pat str)]) : String
  (let
    [prog : regex.RegexProg (regex.regex-compile re-pat false)]
    [n : i64 (svec.len lines)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [inblk : bool false]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (when inblk (append-line! (&mut out) (string.copy (& line))))
        (when (regex.regex-match-line? (& prog) (& line)) (set! inblk true)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-symbol [lines : (& lines svec.Vec)] [label : (& label str)]) : String
  (let
    [n : i64 (svec.len lines)]
    [want : String (str_cat.str-cat (string.copy label) ":")]
    [re-sym : regex.RegexProg
      (regex.regex-compile "^[A-Za-z_][A-Za-z0-9_]*:$" false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [inblk : bool false]
    [done : bool false]
    [i : i64 0]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (cond
          [(and inblk (regex.regex-match-line? (& re-sym) (& line)))
            (set! done true)]
          [inblk (append-line! (&mut out) (string.copy (& line)))]
          [(string.eq (& line) (& want)) (set! inblk true)]
          [else unit]))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-from [lines : (& lines svec.Vec)] [re-pat : (& re-pat str)]) : String
  (let
    [prog : regex.RegexProg (regex.regex-compile re-pat false)]
    [n : i64 (svec.len lines)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [inblk : bool false]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (when (regex.regex-match-line? (& prog) (& line)) (set! inblk true))
        (when inblk (append-line! (&mut out) line)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-ranges [lines : (& lines svec.Vec)] [spec : (& spec str)]) : String
  (let
    [cut : i64 (util.index-of-byte-from spec 0 126)]
    (if (< cut 0)
      ""
      (let
        [start-re : String (string.substring spec 0 cut)]
        [end-re : String
          (string.substring
            spec
            (+ cut 1)
            (- (string.string-length spec) (+ cut 1)))]
        [prog-s : regex.RegexProg (regex.regex-compile (& start-re) false)]
        [prog-e : regex.RegexProg (regex.regex-compile (& end-re) false)]
        [n : i64 (svec.len lines)]
        [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
        [inblk : bool false]
        [i : i64 0]
        (while (< i n)
          (let
            [line : String (svec.get lines i "")]
            (if inblk
              (begin
                (append-line! (&mut out) (string.copy (& line)))
                (when
                  (regex.regex-match-line? (& prog-e) (& line))
                  (set! inblk false)))
              (when
                (regex.regex-match-line? (& prog-s) (& line))
                (append-line! (&mut out) line)
                (set! inblk true))))
          (set! i (+ i 1)))
        (bbc.byte-buf-builder-finish-string (& out))))))

(define (window-block-after
  [lines : (& lines svec.Vec)]
  [re-pat : (& re-pat str)]) : String
  (let
    [prog : regex.RegexProg (regex.regex-compile re-pat false)]
    [re-local : regex.RegexProg
      (regex.regex-compile "^\\.L[A-Za-z0-9_.]*:$" false)]
    [n : i64 (svec.len lines)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [inblk : bool false]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (when
          (regex.regex-match-line? (& re-local) (& line))
          (set! inblk false))
        (if (regex.regex-match-line? (& prog) (& line))
          (set! inblk true)
          (when inblk (append-line! (&mut out) line))))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-call-args
  [lines : (& lines svec.Vec)]
  [symbol : (& symbol str)]) : String
  (let
    [n : i64 (svec.len lines)]
    [needle : String (str_cat.str-cat "call " (string.copy symbol))]
    [re-mov : regex.RegexProg
      (regex.regex-compile
        "^[[:space:]]+movq[[:space:]]+[^,]+,[[:space:]]*%rdi$"
        false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [start : i64 -1]
    [done : bool false]
    [i : i64 0]
    (while (and (not done) (< i n))
      (let
        [line : String (svec.get lines i "")]
        (when (regex.regex-match-line? (& re-mov) (& line)) (set! start i))
        (when
          (>= (util.index-of-str-from (& line) (& needle) 0) 0)
          (when
            (>= start 0)
            (let
              [j : i64 start]
              (while (<= j i)
                (append-line! (&mut out) (svec.get lines j ""))
                (set! j (+ j 1)))))
          (set! done true)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

(define (window-tl-code [lines : (& lines svec.Vec)]) : String
  (let
    [n : i64 (svec.len lines)]
    [re-comment : regex.RegexProg (regex.regex-compile "^[[:space:]]*;" false)]
    [out : bbc.ByteBufBuilder (bbc.byte-buf-builder-new)]
    [i : i64 0]
    (while (< i n)
      (let
        [line : String (svec.get lines i "")]
        (when
          (not (regex.regex-match-line? (& re-comment) (& line)))
          (append-line! (&mut out) line)))
      (set! i (+ i 1)))
    (bbc.byte-buf-builder-finish-string (& out))))

;; Dispatchers
(define (run-metric
  [name : (& name str)]
  [arg : (& arg str)]
  [subject : (& subject str)]) : AnalyzerResult
  (let
    [lines : svec.Vec (util.split-lines subject)]
    (cond
      [(string.eq name "backward-branches")
        (AnalyzerResult true (metric-backward-branches (& lines)))]
      [(string.eq name "fallthrough-jmps")
        (AnalyzerResult true (metric-fallthrough-jmps (& lines)))]
      [(string.eq name "jumps-into-jump-only-blocks")
        (AnalyzerResult true (metric-jumps-into-jump-only-blocks (& lines)))]
      [(string.eq name "self-loop-jmps")
        (AnalyzerResult true (metric-self-loop-jmps (& lines)))]
      [(string.eq name "store-then-cmp-same-slot")
        (AnalyzerResult true (metric-store-then-cmp-same-slot (& lines)))]
      [(string.eq name "copy-chains-to-rax")
        (AnalyzerResult true (metric-copy-chains-to-rax (& lines)))]
      [(string.eq name "abort-staging-push-from-memory")
        (AnalyzerResult true (metric-abort-staging-push-from-memory (& lines)))]
      [(string.eq name "literal-then-test")
        (AnalyzerResult true (metric-literal-then (& lines) true))]
      [(string.eq name "literal-then-redef")
        (AnalyzerResult true (metric-literal-then (& lines) false))]
      [(string.eq name "prologue-csrs")
        (AnalyzerResult
          true
          (string.int->string (svec.len (& (collect-prologue-csrs (& lines))))))]
      [(string.eq name "csr-pushes")
        (AnalyzerResult true (metric-csr-pushes (& lines)))]
      [(string.eq name "csr-pushes-parity")
        (AnalyzerResult true (metric-csr-pushes-parity (& lines)))]
      [(string.eq name "unnamed-pushed-csrs")
        (AnalyzerResult true (metric-unnamed-pushed-csrs (& lines)))]
      [(string.eq name "call-alignment")
        (AnalyzerResult true (metric-call-alignment (& lines) arg))]
      [(string.eq name "dead-slot-region")
        (AnalyzerResult true (metric-dead-slot-region (& lines)))]
      [(string.eq name "stack-frame")
        (AnalyzerResult true (metric-stack-frame (& lines)))]
      [(string.eq name "frame-size")
        (AnalyzerResult true (metric-frame-size (& lines)))]
      [(string.eq name "frame-release")
        (AnalyzerResult true (metric-frame-release (& lines)))]
      [(string.eq name "rmw-fold-staging")
        (AnalyzerResult true (metric-rmw-fold-staging (& lines) arg))]
      [(string.eq name "frame-homed-fold-accumulators")
        (AnalyzerResult true (metric-frame-homed-fold-accumulators (& lines)))]
      [(string.eq name "memory-order")
        (AnalyzerResult true (metric-memory-order (& lines)))]
      [(string.eq name "staged-index-copies")
        (AnalyzerResult true (metric-staged-index-copies (& lines)))]
      [(string.eq name "cmov-under-cmp")
        (AnalyzerResult true (metric-cmov-under-cmp (& lines)))]
      [(string.eq name "distinct")
        (AnalyzerResult true (metric-distinct (& lines) arg))]
      [(string.eq name "copy24-sequences")
        (AnalyzerResult true (metric-copy24-sequences (& lines)))]
      [else (AnalyzerResult false "analyzer-error")])))

(define (run-window
  [name : (& name str)]
  [arg : (& arg str)]
  [subject : (& subject str)]) : AnalyzerResult
  (let
    [lines : svec.Vec (util.split-lines subject)]
    (cond
      [(string.eq name "unroll-body")
        (AnalyzerResult true (window-unroll-body (& lines)))]
      [(string.eq name "labeled-block")
        (AnalyzerResult true (window-labeled-block (& lines) arg))]
      [(string.eq name "seh-endproc")
        (AnalyzerResult true (window-seh-endproc (& lines)))]
      [(string.eq name "fast-self-loop")
        (AnalyzerResult true (window-fast-self-loop (& lines) arg))]
      [(string.eq name "fast-region")
        (AnalyzerResult true (window-fast-region (& lines) arg))]
      [(string.eq name "after")
        (AnalyzerResult true (window-after (& lines) arg))]
      [(string.eq name "symbol")
        (AnalyzerResult true (window-symbol (& lines) arg))]
      [(string.eq name "from")
        (AnalyzerResult true (window-from (& lines) arg))]
      [(string.eq name "ranges")
        (AnalyzerResult true (window-ranges (& lines) arg))]
      [(string.eq name "block-after")
        (AnalyzerResult true (window-block-after (& lines) arg))]
      [(string.eq name "call-args")
        (AnalyzerResult true (window-call-args (& lines) arg))]
      [(string.eq name "tl-code")
        (AnalyzerResult true (window-tl-code (& lines)))]
      [else (AnalyzerResult false "")])))