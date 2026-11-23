;; rustc-oracle - seeded paired TypeLisp/Rust ownership & borrow generator.
;;
;; Emits matching `.tl` and `.rs` files modeling equivalent ownership, move,
;; partial-move, branch-join, loop-move, shared/mutable borrow, disjoint field
;; borrow, reference-lifetime, and reborrow rules. Used by
;; `scripts/run-rustc-oracle.sh` (dev-only optional oracle; never a build dep).
;;
;; usage:
;;   rustc-oracle --batch <seed-start> <count> <out-dir>
;;   rustc-oracle <seed> <tl-out> <rs-out>
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.random)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.text_buf)

(defstruct PairOut
  (tl String)
  (rs String)
  (category String)
  (expected-valid i64))

(define (seed-draw [seed : i64] [salt : i64]) : i64
  (let
    [raw : i64
      (+
        (*
          (%
            (if (< seed 0)
              (neg seed)
              seed)
            1000000)
          997)
        (+ (* salt 31) 19))]
    [d1 : random.RandomDraw (random.next (random.seed raw))]
    [d2 : random.RandomDraw (random.next (random.draw-state d1))]
    (random.draw-value d2)))

(define (nstr [n : i64]) : String
  (string.int->string n))

(define (tl-prelude) : String
  (str_cat.str-cat
    "(defstruct BoxPair (a (Box i64)) (b (Box i64)))\n"
    "(defstruct ScalarPair (a i64) (b i64))\n"
    "(define (consume-box [x : (Box i64)]) : i64 (deref x))\n"
    "(define (consume-pair [p : BoxPair]) : i64 (+ (deref p.a) (deref p.b)))\n"
    "(define (read-i64 [r : (& r i64)]) : i64 (deref r))\n"
    "(define (read-two [a : (& a i64)] [b : (& b i64)]) : i64 (+ (deref a) (deref b)))\n"
    "(define (bump-i64 [r : (&mut r i64)] [d : i64]) : i64 (set! (deref r) (+ (deref r) d)) (deref r))\n"
    "(define (read-and-bump [a : (& a i64)] [b : (&mut b i64)]) : i64 (set! (deref b) (+ (deref b) (deref a))) (deref b))\n"
    "(define (bump-both [a : (&mut a i64)] [b : (&mut b i64)]) : i64 (set! (deref a) (+ (deref a) 1)) (set! (deref b) (+ (deref b) 2)) (+ (deref a) (deref b)))\n"
    "(define (pick-ref [flag : bool] [a : (& r i64)] [b : (& r i64)]) : (& r i64) (if flag a b))\n"))

(define (rs-prelude) : String
  (str_cat.str-cat
    "pub struct BoxPair { pub a: Box<i64>, pub b: Box<i64> }\n"
    "pub struct ScalarPair { pub a: i64, pub b: i64 }\n"
    "pub fn consume_box(x: Box<i64>) -> i64 { *x }\n"
    "pub fn consume_pair(p: BoxPair) -> i64 { *p.a + *p.b }\n"
    "pub fn read_i64(r: &i64) -> i64 { *r }\n"
    "pub fn read_two(a: &i64, b: &i64) -> i64 { *a + *b }\n"
    "pub fn bump_i64(r: &mut i64, d: i64) -> i64 { *r += d; *r }\n"
    "pub fn read_and_bump(a: &i64, b: &mut i64) -> i64 { *b += *a; *b }\n"
    "pub fn bump_both(a: &mut i64, b: &mut i64) -> i64 { *a += 1; *b += 2; *a + *b }\n"
    "pub fn pick_ref<'a>(flag: bool, a: &'a i64, b: &'a i64) -> &'a i64 { if flag { a } else { b } }\n"))

