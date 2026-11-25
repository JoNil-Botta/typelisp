;; Owner of an `(:opaque)` token type and of a sealed handle that points at one
;; (SPEC 3.5.4, 3.5.5). The owner generates the token's equality and hash hooks
;; where its representation is visible; other modules borrow tokens and copy
;; handles but never see the fields (#8103, #8183).
(module owner_eq_hash_token)

(import stdlib.eq)
(import stdlib.hash)

;: An opaque token: outside this family it is only borrowed or pointed at.
(defstruct Token
  (:opaque)
  (id i64)
  (kind i64))

(eq.gen Token)

(hash.gen Token)

;: Token storage owned by this family; handles point into it. Slots 0 and 2
;: hold equal tokens at distinct addresses.
(define token-pool : (Array Token 4)
  (array (Token 1 7) (Token 2 7) (Token 1 7) (Token 3 8)))

;: Lend CHECK borrows of two equal tokens at distinct addresses and of a
;: different token, so another module can compare and hash them.
(define (check-pool [check : (-> (& Token) (& Token) (& Token) bool)]) : bool
  (check
    (& (array-ref token-pool 0))
    (& (array-ref token-pool 2))
    (& (array-ref token-pool 1))))

;: A sealed handle: it holds a pointer to an opaque token, so only this family
;: mints one, while any module may copy, compare and hash it.
(defstruct TokenKey
  (token (MutPtr Token)))

;: Mint the handle of pool slot INDEX.
(define (token-key [index : i64]) : TokenKey
  (TokenKey
    (unsafe
      (ptr-addr-of (array-ref token-pool index)))))

;: Owner equality: handles are equal when their tokens are. A token holds only
;: scalars, so reading a copy out of the pool is sound.
(define (eq-token-key [left : (& left TokenKey)] [right : (& right TokenKey)]) : bool
  (let
    [left-token : Token
      (unsafe
        (ptr-read left.token))]
    [right-token : Token
      (unsafe
        (ptr-read right.token))]
    (eq-token (& left-token) (& right-token))))

;: Owner hash, deliberately coarse: it keeps the token hash's law but sends
;: every handle to one bucket, so each lookup must confirm with `eq-token-key`.
(define (hash-token-key [value : (& value TokenKey)]) : i64
  (let
    [token : Token
      (unsafe
        (ptr-read value.token))]
    (% (hash-token (& token)) 1)))

;: Owner clone: a copied handle points at the same token.
(define (clone-token-key [value : (& value TokenKey)]) : TokenKey
  (TokenKey value.token))