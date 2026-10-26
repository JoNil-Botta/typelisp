;; A `&mut` reborrowed into a `program` region (a `(&mut program T)` parameter
;; or field) stays borrowed for the rest of the body, as a reborrow for Rust's
;; `'static` does: wrapping `r` twice would hand `use2` two aliasing `&mut`s,
;; and `two` then frees the string `s` still views. Main 4e46ce356 accepts it.
(import stdlib.string)

(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (m (&mut program Pt)))

(define (wrap [r : (&mut program Pt)]) : Holder
  (Holder r))

(define (two [x : (&mut x Pt)] [y : (&mut y Pt)]) : i64
  (let
    [s x.name]
    [_old (replace! y.name "new")]
    (string.string-length (& s))))

(define (use2 [a : Holder] [b : Holder]) : i64
  (two a.m b.m))

(define (go [r : (&mut program Pt)]) : i64
  (use2 (wrap r) (wrap r)))

(define (main) : i64
  42)