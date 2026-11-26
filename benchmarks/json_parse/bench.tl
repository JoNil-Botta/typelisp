;# benchmarks/json_parse/bench.tl - recursive-descent JSON parser into flat arena.
;#
;# Equivalent to benchmarks/json_parse/baseline.c. Deterministically generates a
;# ~64 KB nested JSON document containing objects, arrays, escaped strings
;# (including \", \\, \n, \t, \r, \/, \uXXXX), positive/negative/fractional/
;# scientific numbers, booleans, and null. Each round stamps the round counter
;# into the document header, parses the full buffer by recursive descent into a
;# flat pre-allocated arena node pool (linked sibling chains), asserts clean
;# parse status, and recursively walks the arena tree to fold a wrapping 64-bit
;# FNV-1a checksum. Record count and round count are runtime CLI arguments.
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64 core) as i64vec)
(import (vector.vector u8 core) as u8vec)

(define jp-hash-basis : u64
  0xcbf29ce484222325)
(define jp-hash-prime : u64
  1099511628211)
(define jp-kind-null : i64
  0)
(define jp-kind-bool : i64
  1)
(define jp-kind-num : i64
  2)
(define jp-kind-str : i64
  3)
(define jp-kind-arr : i64
  4)
(define jp-kind-obj : i64
  5)

(defstruct ParserState
  (pos i64)
  (len i64)
  (node-count i64)
  (max-nodes i64)
  (err i64))

(define (jp-mix [h : u64] [v : u64]) : u64
  (* (bit-xor h v) jp-hash-prime))

(define (jp-next-rng [state : u64]) : u64
  (+ (* state 6364136223846793005) 1442695040888963407))

(define (jp-rng-draw [state : u64]) : i64
  (cast (bit-and (shr state 33) 2147483647) : i64))

(define (jp-buf-push-str [buf : (&mut buf u8vec.Vec)] [s : (& s str)]) : unit
  (let
    [n : i64 (string.string-length s)]
    [i : i64 0]
    (while (< i n)
      (u8vec.push-ref! buf (cast (string.string-ref s i) : u8))
      (set! i (+ i 1)))))

(define (jp-buf-push-u8 [buf : (&mut buf u8vec.Vec)] [b : i64]) : unit
  (u8vec.push-ref! buf (cast b : u8)))

(define (jp-buf-push-i64 [buf : (&mut buf u8vec.Vec)] [val : i64]) : unit
  (let
    [v : i64 val]
    [digits : (Array u8 24) (make-array u8 24)]
    [count : i64 0]
    (when (< v 0) (jp-buf-push-u8 buf 45) (set! v (neg v)))
    (if (= v 0)
      (jp-buf-push-u8 buf 48)
      (begin
        (while (> v 0)
          (set! (array-ref digits count) (cast (+ 48 (% v 10)) : u8))
          (set! v (/ v 10))
          (set! count (+ count 1)))
        (while (> count 0)
          (set! count (- count 1))
          (u8vec.push-ref! buf (array-ref digits count)))))))

