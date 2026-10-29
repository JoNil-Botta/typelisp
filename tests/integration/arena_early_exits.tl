(import stdlib.arena)
(import stdlib.string)

(defenum Parsed
  (Ok i64)
  (Err String))

(defenum Word
  (Ok String)
  (Err i64))

(defenum MaybeText
  (Some String)
  (None))

(defenum Words
  (Ok i64)
  (Err (Array i64 2)))

(defenum Empty
  (Ok i64)
  (Err (Array String 0)))

(define (scalar-return [n : i64]) : i64
  (with-arena
    outer
    (with-arena
      inner
      (let
        [text (string.int->string n)]
        (return (string.string-length text)))))
  0)

(define (outer-return [n : i64]) : String
  (let
    [text (string.int->string n)]
    (with-arena phase (return text))
    ""))

(define (program-return [text : (in program String)]) : (in program String)
  (with-arena phase (return text))
  "")

(define (input-return [owner : (arena.Arena source)]) : (in source String)
  (with-arena phase (return (in-arena owner (string.append "caller" "-owned"))))
  (in-arena owner (string.append "unused" "")))

(define (parse [n : i64]) : Parsed
  (if (> n 0)
    (Parsed.Ok n)
    (Parsed.Err (string.int->string n))))

(define (outer-try [n : i64]) : Parsed
  (let
    [result (parse n)]
    [value : i64 (with-arena phase (try result))]
    (Parsed.Ok value)))

(define (read-word [n : i64]) : Word
  (if (> n 0)
    (Word.Ok (string.int->string n))
    (Word.Err n)))

(define (scalar-try [n : i64]) : Word
  (let
    [length : i64
      (with-arena
        phase
        (let
          [text (try (read-word n))]
          (string.string-length text)))]
    (Word.Ok (string.int->string length))))

(define (maybe-text [present : bool]) : MaybeText
  (if present
    (MaybeText.Some (string.append "four" ""))
    MaybeText.None))

(define (option-try [present : bool]) : MaybeText
  (let
    [length : i64
      (with-arena
        phase
        (let
          [text (try (maybe-text present))]
          (string.string-length text)))]
    (MaybeText.Some (string.int->string length))))

(define (word-array [n : i64]) : Words
  (Words.Err (array n (+ n 1))))

(define (array-try [n : i64]) : Words
  (let
    [value : i64 (with-arena phase (try (word-array n)))]
    (Words.Ok value)))

(define (empty-array) : Empty
  (Empty.Err (make-array String 0)))

(define (empty-try) : Empty
  (let
    [value : i64 (with-arena phase (try (empty-array)))]
    (Empty.Ok value)))

;; Activating an input's arena must retain its older lifetime, even when
;; return executes inside the activation and an inner arena scope.
(defstruct Holder
  (:lifetimes r)
  (owner (arena.Arena r)))

(define (inside-return [owner : (arena.Arena source)] [n : i64]) : (in
    source
    String)
  (with-arena
    phase
    (in-arena
      owner
      (when (> n 0) (return (string.int->string n)))
      (string.append "neg" ""))))

(define (field-return [holder : (& h (Holder r))] [n : i64]) : (in r String)
  (in-arena
    (deref holder).owner
    (when (> n 0) (return (string.int->string n)))
    (string.append "neg" "")))

(defenum RefResult
  (:lifetimes a)
  (Ok i64)
  (Err (& a str)))

(define (check-text [text : (& a str)] [n : i64]) : (RefResult a)
  (if (> n 0)
    (RefResult.Ok n)
    (RefResult.Err text)))

(define (reference-try [text : (& a str)] [n : i64]) : (RefResult a)
  (let
    [value : i64 (with-arena phase (try (check-text text n)))]
    (RefResult.Ok (+ value 1))))

(define (scratch-empty-try) : Empty
  (let
    [value : i64 (with-scratch (try (empty-array)))]
    (Empty.Ok value)))

;; Owned values allocated in an input arena can move into aggregate fields.
(defstruct TextPair
  (left String)
  (right String))

(define (pair-return [owner : (arena.Arena source)]) : (in source TextPair)
  (in-arena
    owner
    (let
      [a (string.append "a" "")]
      [b (string.append "bb" "")]
      (TextPair a b))))

(define (field-pair-return [holder : (& h (Holder r))]) : (in r TextPair)
  (in-arena
    (deref holder).owner
    (let
      [a (string.append "a" "")]
      [b (string.append "bb" "")]
      (TextPair a b))))

(define (enum-return [owner : (arena.Arena source)]) : (in source MaybeText)
  (in-arena
    owner
    (let
      [a (string.append "abc" "")]
      (MaybeText.Some a))))

