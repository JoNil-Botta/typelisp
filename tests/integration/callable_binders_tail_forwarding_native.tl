;; Tail calls that return a lifetime-parameterized struct or enum forward the
;; caller's return slot by declaration identity, across explicit returns, `try`
;; propagation and indirect dispatch (Refs #9098).
(import stdlib.io)

(defstruct Pair
  (:lifetimes a)
  (left (& a i64))
  (middle (& a i64))
  (right (& a i64)))

(defenum Word
  (:lifetimes a)
  (Ok (Pair a))
  (Err (& a i64)))

(define (make-pair [x : (& a i64)] [n : i64]) : (Pair a)
  (when (> n 10) (return (make-pair x (- n 1))))
  (when (= n 0) (return (Pair x x x)))
  (Pair x x x))

(define (wrap-pair [y : (& b i64)] [n : i64])
  (:export-symbol "tail_forward_wrap_pair") : (Pair b)
  (make-pair y n))

(define (check-ref [x : (& a i64)] [n : i64]) : (Word a)
  (if (= n 0)
    (Word.Err x)
    (Word.Ok (Pair x x x))))

(define (checked [x : (& a i64)] [n : i64]) : (Word a)
  (when (> n 10) (return (checked x (- n 1))))
  (let
    [p : (Pair a) (try (check-ref x n))]
    (Word.Ok p)))

(define (wrap-word [y : (& b i64)] [n : i64])
  (:export-symbol "tail_forward_wrap_word") : (Word b)
  (checked y n))

(define (indirect [cb : (-> (& c i64) i64 (Word c))] [y : (& b i64)] [n : i64])
  (:export-symbol "tail_forward_indirect") : (Word b)
  (cb y n))

(define (score [r : (Word a)]) : i64
  (match r
    [(Word.Ok p) (deref p.right)]
    [(Word.Err e) (deref e)]))

;; Counts above 10 take the explicit-return tail calls down to 10 before the
;; direct path; 0 takes the zero-count return and the `try` exit on `Err`.
(define (main) : i64
  (let
    [n : i64 (- (io.arg-count) 1)]
    [x : i64 7]
    [first : (Pair x) (wrap-pair (& x) n)]
    [second : (Pair x) (wrap-pair (& x) (+ n 12))]
    [ok : i64 (score (wrap-word (& x) (+ n 12)))]
    [err : i64 (score (wrap-word (& x) n))]
    [iok : i64 (score (indirect wrap-word (& x) (+ n 12)))]
    [ierr : i64 (score (indirect wrap-word (& x) n))]
    (+ (+ (deref first.left) (deref second.middle)) (+ (+ ok err) (+ iok ierr)))))