(define (jp-build-corpus [buf : (&mut buf u8vec.Vec)] [records : i64]) : i64
  (let
    [words : (Array String 8)
      (array
        "alpha"
        "beta\\nline"
        "gamma\\\"q\\\""
        "delta\\t1"
        "eps\\u0041z"
        "zeta\\/path"
        "eta\\\\slash"
        "theta\\r0")]
    [state : u64 20261127]
    [ver-pos : i64 0]
    [i : i64 0]
    (jp-buf-push-str buf "{\"meta\":{\"ver\":")
    (set! ver-pos (u8vec.len (& buf)))
    (jp-buf-push-str
      buf
      "0000,\"ok\":true,\"empty\":null,\"label\":\"batch-\\\"alpha\\\"\\\\0\\n\\t\"},\n\"items\":[")
    (while (< i records)
      (when (> i 0) (jp-buf-push-str buf ",\n"))
      (set! state (jp-next-rng state))
      (let
        [id : i64 (+ (* i 17) (% (jp-rng-draw state) 13))]
        [sign-neg : bool (= (bit-and (jp-rng-draw state) 1) 1)]
        [w0 : i64 (% (jp-rng-draw state) 8)]
        [w1 : i64 0]
        [score : i64 0]
        [frac : i64 0]
        [exp-val : i64 0]
        [active : bool false]
        (set! state (jp-next-rng state))
        (set! w1 (% (jp-rng-draw state) 8))
        (set! score (% (jp-rng-draw state) 9973))
        (set! state (jp-next-rng state))
        (set! frac (% (jp-rng-draw state) 1000))
        (set! exp-val (- (% (jp-rng-draw state) 7) 3))
        (set! active (= (bit-and (jp-rng-draw state) 3) 0))
        (jp-buf-push-str buf "  {\"id\":")
        (jp-buf-push-i64 buf id)
        (jp-buf-push-str buf ",\"name\":\"")
        (jp-buf-push-str buf (array-ref words w0))
        (jp-buf-push-str buf "\",\"score\":")
        (when sign-neg (jp-buf-push-u8 buf 45))
        (jp-buf-push-i64 buf score)
        (jp-buf-push-u8 buf 46)
        (jp-buf-push-i64 buf frac)
        (when
          (!= exp-val 0)
          (jp-buf-push-u8 buf 101)
          (jp-buf-push-i64 buf exp-val))
        (jp-buf-push-str buf ",\"active\":")
        (if active
          (jp-buf-push-str buf "true")
          (jp-buf-push-str buf "false"))
        (jp-buf-push-str buf ",\"opt\":")
        (if (= (% i 3) 0)
          (jp-buf-push-str buf "null")
          (begin
            (jp-buf-push-u8 buf 34)
            (jp-buf-push-str buf (array-ref words w1))
            (jp-buf-push-u8 buf 34)))
        (jp-buf-push-str buf ",\"nums\":[")
        (jp-buf-push-i64 buf (- id 50))
        (jp-buf-push-u8 buf 44)
        (jp-buf-push-i64 buf (+ score 1))
        (jp-buf-push-u8 buf 44)
        (jp-buf-push-i64 buf (neg frac))
        (jp-buf-push-str buf "],\"meta\":{\"a\":")
        (if (= (% i 2) 0)
          (jp-buf-push-str buf "true")
          (jp-buf-push-str buf "false"))
        (jp-buf-push-str buf ",\"tags\":[\"")
        (jp-buf-push-str buf (array-ref words (% (+ w0 1) 8)))
        (jp-buf-push-str buf "\",\"")
        (jp-buf-push-str buf (array-ref words (% (+ w1 3) 8)))
        (jp-buf-push-str buf "\"]}}"))
      (set! i (+ i 1)))
    (jp-buf-push-str buf "]}\n")
    ver-pos))

(define (jp-zero-i64-vec [n : i64]) : i64vec.Vec
  (let
    [v : i64vec.Vec (i64vec.with-capacity n)]
    [i : i64 0]
    (while (< i n)
      (i64vec.push! v 0)
      (set! i (+ i 1)))
    v))

(define (jp-alloc-node
  [st : (&mut st ParserState)]
  [kinds : (&mut kinds (Slice i64))]
  [vals : (&mut vals (Slice i64))]
  [keys : (&mut keys (Slice i64))]
  [firsts : (&mut firsts (Slice i64))]
  [nexts : (&mut nexts (Slice i64))]
  [kind : i64]
  [val : i64]) : i64
  (let
    [idx : i64 st.node-count]
    (if (>= idx st.max-nodes)
      (begin
        (set! st.err 1)
        -1)
      (begin
        (set! st.node-count (+ idx 1))
        (set! (array-ref kinds idx) kind)
        (set! (array-ref vals idx) val)
        (set! (array-ref keys idx) 0)
        (set! (array-ref firsts idx) -1)
        (set! (array-ref nexts idx) -1)
        idx))))

(define (jp-skip-ws [src : (& src (Slice u8))] [st : (&mut st ParserState)]) : unit
  (let
    [p : i64 st.pos]
    [n : i64 st.len]
    [done : bool false]
    (while (and (< p n) (not done))
      (let
        [c : i64 (cast (array-ref src p) : i64)]
        (if (or (= c 32) (= c 10) (= c 13) (= c 9))
          (set! p (+ p 1))
          (set! done true))))
    (set! st.pos p)))

(define (jp-hex-digit [c : i64]) : i64
  (cond
    [(and (>= c 48) (<= c 57)) (- c 48)]
    [(and (>= c 65) (<= c 70)) (+ (- c 65) 10)]
    [(and (>= c 97) (<= c 102)) (+ (- c 97) 10)]
    [else -1]))

