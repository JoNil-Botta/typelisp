;; diff-fuzzer - seeded, reproducible TypeLisp differential fuzzer generator.
;;
;; usage:
;;   diff-fuzzer <seed> [--mode <auto|arith|loops|borrow|arena|spmd|mixed>]
;;   diff-fuzzer --batch <seed-start> <count> <out-dir>
;;
;; Emits valid, bounded, deterministic TypeLisp programs exercising arithmetic,
;; if/match, nested while/for with continue/break (including multi-latch loops),
;; Box, __tl_dyn-array (array-ref/set!/array-length/__tl_array-push!), structs,
;; &/&mut borrows, scoped with-arena/with-scratch with tl_arena_poison_enable,
;; and SPMD foreach/spmd-reduce kernels.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.random)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.text_buf)
(import stdlib.vector)
(import (vector.vector String) as svec)

(defstruct GenState
  (seed i64)
  (chunks svec.Vec))

(define (gen-init [seed : i64]) : GenState
  (let
    [mixed : i64
      (+
        (*
          (%
            (if (< seed 0)
              (neg seed)
              seed)
            2000000)
          1009)
        17)]
    [s0 : random.RandomState (random.seed mixed)]
    [d1 : random.RandomDraw (random.next s0)]
    [d2 : random.RandomDraw (random.next (random.draw-state d1))]
    [d3 : random.RandomDraw (random.next (random.draw-state d2))]
    (GenState (random.state-seed (random.draw-state d3)) (svec.new))))

(define (gen-next! [g : (&mut g GenState)]) : i64
  (let
    [draw : random.RandomDraw (random.next (random.seed g.seed))]
    (set! g.seed (random.state-seed (random.draw-state draw)))
    (random.draw-value draw)))

(define (gen-range! [g : (&mut g GenState)] [lo : i64] [hi : i64]) : i64
  (let
    [span : i64 (- hi lo)]
    (if (<= span 0)
      lo
      (+ lo (% (gen-next! g) span)))))

(define (emit! [g : (&mut g GenState)] [text : String]) : unit
  (svec.push-ref! (&mut g.chunks) text))

(define (emit-ln! [g : (&mut g GenState)] [text : String]) : unit
  (svec.push-ref! (&mut g.chunks) text)
  (svec.push-ref! (&mut g.chunks) "\n"))

(define (gen-render [g : (& g GenState)]) : String
  (let
    [buf : text_buf.TextBuf (text_buf.empty)]
    [n : i64 (svec.len (& g.chunks))]
    [i : i64 0]
    (while (< i n)
      (text_buf.append! buf (svec.get (& g.chunks) i ""))
      (+= i 1))
    (text_buf.render buf)))

(define (gen-arith-expr
  [g : (&mut g GenState)]
  [depth : i64]
  [v1 : String]
  [v2 : String]
  [v3 : String]) : String
  (if (<= depth 0)
    (let
      [pick : i64 (gen-range! g 0 6)]
      (cond
        [(= pick 0) v1]
        [(= pick 1) v2]
        [(= pick 2) v3]
        [(= pick 3)
          (str_cat.str-cat
            "(cast "
            (string.int->string (gen-range! g 1 29))
            " : i64)")]
        [(= pick 4)
          (str_cat.str-cat
            "(neg (cast "
            (string.int->string (gen-range! g 1 17))
            " : i64))")]
        [else (str_cat.str-cat "(bit-and " v1 " 255)")]))
    (let
      [op : i64 (gen-range! g 0 10)]
      [lhs : String
        (gen-arith-expr
          g
          (- depth 1)
          (string.copy v1)
          (string.copy v2)
          (string.copy v3))]
      [rhs : String (gen-arith-expr g (- depth 1) v2 v3 v1)]
      (cond
        [(= op 0) (str_cat.str-cat "(bit-and (+ " lhs " " rhs ") 1048575)")]
        [(= op 1) (str_cat.str-cat "(bit-and (- " lhs " " rhs ") 1048575)")]
        [(= op 2)
          (str_cat.str-cat
            "(bit-and (* (bit-and "
            lhs
            " 1023) (bit-and "
            rhs
            " 1023)) 1048575)")]
        [(= op 3) (str_cat.str-cat "(/ " lhs " (+ (bit-and " rhs " 7) 1))")]
        [(= op 4) (str_cat.str-cat "(% " lhs " (+ (bit-and " rhs " 7) 1))")]
        [(= op 5) (str_cat.str-cat "(bit-xor " lhs " " rhs ")")]
        [(= op 6)
          (str_cat.str-cat
            "(bit-or (bit-and "
            lhs
            " 4095) (bit-and "
            rhs
            " 4095))")]
        [(= op 7)
          (str_cat.str-cat "(shl (bit-and " lhs " 4095) (bit-and " rhs " 3))")]
        [(= op 8)
          (str_cat.str-cat "(shr (bit-and " lhs " 65535) (bit-and " rhs " 3))")]
        [else
          (str_cat.str-cat
            "(if (< "
            (string.copy lhs)
            " "
            (string.copy rhs)
            ") (bit-and (+ "
            lhs
            " 3) 1048575) (bit-and (- "
            rhs
            " 1) 1048575))")]))))

(define (emit-report-helper [g : (&mut g GenState)]) : unit
  (emit-ln! g "(import stdlib.runtime)")
  (emit-ln! g "")
  (emit-ln! g "(define (write-str [s : (& s str)]) : unit")
  (emit-ln! g "  (let [len : i64 (runtime.string-length s)]")
  (emit-ln! g "    (unsafe (runtime.os-write 1 (string-data s) len))")
  (emit-ln! g "    unit))")
  (emit-ln! g "")
  (emit-ln! g "(define (report-out [out : i64] [aux : i64]) : unit")
  (emit-ln!
    g
    "  (let [s1 : String (runtime.int-to-string out)] [s2 : String (runtime.int-to-string aux)]")
  (emit-ln! g "    (write-str \"out=\")")
  (emit-ln! g "    (write-str (& s1))")
  (emit-ln! g "    (write-str \" aux=\")")
  (emit-ln! g "    (write-str (& s2))")
  (emit-ln! g "    (write-str \"\\n\")))")
  (emit-ln! g ""))