;; Category 0: Basic move, reinit-after-move, and use-after-move.
(define (gen-move-basic [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 1) 40) 1)]
    [v2 : i64 (+ (% (seed-draw seed 2) 40) 1)]
    [sub : i64 (% (seed-draw seed 3) 2)]
    (if valid
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")] [y : (Box i64) x]\n    (consume-box y)))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  let mut y: Box<i64> = x;\n  consume_box(y)\n}\n")
          "move-basic"
          1)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")] [a : i64 (consume-box x)]\n    (set! x (box "
            (nstr v2)
            "))\n    (+ a (deref x))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  let mut a: i64 = consume_box(x);\n  x = Box::new("
            (nstr v2)
            ");\n  a + *x\n}\n")
          "move-basic"
          1))
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")] [a : i64 (consume-box x)]\n    (+ a (deref x))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  let mut a: i64 = consume_box(x);\n  a + *x\n}\n")
          "move-basic"
          0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")] [y : (Box i64) x]\n    (+ (consume-box x) (consume-box y))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  let mut y: Box<i64> = x;\n  consume_box(x) + consume_box(y)\n}\n")
          "move-basic"
          0)))))

;; Category 1: Partial struct field move, disjoint access, and reinitialization.
(define (gen-partial-field-move [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 4) 30) 1)]
    [v2 : i64 (+ (% (seed-draw seed 5) 30) 1)]
    [v3 : i64 (+ (% (seed-draw seed 6) 30) 1)]
    [sub : i64 (% (seed-draw seed 7) 2)]
    (if valid
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : BoxPair (BoxPair (box "
            (nstr v1)
            ") (box "
            (nstr v2)
            "))] [a : i64 (consume-box p.a)]\n    (+ a (deref p.b))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = BoxPair { a: Box::new("
            (nstr v1)
            "), b: Box::new("
            (nstr v2)
            ") };\n  let mut a: i64 = consume_box(p.a);\n  a + *p.b\n}\n")
          "partial-field-move"
          1)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : BoxPair (BoxPair (box "
            (nstr v1)
            ") (box "
            (nstr v2)
            "))] [a : i64 (consume-box p.a)]\n    (set! p.a (box "
            (nstr v3)
            "))\n    (+ a (consume-pair p))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = BoxPair { a: Box::new("
            (nstr v1)
            "), b: Box::new("
            (nstr v2)
            ") };\n  let mut a: i64 = consume_box(p.a);\n  p.a = Box::new("
            (nstr v3)
            ");\n  a + consume_pair(p)\n}\n")
          "partial-field-move"
          1))
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : BoxPair (BoxPair (box "
            (nstr v1)
            ") (box "
            (nstr v2)
            "))] [a : i64 (consume-box p.a)]\n    (+ a (deref p.a))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = BoxPair { a: Box::new("
            (nstr v1)
            "), b: Box::new("
            (nstr v2)
            ") };\n  let mut a: i64 = consume_box(p.a);\n  a + *p.a\n}\n")
          "partial-field-move"
          0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : BoxPair (BoxPair (box "
            (nstr v1)
            ") (box "
            (nstr v2)
            "))] [a : i64 (consume-box p.a)]\n    (+ a (consume-pair p))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = BoxPair { a: Box::new("
            (nstr v1)
            "), b: Box::new("
            (nstr v2)
            ") };\n  let mut a: i64 = consume_box(p.a);\n  a + consume_pair(p)\n}\n")
          "partial-field-move"
          0)))))