;; Parse a JSON string starting at the opening `"`, folding unescaped bytes
;; into a 64-bit FNV-1a hash returned as i64.
(define (jp-parse-string-hash
  [src : (& src (Slice u8))]
  [st : (&mut st ParserState)]) : i64
  (let
    [p : i64 st.pos]
    [n : i64 st.len]
    [h : u64 jp-hash-basis]
    [count : i64 0]
    [done : bool false]
    (if (or (>= p n) (!= (cast (array-ref src p) : i64) 34))
      (begin
        (set! st.err 2)
        0)
      (begin
        (set! p (+ p 1))
        (while (and (< p n) (not done))
          (let
            [c : i64 (cast (array-ref src p) : i64)]
            (cond
              [(= c 34)
                (set! p (+ p 1))
                (set! done true)]
              [(= c 92)
                (set! p (+ p 1))
                (if (>= p n)
                  (begin
                    (set! st.err 3)
                    (set! done true))
                  (let
                    [esc : i64 (cast (array-ref src p) : i64)]
                    (set! p (+ p 1))
                    (cond
                      [(= esc 34)
                        (set! h (jp-mix h 34))
                        (set! count (+ count 1))]
                      [(= esc 92)
                        (set! h (jp-mix h 92))
                        (set! count (+ count 1))]
                      [(= esc 47)
                        (set! h (jp-mix h 47))
                        (set! count (+ count 1))]
                      [(= esc 98)
                        (set! h (jp-mix h 8))
                        (set! count (+ count 1))]
                      [(= esc 102)
                        (set! h (jp-mix h 12))
                        (set! count (+ count 1))]
                      [(= esc 110)
                        (set! h (jp-mix h 10))
                        (set! count (+ count 1))]
                      [(= esc 114)
                        (set! h (jp-mix h 13))
                        (set! count (+ count 1))]
                      [(= esc 116)
                        (set! h (jp-mix h 9))
                        (set! count (+ count 1))]
                      [(= esc 117)
                        (if (> (+ p 4) n)
                          (begin
                            (set! st.err 4)
                            (set! done true))
                          (let
                            [d0 : i64
                              (jp-hex-digit (cast (array-ref src p) : i64))]
                            [d1 : i64
                              (jp-hex-digit
                                (cast (array-ref src (+ p 1)) : i64))]
                            [d2 : i64
                              (jp-hex-digit
                                (cast (array-ref src (+ p 2)) : i64))]
                            [d3 : i64
                              (jp-hex-digit
                                (cast (array-ref src (+ p 3)) : i64))]
                            (if (or (< d0 0) (< d1 0) (< d2 0) (< d3 0))
                              (begin
                                (set! st.err 5)
                                (set! done true))
                              (let
                                [cp : i64
                                  (bit-or
                                    (shl d0 12)
                                    (bit-or (shl d1 8) (bit-or (shl d2 4) d3)))]
                                (set! p (+ p 4))
                                (set! h (jp-mix h (cast cp : u64)))
                                (set! count (+ count 1))))))]
                      [else
                        (set! st.err 6)
                        (set! done true)])))]
              [else
                (set! p (+ p 1))
                (set! h (jp-mix h (cast c : u64)))
                (set! count (+ count 1))])))
        (unless done (set! st.err 7))
        (set! st.pos p)
        (cast (jp-mix h (cast count : u64)) : i64)))))