(define (emit-common-types [g : (&mut g GenState)]) : unit
  (emit-report-helper g)
  (emit-ln! g "(defstruct AccPair (a i64) (b i64))")
  (emit-ln!
    g
    "(defstruct BoxedState (pair AccPair) (cell (Box i64)) (hits i64))")
  (emit-ln! g "(defenum OpKind (Add i64) (Mix i64 i64) (Invert) (Skip))")
  (emit-ln!
    g
    "(defenum TreeNode (Leaf i64) (Fork (Box TreeNode) (Box TreeNode)))")
  (emit-ln! g "")
  (emit-ln! g "(define (tree-sum [t : (& t TreeNode)]) : i64")
  (emit-ln! g "  (match t")
  (emit-ln! g "    [(Leaf v) v]")
  (emit-ln!
    g
    "    [(Fork l r) (bit-and (+ (tree-sum l) (tree-sum r)) 1048575)]))")
  (emit-ln! g "")
  (emit-ln!
    g
    "(define (apply-op [op : OpKind] [st : (&mut st BoxedState)] [bias : i64]) : i64")
  (emit-ln! g "  (match op")
  (emit-ln! g "    [(Add n)")
  (emit-ln!
    g
    "      (set! st.pair.a (bit-and (+ st.pair.a (+ n bias)) 1048575))")
  (emit-ln! g "      (set! st.hits (+ st.hits 1))")
  (emit-ln! g "      st.pair.a]")
  (emit-ln! g "    [(Mix x y)")
  (emit-ln!
    g
    "      (set! (deref st.cell) (bit-and (+ (deref st.cell) (bit-xor x y)) 1048575))")
  (emit-ln! g "      (set! st.pair.b (bit-and (+ st.pair.b x) 1048575))")
  (emit-ln! g "      (deref st.cell)]")
  (emit-ln! g "    [(Invert)")
  (emit-ln! g "      (let [tmp : i64 st.pair.a]")
  (emit-ln! g "        (set! st.pair.a st.pair.b)")
  (emit-ln! g "        (set! st.pair.b (bit-and (+ tmp 7) 1048575))")
  (emit-ln! g "        st.pair.b)]")
  (emit-ln! g "    [(Skip) (bit-and (+ st.hits bias) 1048575)]))")
  (emit-ln! g "")
  (emit-ln! g "(define (read-state [st : (& st BoxedState)]) : i64")
  (emit-ln!
    g
    "  (bit-and (+ (+ st.pair.a st.pair.b) (+ (deref st.cell) (* st.hits 13))) 1048575))")
  (emit-ln! g "")
  (emit-ln!
    g
    "(define (reborrow-probe [st : (&mut st BoxedState)] [delta : i64]) : i64")
  (emit-ln! g "  (let [before : i64 (read-state st)]")
  (emit-ln! g "    (set! st.pair.a (bit-and (+ st.pair.a delta) 1048575))")
  (emit-ln! g "    (bit-and (+ before (read-state st)) 1048575)))")
  (emit-ln! g ""))

(define (emit-dyn-array-helpers [g : (&mut g GenState)]) : unit
  (emit-ln!
    g
    "(define (push-and-mix [xs : (&mut xs (__tl_dyn-array i64))] [v : i64] [k : i64]) : i64")
  (emit-ln! g "  (__tl_array-push! xs v)")
  (emit-ln! g "  (let [n : i64 (array-length xs)]")
  (emit-ln! g "    (if (> n 0)")
  (emit-ln! g "      (let [idx : i64 (% (bit-and k 255) n)]")
  (emit-ln!
    g
    "        (set! (array-ref xs idx) (bit-and (+ (array-ref xs idx) v) 1048575))")
  (emit-ln! g "        (array-ref xs idx))")
  (emit-ln! g "      0)))")
  (emit-ln! g "")
  (emit-ln! g "(define (sum-slice [view : (& view (Slice i64))]) : i64")
  (emit-ln! g "  (let [acc : i64 0] [n : i64 (array-length view)] [i : i64 0]")
  (emit-ln! g "    (while (< i n)")
  (emit-ln!
    g
    "      (set! acc (bit-and (+ (* acc 3) (array-ref view i)) 1048575))")
  (emit-ln! g "      (+= i 1))")
  (emit-ln! g "    acc))")
  (emit-ln! g ""))

;; Profile 0: Deep arithmetic, casts, if/cond, enums/match, recursive Box Tree, borrows.
(define (emit-profile-arith [g : (&mut g GenState)]) : unit
  (emit-common-types g)
  (let
    [e1 : String (gen-arith-expr g 3 "x" "y" "z")]
    [e2 : String (gen-arith-expr g 3 "y" "z" "x")]
    [e3 : String (gen-arith-expr g 2 "x" "y" "z")]
    [c1 : i64 (gen-range! g 1 40)]
    [c2 : i64 (gen-range! g 1 40)]
    [c3 : i64 (gen-range! g 1 40)]
    [steps : i64 (gen-range! g 6 18)]
    (emit-ln! g "(define (eval-core [x : i64] [y : i64] [z : i64]) : i64")
    (emit-ln! g "  (let")
    (emit! g "    [r1 : i64 ")
    (emit-ln! g (str_cat.str-cat e1 "]"))
    (emit! g "    [r2 : i64 ")
    (emit-ln! g (str_cat.str-cat e2 "]"))
    (emit! g "    [r3 : i64 ")
    (emit-ln! g (str_cat.str-cat e3 "]"))
    (emit-ln! g "    [narrow : i32 (cast (bit-and (+ r1 r2) 65535) : i32)]")
    (emit-ln! g "    [wide : u64 (cast (bit-and (+ r2 r3) 65535) : u64)]")
    (emit-ln! g "    [flt : f64 (+ (cast (bit-and r1 255) : f64) 1.5)]")
    (emit-ln!
      g
      "    (bit-and (+ (+ (cast narrow : i64) (cast wide : i64)) (cast flt : i64)) 1048575)))")
    (emit-ln! g "")
    (emit-ln! g "(define (main) : i64")
    (emit-ln! g "  (let")
    (emit-ln!
      g
      (str_cat.str-cat
        "    [st : BoxedState (BoxedState (AccPair "
        (string.int->string c1)
        " "
        (string.int->string c2)
        ") (box "
        (string.int->string c3)
        ") 0)]"))
    (emit-ln!
      g
      (str_cat.str-cat
        "    [tree : TreeNode (Fork (box (Fork (box (Leaf "
        (string.int->string c1)
        ")) (box (Leaf "
        (string.int->string c2)
        ")))) (box (Leaf "
        (string.int->string c3)
        ")))]"))
    (emit-ln! g "    [acc : i64 (tree-sum (& tree))]")
    (emit-ln! g "    [i : i64 0]")
    (emit-ln!
      g
      (str_cat.str-cat "    (while (< i " (string.int->string steps) ")"))
    (emit-ln! g "      (let [k : i64 (% (+ i st.pair.a) 4)]")
    (emit-ln! g "        [v : i64 (eval-core (+ acc i) st.pair.a st.pair.b)]")
    (emit-ln! g "        [op : OpKind")
    (emit-ln! g "          (cond")
    (emit-ln! g "            [(= k 0) (OpKind.Add v)]")
    (emit-ln! g "            [(= k 1) (OpKind.Mix v (+ i 3))]")
    (emit-ln! g "            [(= k 2) (OpKind.Invert)]")
    (emit-ln! g "            [else (OpKind.Skip)])]")
    (emit-ln!
      g
      "        (set! acc (bit-and (+ acc (apply-op op (&mut st) i)) 1048575))")
    (emit-ln!
      g
      "        (when (= (% i 3) 1) (set! acc (bit-and (+ acc (reborrow-probe (&mut st) 5)) 1048575))))")
    (emit-ln! g "      (+= i 1))")
    (emit-ln! g "    (let [detail : i64 (read-state (& st))]")
    (emit-ln! g "      (report-out acc detail)")
    (emit-ln! g "      (bit-and (+ acc detail) 63))))")))