;; Category 2: Conditional branch moves and join state.
(define (gen-branch-move [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 8) 30) 1)]
    [v2 : i64 (+ (% (seed-draw seed 9) 30) 1)]
    [sub : i64 (% (seed-draw seed 10) 2)]
    (if valid
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (check-branch [flag : bool]) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")] [acc : i64 0]\n    (if flag\n      (begin (set! acc (consume-box x)) (set! x (box "
            (nstr v2)
            ")))\n      (set! acc 1))\n    (+ acc (deref x))))\n(define (main) : i64 (check-branch true))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn check_branch(flag: bool) -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  let mut acc: i64 = 0;\n  if flag {\n    acc = consume_box(x);\n    x = Box::new("
            (nstr v2)
            ");\n  } else {\n    acc = 1;\n  }\n  acc + *x\n}\n")
          "branch-move"
          1)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (check-branch [flag : bool]) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")]\n    (when flag (return (consume-box x)))\n    (deref x)))\n(define (main) : i64 (check-branch false))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn check_branch(flag: bool) -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  if flag { return consume_box(x); }\n  *x\n}\n")
          "branch-move"
          1))
      (PairOut
        (str_cat.str-cat
          (tl-prelude)
          "(define (check-branch [flag : bool]) : i64\n  (let [x : (Box i64) (box "
          (nstr v1)
          ")] [acc : i64 0]\n    (when flag (set! acc (consume-box x)))\n    (+ acc (deref x))))\n(define (main) : i64 (check-branch true))\n")
        (str_cat.str-cat
          (rs-prelude)
          "pub fn check_branch(flag: bool) -> i64 {\n  let mut x: Box<i64> = Box::new("
          (nstr v1)
          ");\n  let mut acc: i64 = 0;\n  if flag { acc = consume_box(x); }\n  acc + *x\n}\n")
        "branch-move"
        0))))

;; Category 3: Loop moves (move+reinit / move+break vs move across loop backedge).
(define (gen-loop-move [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 11) 20) 1)]
    [v2 : i64 (+ (% (seed-draw seed 12) 20) 1)]
    [sub : i64 (% (seed-draw seed 13) 2)]
    (if valid
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")] [i : i64 0] [acc : i64 0]\n    (while (< i 3)\n      (set! acc (+ acc (consume-box x)))\n      (set! x (box (+ i "
            (nstr v2)
            ")))\n      (+= i 1))\n    (+ acc (deref x))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  let mut i: i64 = 0;\n  let mut acc: i64 = 0;\n  while i < 3 {\n    acc += consume_box(x);\n    x = Box::new(i + "
            (nstr v2)
            ");\n    i += 1;\n  }\n  acc + *x\n}\n")
          "loop-move"
          1)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [x : (Box i64) (box "
            (nstr v1)
            ")] [i : i64 0] [acc : i64 0]\n    (while (< i 3)\n      (set! acc (+ acc (consume-box x)))\n      (break))\n    acc))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut x: Box<i64> = Box::new("
            (nstr v1)
            ");\n  let mut i: i64 = 0;\n  let mut acc: i64 = 0;\n  while i < 3 {\n    acc += consume_box(x);\n    break;\n  }\n  acc\n}\n")
          "loop-move"
          1))
      (PairOut
        (str_cat.str-cat
          (tl-prelude)
          "(define (main) : i64\n  (let [x : (Box i64) (box "
          (nstr v1)
          ")] [i : i64 0] [acc : i64 0]\n    (while (< i 3)\n      (set! acc (+ acc (consume-box x)))\n      (+= i 1))\n    acc))\n")
        (str_cat.str-cat
          (rs-prelude)
          "pub fn entry() -> i64 {\n  let mut x: Box<i64> = Box::new("
          (nstr v1)
          ");\n  let mut i: i64 = 0;\n  let mut acc: i64 = 0;\n  while i < 3 {\n    acc += consume_box(x);\n    i += 1;\n  }\n  acc\n}\n")
        "loop-move"
        0))))

