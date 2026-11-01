;; A call whose signature brands an `(in r T)` parameter with the arena an
;; owner parameter binds, by value or behind `&`, takes an allocation of that
;; arena: an owned value of the ownership graph, whose brand ends with the
;; arena. These are main's `arena_branded_operands` case 12 forms (#8993): the
;; value built in the call or bound inside the `in-arena`, the branded value
;; before the owner, a brand bound by the caller's own arena parameter, and a
;; branded result kept until the arena is destroyed. Checked only: running it
;; needs main's branded operand lowering (#8993).
(import stdlib.arena)
(import stdlib.string)

(define (by-value [_owner : (arena.Arena r)] [_text : (in r String)]) : i64
  2)

(define (by-reference [_owner : (& a (arena.Arena r))] [_text : (in r String)]) : i64
  2)

(define (text-first [_text : (in r String)] [_owner : (& a (arena.Arena r))]) : i64
  2)

(define (keep [_o : (& a (arena.Arena r))] [t : (in r String)]) : (in r String)
  t)

(define (built-in-call) : i64
  (let
    [owner (arena.make)]
    (in-arena owner (by-value owner (string.append "a" "b")))))

(define (borrowed-owner) : i64
  (let
    [owner (arena.make)]
    (in-arena owner (by-reference (& owner) (string.append "a" "b")))))

(define (bound-in-scope) : i64
  (let
    [owner (arena.make)]
    (in-arena
      owner
      (let
        [first (string.append "inside" "-scope")]
        [second (string.append "inside" "-again")]
        (+ (by-reference (& owner) first) (text-first second (& owner)))))))

(define (parameter-brand [owner : (& a (arena.Arena r))] [text : (in r String)]) : i64
  (by-reference owner text))

(define (kept-until-destroyed) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (keep (& owner) (string.append "a" "b")))]
    [length (string.string-length text)]
    (begin
      (arena.destroy-safe! owner)
      length)))

(define (main) : i64
  (let
    [owner (arena.make)]
    [text (in-arena owner (string.append "x" "y"))]
    (+
      (built-in-call)
      (borrowed-owner)
      (bound-in-scope)
      (parameter-brand (& owner) text)
      (kept-until-destroyed)
      30)))