;; Profile 1: Nested while/for with multi-latch continue and break, dyn-array, Box, structs.
(define (emit-profile-loops [g : (&mut g GenState)]) : unit
  (emit-ln! g "(import stdlib.iterator)")
  (emit-ln! g "")
  (emit-common-types g)
  (emit-dyn-array-helpers g)
  (let
    [outer-n : i64 (gen-range! g 6 16)]
    [inner-n : i64 (gen-range! g 5 14)]
    [skip-mod1 : i64 (gen-range! g 2 5)]
    [skip-mod2 : i64 (gen-range! g 3 7)]
    [break-cut : i64 (gen-range! g 4 12)]
    [init-len : i64 (gen-range! g 3 8)]
    [seed-a : i64 (gen-range! g 1 31)]
    [seed-b : i64 (gen-range! g 1 31)]
    [latch-style : i64 (gen-range! g 0 3)]
    (emit-ln!
      g
      "(define (multi-latch-while [xs : (&mut xs (__tl_dyn-array i64))] [st : (&mut st BoxedState)] [limit : i64]) : i64")
    (emit-ln! g "  (let [acc : i64 0] [idx : i64 0] [b : (Box i64) (box 7)]")
    (emit-ln! g "    (while (< idx limit)")
    (if (= latch-style 0)
      (begin
        ;; Counter-before-body multi-latch shape (like `for` lowering) with 2 continues + 1 break.
        (emit-ln! g "      (let [i : i64 idx]")
        (emit-ln! g "        (set! idx (+ idx 1))")
        (emit-ln! g "        (let [n : i64 (array-length xs)]")
        (emit-ln! g "          [slot : i64 (% i n)]")
        (emit-ln! g "          [cur : i64 (array-ref xs slot)]")
        (emit-ln!
          g
          (str_cat.str-cat
            "          (when (= (% (+ i cur) "
            (string.int->string skip-mod1)
            ") 0)"))
        (emit-ln!
          g
          "            (set! (array-ref xs slot) (bit-and (+ cur 3) 1048575))")
        (emit-ln! g "            (set! acc (bit-and (+ acc (+ i 1)) 1048575))")
        (emit-ln! g "            (continue))")
        (emit-ln!
          g
          (str_cat.str-cat
            "          (when (= (% (+ i st.pair.a) "
            (string.int->string skip-mod2)
            ") 1)"))
        (emit-ln!
          g
          "            (set! (deref b) (bit-and (+ (deref b) cur) 1048575))")
        (emit-ln!
          g
          "            (set! st.pair.a (bit-and (+ st.pair.a 5) 1048575))")
        (emit-ln! g "            (continue))")
        (emit-ln!
          g
          (str_cat.str-cat
            "          (when (and (> i "
            (string.int->string break-cut)
            ") (= (% cur 5) 0))"))
        (emit-ln!
          g
          "            (set! acc (bit-and (+ acc (deref b)) 1048575))")
        (emit-ln! g "            (break))")
        (emit-ln!
          g
          "          (set! (array-ref xs slot) (bit-and (+ cur (+ (deref b) i)) 1048575))")
        (emit-ln!
          g
          "          (set! acc (bit-and (+ acc (array-ref xs slot)) 1048575)))))"))
      (begin
        ;; Explicit-step before each continue + nested inner loop with continue/break.
        (emit-ln! g "      (let [n : i64 (array-length xs)]")
        (emit-ln! g "        [slot : i64 (% idx n)]")
        (emit-ln! g "        [cur : i64 (array-ref xs slot)]")
        (emit-ln!
          g
          (str_cat.str-cat
            "        (when (= (% idx "
            (string.int->string skip-mod1)
            ") 0)"))
        (emit-ln!
          g
          "          (set! (array-ref xs slot) (bit-and (+ cur 11) 1048575))")
        (emit-ln! g "          (+= idx 1)")
        (emit-ln! g "          (continue))")
        (emit-ln! g "        (let [j : i64 0]")
        (emit-ln!
          g
          (str_cat.str-cat
            "          (while (< j "
            (string.int->string inner-n)
            ")"))
        (emit-ln! g "            (+= j 1)")
        (emit-ln!
          g
          (str_cat.str-cat
            "            (when (= (% (+ idx j) "
            (string.int->string skip-mod2)
            ") 0) (continue))"))
        (emit-ln!
          g
          (str_cat.str-cat
            "            (when (> j "
            (string.int->string break-cut)
            ") (break))"))
        (emit-ln!
          g
          "            (set! acc (bit-and (+ acc (+ (array-ref xs slot) j)) 1048575))")
        (emit-ln!
          g
          "            (set! (deref b) (bit-and (+ (deref b) j) 1048575))))")
        (emit-ln!
          g
          "        (set! st.pair.b (bit-and (+ st.pair.b (deref b)) 1048575))")
        (emit-ln! g "        (when (and (> idx 4) (= (% acc 7) 0)) (break))")
        (emit-ln! g "        (+= idx 1)))")))
    (emit-ln! g "    (bit-and (+ acc (+ idx (deref b))) 1048575)))")
    (emit-ln! g "")
    (emit-ln!
      g
      "(define (nested-for-loops [xs : (&mut xs (__tl_dyn-array i64))] [outer : i64] [inner : i64]) : i64")
    (emit-ln! g "  (let [total : i64 0]")
    (emit-ln! g "    (for [i (iterator.range 0 outer)]")
    (emit-ln!
      g
      (str_cat.str-cat
        "      (when (= (% i "
        (string.int->string skip-mod1)
        ") 0) (continue))"))
    (emit-ln! g "      (for [j (iterator.range-inclusive 0 inner)]")
    (emit-ln!
      g
      (str_cat.str-cat
        "        (when (= (% (+ i j) "
        (string.int->string skip-mod2)
        ") 0) (continue))"))
    (emit-ln!
      g
      (str_cat.str-cat
        "        (when (> j "
        (string.int->string break-cut)
        ") (break))"))
    (emit-ln! g "        (let [n : i64 (array-length xs)]")
    (emit-ln! g "          [idx : i64 (% (+ i j) n)]")
    (emit-ln! g "          [old : i64 (array-ref xs idx)]")
    (emit-ln!
      g
      "          (set! (array-ref xs idx) (bit-and (+ old (+ i (* j 2))) 1048575))")
    (emit-ln!
      g
      "          (set! total (bit-and (+ total (array-ref xs idx)) 1048575))))")
    (emit-ln! g "      (when (and (> i 3) (= (% total 11) 0)) (break)))")
    (emit-ln! g "    (for [elem (& xs)]")
    (emit-ln! g "      (when (= (% (deref elem) 4) 0) (continue))")
    (emit-ln! g "      (set! total (bit-and (+ total (deref elem)) 1048575)))")
    (emit-ln! g "    total))")
    (emit-ln! g "")
    (emit-ln! g "(define (main) : i64")
    (emit-ln! g "  (let")
    (emit-ln!
      g
      (str_cat.str-cat
        "    [xs : (__tl_dyn-array i64) (__tl_make-array i64 "
        (string.int->string init-len)
        ")]"))
    (emit-ln!
      g
      (str_cat.str-cat
        "    [st : BoxedState (BoxedState (AccPair "
        (string.int->string seed-a)
        " "
        (string.int->string seed-b)
        ") (box 19) 0)]"))
    (emit-ln! g "    (for [k (iterator.range 0 (array-length xs))]")
    (emit-ln!
      g
      (str_cat.str-cat
        "      (set! (array-ref xs k) (+ (* k 7) "
        (string.int->string seed-a)
        ")))"))
    (emit-ln! g "    (for [k (iterator.range 0 5)]")
    (emit-ln! g "      (push-and-mix (&mut xs) (+ (* k 5) 3) k))")
    (emit-ln!
      g
      (str_cat.str-cat
        "    (let [r1 : i64 (multi-latch-while (&mut xs) (&mut st) "
        (string.int->string outer-n)
        ")]"))
    (emit-ln!
      g
      (str_cat.str-cat
        "      [r2 : i64 (nested-for-loops (&mut xs) "
        (string.int->string outer-n)
        " "
        (string.int->string inner-n)
        ")]"))
    (emit-ln!
      g
      "      [r3 : i64 (sum-slice (slice-view xs 0 (array-length xs)))]")
    (emit-ln! g "      [out : i64 (bit-and (+ (+ r1 r2) r3) 1048575)]")
    (emit-ln!
      g
      "      [aux : i64 (bit-and (+ (read-state (& st)) (array-length xs)) 1048575)]")
    (emit-ln! g "      (report-out out aux)")
    (emit-ln! g "      (bit-and (+ out aux) 63))))")))

