;; #9604: valid stores into a by-value arena parameter's brand region, which
;; is a caller region outliving the parameters.
(import stdlib.arena)
(import stdlib.string)

(defstruct RefBox
  (:lifetimes m)
  (value (& m i64)))

(defstruct Pair
  (:lifetimes m)
  (left (& m i64))
  (right (& m i64)))

; A reference of the brand's own lifetime may be stored in brand storage.
(define (store-brand
  [v : (& r i64)]
  [ar : (arena.Arena r)]
  [out : (&mut r (RefBox r))]) : unit
  (set! out.value v))

; Data allocated in the brand's arena may be stored in brand storage.
(define (store-allocated [ar : (arena.Arena r)] [out : (&mut r (RefBox r))]) : unit
  (in-arena
    ar
    (let
      [cell (box (ann 9 : i64))]
      (set! out.value (& (deref cell))))))

; A by-value parameter may hold brand data: the brand outlives it.
(define (copy-brand-value
  [held : (RefBox r)]
  [ar : (arena.Arena r)]
  [out : (&mut r (RefBox r))]) : unit
  (set! out.value held.value))

; Brand data may be stored where a parameter's storage is required: the brand
; outlives the call.
(define (store-into-storage-slot
  [a : i64]
  [ar : (arena.Arena r)]
  [v : (& r i64)]
  [slot : (&mut a (RefBox a))]) : unit
  (set! slot.value v))

; An invalidated brand ends inside the call, so parameter storage outlives it.
(define (store-before-release
  [a : i64]
  [ra : (& a i64)]
  [owner : (arena.Arena owner) (:invalidate owner)]
  [out : (&mut owner (RefBox owner))]) : unit
  (begin
    (set! out.value ra)
    (arena.destroy-safe! owner)))

; A branded helper may return arena-allocated data tied to its brand.
(define (allocate-text [ar : (arena.Arena r)]) : (in r String)
  (in-arena ar (string.append "brand" "-text")))

; A self-named arena owner's brand is a caller region too.
(define (self-named [owner : (arena.Arena owner)] [v : (& owner i64)]) : (Pair
    owner)
  (Pair v v))

(define (main) : i64
  (let
    [ar (arena.make)]
    [seen : i64
      (in-arena
        ar
        (let
          [slot (box (ann 5 : i64))]
          [bx (RefBox (& (deref slot)))]
          (begin
            (store-allocated ar (&mut bx))
            (deref bx.value))))]
    (if (= seen 9)
      42
      1)))