;; Category 4: Shared/mutable borrow aliasing & NLL lifetime conflicts.
(define (gen-borrow-conflict [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 14) 30) 1)]
    [v2 : i64 (+ (% (seed-draw seed 15) 30) 1)]
    [sub : i64 (% (seed-draw seed 16) 3)]
    (if valid
      (cond
        [(= sub 0)
          (PairOut
            (str_cat.str-cat
              (tl-prelude)
              "(define (main) : i64\n  (let [x : i64 "
              (nstr v1)
              "]\n    (read-two (& x) (& x))))\n")
            (str_cat.str-cat
              (rs-prelude)
              "pub fn entry() -> i64 {\n  let mut x: i64 = "
              (nstr v1)
              ";\n  read_two(&x, &x)\n}\n")
            "borrow-conflict"
            1)]
        [(= sub 1)
          (PairOut
            (str_cat.str-cat
              (tl-prelude)
              "(define (main) : i64\n  (let [x : i64 "
              (nstr v1)
              "] [a : i64 (bump-i64 (&mut x) "
              (nstr v2)
              ")] [b : i64 (bump-i64 (&mut x) 1)]\n    (+ a b)))\n")
            (str_cat.str-cat
              (rs-prelude)
              "pub fn entry() -> i64 {\n  let mut x: i64 = "
              (nstr v1)
              ";\n  let mut a: i64 = bump_i64(&mut x, "
              (nstr v2)
              ");\n  let mut b: i64 = bump_i64(&mut x, 1);\n  a + b\n}\n")
            "borrow-conflict"
            1)]
        [else
          (PairOut
            (str_cat.str-cat
              (tl-prelude)
              "(define (main) : i64\n  (let [x : i64 "
              (nstr v1)
              "] [r : (& x i64) (& x)] [a : i64 (read-i64 r)]\n    (set! x (+ x "
              (nstr v2)
              "))\n    (+ a x)))\n")
            (str_cat.str-cat
              (rs-prelude)
              "pub fn entry() -> i64 {\n  let mut x: i64 = "
              (nstr v1)
              ";\n  let r: &i64 = &x;\n  let mut a: i64 = read_i64(r);\n  x += "
              (nstr v2)
              ";\n  a + x\n}\n")
            "borrow-conflict"
            1)])
      (cond
        [(= sub 0)
          (PairOut
            (str_cat.str-cat
              (tl-prelude)
              "(define (main) : i64\n  (let [x : i64 "
              (nstr v1)
              "]\n    (read-and-bump (& x) (&mut x))))\n")
            (str_cat.str-cat
              (rs-prelude)
              "pub fn entry() -> i64 {\n  let mut x: i64 = "
              (nstr v1)
              ";\n  read_and_bump(&x, &mut x)\n}\n")
            "borrow-conflict"
            0)]
        [(= sub 1)
          (PairOut
            (str_cat.str-cat
              (tl-prelude)
              "(define (main) : i64\n  (let [x : i64 "
              (nstr v1)
              "]\n    (bump-both (&mut x) (&mut x))))\n")
            (str_cat.str-cat
              (rs-prelude)
              "pub fn entry() -> i64 {\n  let mut x: i64 = "
              (nstr v1)
              ";\n  bump_both(&mut x, &mut x)\n}\n")
            "borrow-conflict"
            0)]
        [else
          (PairOut
            (str_cat.str-cat
              (tl-prelude)
              "(define (main) : i64\n  (let [x : i64 "
              (nstr v1)
              "] [r : (& x i64) (& x)]\n    (set! x (+ x "
              (nstr v2)
              "))\n    (read-i64 r)))\n")
            (str_cat.str-cat
              (rs-prelude)
              "pub fn entry() -> i64 {\n  let mut x: i64 = "
              (nstr v1)
              ";\n  let r: &i64 = &x;\n  x += "
              (nstr v2)
              ";\n  read_i64(r)\n}\n")
            "borrow-conflict"
            0)]))))

