;; Refs #7418: an enum payload moved to a loop-carried local must outlive
;; reuse of the match scrutinee's result slot on the next iteration.
(defstruct Cursor
  (position i64)
  (remaining i64)
  (padding i64))

(defstruct WrappedCursor
  (marker i64)
  (cursors (Array Cursor 1)))

(defenum Step
  (Stop)
  (Next WrappedCursor))

(defmacro (shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(define (advance [cursor : Cursor]) : Step
  (if (= cursor.remaining 0)
    (Step.Stop)
    (Step.Next
      (WrappedCursor
        77
        (array (Cursor (+ cursor.position 1) (- cursor.remaining 1) 99))))))

(define (snapshot-digits [count : i64] [route : i64]) : i64
  (let
    [cursor : Cursor (Cursor 0 count 99)]
    [snapshots : (Array Cursor 4) (init)]
    [latest : (MutPtr Cursor) (ptr-null : (MutPtr Cursor))]
    [index : i64 0]
    [digits : i64 0]
    (begin
      (while (< index count)
        (match (advance (shared-view cursor))
          [(Step.Stop) (set! index count)]
          [(Step.Next rest)
            (begin
              ;; Raw pointer assignment copies the address, not the pointee.
              (set!
                latest
                (unsafe
                  (ptr-addr-of (array-ref rest.cursors 0))))
              (unless
                (=
                  (unsafe
                    (ptr->int latest))
                  (unsafe
                    (ptr->int (ptr-addr-of (array-ref rest.cursors 0)))))
                (set! digits 9000))
              (set! (array-ref snapshots index) (shared-view cursor))
              (match route
                [1
                  ;; The producer belongs to the outer loop while the
                  ;; assignment happens inside an inner loop.
                  (let
                    [once : bool true]
                    (while once
                      (begin
                        (set! cursor (array-ref rest.cursors 0))
                        (set! once false))))]
                [2
                  (set!
                    cursor
                    (if (= index 0)
                      (array-ref rest.cursors 0)
                      (Cursor (+ cursor.position 1) (- cursor.remaining 1) 99)))]
                [3
                  (set!
                    cursor
                    (match index
                      [0 (array-ref rest.cursors 0)]
                      [_
                        (Cursor (+ cursor.position 1) (- cursor.remaining 1) 99)]))]
                [_ (set! cursor (array-ref rest.cursors 0))])
              (set! index (+ index 1)))]))
      (set! index 0)
      (while (< index count)
        (begin
          (set! digits (+ (* digits 10) (array-ref snapshots index).position))
          (set! index (+ index 1))))
      digits)))

(define (main) : i64
  (if (and
    (= (snapshot-digits 0 0) 0)
    (= (snapshot-digits 1 0) 0)
    (= (snapshot-digits 2 0) 1)
    (= (snapshot-digits 4 0) 123)
    (= (snapshot-digits 4 0) 123)
    (= (snapshot-digits 0 1) 0)
    (= (snapshot-digits 1 1) 0)
    (= (snapshot-digits 2 1) 1)
    (= (snapshot-digits 4 1) 123)
    (= (snapshot-digits 4 1) 123)
    (= (snapshot-digits 0 2) 0)
    (= (snapshot-digits 1 2) 0)
    (= (snapshot-digits 2 2) 1)
    (= (snapshot-digits 4 2) 123)
    (= (snapshot-digits 4 2) 123)
    (= (snapshot-digits 0 3) 0)
    (= (snapshot-digits 1 3) 0)
    (= (snapshot-digits 2 3) 1)
    (= (snapshot-digits 4 3) 123)
    (= (snapshot-digits 4 3) 123))
    42
    1))