;; Profile 2: Structs, Box, __tl_dyn-array growth, slice-view/slice-mut-view, &/&mut borrows.
(define (emit-profile-borrow [g : (&mut g GenState)]) : unit
  (emit-ln! g "(import stdlib.iterator)")
  (emit-ln! g "")
  (emit-common-types g)
  (emit-dyn-array-helpers g)
  (let
    [push-n : i64 (gen-range! g 4 14)]
    [bias : i64 (gen-range! g 1 37)]
    [mul : i64 (gen-range! g 2 9)]
    (emit-ln!
      g
      "(defstruct Bucket (tag i64) (items (__tl_dyn-array i64)) (meta (Box AccPair)))")
    (emit-ln! g "")
    (emit-ln!
      g
      "(define (mutate-slice [view : (&mut view (Slice i64))] [bias : i64]) : i64")
    (emit-ln! g "  (let [n : i64 (array-length view)] [acc : i64 0]")
    (emit-ln! g "    (for [i (iterator.range 0 n)]")
    (emit-ln!
      g
      "      (let [v : i64 (bit-and (+ (array-ref view i) (+ (* i 3) bias)) 1048575)]")
    (emit-ln! g "        (set! (array-ref view i) v)")
    (emit-ln!
      g
      "        (when (= (% i 2) 0) (set! acc (bit-and (+ acc v) 1048575)))))")
    (emit-ln! g "    acc))")
    (emit-ln! g "")
    (emit-ln!
      g
      "(define (bucket-step [b : (&mut b Bucket)] [step : i64]) : i64")
    (emit-ln!
      g
      (str_cat.str-cat
        "  (let [v : i64 (bit-and (+ (* step "
        (string.int->string mul)
        ") "
        (string.int->string bias)
        ") 1048575)]"))
    (emit-ln! g "    (__tl_array-push! b.items v)")
    (emit-ln!
      g
      "    (set! (deref b.meta).a (bit-and (+ (deref b.meta).a v) 1048575))")
    (emit-ln!
      g
      "    (set! (deref b.meta).b (bit-and (+ (deref b.meta).b (array-length b.items)) 1048575))")
    (emit-ln! g "    (let [n : i64 (array-length b.items)]")
    (emit-ln! g "      (if (>= n 2)")
    (emit-ln!
      g
      "        (mutate-slice (slice-mut-view b.items 1 (- n 1)) step)")
    (emit-ln! g "        v))))")
    (emit-ln! g "")
    (emit-ln! g "(define (bucket-checksum [b : (& b Bucket)]) : i64")
    (emit-ln! g "  (let [n : i64 (array-length b.items)]")
    (emit-ln! g "    [s : i64 (sum-slice (slice-view b.items 0 n))]")
    (emit-ln!
      g
      "    (bit-and (+ (+ s b.tag) (+ (deref b.meta).a (deref b.meta).b)) 1048575)))")
    (emit-ln! g "")
    (emit-ln! g "(define (main) : i64")
    (emit-ln! g "  (let")
    (emit-ln!
      g
      (str_cat.str-cat
        "    [b : Bucket (Bucket "
        (string.int->string bias)
        " (__tl_make-array i64 2) (box (AccPair 3 5)))]"))
    (emit-ln! g "    [st : BoxedState (BoxedState (AccPair 11 13) (box 17) 0)]")
    (emit-ln! g "    [acc : i64 0]")
    (emit-ln! g "    (set! (array-ref b.items 0) 9)")
    (emit-ln! g "    (set! (array-ref b.items 1) 14)")
    (emit-ln!
      g
      (str_cat.str-cat
        "    (for [i (iterator.range 0 "
        (string.int->string push-n)
        ")]"))
    (emit-ln! g "      (when (= (% i 5) 4) (continue))")
    (emit-ln!
      g
      "      (set! acc (bit-and (+ acc (bucket-step (&mut b) i)) 1048575))")
    (emit-ln!
      g
      "      (set! acc (bit-and (+ acc (apply-op (if (= (% i 2) 0) (OpKind.Add i) (OpKind.Mix i acc)) (&mut st) 1)) 1048575)))")
    (emit-ln! g "    (let [chk : i64 (bucket-checksum (& b))]")
    (emit-ln!
      g
      "      [aux : i64 (bit-and (+ (reborrow-probe (&mut st) 7) (array-length b.items)) 1048575)]")
    (emit-ln! g "      (report-out (bit-and (+ acc chk) 1048575) aux)")
    (emit-ln! g "      (bit-and (+ (+ acc chk) aux) 63))))")))