;; Parse a JSON number into a deterministic folded i64 value (exact parity).
(define (jp-parse-number
  [src : (& src (Slice u8))]
  [st : (&mut st ParserState)]) : i64
  (let
    [p : i64 st.pos]
    [n : i64 st.len]
    [neg-sign : bool false]
    [int-part : i64 0]
    [frac-part : i64 0]
    [frac-digits : i64 0]
    [exp-neg : bool false]
    [exp-part : i64 0]
    [digits : i64 0]
    (when
      (and (< p n) (= (cast (array-ref src p) : i64) 45))
      (set! neg-sign true)
      (set! p (+ p 1)))
    (let
      [scan-int : bool true]
      (while (and (< p n) scan-int)
        (let
          [c : i64 (cast (array-ref src p) : i64)]
          (if (and (>= c 48) (<= c 57))
            (begin
              (set! int-part (+ (* int-part 10) (- c 48)))
              (set! digits (+ digits 1))
              (set! p (+ p 1)))
            (set! scan-int false)))))
    (when (= digits 0) (set! st.err 8))
    (when
      (and (< p n) (= (cast (array-ref src p) : i64) 46))
      (set! p (+ p 1))
      (let
        [scan-frac : bool true]
        (while (and (< p n) scan-frac)
          (let
            [c : i64 (cast (array-ref src p) : i64)]
            (if (and (>= c 48) (<= c 57))
              (begin
                (set! frac-part (+ (* frac-part 10) (- c 48)))
                (set! frac-digits (+ frac-digits 1))
                (set! p (+ p 1)))
              (set! scan-frac false))))))
    (when
      (and
        (< p n)
        (or
          (= (cast (array-ref src p) : i64) 101)
          (= (cast (array-ref src p) : i64) 69)))
      (set! p (+ p 1))
      (when
        (< p n)
        (let
          [sc : i64 (cast (array-ref src p) : i64)]
          (cond
            [(= sc 45)
              (set! exp-neg true)
              (set! p (+ p 1))]
            [(= sc 43) (set! p (+ p 1))]
            [else unit])))
      (let
        [scan-exp : bool true]
        (while (and (< p n) scan-exp)
          (let
            [c : i64 (cast (array-ref src p) : i64)]
            (if (and (>= c 48) (<= c 57))
              (begin
                (set! exp-part (+ (* exp-part 10) (- c 48)))
                (set! p (+ p 1)))
              (set! scan-exp false))))))
    (set! st.pos p)
    (let
      [signed-int : i64
        (if neg-sign
          (neg int-part)
          int-part)]
      [signed-exp : i64
        (if exp-neg
          (neg exp-part)
          exp-part)]
      (+
        (* signed-int 1000003)
        (+ (* frac-part 1009) (+ (* frac-digits 37) signed-exp))))))

(define (jp-parse-array
  [src : (& src (Slice u8))]
  [st : (&mut st ParserState)]
  [kinds : (&mut kinds (Slice i64))]
  [vals : (&mut vals (Slice i64))]
  [keys : (&mut keys (Slice i64))]
  [firsts : (&mut firsts (Slice i64))]
  [nexts : (&mut nexts (Slice i64))]) : i64
  (set! st.pos (+ st.pos 1))
  (let
    [node : i64 (jp-alloc-node st kinds vals keys firsts nexts jp-kind-arr 0)]
    [head : i64 -1]
    [tail : i64 -1]
    [count : i64 0]
    (when (< node 0) (return -1))
    (jp-skip-ws src st)
    (if (and (< st.pos st.len) (= (cast (array-ref src st.pos) : i64) 93))
      (begin
        (set! st.pos (+ st.pos 1))
        node)
      (let
        [cont : bool true]
        (while (and cont (= st.err 0))
          (let
            [child : i64 (jp-parse-value src st kinds vals keys firsts nexts)]
            (when (< child 0) (set! cont false))
            (when
              cont
              (if (< head 0)
                (set! head child)
                (set! (array-ref nexts tail) child))
              (set! tail child)
              (set! count (+ count 1))
              (jp-skip-ws src st)
              (if (>= st.pos st.len)
                (begin
                  (set! st.err 9)
                  (set! cont false))
                (let
                  [sep : i64 (cast (array-ref src st.pos) : i64)]
                  (cond
                    [(= sep 44) (set! st.pos (+ st.pos 1))]
                    [(= sep 93)
                      (set! st.pos (+ st.pos 1))
                      (set! cont false)]
                    [else
                      (set! st.err 10)
                      (set! cont false)]))))))
        (set! (array-ref firsts node) head)
        (set! (array-ref vals node) count)
        node))))

