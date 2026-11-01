(import stdlib.arena)

;; Receiver control flow carries the selected logical place through scope
;; cleanup. Receiver, selected arm, index and RHS each run exactly once.
(defstruct Row
  (items (Array i64 2)))

(defenum Choice
  (Left i64)
  (Right i64))

(define trace : i64
  0)

(define (visit [digit : i64]) : unit
  (set! trace (+ (* trace 10) digit)))

(define (cleanup [digit : i64]) : unit
  (visit digit))

(define (matched? [choice : Choice]) : bool
  (let
    [rows : (__tl_dyn-array Row) (__tl_make-array (Row (array 1 2)))]
    [fixed : (Array i64 2) (array 3 4)]
    (begin
      (set! trace 0)
      (set!
        (array-ref
          (match (begin
            (visit 1)
            choice)
            [(Left digit)
              (begin
                (visit digit)
                (array-ref rows 0).items)]
            [(Right digit)
              (begin
                (visit digit)
                fixed)])
          (begin
            (visit 4)
            0))
        (begin
          (visit 5)
          (__tl_array-push! rows (Row (array 8 9)))
          40))
      (and
        (= (array-length rows) 2)
        (match choice
          [(Left _)
            (and
              (= trace 1245)
              (= (array-ref (array-ref rows 0).items 0) 40)
              (= (array-ref fixed 0) 3))]
          [(Right _)
            (and
              (= trace 1345)
              (= (array-ref fixed 0) 40)
              (= (array-ref (array-ref rows 0).items 0) 1))])))))

(define (matched-return? [choose : bool]) : bool
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (set!
        (array-ref
          (match choose
            [true (return true)]
            [false items])
          0)
        40)
      (= (array-ref items 0) 40))))

(define (scoped? [mode : i64]) : bool
  (let
    [rows : (__tl_dyn-array Row) (__tl_make-array (Row (array 1 2)))]
    [owner : arena.Arena (arena.make)]
    (begin
      (set! trace 0)
      (set!
        (array-ref
          (match mode
            [0
              (with
                ([resource
                    (begin
                      (visit 1)
                      3)
                    cleanup])
                (begin
                  (visit 2)
                  (array-ref rows 0).items))]
            [1 (with-arena region (visit 1) (visit 2) (array-ref rows 0).items)]
            [_ (in-arena owner (visit 1) (visit 2) (array-ref rows 0).items)])
          (begin
            (visit 4)
            0))
        (begin
          (visit 5)
          (__tl_array-push! rows (Row (array 8 9)))
          40))
      (and
        (=
          trace
          (if (= mode 0)
            12345
            1245))
        (= (array-ref (array-ref rows 0).items 0) 40)
        (= (array-ref (array-ref rows 0).items 1) 2)
        (= (array-length rows) 2)))))

(define (fresh [digit : i64]) : (Array i64 2)
  (begin
    (visit digit)
    (array 1 2)))

(define (fresh?) : bool
  (let
    [scratch : arena.Arena (arena.make)]
    (begin
      (set! trace 0)
      (set!
        (array-ref
          (array
            (begin
              (visit 1)
              1)
            2)
          (begin
            (visit 2)
            0))
        (begin
          (visit 3)
          40))
      (set!
        (array-ref
          (fresh 4)
          (begin
            (visit 5)
            0))
        (begin
          (visit 6)
          40))
      (set!
        (array-ref
          (with-scratch (fresh 7))
          (begin
            (visit 8)
            0))
        (begin
          (visit 9)
          40))
      (set!
        (array-ref
          (with-escape scratch (fresh 1))
          (begin
            (visit 2)
            0))
        (begin
          (visit 3)
          40))
      (= trace 123456789123))))

(define (borrowed-match? [choice : Choice]) : bool
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (set! trace 0)
      (set!
        (array-ref
          (match (& choice)
            [(Left digit)
              (begin
                (visit digit)
                items)]
            [(Right digit)
              (begin
                (visit digit)
                items)])
          0)
        40)
      (and (= trace 2) (= (array-ref items 0) 40)))))

(define (forward [items : (&mut items (Array i64 2))]) : (&mut
    items
    (Array i64 2))
  items)

(define (reference-receiver? [choose : bool]) : bool
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (set!
        (array-ref
          (match choose
            [true (forward (&mut items))]
            [false (forward (&mut items))])
          0)
        40)
      (= (array-ref items 0) 40))))

(define (scoped-return [choose : bool]) : bool
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (set!
        (array-ref
          (with
            ([resource 3 cleanup])
            (if choose
              (return true)
              items))
          (begin
            (visit 4)
            0))
        (begin
          (visit 5)
          40))
      (= (array-ref items 0) 40))))

(define (scoped-return? [choose : bool]) : bool
  (begin
    (set! trace 0)
    (and
      (scoped-return choose)
      (=
        trace
        (if choose
          3
          345)))))

(define (main) : i64
  (cond
    [(not (matched? (Left 2))) 1]
    [(not (matched? (Right 3))) 2]
    [(not (matched-return? true)) 3]
    [(not (matched-return? false)) 4]
    [(not (scoped? 0)) 5]
    [(not (scoped? 1)) 6]
    [(not (scoped? 2)) 7]
    [(not (fresh?)) 8]
    [(not (borrowed-match? (Left 2))) 9]
    [(not (borrowed-match? (Right 2))) 10]
    [(not (reference-receiver? true)) 11]
    [(not (reference-receiver? false)) 12]
    [(not (scoped-return? true)) 13]
    [(not (scoped-return? false)) 14]
    [else 42]))