;; Profile 3: Scoped with-arena / with-scratch with tl_arena_poison_enable at main entry.
(define (emit-profile-arena [g : (&mut g GenState)]) : unit
  (emit-ln! g "(import stdlib.iterator)")
  (emit-ln! g "(import stdlib.string)")
  (emit-common-types g)
  (emit-ln! g "(extern (tl_arena_poison_enable) : unit)")
  (emit-ln! g "")
  (emit-dyn-array-helpers g)
  (let
    [rounds : i64 (gen-range! g 4 12)]
    [inner-k : i64 (gen-range! g 3 9)]
    [base-a : i64 (gen-range! g 2 29)]
    [base-b : i64 (gen-range! g 3 31)]
    (emit-ln!
      g
      "(defstruct ArenaRecord (label String) (score i64) (boxed (Box i64)))")
    (emit-ln! g "")
    (emit-ln! g "(define (scratch-round [iter : i64] [seed-v : i64]) : i64")
    (emit-ln! g "  (with-scratch")
    (emit-ln! g "    (let")
    (emit-ln! g "      [xs : (__tl_dyn-array i64) (__tl_make-array i64 2)]")
    (emit-ln! g "      [b : (Box AccPair) (box (AccPair iter seed-v))]")
    (emit-ln! g "      [acc : i64 0]")
    (emit-ln! g "      (set! (array-ref xs 0) (+ iter 1))")
    (emit-ln! g "      (set! (array-ref xs 1) (+ seed-v 3))")
    (emit-ln!
      g
      (str_cat.str-cat
        "      (for [j (iterator.range 0 "
        (string.int->string inner-k)
        ")]"))
    (emit-ln! g "        (when (= (% (+ iter j) 3) 0) (continue))")
    (emit-ln!
      g
      "        (set! acc (bit-and (+ acc (push-and-mix (&mut xs) (+ j seed-v) j)) 1048575))")
    (emit-ln!
      g
      "        (set! (deref b).a (bit-and (+ (deref b).a j) 1048575)))")
    (emit-ln!
      g
      "      (let [tag : String (string.append \"r-\" (string.int->string acc))]")
    (emit-ln!
      g
      "        (bit-and (+ (+ acc (string.string-length (& tag))) (+ (deref b).a (array-length xs))) 1048575)))))")
    (emit-ln! g "")
    (emit-ln! g "(define (main) : i64")
    (emit-ln! g "  (tl_arena_poison_enable)")
    (emit-ln! g "  (let [grand : i64 0] [surviving : i64 0]")
    (emit-ln! g "    (with-arena outer")
    (emit-ln! g "      (let")
    (emit-ln!
      g
      "        [kept-str : String (with-scratch (string.append \"keep-\" (string.int->string (+ 10 32))))]")
    (emit-ln!
      g
      (str_cat.str-cat
        "        [kept-box : (Box i64) (with-scratch (box "
        (string.int->string base-a)
        "))]"))
    (emit-ln!
      g
      (str_cat.str-cat
        "        [rec : ArenaRecord (ArenaRecord (string.copy kept-str) "
        (string.int->string base-b)
        " (box (+ "
        (string.int->string base-a)
        " "
        (string.int->string base-b)
        ")))]"))
    (emit-ln!
      g
      "        [outer-arr : (__tl_dyn-array i64) (__tl_make-array i64 2)]")
    (emit-ln! g "        (set! (array-ref outer-arr 0) (deref kept-box))")
    (emit-ln! g "        (set! (array-ref outer-arr 1) rec.score)")
    (emit-ln!
      g
      (str_cat.str-cat
        "        (for [i (iterator.range 0 "
        (string.int->string rounds)
        ")]"))
    (emit-ln! g "          (let [step : i64 (scratch-round i (+ grand i))]")
    (emit-ln! g "            (with-arena inner")
    (emit-ln! g "              (let [tmp : (Box i64) (box (+ step i))]")
    (emit-ln!
      g
      "                (set! grand (bit-and (+ grand (deref tmp)) 1048575))))")
    (emit-ln! g "            (__tl_array-push! outer-arr step)")
    (emit-ln! g "            (when (= (% i 4) 3) (continue))")
    (emit-ln!
      g
      "            (set! (deref rec.boxed) (bit-and (+ (deref rec.boxed) step) 1048575))))")
    (emit-ln! g "        (let [olen : i64 (array-length (& outer-arr))]")
    (emit-ln! g "          (set! surviving")
    (emit-ln!
      g
      "            (bit-and (+ (+ (string.string-length (& rec.label)) (deref kept-box)) (+ (deref rec.boxed) (sum-slice (slice-view outer-arr 0 olen)))) 1048575)))))")
    (emit-ln! g "    (report-out grand surviving)")
    (emit-ln! g "    (bit-and (+ grand surviving) 63)))")))