(define (nested-pair-return [owner : (arena.Arena source)] [n : i64]) : (in
    source
    TextPair)
  (in-arena
    owner
    (let
      [a (string.append "a" "")]
      [b (string.append "bb" "")]
      [length : i64
        (with-arena phase (string.string-length (string.int->string n)))]
      (if (> length 0)
        (TextPair a b)
        (TextPair (string.append "" "") (string.append "" ""))))))

(define (macro-pair-return [owner : (arena.Arena source)] [n : i64]) : (in
    source
    TextPair)
  (in-arena
    owner
    (let
      [a (string.append "a" "")]
      [b (string.append "bb" "")]
      (when (> n 0) (return (TextPair a b)))
      (TextPair a b))))

;; Separate wide binding windows keep the activation apart from the signature.
(define (wide-pair-return [owner : (arena.Arena source)] [n : i64]) : (in
    source
    TextPair)
  (let
    [before0 : i64 n]
    [before1 : i64 (+ before0 0)]
    [before2 : i64 (+ before1 0)]
    [before3 : i64 (+ before2 0)]
    [before4 : i64 (+ before3 0)]
    [before5 : i64 (+ before4 0)]
    [before6 : i64 (+ before5 0)]
    [before7 : i64 (+ before6 0)]
    [before8 : i64 (+ before7 0)]
    [before9 : i64 (+ before8 0)]
    [before10 : i64 (+ before9 0)]
    [before11 : i64 (+ before10 0)]
    [before12 : i64 (+ before11 0)]
    [before13 : i64 (+ before12 0)]
    [before14 : i64 (+ before13 0)]
    [before15 : i64 (+ before14 0)]
    [before16 : i64 (+ before15 0)]
    [before17 : i64 (+ before16 0)]
    [before18 : i64 (+ before17 0)]
    [before19 : i64 (+ before18 0)]
    [before20 : i64 (+ before19 0)]
    [before21 : i64 (+ before20 0)]
    [before22 : i64 (+ before21 0)]
    [before23 : i64 (+ before22 0)]
    [before24 : i64 (+ before23 0)]
    [before25 : i64 (+ before24 0)]
    [before26 : i64 (+ before25 0)]
    [before27 : i64 (+ before26 0)]
    [before28 : i64 (+ before27 0)]
    [before29 : i64 (+ before28 0)]
    [before30 : i64 (+ before29 0)]
    [before31 : i64 (+ before30 0)]
    [before32 : i64 (+ before31 0)]
    [before33 : i64 (+ before32 0)]
    [before34 : i64 (+ before33 0)]
    [before35 : i64 (+ before34 0)]
    [before36 : i64 (+ before35 0)]
    [before37 : i64 (+ before36 0)]
    [before38 : i64 (+ before37 0)]
    [before39 : i64 (+ before38 0)]
    (in-arena
      owner
      (let
        [a (string.append "a" "")]
        [b (string.append "bb" "")]
        [p0 : i64 before39]
        [p1 : i64 (+ p0 0)]
        [p2 : i64 (+ p1 0)]
        [p3 : i64 (+ p2 0)]
        [p4 : i64 (+ p3 0)]
        [p5 : i64 (+ p4 0)]
        [p6 : i64 (+ p5 0)]
        [p7 : i64 (+ p6 0)]
        [p8 : i64 (+ p7 0)]
        [p9 : i64 (+ p8 0)]
        [p10 : i64 (+ p9 0)]
        [p11 : i64 (+ p10 0)]
        [p12 : i64 (+ p11 0)]
        [p13 : i64 (+ p12 0)]
        [p14 : i64 (+ p13 0)]
        [p15 : i64 (+ p14 0)]
        [p16 : i64 (+ p15 0)]
        [p17 : i64 (+ p16 0)]
        [p18 : i64 (+ p17 0)]
        [p19 : i64 (+ p18 0)]
        [p20 : i64 (+ p19 0)]
        [p21 : i64 (+ p20 0)]
        [p22 : i64 (+ p21 0)]
        [p23 : i64 (+ p22 0)]
        [p24 : i64 (+ p23 0)]
        [p25 : i64 (+ p24 0)]
        [p26 : i64 (+ p25 0)]
        [p27 : i64 (+ p26 0)]
        [p28 : i64 (+ p27 0)]
        [p29 : i64 (+ p28 0)]
        [p30 : i64 (+ p29 0)]
        [p31 : i64 (+ p30 0)]
        [p32 : i64 (+ p31 0)]
        [p33 : i64 (+ p32 0)]
        [p34 : i64 (+ p33 0)]
        [p35 : i64 (+ p34 0)]
        [p36 : i64 (+ p35 0)]
        [p37 : i64 (+ p36 0)]
        [p38 : i64 (+ p37 0)]
        [p39 : i64 (+ p38 0)]
        (if (= p39 n)
          (TextPair a b)
          (TextPair (string.append "" "") (string.append "" "")))))))

