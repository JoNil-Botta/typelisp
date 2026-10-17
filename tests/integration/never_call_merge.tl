(import stdlib.io)
(import stdlib.test)

(defstruct Pair
  (a i64)
  (b i64))

(defenum Choice
  (Good i64)
  (Bad))

(extern (fail [message : String]) : never (:symbol "tl_abort_string"))

(define (die [message : String]) : never
  (fail message))

(define (sink [value : (&mut value i64)]) : never
  (set! (deref value) 0)
  (io.panic "unexpected sink"))

(define (direct [choice : Choice]) : i64
  (let
    [value : i64
      (match choice
        [(Good n) n]
        [(Bad) (die "unexpected direct")])]
    (+ value 2)))

(define (foreign [choice : Choice]) : i64
  (let
    [value : i64
      (match choice
        [(Good n) n]
        [(Bad) (fail "unexpected foreign")])]
    (+ value 2)))

(define (indirect [choice : Choice] [f : (-> String never)]) : i64
  (let
    [value : i64
      (match choice
        [(Good n) n]
        [(Bad) (f "unexpected indirect")])]
    (+ value 2)))

(define (foreign-indirect
  [choice : Choice]
  [f : (CFunc nullable (-> String never))]) : i64
  (let
    [value : i64
      (match choice
        [(Good n) n]
        [(Bad) ((c-fn-check f) "unexpected foreign indirect")])]
    (+ value 2)))

(define (packed [keep : bool]) : i64
  (let
    [pair : Pair (Pair 20 22)]
    (if keep
      (+ pair.a pair.b)
      (sink (&mut pair.a)))))

(define (main) : i64
  (test.assert-i64-eq (direct (Good 40)) 42 "direct Never merge")
  (test.assert-i64-eq (foreign (Good 40)) 42 "foreign Never merge")
  (test.assert-i64-eq (indirect (Good 40) die) 42 "indirect Never merge")
  (test.assert-i64-eq
    (foreign-indirect (Good 40) (ptr-null : (CFunc nullable (-> String never))))
    42
    "C indirect Never merge")
  (test.assert-i64-eq (packed true) 42 "packed writeback after Never")
  42)