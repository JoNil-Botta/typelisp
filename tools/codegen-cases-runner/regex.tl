;; POSIX Extended Regular Expression (ERE) engine for codegen-cases-runner.
;; Supports anchors (^, $), '.', '[...]' / '[^...]' with POSIX classes
;; ([:space:], [:blank:], [:digit:], [:xdigit:], [:alpha:], [:alnum:],
;; [:lower:], [:upper:], [:print:], [:graph:], [:punct:], [:cntrl:]),
;; alternation '|', grouping '(...)' with capture group 1, quantifiers
;; (*, +, ?, {m}, {m,}, {m,n}), backslash escapes, and case-insensitive mode.
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as ivec)
(import util)

;; NFA instruction opcodes.
(define op-char : i64
  1)
(define op-any : i64
  2)
(define op-cclass : i64
  3)
(define op-bol : i64
  4)
(define op-eol : i64
  5)
(define op-split : i64
  6)
(define op-jmp : i64
  7)
(define op-save : i64
  8)
(define op-match : i64
  9)

(defstruct CharClass
  (w0 u64)
  (w1 u64)
  (w2 u64)
  (w3 u64))

(defstruct RegexInst
  (op i64)
  (a i64)
  (b i64))

(import (vector.vector CharClass core) as ccvec)
(import (vector.vector RegexInst core) as instvec)

(defstruct RegexProg
  (ok bool)
  (case-insensitive bool)
  (anchored-bol bool)
  (insts instvec.Vec)
  (classes ccvec.Vec))

(defstruct RegexMatch
  (matched bool)
  (start i64)
  (end i64)
  (g1-ok bool)
  (g1-start i64)
  (g1-end i64))

(defstruct RegexCompiler
  (pat String)
  (len i64)
  (pos i64)
  (case-insensitive bool)
  (group-count i64)
  (ok bool)
  (insts instvec.Vec)
  (classes ccvec.Vec))

(define (cclass-empty) : CharClass
  (CharClass (cast 0 : u64) (cast 0 : u64) (cast 0 : u64) (cast 0 : u64)))

(define (cclass-set [cc : CharClass] [b : i64]) : CharClass
  (if (or (< b 0) (> b 255))
    cc
    (let
      [word : i64 (shr b 6)]
      [bit : u64 (shl (cast 1 : u64) (cast (bit-and b 63) : u64))]
      (cond
        [(= word 0) (CharClass (bit-or cc.w0 bit) cc.w1 cc.w2 cc.w3)]
        [(= word 1) (CharClass cc.w0 (bit-or cc.w1 bit) cc.w2 cc.w3)]
        [(= word 2) (CharClass cc.w0 cc.w1 (bit-or cc.w2 bit) cc.w3)]
        [else (CharClass cc.w0 cc.w1 cc.w2 (bit-or cc.w3 bit))]))))

(define (cclass-set-ci [cc : CharClass] [b : i64] [ci : bool]) : CharClass
  (let
    [c1 : CharClass (cclass-set cc b)]
    (if (not ci)
      c1
      (cond
        [(util.is-lower-byte? b) (cclass-set c1 (util.ascii-upper-byte b))]
        [(util.is-upper-byte? b) (cclass-set c1 (util.ascii-lower-byte b))]
        [else c1]))))

(define (cclass-invert [cc : CharClass]) : CharClass
  (CharClass (bit-not cc.w0) (bit-not cc.w1) (bit-not cc.w2) (bit-not cc.w3)))

(define (cclass-test [cc : CharClass] [b : i64]) : bool
  (if (or (< b 0) (> b 255))
    false
    (let
      [word : i64 (shr b 6)]
      [bit : u64 (shl (cast 1 : u64) (cast (bit-and b 63) : u64))]
      (cond
        [(= word 0) (!= (bit-and cc.w0 bit) (cast 0 : u64))]
        [(= word 1) (!= (bit-and cc.w1 bit) (cast 0 : u64))]
        [(= word 2) (!= (bit-and cc.w2 bit) (cast 0 : u64))]
        [else (!= (bit-and cc.w3 bit) (cast 0 : u64))]))))

(define (cclass-add-range [cc : CharClass] [lo : i64] [hi : i64] [ci : bool]) : CharClass
  (let
    [cur : CharClass cc]
    [b : i64 lo]
    (while (<= b hi)
      (set! cur (cclass-set-ci cur b ci))
      (set! b (+ b 1)))
    cur))