;; Profile 4: SPMD kernels comparing --backend-mode scalar vs --backend-mode avx2.
(define (emit-profile-spmd [g : (&mut g GenState)]) : unit
  (emit-ln! g "(import stdlib.iterator)")
  (emit-ln! g "")
  (emit-report-helper g)
  (let
    [sizes : (Array i64 12) (array 0 1 3 4 7 8 9 15 16 17 23 33)]
    [n1 : i64 (array-ref sizes (gen-range! g 1 12))]
    [n2 : i64 (array-ref sizes (gen-range! g 0 12))]
    [c-mul : i64 (gen-range! g 2 9)]
    [c-add : i64 (gen-range! g 1 19)]
    [cut : i64 (gen-range! g 4 24)]
    [variant : i64 (gen-range! g 0 3)]
    (emit-ln! g "(define (spmd-i64-kernel")
    (emit-ln! g "  [a : (& a (__tl_dyn-array i64))]")
    (emit-ln! g "  [b : (& b (__tl_dyn-array i64))]")
    (emit-ln! g "  [ix : (& ix (__tl_dyn-array i64))]")
    (emit-ln! g "  [out : (&mut out (__tl_dyn-array i64))]")
    (emit-ln! g "  [n : i64]) : unit")
    (cond
      [(= variant 0)
        (emit-ln! g "  (foreach ([i : i64 0 n])")
        (emit-ln!
          g
          (str_cat.str-cat
            "    (let [av : i64 (array-ref a i)] [bv : i64 (array-ref b i)]"
            "\n      (if (< av "
            (string.int->string cut)
            ")"
            "\n        (set! (array-ref out i) (+ (* av "
            (string.int->string c-mul)
            ") bv))"
            "\n        (set! (array-ref out i) (- (+ av bv) "
            (string.int->string c-add)
            "))))))"))]
      [(= variant 1)
        (emit-ln! g "  (foreach ([i : i64 0 n])")
        (emit-ln!
          g
          (str_cat.str-cat
            "    (set! (array-ref out i) (+ (* (array-ref a i) "
            (string.int->string c-mul)
            ") (+ (array-ref b i) "
            (string.int->string c-add)
            ")))))"))]
      [else
        (emit-ln!
          g
          "  (let [gathered : (__tl_dyn-array i64) (__tl_make-array i64 36)]")
        (emit-ln! g "    (foreach ([i : i64 0 n])")
        (emit-ln!
          g
          "      (set! (array-ref gathered i) (array-ref b (array-ref ix i))))")
        (emit-ln! g "    (foreach ([i : i64 0 n])")
        (emit-ln!
          g
          (str_cat.str-cat
            "      (set! (array-ref out i) (bit-xor (+ (array-ref a i) (array-ref gathered i)) "
            (string.int->string c-add)
            ")))))"))])
    (emit-ln! g "")
    (emit-ln! g "(define (spmd-i32-and-bool")
    (emit-ln! g "  [src : (& src (__tl_dyn-array i32))]")
    (emit-ln! g "  [dst : (&mut dst (__tl_dyn-array i32))]")
    (emit-ln! g "  [flags : (&mut flags (__tl_dyn-array bool))]")
    (emit-ln! g "  [n : i64]) : unit")
    (emit-ln! g "  (foreach ([i : i64 0 n])")
    (emit-ln! g "    (set! (array-ref dst i) (+ (* (array-ref src i) 3) 5)))")
    (emit-ln! g "  (foreach ([i : i64 0 n])")
    (emit-ln! g "    (set! (array-ref flags i) (< (array-ref src i) 10))))")
    (emit-ln! g "")
    (emit-ln! g "(define (spmd-f64-kernel")
    (emit-ln! g "  [a : (& a (Array f64 36))]")
    (emit-ln! g "  [b : (& b (Array f64 36))]")
    (emit-ln! g "  [out : (&mut out (Array f64 36))]")
    (emit-ln! g "  [n : i64]) : unit")
    (emit-ln! g "  (foreach ([i : i64 0 n])")
    (emit-ln! g "    (let [x : f64 (array-ref a i)] [y : f64 (array-ref b i)]")
    (emit-ln! g "      (if (< x y)")
    (emit-ln! g "        (set! (array-ref out i) (+ (* x 2.0) y))")
    (emit-ln! g "        (set! (array-ref out i) (- x (* y 0.5)))))))")
    (emit-ln! g "")
    (emit-ln!
      g
      "(define (spmd-sum-reduce [xs : (& xs (__tl_dyn-array i64))] [n : i64]) : i64")
    (emit-ln!
      g
      (str_cat.str-cat
        "  (spmd-reduce sum ([i : i64 0 n]) 0 (+ (array-ref xs i) "
        (string.int->string c-add)
        ")))"))
    (emit-ln! g "")
    (emit-ln! g "(define (main) : i64")
    (emit-ln! g "  (let")
    (emit-ln! g (str_cat.str-cat "    [n1 : i64 " (string.int->string n1) "]"))
    (emit-ln! g (str_cat.str-cat "    [n2 : i64 " (string.int->string n2) "]"))
    (emit-ln! g "    [a : (__tl_dyn-array i64) (__tl_make-array i64 36)]")
    (emit-ln! g "    [b : (__tl_dyn-array i64) (__tl_make-array i64 36)]")
    (emit-ln! g "    [ix : (__tl_dyn-array i64) (__tl_make-array i64 36)]")
    (emit-ln! g "    [out : (__tl_dyn-array i64) (__tl_make-array i64 36)]")
    (emit-ln! g "    [s32 : (__tl_dyn-array i32) (__tl_make-array i32 36)]")
    (emit-ln! g "    [d32 : (__tl_dyn-array i32) (__tl_make-array i32 36)]")
    (emit-ln! g "    [flags : (__tl_dyn-array bool) (__tl_make-array bool 36)]")
    (emit-ln! g "    [fa : (Array f64 36) (make-array f64 36)]")
    (emit-ln! g "    [fb : (Array f64 36) (make-array f64 36)]")
    (emit-ln! g "    [fout : (Array f64 36) (make-array f64 36)]")
    (emit-ln! g "    [acc : i64 0]")
    (emit-ln! g "    (for [i (iterator.range 0 36)]")
    (emit-ln!
      g
      (str_cat.str-cat
        "      (set! (array-ref a i) (+ (* i 3) "
        (string.int->string c-add)
        "))"))
    (emit-ln!
      g
      (str_cat.str-cat
        "      (set! (array-ref b i) (+ (* i 5) "
        (string.int->string c-mul)
        "))"))
    (emit-ln! g "      (set! (array-ref ix i) (% (+ (* i 7) 3) 36))")
    (emit-ln! g "      (set! (array-ref s32 i) (cast (- (* i 2) 10) : i32))")
    (emit-ln! g "      (set! (array-ref fa i) (* (cast i : f64) 1.5))")
    (emit-ln! g "      (set! (array-ref fb i) (* (cast (+ i 2) : f64) 0.5)))")
    (emit-ln! g "    (spmd-i64-kernel (& a) (& b) (& ix) (&mut out) n1)")
    (emit-ln! g "    (spmd-i32-and-bool (& s32) (&mut d32) (&mut flags) n2)")
    (emit-ln! g "    (spmd-f64-kernel (& fa) (& fb) (&mut fout) n1)")
    (emit-ln! g "    (for [i (iterator.range 0 n1)]")
    (emit-ln!
      g
      "      (set! acc (bit-and (+ (* acc 3) (+ (array-ref out i) (cast (* (array-ref fout i) 4.0) : i64))) 1048575)))")
    (emit-ln!
      g
      "    (let [aux : i64 (bit-and (spmd-sum-reduce (& out) n1) 1048575)]")
    (emit-ln! g "      (for [i (iterator.range 0 n2)]")
    (emit-ln!
      g
      "        (set! aux (bit-and (+ aux (+ (cast (array-ref d32 i) : i64) (if (array-ref flags i) 7 1))) 1048575)))")
    (emit-ln! g "      (report-out acc aux)")
    (emit-ln! g "      (bit-and (+ acc aux) 63))))")))