(define (jp-parse-object
  [src : (& src (Slice u8))]
  [st : (&mut st ParserState)]
  [kinds : (&mut kinds (Slice i64))]
  [vals : (&mut vals (Slice i64))]
  [keys : (&mut keys (Slice i64))]
  [firsts : (&mut firsts (Slice i64))]
  [nexts : (&mut nexts (Slice i64))]) : i64
  (set! st.pos (+ st.pos 1))
  (let
    [node : i64 (jp-alloc-node st kinds vals keys firsts nexts jp-kind-obj 0)]
    [head : i64 -1]
    [tail : i64 -1]
    [count : i64 0]
    (when (< node 0) (return -1))
    (jp-skip-ws src st)
    (if (and (< st.pos st.len) (= (cast (array-ref src st.pos) : i64) 125))
      (begin
        (set! st.pos (+ st.pos 1))
        node)
      (let
        [cont : bool true]
        (while (and cont (= st.err 0))
          (jp-skip-ws src st)
          (let
            [key-hash : i64 (jp-parse-string-hash src st)]
            (when (!= st.err 0) (set! cont false))
            (when
              cont
              (jp-skip-ws src st)
              (if (or
                (>= st.pos st.len)
                (!= (cast (array-ref src st.pos) : i64) 58))
                (begin
                  (set! st.err 11)
                  (set! cont false))
                (begin
                  (set! st.pos (+ st.pos 1))
                  (let
                    [child : i64
                      (jp-parse-value src st kinds vals keys firsts nexts)]
                    (if (< child 0)
                      (set! cont false)
                      (begin
                        (set! (array-ref keys child) key-hash)
                        (if (< head 0)
                          (set! head child)
                          (set! (array-ref nexts tail) child))
                        (set! tail child)
                        (set! count (+ count 1))
                        (jp-skip-ws src st)
                        (if (>= st.pos st.len)
                          (begin
                            (set! st.err 12)
                            (set! cont false))
                          (let
                            [sep : i64 (cast (array-ref src st.pos) : i64)]
                            (cond
                              [(= sep 44) (set! st.pos (+ st.pos 1))]
                              [(= sep 125)
                                (set! st.pos (+ st.pos 1))
                                (set! cont false)]
                              [else
                                (set! st.err 13)
                                (set! cont false)])))))))))))
        (set! (array-ref firsts node) head)
        (set! (array-ref vals node) count)
        node))))

(define (jp-parse-value
  [src : (& src (Slice u8))]
  [st : (&mut st ParserState)]
  [kinds : (&mut kinds (Slice i64))]
  [vals : (&mut vals (Slice i64))]
  [keys : (&mut keys (Slice i64))]
  [firsts : (&mut firsts (Slice i64))]
  [nexts : (&mut nexts (Slice i64))]) : i64
  (jp-skip-ws src st)
  (if (>= st.pos st.len)
    (begin
      (set! st.err 14)
      -1)
    (let
      [c : i64 (cast (array-ref src st.pos) : i64)]
      (cond
        [(= c 123) (jp-parse-object src st kinds vals keys firsts nexts)]
        [(= c 91) (jp-parse-array src st kinds vals keys firsts nexts)]
        [(= c 34)
          (let
            [sh : i64 (jp-parse-string-hash src st)]
            (if (!= st.err 0)
              -1
              (jp-alloc-node st kinds vals keys firsts nexts jp-kind-str sh)))]
        [(= c 116)
          (if (and
            (<= (+ st.pos 4) st.len)
            (= (cast (array-ref src (+ st.pos 1)) : i64) 114)
            (= (cast (array-ref src (+ st.pos 2)) : i64) 117)
            (= (cast (array-ref src (+ st.pos 3)) : i64) 101))
            (begin
              (set! st.pos (+ st.pos 4))
              (jp-alloc-node st kinds vals keys firsts nexts jp-kind-bool 1))
            (begin
              (set! st.err 15)
              -1))]
        [(= c 102)
          (if (and
            (<= (+ st.pos 5) st.len)
            (= (cast (array-ref src (+ st.pos 1)) : i64) 97)
            (= (cast (array-ref src (+ st.pos 2)) : i64) 108)
            (= (cast (array-ref src (+ st.pos 3)) : i64) 115)
            (= (cast (array-ref src (+ st.pos 4)) : i64) 101))
            (begin
              (set! st.pos (+ st.pos 5))
              (jp-alloc-node st kinds vals keys firsts nexts jp-kind-bool 0))
            (begin
              (set! st.err 16)
              -1))]
        [(= c 110)
          (if (and
            (<= (+ st.pos 4) st.len)
            (= (cast (array-ref src (+ st.pos 1)) : i64) 117)
            (= (cast (array-ref src (+ st.pos 2)) : i64) 108)
            (= (cast (array-ref src (+ st.pos 3)) : i64) 108))
            (begin
              (set! st.pos (+ st.pos 4))
              (jp-alloc-node st kinds vals keys firsts nexts jp-kind-null 0))
            (begin
              (set! st.err 17)
              -1))]
        [(or (= c 45) (and (>= c 48) (<= c 57)))
          (let
            [nv : i64 (jp-parse-number src st)]
            (if (!= st.err 0)
              -1
              (jp-alloc-node st kinds vals keys firsts nexts jp-kind-num nv)))]
        [else
          (set! st.err 18)
          -1]))))