(define (cclass-add-posix [cc : CharClass] [name : (& name str)] [ci : bool]) : CharClass
  (cond
    [(string.eq name "space")
      (cclass-set
        (cclass-set
          (cclass-set (cclass-set (cclass-set (cclass-set cc 32) 9) 10) 11)
          12)
        13)]
    [(string.eq name "blank") (cclass-set (cclass-set cc 32) 9)]
    [(string.eq name "digit") (cclass-add-range cc 48 57 false)]
    [(string.eq name "xdigit")
      (cclass-add-range
        (cclass-add-range (cclass-add-range cc 48 57 false) 65 70 true)
        97
        102
        true)]
    [(string.eq name "lower") (cclass-add-range cc 97 122 ci)]
    [(string.eq name "upper") (cclass-add-range cc 65 90 ci)]
    [(string.eq name "alpha")
      (cclass-add-range (cclass-add-range cc 65 90 false) 97 122 false)]
    [(string.eq name "alnum")
      (cclass-add-range
        (cclass-add-range (cclass-add-range cc 48 57 false) 65 90 false)
        97
        122
        false)]
    [(string.eq name "print") (cclass-add-range cc 32 126 false)]
    [(string.eq name "graph") (cclass-add-range cc 33 126 false)]
    [(string.eq name "cntrl") (cclass-set (cclass-add-range cc 0 31 false) 127)]
    [(string.eq name "punct")
      (cclass-add-range
        (cclass-add-range
          (cclass-add-range (cclass-add-range cc 33 47 false) 58 64 false)
          91
          96
          false)
        123
        126
        false)]
    [else cc]))

(define (rc-emit! [rc : (&mut rc RegexCompiler)] [op : i64] [a : i64] [b : i64]) : i64
  (let
    [idx : i64 (instvec.len (& rc.insts))]
    (instvec.push-ref! (&mut rc.insts) (RegexInst op a b))
    idx))

(define (rc-emit-unit!
  [rc : (&mut rc RegexCompiler)]
  [op : i64]
  [a : i64]
  [b : i64]) : unit
  (instvec.push-ref! (&mut rc.insts) (RegexInst op a b)))

(define (rc-peek [rc : (& rc RegexCompiler)]) : i64
  (if (< rc.pos rc.len)
    (util.byte-at (& rc.pat) rc.pos)
    -1))

;; Clone instructions [from, to) appending to rc.insts and adjusting internal jumps.
(define (rc-clone-slice! [rc : (&mut rc RegexCompiler)] [from : i64] [to : i64]) : unit
  (let
    [base : i64 (instvec.len (& rc.insts))]
    [delta : i64 (- base from)]
    [i : i64 from]
    (while (< i to)
      (let
        [inst : RegexInst (instvec.get (& rc.insts) i (RegexInst 0 0 0))]
        (cond
          [(= inst.op op-jmp) (rc-emit-unit! rc op-jmp (+ inst.a delta) 0)]
          [(= inst.op op-split)
            (rc-emit-unit! rc op-split (+ inst.a delta) (+ inst.b delta))]
          [else (rc-emit-unit! rc inst.op inst.a inst.b)]))
      (set! i (+ i 1)))))

;; Parse '[...]' starting right after '['.
(define (rc-parse-cclass! [rc : (&mut rc RegexCompiler)]) : unit
  (let
    [neg : bool false]
    [cc : CharClass (cclass-empty)]
    [closed : bool false]
    [first : bool true]
    (when (= (rc-peek rc) 94) (set! neg true) (set! rc.pos (+ rc.pos 1)))
    (while (and (< rc.pos rc.len) (not closed))
      (let
        [ch : i64 (rc-peek rc)]
        (cond
          [(and (not first) (= ch 93))
            (set! rc.pos (+ rc.pos 1))
            (set! closed true)]
          [(and
              (= ch 91)
              (< (+ rc.pos 1) rc.len)
              (= (util.byte-at (& rc.pat) (+ rc.pos 1)) 58))
            ;; POSIX [:name:]
            (let
              [end-pos : i64
                (util.index-of-str-from (& rc.pat) ":]" (+ rc.pos 2))]
              (if (< end-pos 0)
                (begin
                  (set! cc (cclass-set-ci cc 91 rc.case-insensitive))
                  (set! rc.pos (+ rc.pos 1))
                  (set! first false))
                (let
                  [cname : String
                    (string.substring
                      (& rc.pat)
                      (+ rc.pos 2)
                      (- end-pos (+ rc.pos 2)))]
                  (set! cc (cclass-add-posix cc (& cname) rc.case-insensitive))
                  (set! rc.pos (+ end-pos 2))
                  (set! first false))))]
          [else
            (let
              [c1 : i64 ch]
              (set! rc.pos (+ rc.pos 1))
              (set! first false)
              (if (and
                (< (+ rc.pos 1) rc.len)
                (= (util.byte-at (& rc.pat) rc.pos) 45)
                (!= (util.byte-at (& rc.pat) (+ rc.pos 1)) 93))
                (let
                  [c2 : i64 (util.byte-at (& rc.pat) (+ rc.pos 1))]
                  (set! rc.pos (+ rc.pos 2))
                  (set! cc (cclass-add-range cc c1 c2 rc.case-insensitive)))
                (set! cc (cclass-set-ci cc c1 rc.case-insensitive))))])))
    (if (not closed)
      (set! rc.ok false)
      (let
        [final-cc : CharClass
          (if neg
            (cclass-invert cc)
            cc)]
        [cidx : i64 (ccvec.len (& rc.classes))]
        (ccvec.push-ref! (&mut rc.classes) final-cc)
        (rc-emit! rc op-cclass cidx 0)
        unit))))

