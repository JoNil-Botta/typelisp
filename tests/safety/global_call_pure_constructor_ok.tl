(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defenum Choice
  (A)
  (B))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (choose [choice : Choice]) : Choice
  (match choice
    [A (A)]
    [B (B)]))

(define (write-local!) : unit
  (match 0
    [g (set! g 1)]))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (Big 5 6 7 8)
    (match (Choice.A)
      [Choice.A (Choice.A)]
      [Choice.B (Choice.B)])
    (let
      [choice (A)]
      [choice (choose choice)]
      (match choice
        [A (A)]
        [B (B)]))
    (match (if true
      (A)
      (B))
      [A (A)]
      [B (B)])
    (write-local!)
    (let
      [items : (Array i64 2) (array 10 20)]
      [view (slice-view items 0 1)]
      (array-ref view 0))
    (let
      [word : i64 0]
      (unsafe
        (atomic-store! (ptr-addr-of word) 42)
        (atomic-load (ptr-addr-of word))))
    r.a))

(define (main) : i64
  (let
    [writer rebind!]
    (read-after (& g))))