(define (pair-length [pair : (& a TextPair)]) : i64
  (+
    (string.string-length (deref pair).left)
    (string.string-length (deref pair).right)))

(define (main) : i64
  (unless (= (scalar-return -12345) 6) (return 1))
  (unless (= (string.string-length (outer-return -12345)) 6) (return 2))
  (unless (= (string.string-length (program-return "program")) 7) (return 3))
  (let
    [owner (arena.make)]
    [text (input-return owner)]
    (unless (= (string.string-length text) 12) (return 4)))
  (match (outer-try -12345)
    [(Parsed.Ok _) (return 5)]
    [(Parsed.Err text) (unless (= (string.string-length text) 6) (return 6))])
  (match (outer-try 7)
    [(Parsed.Ok n) (unless (= n 7) (return 7))]
    [(Parsed.Err _) (return 8)])
  (match (scalar-try -9)
    [(Word.Ok _) (return 9)]
    [(Word.Err n) (unless (= n -9) (return 10))])
  (match (scalar-try 9)
    [(Word.Ok text) (unless (string.eq (& text) "1") (return 11))]
    [(Word.Err _) (return 12)])
  (match (option-try false)
    [(MaybeText.Some _) (return 13)]
    [(MaybeText.None) unit])
  (match (option-try true)
    [(MaybeText.Some text) (unless (string.eq (& text) "4") (return 14))]
    [(MaybeText.None) (return 15)])
  (match (array-try 41)
    [(Words.Ok _) (return 16)]
    [(Words.Err items)
      (unless (= (+ (array-ref items 0) (array-ref items 1)) 83) (return 17))])
  (match (empty-try)
    [(Empty.Ok _) (return 18)]
    [(Empty.Err items) (unless (= (array-length items) 0) (return 19))])
  (let
    [saved : i64 (arena.tl_arena_current)]
    [owner (arena.make)]
    [owner-tail (arena.make)]
    [atomic (arena.make-atomic)]
    [holder (Holder (arena.make))]
    [early (inside-return owner 12345)]
    [tail (inside-return owner-tail -1)]
    [shared (inside-return atomic 12345)]
    [field (field-return (& holder) 12345)]
    (unless (string.eq (& early) "12345") (return 20))
    (unless (string.eq (& tail) "neg") (return 21))
    (unless (string.eq (& shared) "12345") (return 22))
    (unless (string.eq (& field) "12345") (return 23))
    (match (reference-try (& early) -1)
      [(RefResult.Ok _) (return 24)]
      [(RefResult.Err text)
        (unless (= (string.string-length text) 5) (return 25))])
    (match (reference-try (& shared) 41)
      [(RefResult.Ok n) (unless (= n 42) (return 26))]
      [(RefResult.Err _) (return 27)])
    (unless (= (arena.tl_arena_current) saved) (return 30)))
  (match (scratch-empty-try)
    [(Empty.Ok _) (return 28)]
    [(Empty.Err items) (unless (= (array-length items) 0) (return 29))])
  (let
    [pair-owner (arena.make)]
    [pair (pair-return pair-owner)]
    [atomic-owner (arena.make-atomic)]
    [atomic-pair (pair-return atomic-owner)]
    [holder (Holder (arena.make))]
    [field-pair (field-pair-return (& holder))]
    [nested-owner (arena.make)]
    [nested-pair (nested-pair-return nested-owner 7)]
    [early-owner (arena.make)]
    [macro-early (macro-pair-return early-owner 7)]
    [tail-owner (arena.make)]
    [macro-tail (macro-pair-return tail-owner -1)]
    [wide-owner (arena.make)]
    [wide-pair (wide-pair-return wide-owner 7)]
    [local-owner (arena.make)]
    [local-pair
      (in-arena
        local-owner
        (let
          [a (string.append "a" "")]
          [b (string.append "bb" "")]
          (TextPair a b)))]
    (unless (= (pair-length (& pair)) 3) (return 31))
    (unless (= (pair-length (& atomic-pair)) 3) (return 32))
    (unless (= (pair-length (& field-pair)) 3) (return 33))
    (unless (= (pair-length (& nested-pair)) 3) (return 34))
    (unless (= (pair-length (& macro-early)) 3) (return 35))
    (unless (= (pair-length (& macro-tail)) 3) (return 36))
    (unless (= (pair-length (& wide-pair)) 3) (return 37))
    (unless (= (pair-length (& local-pair)) 3) (return 38)))
  (let
    [owner (arena.make)]
    (match (enum-return owner)
      [(MaybeText.Some text)
        (unless (= (string.string-length text) 3) (return 39))]
      [(MaybeText.None) (return 40)]))
  42)