;; Parse optional {m}, {m,}, {m,n} at rc.pos. Returns true if valid bound consumed.
(defstruct BoundResult
  (ok bool)
  (min-rep i64)
  (max-rep i64))

(define (rc-parse-bound! [rc : (&mut rc RegexCompiler)]) : BoundResult
  (let
    [saved : i64 rc.pos]
    (if (!= (rc-peek rc) 123)
      (BoundResult false 0 0)
      (begin
        (set! rc.pos (+ rc.pos 1))
        (let
          [m-start : i64 rc.pos]
          (while (and (< rc.pos rc.len) (util.is-digit-byte? (rc-peek rc)))
            (set! rc.pos (+ rc.pos 1)))
          (if (= rc.pos m-start)
            (begin
              (set! rc.pos saved)
              (BoundResult false 0 0))
            (let
              [m-str : String
                (string.substring (& rc.pat) m-start (- rc.pos m-start))]
              [m : i64 (util.parse-u64-strict (& m-str)).value]
              [ch : i64 (rc-peek rc)]
              (cond
                [(= ch 125)
                  (set! rc.pos (+ rc.pos 1))
                  (BoundResult true m m)]
                [(= ch 44)
                  (set! rc.pos (+ rc.pos 1))
                  (if (= (rc-peek rc) 125)
                    (begin
                      (set! rc.pos (+ rc.pos 1))
                      (BoundResult true m -1))
                    (let
                      [n-start : i64 rc.pos]
                      (while (and
                        (< rc.pos rc.len)
                        (util.is-digit-byte? (rc-peek rc)))
                        (set! rc.pos (+ rc.pos 1)))
                      (if (and (> rc.pos n-start) (= (rc-peek rc) 125))
                        (let
                          [n-str : String
                            (string.substring
                              (& rc.pat)
                              n-start
                              (- rc.pos n-start))]
                          [n-val : i64 (util.parse-u64-strict (& n-str)).value]
                          (set! rc.pos (+ rc.pos 1))
                          (if (< n-val m)
                            (begin
                              (set! rc.ok false)
                              (BoundResult false 0 0))
                            (BoundResult true m n-val)))
                        (begin
                          (set! rc.pos saved)
                          (BoundResult false 0 0)))))]
                [else
                  (set! rc.pos saved)
                  (BoundResult false 0 0)]))))))))