;; Profile 5: Kitchen-sink combining arena poison, multi-latch loops, Box, dyn-array, borrows, match, and SPMD.
(define (emit-profile-mixed [g : (&mut g GenState)] [with-spmd : bool]) : unit
  (emit-ln! g "(import stdlib.iterator)")
  (emit-ln! g "(import stdlib.string)")
  (emit-common-types g)
  (emit-ln! g "(extern (tl_arena_poison_enable) : unit)")
  (emit-ln! g "")
  (emit-dyn-array-helpers g)
  (let
    [n : i64 (gen-range! g 5 18)]
    [mod-skip : i64 (gen-range! g 2 5)]
    [cut : i64 (gen-range! g 4 14)]
    [bias : i64 (gen-range! g 1 23)]
    (when
      with-spmd
      (emit-ln!
        g
        "(define (mix-spmd [src : (& src (__tl_dyn-array i64))] [dst : (&mut dst (__tl_dyn-array i64))] [n : i64]) : i64")
      (emit-ln! g "  (foreach ([i : i64 0 n])")
      (emit-ln!
        g
        (str_cat.str-cat
          "    (let [v : i64 (array-ref src i)] (set! (array-ref dst i) (if (< v "
          (string.int->string cut)
          ") (+ (* v 2) 3) (- v 1)))))"))
      (emit-ln! g "  (spmd-reduce sum ([i : i64 0 n]) 0 (array-ref dst i)))")
      (emit-ln! g ""))
    (emit-ln! g "(define (main) : i64")
    (emit-ln! g "  (tl_arena_poison_enable)")
    (emit-ln! g "  (let [acc : i64 0] [aux : i64 0]")
    (emit-ln! g "    (with-arena work")
    (emit-ln! g "      (let")
    (emit-ln!
      g
      (str_cat.str-cat
        "        [st : BoxedState (BoxedState (AccPair "
        (string.int->string bias)
        " 9) (box 13) 0)]"))
    (emit-ln! g "        [xs : (__tl_dyn-array i64) (__tl_make-array i64 3)]")
    (emit-ln! g "        [ys : (__tl_dyn-array i64) (__tl_make-array i64 18)]")
    (emit-ln! g "        [idx : i64 0]")
    (emit-ln! g "        (set! (array-ref xs 0) 4)")
    (emit-ln! g "        (set! (array-ref xs 1) 7)")
    (emit-ln! g "        (set! (array-ref xs 2) 11)")
    (emit-ln!
      g
      (str_cat.str-cat "        (while (< idx " (string.int->string n) ")"))
    (emit-ln! g "          (let [i : i64 idx]")
    (emit-ln! g "            (set! idx (+ idx 1))")
    (emit-ln!
      g
      "            (let [s : i64 (with-scratch (let [t : String (string.append \"k\" (string.int->string i))] (+ (string.string-length (& t)) i)))]")
    (emit-ln!
      g
      "              (__tl_array-push! xs (bit-and (+ s st.pair.a) 1048575))")
    (emit-ln!
      g
      (str_cat.str-cat
        "              (when (= (% i "
        (string.int->string mod-skip)
        ") 0)"))
    (emit-ln!
      g
      "                (set! st.pair.a (bit-and (+ st.pair.a s) 1048575))")
    (emit-ln!
      g
      "                (set! acc (bit-and (+ acc (+ st.pair.a i)) 1048575))")
    (emit-ln! g "                (continue))")
    (emit-ln! g "              (when (and (> i 9) (= (% acc 7) 0)) (break))")
    (emit-ln!
      g
      "              (set! (deref st.cell) (bit-and (+ (deref st.cell) (bit-xor s i)) 1048575))")
    (emit-ln!
      g
      "              (set! acc (bit-and (+ acc (deref st.cell)) 1048575)))))")
    (emit-ln! g "        (let [xlen : i64 (array-length (& xs))]")
    (emit-ln! g "          (for [k (iterator.range 0 xlen)]")
    (emit-ln! g "            (when (= (% k 4) 0) (continue))")
    (emit-ln!
      g
      "            (set! aux (bit-and (+ aux (array-ref xs k)) 1048575)))")
    (when
      with-spmd
      (emit-ln! g "          (let [spmd-n : i64 (if (< xlen 18) xlen 18)]")
      (emit-ln!
        g
        "            (set! aux (bit-and (+ aux (mix-spmd (& xs) (&mut ys) spmd-n)) 1048575)))"))
    (emit-ln!
      g
      "          (set! aux (bit-and (+ aux (+ st.pair.a (+ st.pair.b (deref st.cell)))) 1048575)))))")
    (emit-ln! g "    (report-out acc aux)")
    (emit-ln! g "    (bit-and (+ acc aux) 63)))")))