(define (jp-sum-tree
  [kinds : (& kinds (Slice i64))]
  [vals : (& vals (Slice i64))]
  [keys : (& keys (Slice i64))]
  [firsts : (& firsts (Slice i64))]
  [nexts : (& nexts (Slice i64))]
  [idx : i64]
  [depth : i64]
  [acc : u64]) : u64
  (let
    [h : u64 (jp-mix acc (cast (array-ref kinds idx) : u64))]
    [child : i64 (array-ref firsts idx)]
    (set! h (jp-mix h (cast (array-ref vals idx) : u64)))
    (set! h (jp-mix h (cast (array-ref keys idx) : u64)))
    (set! h (jp-mix h (cast depth : u64)))
    (while (>= child 0)
      (set! h (jp-sum-tree kinds vals keys firsts nexts child (+ depth 1) h))
      (set! child (array-ref nexts child)))
    h))

(define (jp-bench [records : i64] [rounds : i64]) : u64
  (let
    [buf : u8vec.Vec (u8vec.with-capacity (* records 256))]
    [ver-pos : i64 (jp-build-corpus (&mut buf) records)]
    [buf-len : i64 (u8vec.len (& buf))]
    [max-nodes : i64 (+ (* records 24) 64)]
    [kinds-v : i64vec.Vec (jp-zero-i64-vec max-nodes)]
    [vals-v : i64vec.Vec (jp-zero-i64-vec max-nodes)]
    [keys-v : i64vec.Vec (jp-zero-i64-vec max-nodes)]
    [firsts-v : i64vec.Vec (jp-zero-i64-vec max-nodes)]
    [nexts-v : i64vec.Vec (jp-zero-i64-vec max-nodes)]
    [acc : u64 jp-hash-basis]
    [round : i64 0]
    (while (< round rounds)
      (let
        [rval : i64 (% round 10000)]
        [d0 : i64 (/ rval 1000)]
        [d1 : i64 (% (/ rval 100) 10)]
        [d2 : i64 (% (/ rval 10) 10)]
        [d3 : i64 (% rval 10)]
        [buf-mut : (&mut buf (Slice u8)) (u8vec.view-mut (&mut buf))]
        (set! (array-ref buf-mut ver-pos) (cast (+ 48 d0) : u8))
        (set! (array-ref buf-mut (+ ver-pos 1)) (cast (+ 48 d1) : u8))
        (set! (array-ref buf-mut (+ ver-pos 2)) (cast (+ 48 d2) : u8))
        (set! (array-ref buf-mut (+ ver-pos 3)) (cast (+ 48 d3) : u8)))
      (let
        [st : ParserState (ParserState 0 buf-len 0 max-nodes 0)]
        [root : i64
          (jp-parse-value
            (u8vec.view (& buf))
            (&mut st)
            (i64vec.view-mut (&mut kinds-v))
            (i64vec.view-mut (&mut vals-v))
            (i64vec.view-mut (&mut keys-v))
            (i64vec.view-mut (&mut firsts-v))
            (i64vec.view-mut (&mut nexts-v)))]
        (when (or (!= st.err 0) (< root 0)) (io.panic "json parse failed"))
        (set! acc (jp-mix acc (cast st.node-count : u64)))
        (set!
          acc
          (jp-sum-tree
            (i64vec.view (& kinds-v))
            (i64vec.view (& vals-v))
            (i64vec.view (& keys-v))
            (i64vec.view (& firsts-v))
            (i64vec.view (& nexts-v))
            root
            0
            acc)))
      (set! round (+ round 1)))
    acc))

(define (main) : i64
  (let
    [records : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    (io.println "{}" (jp-bench records rounds))
    0))