;; Apply quantifier (*, +, ?, {m,n}) to atom emitted at [atom-start, atom-end).
(define (rc-apply-quantifier! [rc : (&mut rc RegexCompiler)] [atom-start : i64]) : unit
  (let
    [atom-end : i64 (instvec.len (& rc.insts))]
    [ch : i64 (rc-peek rc)]
    (cond
      [(= ch 42)
        ;; atom* -> SPLIT(copy, end) [atom] JMP(split)
        ;; Rewrite by inserting SPLIT at atom-start? Easier: shift instructions up by 1!
        (set! rc.pos (+ rc.pos 1))
        (let
          [count : i64 (- atom-end atom-start)]
          (rc-emit! rc op-jmp atom-start 0)
          ;; Move [atom-start..atom-end+1) up by 1 so SPLIT sits at atom-start
          (rc-emit! rc op-jmp 0 0)
          (let
            [i : i64 (+ atom-end 1)]
            (while (> i atom-start)
              (let
                [prev : RegexInst
                  (instvec.get (& rc.insts) (- i 1) (RegexInst 0 0 0))]
                (cond
                  [(= prev.op op-jmp)
                    (instvec.set-ref!
                      (&mut rc.insts)
                      i
                      (RegexInst op-jmp (+ prev.a 1) 0))]
                  [(= prev.op op-split)
                    (instvec.set-ref!
                      (&mut rc.insts)
                      i
                      (RegexInst op-split (+ prev.a 1) (+ prev.b 1)))]
                  [else (instvec.set-ref! (&mut rc.insts) i prev)]))
              (set! i (- i 1))))
          ;; Fix back-jump at atom-end+1 to point to atom-start (the SPLIT)
          (instvec.set-ref!
            (&mut rc.insts)
            (+ atom-start count 1)
            (RegexInst op-jmp atom-start 0))
          (instvec.set-ref!
            (&mut rc.insts)
            atom-start
            (RegexInst op-split (+ atom-start 1) (+ atom-start count 2))))]
      [(= ch 43)
        ;; atom+ -> [atom] SPLIT(atom-start, after)
        (set! rc.pos (+ rc.pos 1))
        (let
          [after : i64 (+ (instvec.len (& rc.insts)) 1)]
          (rc-emit! rc op-split atom-start after)
          unit)]
      [(= ch 63)
        ;; atom? -> SPLIT(atom-start+1, after) [shifted atom]
        (set! rc.pos (+ rc.pos 1))
        (let
          [count : i64 (- atom-end atom-start)]
          (rc-emit! rc op-jmp 0 0)
          (let
            [i : i64 atom-end]
            (while (> i atom-start)
              (let
                [prev : RegexInst
                  (instvec.get (& rc.insts) (- i 1) (RegexInst 0 0 0))]
                (cond
                  [(= prev.op op-jmp)
                    (instvec.set-ref!
                      (&mut rc.insts)
                      i
                      (RegexInst op-jmp (+ prev.a 1) 0))]
                  [(= prev.op op-split)
                    (instvec.set-ref!
                      (&mut rc.insts)
                      i
                      (RegexInst op-split (+ prev.a 1) (+ prev.b 1)))]
                  [else (instvec.set-ref! (&mut rc.insts) i prev)]))
              (set! i (- i 1))))
          (instvec.set-ref!
            (&mut rc.insts)
            atom-start
            (RegexInst op-split (+ atom-start 1) (+ atom-start count 1))))]
      [(= ch 123)
        (let
          [b : BoundResult (rc-parse-bound! rc)]
          (when
            b.ok
            (let
              [min-r : i64 b.min-rep]
              [max-r : i64 b.max-rep]
              (cond
                [(and (= min-r 0) (= max-r 0))
                  ;; Drop atom by jumping over it (prefix jump)
                  (let
                    [count : i64 (- atom-end atom-start)]
                    (rc-emit! rc op-jmp 0 0)
                    (let
                      [i : i64 atom-end]
                      (while (> i atom-start)
                        (instvec.set-ref!
                          (&mut rc.insts)
                          i
                          (instvec.get (& rc.insts) (- i 1) (RegexInst 0 0 0)))
                        (set! i (- i 1))))
                    (instvec.set-ref!
                      (&mut rc.insts)
                      atom-start
                      (RegexInst op-jmp (+ atom-start count 1) 0)))]
                [(= min-r 0)
                  ;; First copy becomes optional; then emit max-r - 1 optional copies (or * if max-r < 0)
                  (if (< max-r 0)
                    ;; {0,} is '*'
                    (let
                      [count : i64 (- atom-end atom-start)]
                      (rc-emit! rc op-jmp atom-start 0)
                      (rc-emit! rc op-jmp 0 0)
                      (let
                        [i : i64 (+ atom-end 1)]
                        (while (> i atom-start)
                          (let
                            [prev : RegexInst
                              (instvec.get
                                (& rc.insts)
                                (- i 1)
                                (RegexInst 0 0 0))]
                            (cond
                              [(= prev.op op-jmp)
                                (instvec.set-ref!
                                  (&mut rc.insts)
                                  i
                                  (RegexInst op-jmp (+ prev.a 1) 0))]
                              [(= prev.op op-split)
                                (instvec.set-ref!
                                  (&mut rc.insts)
                                  i
                                  (RegexInst op-split (+ prev.a 1) (+ prev.b 1)))]
                              [else (instvec.set-ref! (&mut rc.insts) i prev)]))
                          (set! i (- i 1))))
                      (instvec.set-ref!
                        (&mut rc.insts)
                        (+ atom-start count 1)
                        (RegexInst op-jmp atom-start 0))
                      (instvec.set-ref!
                        (&mut rc.insts)
                        atom-start
                        (RegexInst
                          op-split
                          (+ atom-start 1)
                          (+ atom-start count 2))))
                    ;; {0,n}: wrap first copy in SPLIT, then emit n-1 optional copies
                    (let
                      [count : i64 (- atom-end atom-start)]
                      (rc-emit! rc op-jmp 0 0)
                      (let
                        [i : i64 atom-end]
                        (while (> i atom-start)
                          (let
                            [prev : RegexInst
                              (instvec.get
                                (& rc.insts)
                                (- i 1)
                                (RegexInst 0 0 0))]
                            (cond
                              [(= prev.op op-jmp)
                                (instvec.set-ref!
                                  (&mut rc.insts)
                                  i
                                  (RegexInst op-jmp (+ prev.a 1) 0))]
                              [(= prev.op op-split)
                                (instvec.set-ref!
                                  (&mut rc.insts)
                                  i
                                  (RegexInst op-split (+ prev.a 1) (+ prev.b 1)))]
                              [else (instvec.set-ref! (&mut rc.insts) i prev)]))
                          (set! i (- i 1))))
                      (instvec.set-ref!
                        (&mut rc.insts)
                        atom-start
                        (RegexInst
                          op-split
                          (+ atom-start 1)
                          (+ atom-start count 1)))
                      (let
                        [src-start : i64 (+ atom-start 1)]
                        [src-end : i64 (+ atom-start 1 count)]
                        [k : i64 1]
                        (while (< k max-r)
                          (let
                            [sp : i64 (rc-emit! rc op-split 0 0)]
                            (rc-clone-slice! rc src-start src-end)
                            (let
                              [after : i64 (instvec.len (& rc.insts))]
                              (instvec.set-ref!
                                (&mut rc.insts)
                                sp
                                (RegexInst op-split (+ sp 1) after))))
                          (set! k (+ k 1))))))]
                [else
                  ;; min-r >= 1: already have 1 copy at [atom-start, atom-end)
                  (let
                    [k : i64 1]
                    (while (< k min-r)
                      (rc-clone-slice! rc atom-start atom-end)
                      (set! k (+ k 1))))
                  (if (< max-r 0)
                    ;; {m,}: add atom* at the end
                    (let
                      [sp : i64 (rc-emit! rc op-split 0 0)]
                      (rc-clone-slice! rc atom-start atom-end)
                      (rc-emit! rc op-jmp sp 0)
                      (let
                        [after : i64 (instvec.len (& rc.insts))]
                        (instvec.set-ref!
                          (&mut rc.insts)
                          sp
                          (RegexInst op-split (+ sp 1) after))))
                    ;; {m,n}: add (n - m) optional copies
                    (let
                      [k : i64 min-r]
                      (while (< k max-r)
                        (let
                          [sp : i64 (rc-emit! rc op-split 0 0)]
                          (rc-clone-slice! rc atom-start atom-end)
                          (let
                            [after : i64 (instvec.len (& rc.insts))]
                            (instvec.set-ref!
                              (&mut rc.insts)
                              sp
                              (RegexInst op-split (+ sp 1) after))))
                        (set! k (+ k 1)))))]))))]
      [else unit])))