(define (profile-for-seed [seed : i64] [mode : (& mode str)]) : i64
  (cond
    [(string.eq mode "arith") 0]
    [(string.eq mode "loops") 1]
    [(string.eq mode "borrow") 2]
    [(string.eq mode "arena") 3]
    [(string.eq mode "spmd") 4]
    [(string.eq mode "mixed") 5]
    [else
      (%
        (if (< seed 0)
          (neg seed)
          seed)
        6)]))

(define (profile-name [profile : i64]) : String
  (cond
    [(= profile 0) "arith"]
    [(= profile 1) "loops"]
    [(= profile 2) "borrow"]
    [(= profile 3) "arena"]
    [(= profile 4) "spmd"]
    [else "mixed"]))

(define (generate-program [seed : i64] [profile : i64]) : String
  (let
    [g : GenState (gen-init seed)]
    (cond
      [(= profile 0) (emit-profile-arith (&mut g))]
      [(= profile 1) (emit-profile-loops (&mut g))]
      [(= profile 2) (emit-profile-borrow (&mut g))]
      [(= profile 3) (emit-profile-arena (&mut g))]
      [(= profile 4) (emit-profile-spmd (&mut g))]
      [else (emit-profile-mixed (&mut g) (= (% (/ seed 6) 2) 0))])
    (gen-render (& g))))

(define (is-decimal-int? [text : (& text str)]) : bool
  (let
    [len : i64 (string.string-length text)]
    [i : i64 0]
    [ok : bool (and (> len 0) (<= len 12))]
    (while (and ok (< i len))
      (let
        [c : i64 (cast (string.string-ref text i) : i64)]
        (set! ok (and (>= c 48) (<= c 57)))
        (+= i 1)))
    ok))

(define (usage) : i64
  (io.print-error
    "usage:\n  diff-fuzzer <seed> [--mode <auto|arith|loops|borrow|arena|spmd|mixed>]\n  diff-fuzzer --batch <seed-start> <count> <out-dir>\n")
  2)

(define (run-batch [seed-start : i64] [count : i64] [out-dir : String]) : i64
  (let
    [manifest : text_buf.TextBuf (text_buf.empty)]
    [i : i64 0]
    (while (< i count)
      (let
        [seed : i64 (+ seed-start i)]
        [profile : i64 (profile-for-seed seed "auto")]
        [has-arena : i64
          (if (or (= profile 3) (= profile 5))
            1
            0)]
        [has-spmd : i64
          (if (or (= profile 4) (and (= profile 5) (= (% (/ seed 6) 2) 0)))
            1
            0)]
        [src : String (generate-program seed profile)]
        [path : String
          (str_cat.str-cat
            (string.copy out-dir)
            "/seed_"
            (string.int->string seed)
            ".tl")]
        (io.write-file (& path) (byte_buf.str-as-bytes (& src)))
        (text_buf.append!
          manifest
          (str_cat.str-cat
            (string.int->string seed)
            "\t"
            (profile-name profile)
            "\t"
            (string.int->string has-arena)
            "\t"
            (string.int->string has-spmd)
            "\t"
            path
            "\n")))
      (+= i 1))
    (let
      [manifest-path : String (str_cat.str-cat out-dir "/manifest.tsv")]
      [rendered : String (text_buf.render manifest)]
      (io.write-file (& manifest-path) (byte_buf.str-as-bytes (& rendered))))
    0))

(define (main) : i64
  (let
    [argc : i64 (io.arg-count)]
    (cond
      [(= argc 5)
        (let
          [flag : String (io.arg 1)]
          [start-s : String (io.arg 2)]
          [count-s : String (io.arg 3)]
          [out-dir : String (io.arg 4)]
          (if (and
            (string.eq (& flag) "--batch")
            (is-decimal-int? (& start-s))
            (is-decimal-int? (& count-s)))
            (run-batch
              (string.>int (& start-s))
              (string.>int (& count-s))
              out-dir)
            (usage)))]
      [(= argc 2)
        (let
          [seed-s : String (io.arg 1)]
          (if (is-decimal-int? (& seed-s))
            (let
              [seed : i64 (string.>int (& seed-s))]
              [src : String
                (generate-program seed (profile-for-seed seed "auto"))]
              (io.print-format "{}" src)
              0)
            (usage)))]
      [(= argc 4)
        (let
          [seed-s : String (io.arg 1)]
          [flag : String (io.arg 2)]
          [mode : String (io.arg 3)]
          (if (and (string.eq (& flag) "--mode") (is-decimal-int? (& seed-s)))
            (let
              [seed : i64 (string.>int (& seed-s))]
              [src : String
                (generate-program seed (profile-for-seed seed (& mode)))]
              (io.print-format "{}" src)
              0)
            (usage)))]
      [else (usage)])))