;; Category 5: Disjoint vs overlapping struct field borrows.
(define (gen-field-borrow [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 17) 30) 1)]
    [v2 : i64 (+ (% (seed-draw seed 18) 30) 1)]
    [sub : i64 (% (seed-draw seed 19) 2)]
    (if valid
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : ScalarPair (ScalarPair "
            (nstr v1)
            " "
            (nstr v2)
            ")]\n    (bump-both (&mut p.a) (&mut p.b))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = ScalarPair { a: "
            (nstr v1)
            ", b: "
            (nstr v2)
            " };\n  bump_both(&mut p.a, &mut p.b)\n}\n")
          "field-borrow"
          1)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : ScalarPair (ScalarPair "
            (nstr v1)
            " "
            (nstr v2)
            ")]\n    (read-and-bump (& p.a) (&mut p.b))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = ScalarPair { a: "
            (nstr v1)
            ", b: "
            (nstr v2)
            " };\n  read_and_bump(&p.a, &mut p.b)\n}\n")
          "field-borrow"
          1))
      (if (= sub 0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : ScalarPair (ScalarPair "
            (nstr v1)
            " "
            (nstr v2)
            ")]\n    (bump-both (&mut p.a) (&mut p.a))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = ScalarPair { a: "
            (nstr v1)
            ", b: "
            (nstr v2)
            " };\n  bump_both(&mut p.a, &mut p.a)\n}\n")
          "field-borrow"
          0)
        (PairOut
          (str_cat.str-cat
            (tl-prelude)
            "(define (main) : i64\n  (let [p : ScalarPair (ScalarPair "
            (nstr v1)
            " "
            (nstr v2)
            ")]\n    (read-and-bump (& p.a) (&mut p.a))))\n")
          (str_cat.str-cat
            (rs-prelude)
            "pub fn entry() -> i64 {\n  let mut p = ScalarPair { a: "
            (nstr v1)
            ", b: "
            (nstr v2)
            " };\n  read_and_bump(&p.a, &mut p.a)\n}\n")
          "field-borrow"
          0)))))

;; Category 6: Reference return lifetimes (valid input ref vs dangling local ref).
(define (gen-ref-lifetime [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 20) 30) 1)]
    [v2 : i64 (+ (% (seed-draw seed 21) 30) 1)]
    (if valid
      (PairOut
        (str_cat.str-cat
          (tl-prelude)
          "(define (main) : i64\n  (let [a : i64 "
          (nstr v1)
          "] [b : i64 "
          (nstr v2)
          "] [chosen (pick-ref true (& a) (& b))]\n    (deref chosen)))\n")
        (str_cat.str-cat
          (rs-prelude)
          "pub fn entry() -> i64 {\n  let mut a: i64 = "
          (nstr v1)
          ";\n  let mut b: i64 = "
          (nstr v2)
          ";\n  let chosen: &i64 = pick_ref(true, &a, &b);\n  *chosen\n}\n")
        "ref-lifetime"
        1)
      (PairOut
        (str_cat.str-cat
          (tl-prelude)
          "(define (dangling [x : i64]) : (& r i64)\n  (let [local : i64 (+ x "
          (nstr v1)
          ")]\n    (& local)))\n(define (main) : i64 (deref (dangling "
          (nstr v2)
          ")))\n")
        (str_cat.str-cat
          (rs-prelude)
          "pub fn dangling<'a>(x: i64) -> &'a i64 {\n  let local: i64 = x + "
          (nstr v1)
          ";\n  &local\n}\npub fn entry() -> i64 { *dangling("
          (nstr v2)
          ") }\n")
        "ref-lifetime"
        0))))