(define (rc-parse-atom! [rc : (&mut rc RegexCompiler)]) : bool
  (let
    [ch : i64 (rc-peek rc)]
    (cond
      [(or (< ch 0) (= ch 124) (= ch 41)) false]
      [else
        (let
          [atom-start : i64 (instvec.len (& rc.insts))]
          (cond
            [(= ch 94)
              (set! rc.pos (+ rc.pos 1))
              (rc-emit! rc op-bol 0 0)
              unit]
            [(= ch 36)
              (set! rc.pos (+ rc.pos 1))
              (rc-emit! rc op-eol 0 0)
              unit]
            [(= ch 46)
              (set! rc.pos (+ rc.pos 1))
              (rc-emit! rc op-any 0 0)
              unit]
            [(= ch 91)
              (set! rc.pos (+ rc.pos 1))
              (rc-parse-cclass! rc)]
            [(= ch 40)
              (set! rc.pos (+ rc.pos 1))
              (set! rc.group-count (+ rc.group-count 1))
              (let
                [gid : i64 rc.group-count]
                (when (= gid 1) (rc-emit-unit! rc op-save 2 0))
                (rc-parse-alt! rc)
                (if (= (rc-peek rc) 41)
                  (set! rc.pos (+ rc.pos 1))
                  (set! rc.ok false))
                (when (= gid 1) (rc-emit-unit! rc op-save 3 0))
                unit)]
            [(= ch 92)
              (set! rc.pos (+ rc.pos 1))
              (if (< rc.pos rc.len)
                (let
                  [esc : i64 (rc-peek rc)]
                  [val : i64
                    (if rc.case-insensitive
                      (util.ascii-lower-byte esc)
                      esc)]
                  (set! rc.pos (+ rc.pos 1))
                  (rc-emit! rc op-char val 0)
                  unit)
                (begin
                  (set! rc.ok false)
                  unit))]
            [else
              (let
                [val : i64
                  (if rc.case-insensitive
                    (util.ascii-lower-byte ch)
                    ch)]
                (set! rc.pos (+ rc.pos 1))
                (rc-emit! rc op-char val 0)
                unit)])
          (when rc.ok (rc-apply-quantifier! rc atom-start))
          true)])))

(define (rc-parse-concat! [rc : (&mut rc RegexCompiler)]) : unit
  (let
    [cont : bool true]
    (while (and rc.ok cont)
      (set! cont (rc-parse-atom! rc)))))

