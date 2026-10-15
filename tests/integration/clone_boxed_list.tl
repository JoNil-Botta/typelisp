(import stdlib.arena)
(import stdlib.string)

(defenum TextList
  (End)
  (Item String (Box TextList)))

;; Reverse declaration order exercises the other structural list match.
(defenum BoxList
  (More (Box i64) (Box BoxList))
  (Done))

(define (make-text-list [count : i64]) : TextList
  (let
    [value : TextList (End)]
    [index : i64 0]
    (while (< index count)
      (set! value (Item (string.int->string index) (box value)))
      (+= index 1))
    value))

(define (valid-text-list? [value : TextList] [expected : i64]) : bool
  (match value
    [(End) (= expected -1)]
    [(Item head tail)
      (if (string.eq head (string.int->string expected))
        (valid-text-list? (deref tail) (- expected 1))
        false)]))

(define (text-list-case [home : arena.Arena] [count : i64]) : bool
  (let
    [scratch : arena.Arena (arena.make)]
    (unsafe
      (arena.set! scratch))
    (let
      [source : TextList (make-text-list count)]
      (unsafe
        (arena.set! home))
      (let
        [copied : TextList (clone source)]
        [source-valid : bool (valid-text-list? source (- count 1))]
        (unsafe
          (arena.destroy scratch))
        (and source-valid (valid-text-list? copied (- count 1)))))))

(define (box-list-total [value : (& value BoxList)]) : i64
  (match value
    [(Done) 0]
    [(More head tail) (+ (deref head) (box-list-total (deref tail)))]))

(define (box-list-case) : bool
  (let
    [source : BoxList (More (box 7) (box (More (box 8) (box (Done)))))]
    [copied : BoxList (clone source)]
    [empty : BoxList (clone (Done))]
    (match copied
      [(Done) false]
      [(More head tail)
        (set! (deref head) 99)
        (match (deref tail)
          [(Done) false]
          [(More second end)
            (set! (deref second) 100)
            (and
              (= (box-list-total (& source)) 15)
              (= (deref head) 99)
              (= (deref second) 100)
              (match (deref end)
                [(Done) true]
                [_ false])
              (match empty
                [(Done) true]
                [_ false]))])])))

(define (main) : i64
  (let
    [home : arena.Arena (arena.current)]
    (if (and
      (text-list-case home 0)
      (text-list-case home 1)
      (text-list-case home 30000)
      (box-list-case))
      42
      1)))