;; Category 7: Reborrowing &mut T as &T vs illegal &T -> &mut T escalation.
(define (gen-reborrow-mut [seed : i64] [valid : bool]) : PairOut
  (let
    [v1 : i64 (+ (% (seed-draw seed 22) 30) 1)]
    [v2 : i64 (+ (% (seed-draw seed 23) 15) 1)]
    (if valid
      (PairOut
        (str_cat.str-cat
          (tl-prelude)
          "(define (reborrow-step [r : (&mut r i64)] [d : i64]) : i64\n  (let [v : i64 (read-i64 r)]\n    (set! (deref r) (+ v d))\n    (deref r)))\n(define (main) : i64\n  (let [x : i64 "
          (nstr v1)
          "]\n    (reborrow-step (&mut x) "
          (nstr v2)
          ")))\n")
        (str_cat.str-cat
          (rs-prelude)
          "pub fn reborrow_step(r: &mut i64, d: i64) -> i64 {\n  let v: i64 = read_i64(r);\n  *r = v + d;\n  *r\n}\npub fn entry() -> i64 {\n  let mut x: i64 = "
          (nstr v1)
          ";\n  reborrow_step(&mut x, "
          (nstr v2)
          ")\n}\n")
        "reborrow-mut"
        1)
      (PairOut
        (str_cat.str-cat
          (tl-prelude)
          "(define (escalate [r : (& r i64)] [d : i64]) : i64\n  (bump-i64 r d))\n(define (main) : i64\n  (let [x : i64 "
          (nstr v1)
          "]\n    (escalate (& x) "
          (nstr v2)
          ")))\n")
        (str_cat.str-cat
          (rs-prelude)
          "pub fn escalate(r: &i64, d: i64) -> i64 {\n  bump_i64(r, d)\n}\npub fn entry() -> i64 {\n  let mut x: i64 = "
          (nstr v1)
          ";\n  escalate(&x, "
          (nstr v2)
          ")\n}\n")
        "reborrow-mut"
        0))))

(define (generate-pair [seed : i64]) : PairOut
  (let
    [abs-seed : i64
      (if (< seed 0)
        (neg seed)
        seed)]
    [cat : i64 (% abs-seed 8)]
    [valid : bool (= (% (/ abs-seed 8) 2) 0)]
    (cond
      [(= cat 0) (gen-move-basic seed valid)]
      [(= cat 1) (gen-partial-field-move seed valid)]
      [(= cat 2) (gen-branch-move seed valid)]
      [(= cat 3) (gen-loop-move seed valid)]
      [(= cat 4) (gen-borrow-conflict seed valid)]
      [(= cat 5) (gen-field-borrow seed valid)]
      [(= cat 6) (gen-ref-lifetime seed valid)]
      [else (gen-reborrow-mut seed valid)])))

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
    "usage:\n  rustc-oracle --batch <seed-start> <count> <out-dir>\n  rustc-oracle <seed> <tl-out> <rs-out>\n")
  2)

(define (run-batch [seed-start : i64] [count : i64] [out-dir : String]) : i64
  (let
    [manifest : text_buf.TextBuf (text_buf.empty)]
    [i : i64 0]
    (while (< i count)
      (let
        [seed : i64 (+ seed-start i)]
        [pair : PairOut (generate-pair seed)]
        [tl-path : String
          (str_cat.str-cat (clone out-dir) "/case_" (nstr seed) ".tl")]
        [rs-path : String
          (str_cat.str-cat (clone out-dir) "/case_" (nstr seed) ".rs")]
        (io.write-file (& tl-path) (byte_buf.str-as-bytes (& pair.tl)))
        (io.write-file (& rs-path) (byte_buf.str-as-bytes (& pair.rs)))
        (text_buf.append!
          manifest
          (str_cat.str-cat
            (nstr seed)
            "\t"
            pair.category
            "\t"
            (nstr pair.expected-valid)
            "\t"
            tl-path
            "\t"
            rs-path
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
      [(= argc 4)
        (let
          [seed-s : String (io.arg 1)]
          [tl-out : String (io.arg 2)]
          [rs-out : String (io.arg 3)]
          (if (is-decimal-int? (& seed-s))
            (let
              [pair : PairOut (generate-pair (string.>int (& seed-s)))]
              (io.write-file (& tl-out) (byte_buf.str-as-bytes (& pair.tl)))
              (io.write-file (& rs-out) (byte_buf.str-as-bytes (& pair.rs)))
              0)
            (usage)))]
      [else (usage)])))