(define (rc-parse-alt! [rc : (&mut rc RegexCompiler)]) : unit
  (let
    [first-start : i64 (instvec.len (& rc.insts))]
    (rc-parse-concat! rc)
    (while (and rc.ok (= (rc-peek rc) 124))
      (set! rc.pos (+ rc.pos 1))
      ;; Wrap existing branch [first-start..mid) with SPLIT at first-start, JMP at end of branch 1.
      (let
        [mid : i64 (instvec.len (& rc.insts))]
        (rc-emit! rc op-jmp 0 0)
        ;; Shift [first-start..mid] up by 1 to make room for SPLIT at first-start.
        (rc-emit! rc op-jmp 0 0)
        (let
          [i : i64 (+ mid 1)]
          (while (> i first-start)
            (let
              [prev : RegexInst
                (instvec.get (& rc.insts) (- i 1) (RegexInst 0 0 0))]
              (cond
                [(= prev.op op-jmp)
                  (instvec.set-ref!
                    (&mut rc.insts)
                    i
                    (RegexInst op-jmp (+ prev.a 1) 0))]
                [(= prev.op op-split)
                  (instvec.set-ref!
                    (&mut rc.insts)
                    i
                    (RegexInst op-split (+ prev.a 1) (+ prev.b 1)))]
                [else (instvec.set-ref! (&mut rc.insts) i prev)]))
            (set! i (- i 1))))
        (let
          [jmp-pos : i64 (+ mid 1)]
          [alt-start : i64 (+ mid 2)]
          (instvec.set-ref!
            (&mut rc.insts)
            first-start
            (RegexInst op-split (+ first-start 1) alt-start))
          (rc-parse-concat! rc)
          (let
            [after : i64 (instvec.len (& rc.insts))]
            (instvec.set-ref!
              (&mut rc.insts)
              jmp-pos
              (RegexInst op-jmp after 0))))))))

(define (regex-compile [pattern : (& pattern str)] [case-insensitive : bool]) : RegexProg
  (let
    [rc : RegexCompiler
      (RegexCompiler
        (string.copy pattern)
        (string.string-length pattern)
        0
        case-insensitive
        0
        true
        (instvec.new)
        (ccvec.new))]
    (rc-parse-alt! (&mut rc))
    (when (< rc.pos rc.len) (set! rc.ok false))
    (rc-emit! (&mut rc) op-match 0 0)
    (let
      [anchored : bool
        (and
          rc.ok
          (> (instvec.len (& rc.insts)) 0)
          (= (instvec.get (& rc.insts) 0 (RegexInst 0 0 0)).op op-bol))]
      (RegexProg rc.ok case-insensitive anchored rc.insts rc.classes))))

;; Fast single-pass boolean match on one line (no capture tracking needed).
(define (vm-add-bool-state!
  [prog : (& prog RegexProg)]
  [list : (&mut list ivec.Vec)]
  [seen : (&mut seen (__tl_dyn-array i64))]
  [gen : i64]
  [pc : i64]
  [pos : i64]
  [line-len : i64]) : bool
  (if (= (array-ref seen pc) gen)
    false
    (begin
      (set! (array-ref seen pc) gen)
      (let
        [inst : RegexInst (instvec.get (& prog.insts) pc (RegexInst 0 0 0))]
        (cond
          [(= inst.op op-match) true]
          [(= inst.op op-jmp)
            (vm-add-bool-state! prog list seen gen inst.a pos line-len)]
          [(= inst.op op-split)
            (if (vm-add-bool-state! prog list seen gen inst.a pos line-len)
              true
              (vm-add-bool-state! prog list seen gen inst.b pos line-len))]
          [(= inst.op op-save)
            (vm-add-bool-state! prog list seen gen (+ pc 1) pos line-len)]
          [(= inst.op op-bol)
            (if (= pos 0)
              (vm-add-bool-state! prog list seen gen (+ pc 1) pos line-len)
              false)]
          [(= inst.op op-eol)
            (if (= pos line-len)
              (vm-add-bool-state! prog list seen gen (+ pc 1) pos line-len)
              false)]
          [else
            (ivec.push-ref! list pc)
            false])))))

(define (regex-match-line? [prog : (& prog RegexProg)] [line : (& line str)]) : bool
  (if (not prog.ok)
    false
    (let
      [ninst : i64 (instvec.len (& prog.insts))]
      [llen : i64 (string.string-length line)]
      [seen : (__tl_dyn-array i64) (__tl_make-array i64 ninst)]
      [curr : ivec.Vec (ivec.with-capacity 16)]
      [next : ivec.Vec (ivec.with-capacity 16)]
      [gen : i64 1]
      [pos : i64 0]
      [matched : bool false]
      (if (vm-add-bool-state! prog (&mut curr) (&mut seen) gen 0 0 llen)
        true
        (begin
          (while (and (not matched) (< pos llen))
            (let
              [raw-b : i64 (util.byte-at line pos)]
              [cmp-b : i64
                (if prog.case-insensitive
                  (util.ascii-lower-byte raw-b)
                  raw-b)]
              [next-pos : i64 (+ pos 1)]
              [clen : i64 (ivec.len (& curr))]
              [k : i64 0]
              (set! gen (+ gen 1))
              (set! next (ivec.with-capacity 16))
              (while (and (not matched) (< k clen))
                (let
                  [pc : i64 (ivec.get (& curr) k 0)]
                  [inst : RegexInst
                    (instvec.get (& prog.insts) pc (RegexInst 0 0 0))]
                  [step-ok : bool
                    (cond
                      [(= inst.op op-char) (= cmp-b inst.a)]
                      [(= inst.op op-any) true]
                      [(= inst.op op-cclass)
                        (cclass-test
                          (ccvec.get (& prog.classes) inst.a (cclass-empty))
                          raw-b)]
                      [else false])]
                  (when
                    step-ok
                    (when
                      (vm-add-bool-state!
                        prog
                        (&mut next)
                        (&mut seen)
                        gen
                        (+ pc 1)
                        next-pos
                        llen)
                      (set! matched true))))
                (set! k (+ k 1)))
              (when
                (and (not matched) (not prog.anchored-bol))
                (when
                  (vm-add-bool-state!
                    prog
                    (&mut next)
                    (&mut seen)
                    gen
                    0
                    next-pos
                    llen)
                  (set! matched true)))
              (set! curr next)
              (set! pos next-pos)
              (when
                (and (not matched) prog.anchored-bol (= (ivec.len (& curr)) 0))
                (set! pos llen))))
          matched)))))

;; Capture-aware PikeVM anchored at start-pos, finding the longest match from start-pos.
(defstruct CapThread
  (pc i64)
  (g1s i64)
  (g1e i64))

(import (vector.vector CapThread core) as ctvec)

(defstruct CapBest
  (matched bool)
  (end i64)
  (g1s i64)
  (g1e i64))

(define (vm-add-cap-state!
  [prog : (& prog RegexProg)]
  [list : (&mut list ctvec.Vec)]
  [seen : (&mut seen (__tl_dyn-array i64))]
  [gen : i64]
  [pc : i64]
  [g1s : i64]
  [g1e : i64]
  [pos : i64]
  [line-len : i64]
  [best : (&mut best CapBest)]) : unit
  (if (= (array-ref seen pc) gen)
    unit
    (begin
      (set! (array-ref seen pc) gen)
      (let
        [inst : RegexInst (instvec.get (& prog.insts) pc (RegexInst 0 0 0))]
        (cond
          [(= inst.op op-match)
            (when
              (or (not best.matched) (> pos best.end))
              (set! best.matched true)
              (set! best.end pos)
              (set! best.g1s g1s)
              (set! best.g1e g1e))]
          [(= inst.op op-jmp)
            (vm-add-cap-state!
              prog
              list
              seen
              gen
              inst.a
              g1s
              g1e
              pos
              line-len
              best)]
          [(= inst.op op-split)
            (vm-add-cap-state!
              prog
              list
              seen
              gen
              inst.a
              g1s
              g1e
              pos
              line-len
              best)
            (vm-add-cap-state!
              prog
              list
              seen
              gen
              inst.b
              g1s
              g1e
              pos
              line-len
              best)]
          [(= inst.op op-save)
            (cond
              [(= inst.a 2)
                (vm-add-cap-state!
                  prog
                  list
                  seen
                  gen
                  (+ pc 1)
                  pos
                  g1e
                  pos
                  line-len
                  best)]
              [(= inst.a 3)
                (vm-add-cap-state!
                  prog
                  list
                  seen
                  gen
                  (+ pc 1)
                  g1s
                  pos
                  pos
                  line-len
                  best)]
              [else
                (vm-add-cap-state!
                  prog
                  list
                  seen
                  gen
                  (+ pc 1)
                  g1s
                  g1e
                  pos
                  line-len
                  best)])]
          [(= inst.op op-bol)
            (when
              (= pos 0)
              (vm-add-cap-state!
                prog
                list
                seen
                gen
                (+ pc 1)
                g1s
                g1e
                pos
                line-len
                best))]
          [(= inst.op op-eol)
            (when
              (= pos line-len)
              (vm-add-cap-state!
                prog
                list
                seen
                gen
                (+ pc 1)
                g1s
                g1e
                pos
                line-len
                best))]
          [else (ctvec.push-ref! list (CapThread pc g1s g1e))])))))

(define (regex-match-from
  [prog : (& prog RegexProg)]
  [line : (& line str)]
  [start-pos : i64]) : RegexMatch
  (let
    [ninst : i64 (instvec.len (& prog.insts))]
    [llen : i64 (string.string-length line)]
    [seen : (__tl_dyn-array i64) (__tl_make-array i64 ninst)]
    [curr : ctvec.Vec (ctvec.with-capacity 16)]
    [next : ctvec.Vec (ctvec.with-capacity 16)]
    [best : CapBest (CapBest false -1 -1 -1)]
    [gen : i64 1]
    [pos : i64 start-pos]
    (vm-add-cap-state!
      prog
      (&mut curr)
      (&mut seen)
      gen
      0
      -1
      -1
      pos
      llen
      (&mut best))
    (while (and (< pos llen) (> (ctvec.len (& curr)) 0))
      (let
        [raw-b : i64 (util.byte-at line pos)]
        [cmp-b : i64
          (if prog.case-insensitive
            (util.ascii-lower-byte raw-b)
            raw-b)]
        [next-pos : i64 (+ pos 1)]
        [clen : i64 (ctvec.len (& curr))]
        [k : i64 0]
        (set! gen (+ gen 1))
        (set! next (ctvec.with-capacity 16))
        (while (< k clen)
          (let
            [th : CapThread (ctvec.get (& curr) k (CapThread 0 -1 -1))]
            [inst : RegexInst
              (instvec.get (& prog.insts) th.pc (RegexInst 0 0 0))]
            [step-ok : bool
              (cond
                [(= inst.op op-char) (= cmp-b inst.a)]
                [(= inst.op op-any) true]
                [(= inst.op op-cclass)
                  (cclass-test
                    (ccvec.get (& prog.classes) inst.a (cclass-empty))
                    raw-b)]
                [else false])]
            (when
              step-ok
              (vm-add-cap-state!
                prog
                (&mut next)
                (&mut seen)
                gen
                (+ th.pc 1)
                th.g1s
                th.g1e
                next-pos
                llen
                (&mut best))))
          (set! k (+ k 1)))
        (set! curr next)
        (set! pos next-pos)))
    (RegexMatch
      best.matched
      start-pos
      best.end
      (and best.matched (>= best.g1s 0) (>= best.g1e best.g1s))
      best.g1s
      best.g1e)))

;; Leftmost-longest match on a single line, starting search at from-pos.
(define (regex-find-line-from
  [prog : (& prog RegexProg)]
  [line : (& line str)]
  [from-pos : i64]) : RegexMatch
  (if (not prog.ok)
    (RegexMatch false -1 -1 false -1 -1)
    (let
      [llen : i64 (string.string-length line)]
      [limit : i64
        (if prog.anchored-bol
          (if (= from-pos 0)
            0
            -1)
          llen)]
      [s : i64 from-pos]
      [result : RegexMatch (RegexMatch false -1 -1 false -1 -1)]
      (while (and (not result.matched) (<= s limit))
        (let
          [m : RegexMatch (regex-match-from prog line s)]
          (if m.matched
            (set! result m)
            (set! s (+ s 1)))))
      result)))

(define (regex-find-line [prog : (& prog RegexProg)] [line : (& line str)]) : RegexMatch
  (regex-find-line-from prog line 0))

;; Match any line in text (grep -E semantics).
(define (regex-match-text?
  [pattern : (& pattern str)]
  [text : (& text str)]
  [case-insensitive : bool]) : bool
  (let
    [prog : RegexProg (regex-compile pattern case-insensitive)]
    (if (not prog.ok)
      false
      (let
        [n : i64 (string.string-length text)]
        [start : i64 0]
        [i : i64 0]
        [found : bool false]
        (while (and (not found) (< i n))
          (if (= (util.byte-at text i) 10)
            (begin
              (let
                [line : String (string.substring text start (- i start))]
                (when (regex-match-line? (& prog) (& line)) (set! found true)))
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! i (+ i 1))))
        (when
          (and (not found) (< start n))
          (let
            [line : String (string.substring text start (- n start))]
            (when (regex-match-line? (& prog) (& line)) (set! found true))))
        found))))

;; Count matching lines in text (grep -E | wc -l semantics).
(define (regex-count-lines
  [pattern : (& pattern str)]
  [text : (& text str)]
  [case-insensitive : bool]) : i64
  (let
    [prog : RegexProg (regex-compile pattern case-insensitive)]
    (if (not prog.ok)
      0
      (let
        [n : i64 (string.string-length text)]
        [start : i64 0]
        [i : i64 0]
        [count : i64 0]
        (while (< i n)
          (if (= (util.byte-at text i) 10)
            (begin
              (let
                [line : String (string.substring text start (- i start))]
                (when
                  (regex-match-line? (& prog) (& line))
                  (set! count (+ count 1))))
              (set! start (+ i 1))
              (set! i (+ i 1)))
            (set! i (+ i 1))))
        (when
          (< start n)
          (let
            [line : String (string.substring text start (- n start))]
            (when
              (regex-match-line? (& prog) (& line))
              (set! count (+ count 1)))))
        count))))