;; Compiler-owned payload codec (v3): one LZ77 + canonical Huffman coder for
;; every embedded payload, replacing the v1/v2 LZSS envelopes.
;;
;; A frame is the 36-byte marker, the decimal raw byte length and a newline,
;; then a token bitstream, most significant bit first, zero-padded to a byte.
;;
;; A token is one symbol of the literal-context model for the current output
;; position: 0..255 is that literal byte, 256 is a match with a new distance,
;; 257..260 are matches with repeat distance 0..3, and 261 is a repeat-0 match
;; of length one. A match carries a length symbol and its extra bits, plus for
;; a new distance a distance bucket and its extra bits. The model is chosen by
;; the context `literal class * 2 + (position & 1)`, where the class is a fixed
;; 8-way split of the previous output byte.
;;
;; Source frames carry no model: the compiler's fixed model below applies. The
;; stdlib catalog envelope stores one model for its whole stream.
(import stdlib.string)
(import stdlib.str_cat_runtime as str_cat)
(import stdlib.byte_buf_core as byte_buf)
(import compiler_owned_view as owned_view)
(import compiler_abort as abort)
(import compiler_lzss_v2 as lzss_v2)

(defenum CompilerLzssFrame
  (Err String)
  ;; uncompressed byte length, first token-stream input byte
  (Ok i64 i64))

(defenum CompilerLzssBytes
  (Err String)
  (Ok (__tl_dyn-array u8)))

(defenum CompilerLzssCheck
  (Err String)
  (Ok unit))

;; Built from two halves so no literal holds the whole marker: literal bytes
;; carry no NUL and may run into an adjacent literal, which a binary scanner
;; would mistake for a frame.
(define (compiler-lzss-envelope-prefix) : String
  (str_cat.str-cat "__typelisp_embedded_" "stdlib_tlss_v3__"))

;; Tokens and symbols.
(define (compiler-lzss-match-new) : i64
  256)

(define (compiler-lzss-match-rep) : i64
  257)

(define (compiler-lzss-shortrep) : i64
  261)

;; Format constants.
(define (compiler-lzss-contexts) : i64
  16)

(define (compiler-lzss-main-symbols) : i64
  262)

(define (compiler-lzss-length-symbols) : i64
  29)

(define (compiler-lzss-length-buckets) : i64
  4)

(define (compiler-lzss-distance-symbols) : i64
  48)

(define (compiler-lzss-max-code-bits) : i64
  15)

(define (compiler-lzss-min-match) : i64
  3)

(define (compiler-lzss-max-match) : i64
  258)

;; Largest distance any frame may use, and with it the encoder's window.
(define (compiler-lzss-window) : i64
  16777216)

;; One compressed byte expands to at most 8 * 258 = 2064 output bytes.
(define (compiler-lzss-max-expansion) : i64
  2064)

;; Literal and match symbols share one alphabet per context, so decoding reads
;; one context table; a direct table of `bits` bits covers most codes and the
;; canonical walk finishes the rest.
;; Check a stored model before anything decodes with it: every symbol needs a
;; code of at most `max-code-bits`, and no table may claim more code space than
;; a prefix code allows (a Kraft sum over one).
(define (compiler-lzss-model-check [lengths : (& lengths (__tl_dyn-array i64))]) : CompilerLzssCheck
  (let
    [contexts : i64 (compiler-lzss-contexts)]
    [main-symbols : i64 (compiler-lzss-main-symbols)]
    [length-start : i64 (* contexts main-symbols)]
    [distance-start : i64 (+ length-start (compiler-lzss-length-symbols))]
    [limit : i64 (shl 1 (compiler-lzss-max-code-bits))]
    [context : i64 0]
    [ok : bool (= (array-length lengths) (compiler-lzss-model-spec-bytes))]
    (while (and ok (< context contexts))
      (unless
        (compiler-lzss-table-check
          lengths
          (* context main-symbols)
          main-symbols
          limit)
        (set! ok false))
      (set! context (+ context 1)))
    (when
      ok
      (unless
        (compiler-lzss-table-check
          lengths
          length-start
          (compiler-lzss-length-symbols)
          limit)
        (set! ok false)))
    (set! context 0)
    (while (and ok (< context (compiler-lzss-length-buckets)))
      (unless
        (compiler-lzss-table-check
          lengths
          (+ distance-start (* context (compiler-lzss-distance-symbols)))
          (compiler-lzss-distance-symbols)
          limit)
        (set! ok false))
      (set! context (+ context 1)))
    (if ok
      (Ok unit)
      (Err "compiler lzss: invalid stored model"))))

(define (compiler-lzss-table-check
  [lengths : (& lengths (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]
  [limit : i64]) : bool
  (let
    [index : i64 0]
    [total : i64 0]
    [ok : bool true]
    (while (and ok (< index n))
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (cond
          [(< length 1) (set! ok false)]
          [(> length (compiler-lzss-max-code-bits)) (set! ok false)]
          [else (+= total (shl 1 (- (compiler-lzss-max-code-bits) length)))]))
      (set! index (+ index 1)))
    (and ok (<= total limit))))

;; Bytes of one stored model: every table's code lengths as 'A' + length.
(define (compiler-lzss-model-spec-bytes) : i64
  (+
    (* (compiler-lzss-contexts) (compiler-lzss-main-symbols))
    (compiler-lzss-length-symbols)
    (* (compiler-lzss-length-buckets) (compiler-lzss-distance-symbols))))

(define (compiler-lzss-main-lookup-bits) : i64
  10)

(define (compiler-lzss-length-lookup-bits) : i64
  5)

(define (compiler-lzss-distance-lookup-bits) : i64
  6)

;; Encoder search: hash-chain links per position and the lazy-match cap.
(define (compiler-lzss-chain-links) : i64
  128)

(define (compiler-lzss-lazy-floor) : i64
  12)

;; The fixed model's symbol spec: one character 'A' + code length per symbol,
;; in this order: 16 context tables of 262 symbols, the 29 length symbols, and
;; the 4 distance buckets of 48 symbols. The code lengths were trained on the
;; embedded stdlib sources; a different payload stays decodable, only its ratio
;; depends on them.
(define compiler-lzss-fixed-spec : String
  (str_cat.str-cat
    "JJJJJJJJJJIJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJCJJJJJJJJJJJJ"
    "JJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJIIII"
    "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII"
    "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIJJJJJJJJJJJJIIIIIIIIIIIIII"
    "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII"
    "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII"
    "IIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII"
    "IIIIIIIIIIIIIIIIIIIILLLLLLLLLLFLLLLLLLLLLLLLLLLLLLLLELLLLLLLFLLLLKKKKKKK"
    "KKKKKKKDKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK"
    "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK"
    "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKBIHHIKLLLLLL"
    "LLLLELLLLLLLLLLLLLLLLLLLLLELLLLLLLFLLLLLLLLLLLLLLLLLLDLLLLLLLLLLLLLLLLLL"
    "LLLLLLLLLLLLLLLLLLLLLLKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK"
    "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKK"
    "KKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKKBHHJKKPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
    "GPIOPPOKFPNLIILMGGHIIJIKJJHKLMNOPIJIKJJLLINLKKJJJPIIIJLKNPMGPPPJGFGGHHGJ"
    "IFKJHHHFHLGGGHIHKKKPOPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
    "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPOPPPPPPPPPPPPPPPPPPPPP"
    "PPPPPPPPBJGIJPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPGOHOPPPLFPOMIJMMGGHIIJJKJJ"
    "HKMNMPPIJIJJJKLJNLJKJJJOJIIJKKNNMGPPPKGFGGHGGJIFKJHHHGGLGGGHIHLLKNNPPPPP"
    "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
    "PPPPPPPPPPPPPPPPPPPPPPPPNPPPPPPPPPPPPPPPPPPPPPPPPPPPPPBIGIIPOOOOOOOOOOJO"
    "OOONNNNNNNNNNNNNNNNNFLKNNMNMMFMMKIHJEFEFEFEFFFKLNMMNNMMNMMLNMMNMMLMLMNML"
    "MLMNMNNNNHKKJGGFGGGNNNNNNNNNMNNNNNMNJNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
    "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
    "NNNNNNNNNNNNNNNNNNNNNNNNNNNNCEHIJNNNNNNNNNNNJNNNNNNNNNNNNNNNNNNNNNFLKNNN"
    "NKLFNMJIHKEFEFEFFFFFLLNMNNNNMMLNLNNLNMMMLLNNMMMNMNNNMNNHKLIGGFGGFNNNNNNN"
    "NMNNNNNNNNJNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
    "NNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNNN"
    "NNCEGHIMPPPPPPPPPPJPPPPPPPPPPPPPPPPPPPPPEJKPPPPKPHPPIGHJJIJIJJIJIJJJPPPJ"
    "PPLLPKLPPMPPKLLKLPLLLPPPPPPPPKPJIFHGFEGHGFPIFGEFGKEFEGHHIHKPPPPPPPPPPPPP"
    "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
    "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPCIIJKPPPPPPPPPPPJPPPPPPP"
    "PPPPPPPPPPPPPPEJKPPPPKPHPPHGHKJJJIJJIJJJJJPPPJPPLLPLLPPPPPLPMKLPPLLPPPPP"
    "PPPKPJIFHGFEGHGFLIFGEFGKEFEGIHIGKPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
    "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP"
    "PPPPPPPPPPPPPPPPPPPPPPCIIKKPMMMMMMMMMMLMMMMMMMMMMMMMMMMMMMMMFMJMMMMKLHMM"
    "IHIHKLLKKKIMMMKJMKMMMGIHHGHIJFLJHHHHGKHGGHJJIJLLMMMIIFJJIEKMGFMGGHFEHLFH"
    "FFJJHIMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM"
    "MMMMMMMLMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMCIKL"
    "KMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMFLJMMLMKLIMKIHIIKKKKKLJMMMKKMKLLMHIGHG"
    "HIIGLIHIHHGKGGGIJJKKKLLMMIIFKIIEJMFFMGHHFEHKFGFFIKHHMMMMMMMMMMMMMMMMMMMM"
    "MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM"
    "MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMCIJKLMPPPPPPOOOOHOOOOOOOOOOOOO"
    "OOOOOOOODJIJMKHKIGIGIHIJJIJKKLNLLMHJHGHNKKLLLKLLNKOMMJLKKMLKJMLMMNNKKHNI"
    "HGHGHHHJJGLJHHHHHKHGHIIIKLKMNMNOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"
    "OOOOOOOOOOOOOOOOOOOOOOOOOOONOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"
    "OOOOOOOOOOOOOOOOBHHIJOPPPPPPPPPPHPPPPPPPPPPPPPPPPPPPPPDJIHNKHLIGIHIHIJJI"
    "KKLMMLLMHJHGHMLKLLLKLMMKNMMKLKKMLKJMLMNPNKKGNIHGHGHHHKJGLJHHHHHKHGHIJIKM"
    "KMNMNOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO"
    "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOBHHIIOMMLL"
    "LLLLLLELLLLLLLLLLLLLLLLLLLLLDKILLLLILJLLLLGKIIIKIIKIJJLLLLKLLJIKKIKLKHLL"
    "LJKJJLJJJKILLLLLLJLLJIIHJGJJJHKKHJHKHLJGHKJJKKLLLLLLJLLLLLLLLLLLLLLLLLLL"
    "KLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL"
    "LLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLBIJKKLLLLLLLLLLLELLLLLLLLLLLLLLLLLLL"
    "LLDLILLLLLLJLLLLGKHIIJKJJKKJLLLKLLLKHJKIKLLIKLKLLJJLKKJLILLLLLKJLLJIIHKH"
    "IIIHLJHKHIHLJGHJJIKLLLLLLLKLLLLLLLLLLLLLLLLLLLKLLLLLLLLLLLLLLLLLKLLLLLLL"
    "LLLLLLLLJLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLLL"
    "LLLLLLLLLLBIHJKLGEDDEEEFEEEFEFFGFGGHHIIJJKLLJGKHIHGFFEEEEDEEEDFEFFGGIJLJ"
    "NNNNNOONNNNNNNNNNNNNNIMMNKIHHGGFFEFEFEFEFEEEFEFEFFGFHHJKJKPPPPPPPPPPOIMP"
    "PMOIHGGFFFFEFEFEFEFEEEFEFEFGGHJJKJPPPPPPPPPPPJNPPMNLLHHFGFFEFEEEEEEEEEFE"
    "FFGGHHIIJJPPPPPPPPOOO"))

;; The literal classes: byte -> digit '0'..'7'.
(define compiler-lzss-literal-classes : String
  (str_cat.str-cat
    "0000000001177177777777777777777726666666666666763333333333666666"
    "6555555555555555555555555556666464444444444444444444444444466667"
    "7777777777777777777777777777777777777777777777777777777777777777"
    "7777777777777777777777777777777777777777777777777777777777777777"))

;; --- structures ---------------------------------------------------------------
(defstruct CompilerLzssDecode
  ;; per code length: symbol count, first code, first symbol index
  (counts (__tl_dyn-array i64))
  (firsts (__tl_dyn-array i64))
  (starts (__tl_dyn-array i64))
  (symbols (__tl_dyn-array i64)))

(defstruct CompilerLzssReader
  (start i64)
  (len i64)
  (consumed i64)
  (produced i64)
  (rep0 i64)
  (rep1 i64)
  (rep2 i64)
  (rep3 i64))

(defstruct CompilerLzssWriter
  (out byte_buf.ByteBufBuilder)
  (pending i64)
  (used i64))

;; Flat code lengths and codes for every table of one model, plus the direct
;; decoding tables. `length-start` and `distance-start` index the flat arrays.
(defstruct CompilerLzssModel
  (lengths (__tl_dyn-array i64))
  (codes (__tl_dyn-array i64))
  (length-start i64)
  (distance-start i64)
  ;; Primary tables in main, length, then distance order. Entries pack
  ;; symbol * 16 + width, with zero for codes that need a canonical walk.
  (primary (__tl_dyn-array i64))
  (main-code (__tl_dyn-array CompilerLzssDecode))
  (length-code CompilerLzssDecode)
  (dist-code (__tl_dyn-array CompilerLzssDecode)))

(define (compiler-lzss-spec-length [c : char]) : i64
  (- (cast c : i64) 65))

(defstruct CompilerLzssMatch
  (offset i64)
  (length i64))

(defstruct CompilerLzssToken
  ;; symbol 0..255 is a literal byte, 256 a new-distance match, 257..260 a
  ;; repeat-0..3 match and 261 a repeat-0 match of length one
  (symbol i64)
  (length i64)
  (distance i64))

(define (compiler-lzss-bit-length [value : i64]) : i64
  (let
    [bits : i64 0]
    [rest : i64 value]
    (while (> rest 0)
      (set! rest (shr rest 1))
      (set! bits (+ bits 1)))
    bits))

;; Length 3..258 -> symbol 0..28 (the deflate ladder, with 258 on its own).
(define (compiler-lzss-length-slot [length : i64]) : i64
  (if (<= length 10)
    (- length 3)
    (if (>= length 258)
      28
      (let
        [e : i64 (- (compiler-lzss-bit-length (- length 3)) 3)]
        (+ 8 (* 4 (- e 1)) (shr (- length (+ (shl 1 (+ e 2)) 3)) e))))))

(define (compiler-lzss-length-extra [slot : i64]) : i64
  (cond [(< slot 8) 0] [(> slot 27) 0] [else (+ 1 (/ (- slot 8) 4))]))

(define (compiler-lzss-length-base [slot : i64]) : i64
  (if (< slot 8)
    (+ slot 3)
    (if (> slot 27)
      258
      (let
        [e : i64 (+ 1 (/ (- slot 8) 4))]
        (+ (shl 1 (+ e 2)) 3 (* (% (- slot 8) 4) (shl 1 e)))))))

(define (compiler-lzss-length-bucket [length : i64]) : i64
  (cond [(<= length 4) 0] [(<= length 8) 1] [(<= length 16) 2] [else 3]))

;; Distance 1..16777216 -> symbol 0..47.
(define (compiler-lzss-distance-slot [distance : i64]) : i64
  (if (<= distance 4)
    (- distance 1)
    (let
      [e : i64 (- (compiler-lzss-bit-length (- distance 1)) 2)]
      (+ 4 (* 2 (- e 1)) (shr (- distance (+ (shl 1 (+ e 1)) 1)) e)))))

(define (compiler-lzss-distance-extra [slot : i64]) : i64
  (if (< slot 4)
    0
    (+ 1 (/ (- slot 4) 2))))

(define (compiler-lzss-distance-base [slot : i64]) : i64
  (if (< slot 4)
    (+ slot 1)
    (let
      [e : i64 (+ 1 (/ (- slot 4) 2))]
      (+ (shl 1 (+ e 1)) 1 (* (% (- slot 4) 2) (shl 1 e))))))

;; --- canonical codes ---------------------------------------------------------
;; A code length of 0 means the symbol has no code; callers never emit one.
;; Canonical codes for `n` symbols whose lengths are `lengths[start..]`.
(define (compiler-lzss-fill-codes!
  [lengths : (& lengths (__tl_dyn-array i64))]
  [codes : (&mut codes (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]) : unit
  (let
    [limit : i64 (+ (compiler-lzss-max-code-bits) 1)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [next : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [len : i64 1]
    [index : i64 0]
    [code : i64 0]
    (while (< index n)
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (when
          (> length 0)
          (set! (array-ref counts length) (+ (array-ref counts length) 1))))
      (set! index (+ index 1)))
    (while (< len limit)
      (set! code (shl (+ code (array-ref counts (- len 1))) 1))
      (set! (array-ref next len) code)
      (set! len (+ len 1)))
    (set! index 0)
    (while (< index n)
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (when
          (> length 0)
          (set! (array-ref codes (+ start index)) (array-ref next length))
          (set! (array-ref next length) (+ (array-ref next length) 1))))
      (set! index (+ index 1)))))

(define (compiler-lzss-decode-table
  [lengths : (& lengths (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]) : CompilerLzssDecode
  (let
    [limit : i64 (+ (compiler-lzss-max-code-bits) 1)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [firsts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [symbols : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [len : i64 1]
    [index : i64 0]
    [placed : i64 0]
    [code : i64 0]
    (while (< index n)
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (when
          (> length 0)
          (set! (array-ref counts length) (+ (array-ref counts length) 1))))
      (set! index (+ index 1)))
    (while (< len limit)
      (set! code (shl (+ code (array-ref counts (- len 1))) 1))
      (set! (array-ref firsts len) code)
      (set! (array-ref starts len) placed)
      (set! placed (+ placed (array-ref counts len)))
      (set! len (+ len 1)))
    ;; Symbols sorted by length, then symbol.
    (set! len 1)
    (set! placed 0)
    (while (< len limit)
      (set! index 0)
      (while (< index n)
        (when
          (= (array-ref lengths (+ start index)) len)
          (set! (array-ref symbols placed) index)
          (set! placed (+ placed 1)))
        (set! index (+ index 1)))
      (set! len (+ len 1)))
    (CompilerLzssDecode counts firsts starts symbols)))

(define (compiler-lzss-fill-lookup!
  [entries : (&mut entries (__tl_dyn-array i64))]
  [offset : i64]
  [lengths : (& lengths (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]
  [bits : i64]) : CompilerLzssDecode
  (let
    [limit : i64 (+ (compiler-lzss-max-code-bits) 1)]
    [next : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
    [index : i64 0]
    [len : i64 1]
    [code : i64 0]
    (while (< index n)
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (when
          (> length 0)
          (set! (array-ref counts length) (+ (array-ref counts length) 1))))
      (set! index (+ index 1)))
    (while (< len limit)
      (set! code (shl (+ code (array-ref counts (- len 1))) 1))
      (set! (array-ref next len) code)
      (set! len (+ len 1)))
    (set! index 0)
    (while (< index n)
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (when
          (and (> length 0) (<= length bits))
          (let
            [first : i64 (shl (array-ref next length) (- bits length))]
            [span : i64 (shl 1 (- bits length))]
            [k : i64 0]
            (while (< k span)
              (set!
                (array-ref entries (+ offset first k))
                (+ (* index 16) length))
              (set! k (+ k 1))))
          (set! (array-ref next length) (+ (array-ref next length) 1))))
      (set! index (+ index 1)))
    (compiler-lzss-decode-table lengths start n)))

;; --- model -------------------------------------------------------------------
;; `spec` holds every model's code lengths in order: the 16 context tables, the
;; length table, then the 4 distance buckets.
(define (compiler-lzss-spec-lengths [spec : (& spec str)]) : (__tl_dyn-array
    i64)
  (let
    [n : i64 (string.string-length spec)]
    [lengths : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [index : i64 0]
    (while (< index n)
      (set!
        (array-ref lengths index)
        (compiler-lzss-spec-length (string.string-ref spec index)))
      (set! index (+ index 1)))
    lengths))

(define (compiler-lzss-length-table-start) : i64
  (shl (compiler-lzss-contexts) (compiler-lzss-main-lookup-bits)))

(define (compiler-lzss-distance-table-start) : i64
  (+
    (compiler-lzss-length-table-start)
    (shl 1 (compiler-lzss-length-lookup-bits))))

(define (compiler-lzss-primary-size) : i64
  (+
    (compiler-lzss-distance-table-start)
    (shl (compiler-lzss-length-buckets) (compiler-lzss-distance-lookup-bits))))

(define (compiler-lzss-model-from-lengths [lengths : (__tl_dyn-array i64)]) : CompilerLzssModel
  (let
    [contexts : i64 (compiler-lzss-contexts)]
    [main-symbols : i64 (compiler-lzss-main-symbols)]
    [length-symbols : i64 (compiler-lzss-length-symbols)]
    [buckets : i64 (compiler-lzss-length-buckets)]
    [distance-symbols : i64 (compiler-lzss-distance-symbols)]
    [length-start : i64 (* contexts main-symbols)]
    [distance-start : i64 (+ length-start length-symbols)]
    [total : i64 (+ distance-start (* buckets distance-symbols))]
    [codes : (__tl_dyn-array i64) (__tl_make-array i64 total)]
    [primary : (__tl_dyn-array i64)
      (__tl_make-array i64 (compiler-lzss-primary-size))]
    [main-code : (__tl_dyn-array CompilerLzssDecode)
      (__tl_make-array CompilerLzssDecode contexts)]
    [dist-code : (__tl_dyn-array CompilerLzssDecode)
      (__tl_make-array CompilerLzssDecode buckets)]
    [context : i64 0]
    (when
      (< (array-length lengths) total)
      (abort.compiler-abort
        "tl: compiler_lzss.compiler-lzss-model-from-lengths: short model spec\n"))
    ;; Canonical codes restart in 0 for every table.
    (while (< context contexts)
      (compiler-lzss-fill-codes!
        (& lengths)
        (&mut codes)
        (* context main-symbols)
        main-symbols)
      (set! context (+ context 1)))
    (compiler-lzss-fill-codes!
      (& lengths)
      (&mut codes)
      length-start
      length-symbols)
    (set! context 0)
    (while (< context buckets)
      (compiler-lzss-fill-codes!
        (& lengths)
        (&mut codes)
        (+ distance-start (* context distance-symbols))
        distance-symbols)
      (set! context (+ context 1)))
    (set! context 0)
    (while (< context contexts)
      (set!
        (array-ref main-code context)
        (compiler-lzss-fill-lookup!
          (&mut primary)
          (shl context (compiler-lzss-main-lookup-bits))
          (& lengths)
          (* context main-symbols)
          main-symbols
          (compiler-lzss-main-lookup-bits)))
      (set! context (+ context 1)))
    (set! context 0)
    (while (< context buckets)
      (set!
        (array-ref dist-code context)
        (compiler-lzss-fill-lookup!
          (&mut primary)
          (+
            (compiler-lzss-distance-table-start)
            (shl context (compiler-lzss-distance-lookup-bits)))
          (& lengths)
          (+ distance-start (* context distance-symbols))
          distance-symbols
          (compiler-lzss-distance-lookup-bits)))
      (set! context (+ context 1)))
    (let
      [length-code : CompilerLzssDecode
        (compiler-lzss-fill-lookup!
          (&mut primary)
          (compiler-lzss-length-table-start)
          (& lengths)
          length-start
          length-symbols
          (compiler-lzss-length-lookup-bits))]
      (CompilerLzssModel
        lengths
        codes
        length-start
        distance-start
        primary
        main-code
        length-code
        dist-code))))

(define (compiler-lzss-model-from-spec [spec : (& spec str)]) : CompilerLzssModel
  (compiler-lzss-model-from-lengths (compiler-lzss-spec-lengths spec)))

;; The model every source frame is coded under, built once per process.
(define compiler-lzss-fixed-model : CompilerLzssModel
  (compiler-lzss-model-from-spec (& compiler-lzss-fixed-spec)))

;; Precomputed literal-class * 2 lookup table (0..14) for fast context dispatch.
(define compiler-lzss-literal-class-twice : (Array u8 256)
  (let
    [table : (Array u8 256) (make-array u8 256)]
    [i : i64 0]
    (while (< i 256)
      (set!
        (array-ref table i)
        (cast
          (*
            2
            (-
              (cast
                (string.string-ref (& compiler-lzss-literal-classes) i)
                : i64)
              48))
          : u8))
      (+= i 1))
    table))

;; The context of the model for output position `position` after `previous`.
(define (compiler-lzss-context [previous : i64] [position : i64]) : i64
  (+
    (cast
      (array-ref compiler-lzss-literal-class-twice (bit-and previous 255))
      : i64)
    (bit-and position 1)))

(define (compiler-lzss-prefix?
  [payload : (& payload (__tl_dyn-array u8))]
  [prefix : (& str)]) : bool
  (let
    [index : i64 0]
    [prefix-len : i64 (string.string-length prefix)]
    [matches : bool (>= (array-length payload) prefix-len)]
    (while (and matches (< index prefix-len))
      (if (!=
        (array-ref payload index)
        (cast (string.string-ref prefix index) : u8))
        (set! matches false)
        unit)
      (+= index 1))
    matches))

;: Validate the envelope and return the claimed raw length and token offset.
;: `raw-limit` is a consumer policy and is checked before any output allocation.
(define (compiler-lzss-frame
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerLzssFrame
  (compiler-lzss-frame-with-prefix
    payload
    raw-limit
    (compiler-lzss-envelope-prefix)
    (compiler-lzss-max-expansion)))

;: The frame under `prefix`, where one compressed byte expands to at most
;: `expansion` output bytes (v1: a flag byte's eight literals and a token's
;: nine; v2: a 3-bit back-reference of 18 bytes, 48 per byte).
(define (compiler-lzss-frame-with-prefix
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]
  [prefix : String]
  [expansion : i64]) : CompilerLzssFrame
  (let
    [prefix-len : i64 (string.string-length prefix)]
    (cond
      [(< raw-limit 0) (Err "compiler lzss: invalid raw length limit")]
      [(not (compiler-lzss-prefix? payload (& prefix)))
        (Err "compiler lzss: bad envelope prefix")]
      [else
        (let
          [payload-len : i64 (array-length payload)]
          [index : i64 prefix-len]
          [raw-len : i64 0]
          [digits : i64 0]
          [overflow : bool false]
          [max-i64 : i64 9223372036854775807]
          (while (and
            (not overflow)
            (< index payload-len)
            (>= (array-ref payload index) (cast 48 : u8))
            (<= (array-ref payload index) (cast 57 : u8)))
            (let
              [digit : i64 (- (cast (array-ref payload index) : i64) 48)]
              (if (> raw-len (/ (- max-i64 digit) 10))
                (set! overflow true)
                (set! raw-len (+ (* raw-len 10) digit)))
              (+= digits 1)
              (+= index 1)))
          (cond
            [overflow (Err "compiler lzss: raw length overflows i64")]
            [(= digits 0) (Err "compiler lzss: missing raw length")]
            [(or
                (>= index payload-len)
                (!= (array-ref payload index) (cast 10 : u8)))
              (Err "compiler lzss: malformed raw length")]
            [(> raw-len raw-limit)
              (Err "compiler lzss: raw length exceeds consumer limit")]
            [else
              (let
                [compressed-start : i64 (+ index 1)]
                [compressed-len : i64 (- payload-len compressed-start)]
                ;; A compressed byte expands to at most `expansion` output
                ;; bytes. This cheap necessary bound rejects absurd claimed
                ;; lengths before allocating; the token walk proves the exact
                ;; length.
                [ratio-safe : bool
                  (or
                    (>= compressed-len (/ 9223372036854775807 expansion))
                    (<= raw-len (* compressed-len expansion)))]
                (if ratio-safe
                  (Ok raw-len compressed-start)
                  (Err "compiler lzss: impossible raw length")))]))])))

;; --- bit reader --------------------------------------------------------------
;; Read up to eight bytes, high bits first, with zero padding at the end.
;; The unaligned word load is used only when it lies entirely in the payload.
(define (compiler-lzss-read-word [input : (Ptr u8)] [pos : i64] [size : i64]) : u64
  (if (= size 8)
    (let
      [word : u64
        (unsafe
          (ptr-read (ptr-cast (ptr-offset input pos) : (Ptr u64))))]
      [halves : u64 (bit-or (shl word 32) (shr word 32))]
      [pairs : u64
        (bit-or
          (shl (bit-and halves 281470681808895) 16)
          (bit-and (shr halves 16) 281470681808895))]
      (bit-or
        (shl (bit-and pairs 71777214294589695) 8)
        (bit-and (shr pairs 8) 71777214294589695)))
    (let
      [word : u64 0]
      [end : i64 (+ pos size)]
      (while (> end pos)
        (-= end 1)
        (set!
          word
          (bit-or
            (shr word 8)
            (shl
              (cast
                (unsafe
                  (ptr-read (ptr-offset input end)))
                : u64)
              56))))
      word)))

;; Reload at the byte containing the next bit. Shifting off the consumed part
;; leaves the next `count` bits in the high end of `buf`, zero-filled below.
(defmacro (compiler-lzss-ensure-bits!
  [input : Expr]
  [limit : Expr]
  [pos : Expr]
  [buf : Expr]
  [count : Expr]
  [needed : Expr]) : unit
  `(when
    (and (< ,count ,needed) (< ,pos ,limit))
    (let
      [skip : i64 (bit-and (- 0 ,count) 7)]
      [start : i64 (- ,pos (shr (+ ,count 7) 3))]
      [left : i64 (- ,limit start)]
      [size : i64
        (if (>= left 8)
          8
          left)]
      (set! ,buf (shl (compiler-lzss-read-word ,input start size) skip))
      (set! ,pos (+ start size))
      (set! ,count (- (* size 8) skip)))))

;; Finish a code longer than the primary table. Like a primary lookup this
;; returns the packed symbol and width, or zero if no code fits.
(define (compiler-lzss-long-entry
  [code : (& code CompilerLzssDecode)]
  [buf : u64]
  [count : i64]
  [bits : i64]) : i64
  (let
    [len : i64 (+ bits 1)]
    (while (and (<= len count) (<= len (compiler-lzss-max-code-bits)))
      (let
        [index : i64
          (- (cast (shr buf (- 64 len)) : i64) (array-ref code.firsts len))]
        (when
          (and (>= index 0) (< index (array-ref code.counts len)))
          (return
            (+
              (*
                (array-ref code.symbols (+ (array-ref code.starts len) index))
                16)
              len))))
      (+= len 1))
    0))

;; The caller has filled the reservoir for this token (or reached the payload
;; end). The primary index is bounded by the width used to build the table.
(defmacro (compiler-lzss-take-symbol!
  [primary : Expr]
  [base : Expr]
  [code : Expr]
  [bits : Expr]
  [buf : Expr]
  [count : Expr]
  [error : Expr]) : i64
  `(let
    [entry : i64
      (unsafe
        (ptr-read
          (ptr-offset ,primary (+ ,base (cast (shr ,buf (- 64 ,bits)) : i64)))))]
    (when
      (= entry 0)
      (set! entry (compiler-lzss-long-entry ,code ,buf ,count ,bits))
      (when (= entry 0) (return ,error)))
    (let
      [need : i64 (bit-and entry 15)]
      (when (> need ,count) (return ,error))
      (set! ,buf (shl ,buf need))
      (-= ,count need)
      (shr entry 4))))

;; The extra widths are positive and bounded by the length/distance ladders.
;; Reducing the negative width modulo 64 gives the high-bit shift.
(defmacro (compiler-lzss-take-bits!
  [buf : Expr]
  [count : Expr]
  [width : Expr]
  [error : Expr]) : i64
  `(let
    [bits : i64 ,width]
    (when (> bits ,count) (return ,error))
    (let
      [value : i64 (cast (shr ,buf (bit-and (neg bits) 63)) : i64)]
      (set! ,buf (shl ,buf bits))
      (-= ,count bits)
      value)))

;; The zero padding at the end of a stream, or false when bytes or bits are
;; left unaccounted for.
(define (compiler-lzss-tail-ok?
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (& reader CompilerLzssReader)]) : bool
  (and
    (= (shr (+ reader.consumed 7) 3) reader.len)
    (if (= (bit-and reader.consumed 7) 0)
      true
      (=
        (bit-and
          (cast (array-ref payload (+ reader.start (- reader.len 1))) : i64)
          (- (shl 1 (- 8 (bit-and reader.consumed 7))) 1))
        0))))

;; --- copy --------------------------------------------------------------------
;; Copy one back-reference after validating the source and destination spans.
;; When the distance is at least a word, the source of each word has already
;; been written. The final word may overlap the previous store.
(defmacro (compiler-lzss-copy-match!
  [out-data : Expr]
  [out-index : Expr]
  [distance : Expr]
  [length : Expr]) : unit
  `(let
    [dst : (MutPtr u8)
      (unsafe
        (ptr-offset ,out-data ,out-index))]
    [src : (Ptr u8)
      (unsafe
        (ptr-offset (ptr-cast dst : (Ptr u8)) (neg ,distance)))]
    [copied : i64 0]
    (if (and (>= ,distance 8) (>= ,length 8))
      (let
        [last : i64 (- ,length 8)]
        (while (< copied last)
          (unsafe
            (ptr-write!
              (ptr-cast (ptr-offset dst copied) : (MutPtr i64))
              (ptr-read (ptr-cast (ptr-offset src copied) : (Ptr i64)))))
          (+= copied 8))
        (unsafe
          (ptr-write!
            (ptr-cast (ptr-offset dst last) : (MutPtr i64))
            (ptr-read (ptr-cast (ptr-offset src last) : (Ptr i64))))))
      (while (< copied ,length)
        (unsafe
          (ptr-write!
            (ptr-offset dst copied)
            (ptr-read (ptr-offset src copied))))
        (+= copied 1)))))

;; --- decode ------------------------------------------------------------------
;; Fill through `end` under `model`, based on the saved token boundary.
;; Output from previous tokens remains available to back-references.
;; Returns "" on success, else a diagnostic. Every code, length, distance and
;; output range is checked before it is used.
(define (compiler-lzss-decode-body
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]
  [data : (MutPtr u8)]
  [end : i64]
  ;; The token that crosses a soft prefix boundary finishes inside hard-end.
  [hard-end : i64]
  [model : (& model CompilerLzssModel)]) : String
  (when
    (or
      (< reader.start 0)
      (> reader.start (array-length payload))
      (< reader.len 0)
      (> reader.len (- (array-length payload) reader.start))
      (< reader.consumed 0)
      (> (cast (shr (+ (cast reader.consumed : u64) 7) 3) : i64) reader.len)
      (< (array-length model.primary) (compiler-lzss-primary-size)))
    (return "compiler lzss: truncated symbol"))
  (let
    [window : i64 (compiler-lzss-window)]
    [input : (Ptr u8)
      (unsafe
        (ptr-offset
          (ptr-cast (__tl_array-data (deref payload)) : (Ptr u8))
          reader.start))]
    ;; Each index is bounded by its context/bucket and the table width.
    [primary : (Ptr i64)
      (unsafe
        (ptr-cast (__tl_array-data (deref model).primary) : (Ptr i64)))]
    [length-base : i64 (compiler-lzss-length-table-start)]
    [distance-base : i64 (compiler-lzss-distance-table-start)]
    [limit : i64 reader.len]
    [pos : i64 (cast (shr (+ (cast reader.consumed : u64) 7) 3) : i64)]
    [count : i64 (bit-and (- 0 reader.consumed) 7)]
    [buf : u64
      (if (= count 0)
        0
        (shl
          (cast
            (unsafe
              (ptr-read (ptr-offset input (- pos 1))))
            : u64)
          (- 64 count)))]
    [class-ptr : (Ptr u8)
      (unsafe
        (ptr-cast
          (ptr-addr-of (array-ref compiler-lzss-literal-class-twice 0))
          : (Ptr u8)))]
    [data-ro : (Ptr u8)
      (unsafe
        (ptr-cast data : (Ptr u8)))]
    [rep0 : i64 reader.rep0]
    [rep1 : i64 reader.rep1]
    [rep2 : i64 reader.rep2]
    [rep3 : i64 reader.rep3]
    [out-index : i64 reader.produced]
    (while (< out-index end)
      ;; A main and length code take up to 15 bits each, plus five extra bits.
      (compiler-lzss-ensure-bits! input limit pos buf count 35)
      (let
        [previous : i64
          (if (> out-index 0)
            (cast
              (unsafe
                (ptr-read (ptr-offset data-ro (- out-index 1))))
              : i64)
            0)]
        [context : i64
          (+
            (cast
              (unsafe
                (ptr-read (ptr-offset class-ptr previous)))
              : i64)
            (bit-and out-index 1))]
        [symbol : i64
          (compiler-lzss-take-symbol!
            primary
            (shl (bit-and context 15) (compiler-lzss-main-lookup-bits))
            (& (array-ref model.main-code context))
            (compiler-lzss-main-lookup-bits)
            buf
            count
            "compiler lzss: truncated symbol")]
        (cond
          [(< symbol 256)
            (unsafe
              (ptr-write! (ptr-offset data out-index) (cast symbol : u8)))
            (+= out-index 1)]
          [(>= symbol 261)
            (when
              (or (<= rep0 0) (> rep0 out-index) (> rep0 window))
              (return "compiler lzss: invalid repeat distance"))
            (unsafe
              (ptr-write!
                (ptr-offset data out-index)
                (ptr-read (ptr-offset data-ro (- out-index rep0)))))
            (+= out-index 1)]
          [else
            (let
              [kind : i64 (- symbol 256)]
              [slot : i64
                (compiler-lzss-take-symbol!
                  primary
                  length-base
                  (& model.length-code)
                  (compiler-lzss-length-lookup-bits)
                  buf
                  count
                  "compiler lzss: truncated length")]
              [length : i64 0]
              [distance : i64 0]
              (if (< slot 8)
                (set! length (+ slot 3))
                (if (> slot 27)
                  (set! length 258)
                  (let
                    [ebits : i64 (bit-and (+ 1 (shr (- slot 8) 2)) 7)]
                    [extra : i64
                      (compiler-lzss-take-bits!
                        buf
                        count
                        ebits
                        "compiler lzss: truncated length")]
                    (set!
                      length
                      (+ (shl (+ 4 (bit-and (- slot 8) 3)) ebits) 3 extra)))))
              (when
                (or (< length 3) (> length 258))
                (return "compiler lzss: invalid match length"))
              (when
                (> length (- hard-end out-index))
                (return "compiler lzss: token exceeds raw length"))
              (cond
                [(= kind 0)
                  ;; Up to 15 bits for the distance code and 22 extra bits.
                  (compiler-lzss-ensure-bits! input limit pos buf count 37)
                  (let
                    [bucket : i64
                      (cond
                        [(<= length 4) 0]
                        [(<= length 8) 1]
                        [(<= length 16) 2]
                        [else 3])]
                    [dslot : i64
                      (compiler-lzss-take-symbol!
                        primary
                        (+
                          distance-base
                          (shl bucket (compiler-lzss-distance-lookup-bits)))
                        (& (array-ref model.dist-code bucket))
                        (compiler-lzss-distance-lookup-bits)
                        buf
                        count
                        "compiler lzss: truncated distance")]
                    (if (< dslot 4)
                      (set! distance (+ dslot 1))
                      (let
                        [dbits : i64 (bit-and (+ 1 (shr (- dslot 4) 1)) 31)]
                        [dextra : i64
                          (compiler-lzss-take-bits!
                            buf
                            count
                            dbits
                            "compiler lzss: truncated distance")]
                        (set!
                          distance
                          (+ (shl (+ 2 (bit-and (- dslot 4) 1)) dbits) 1 dextra)))))
                  (when
                    (<= distance 0)
                    (return "compiler lzss: invalid match distance"))
                  (set! rep3 rep2)
                  (set! rep2 rep1)
                  (set! rep1 rep0)
                  (set! rep0 distance)]
                [(= kind 1) (set! distance rep0)]
                [(= kind 2)
                  (set! distance rep1)
                  (set! rep1 rep0)
                  (set! rep0 distance)]
                [(= kind 3)
                  (set! distance rep2)
                  (set! rep2 rep1)
                  (set! rep1 rep0)
                  (set! rep0 distance)]
                [else
                  (set! distance rep3)
                  (set! rep3 rep2)
                  (set! rep2 rep1)
                  (set! rep1 rep0)
                  (set! rep0 distance)])
              (when
                (or (> distance out-index) (> distance window))
                (return "compiler lzss: backreference before output"))
              (compiler-lzss-copy-match! data out-index distance length)
              (+= out-index length))])))
    (set! reader.consumed (- (* pos 8) count))
    (set! reader.produced out-index)
    (set! reader.rep0 rep0)
    (set! reader.rep1 rep1)
    (set! reader.rep2 rep2)
    (set! reader.rep3 rep3)
    ""))

;; --- bit writer --------------------------------------------------------------
(define (compiler-lzss-writer) : CompilerLzssWriter
  (CompilerLzssWriter (byte_buf.byte-buf-builder-with-capacity 256) 0 0))

;; Whole bytes leave `out`; `pending` holds `used` bits not yet a byte, the
;; oldest most significant.
(define (compiler-lzss-write-bits!
  [writer : (&mut writer CompilerLzssWriter)]
  [value : i64]
  [count : i64]) : unit
  (when
    (> count 0)
    (let
      [used : i64 (+ writer.used count)]
      [pending : i64
        (bit-or (shl writer.pending count) (bit-and value (- (shl 1 count) 1)))]
      (while (>= used 8)
        (set! used (- used 8))
        (byte_buf.byte-buf-builder-push
          (&mut writer.out)
          (cast (bit-and (shr pending used) 255) : u8)))
      (set! writer.pending (bit-and pending (- (shl 1 used) 1)))
      (set! writer.used used))))

(define (compiler-lzss-write-symbol!
  [writer : (&mut writer CompilerLzssWriter)]
  [model : (& model CompilerLzssModel)]
  [base : i64]
  [symbol : i64]) : unit
  (compiler-lzss-write-bits!
    writer
    (array-ref model.codes (+ base symbol))
    (array-ref model.lengths (+ base symbol))))

;; Zero-pad the last byte and return the whole bitstream.
(define (compiler-lzss-finish-writer
  [writer : (&mut writer CompilerLzssWriter)]) : String
  (when
    (> writer.used 0)
    (compiler-lzss-write-bits! writer 0 (- 8 writer.used)))
  (byte_buf.byte-buf-builder-to-string (& writer.out)))

;; --- matcher -----------------------------------------------------------------
(define (compiler-lzss-byte [data : (Ptr u8)] [index : i64]) : i64
  (cast
    (unsafe
      (ptr-read (ptr-offset data index)))
    : i64))

;; Unaligned 8-byte read; the caller keeps `index + 8` inside the source.
(define (compiler-lzss-word [data : (Ptr u8)] [index : i64]) : i64
  (unsafe
    (ptr-read (ptr-cast (ptr-offset data index) : (Ptr i64)))))

;; The weighted trigram sum fits 65535, so one mask reproduces `% 65536`.
(define (compiler-lzss-hash [data : (Ptr u8)] [index : i64]) : i64
  (bit-and
    (+
      (* (compiler-lzss-byte data index) 251)
      (* (compiler-lzss-byte data (+ index 1)) 31)
      (compiler-lzss-byte data (+ index 2)))
    65535))

(define (compiler-lzss-fill!
  [items : (&mut items (__tl_dyn-array i64))]
  [value : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (array-length items))
      (set! (array-ref items index) value)
      (+= index 1))))

;; Longest common prefix of the candidate and cursor spans, capped by `cap`.
(define (compiler-lzss-match-len
  [data : (Ptr u8)]
  [cap : i64]
  [candidate : i64]
  [index : i64]) : i64
  (let
    [length : i64 0]
    [words-done : bool false]
    [tail-done : bool false]
    (while (and (not words-done) (<= (+ length 8) cap))
      (if (=
        (compiler-lzss-word data (+ candidate length))
        (compiler-lzss-word data (+ index length)))
        (+= length 8)
        (set! words-done true)))
    (while (and (not tail-done) (< length cap))
      (if (=
        (compiler-lzss-byte data (+ candidate length))
        (compiler-lzss-byte data (+ index length)))
        (+= length 1)
        (set! tail-done true)))
    length))

(define (compiler-lzss-insert!
  [data : (Ptr u8)]
  [source-len : i64]
  [head : (MutPtr i64)]
  [previous : (MutPtr i64)]
  [index : i64]) : unit
  (when
    (<= (+ index 2) (- source-len 1))
    (let
      [slot : (MutPtr i64)
        (unsafe
          (ptr-offset head (compiler-lzss-hash data index)))]
      (unsafe
        (ptr-write! (ptr-offset previous index) (ptr-read slot))
        (ptr-write! slot index)))))

(define (compiler-lzss-insert-range!
  [data : (Ptr u8)]
  [source-len : i64]
  [head : (MutPtr i64)]
  [previous : (MutPtr i64)]
  [start : i64]
  [count : i64]) : unit
  (let
    [limit : i64 (- source-len 2)]
    [end : i64
      (let
        [stop : i64 (+ start count)]
        (if (< stop limit)
          stop
          limit))]
    [index : i64 start]
    (while (< index end)
      (compiler-lzss-insert! data source-len head previous index)
      (set! index (+ index 1)))))

;; The longest match at `index` longer than `min-len`; a returned length of at
;; most `min-len` means the capped walk found none.
(define (compiler-lzss-find
  [data : (Ptr u8)]
  [source-len : i64]
  [head : (Ptr i64)]
  [previous : (Ptr i64)]
  [index : i64]
  [min-len : i64]) : CompilerLzssMatch
  (if (> (+ index 2) (- source-len 1))
    (CompilerLzssMatch 0 0)
    (let
      [candidate : i64
        (unsafe
          (ptr-read (ptr-offset head (compiler-lzss-hash data index))))]
      [best-offset : i64 0]
      [best-len : i64 min-len]
      [cap : i64
        (let
          [avail : i64 (- source-len index)]
          (if (< avail (compiler-lzss-max-match))
            avail
            (compiler-lzss-max-match)))]
      [chain : (Ptr i64)
        (unsafe
          (ptr-offset previous 0))]
      ;; A distance at most the window keeps the token decodable.
      [floor : i64
        (let
          [oldest : i64 (- index (compiler-lzss-window))]
          (if (< oldest 0)
            0
            oldest))]
      [links : i64 (compiler-lzss-chain-links)]
      (while (< best-len cap)
        (let
          [probe : i64 (compiler-lzss-byte data (+ index best-len))]
          (while (and
            (>= candidate floor)
            (> links 0)
            (not (= (compiler-lzss-byte data (+ candidate best-len)) probe)))
            (set!
              candidate
              (unsafe
                (ptr-read (ptr-offset chain candidate))))
            (-= links 1))
          (if (or (< candidate floor) (= links 0))
            (return (CompilerLzssMatch best-offset best-len))
            (let
              [length : i64 (compiler-lzss-match-len data cap candidate index)]
              (when
                (> length best-len)
                (set! best-len length)
                (set! best-offset (- index candidate)))
              (set!
                candidate
                (unsafe
                  (ptr-read (ptr-offset chain candidate))))
              (-= links 1)))))
      (CompilerLzssMatch best-offset best-len))))

(define (compiler-lzss-rep-len
  [data : (Ptr u8)]
  [index : i64]
  [distance : i64]
  [cap : i64]) : i64
  (if (or (<= distance 0) (< index distance))
    0
    (compiler-lzss-match-len data cap (- index distance) index)))

;; --- prices ------------------------------------------------------------------
;; Bit prices from the model: the code length of the symbol, or a conservative
;; fallback for a symbol the model has no code for (the encoder never emits one).
(define (compiler-lzss-symbol-price
  [model : (& model CompilerLzssModel)]
  [base : i64]
  [symbol : i64]) : i64
  (let
    [length : i64 (array-ref model.lengths (+ base symbol))]
    (if (> length 0)
      length
      15)))

(define (compiler-lzss-literal-price
  [model : (& model CompilerLzssModel)]
  [context : i64]
  [byte : i64]) : i64
  (compiler-lzss-symbol-price
    model
    (* context (compiler-lzss-main-symbols))
    byte))

;; Bits for one match token under `model`.
(define (compiler-lzss-match-price
  [model : (& model CompilerLzssModel)]
  [context : i64]
  [symbol : i64]
  [length : i64]
  [distance : i64]) : i64
  (let
    [base : i64 (* context (compiler-lzss-main-symbols))]
    [slot : i64 (compiler-lzss-length-slot length)]
    [cost : i64
      (+
        (compiler-lzss-symbol-price model base symbol)
        (compiler-lzss-symbol-price model model.length-start slot)
        (compiler-lzss-length-extra slot))]
    (if (= symbol (compiler-lzss-match-new))
      (let
        [bucket : i64 (compiler-lzss-length-bucket length)]
        [dslot : i64 (compiler-lzss-distance-slot distance)]
        (+
          cost
          (compiler-lzss-symbol-price
            model
            (+ model.distance-start (* bucket (compiler-lzss-distance-symbols)))
            dslot)
          (compiler-lzss-distance-extra dslot)))
      cost)))

;; --- tokenizer ---------------------------------------------------------------
;; Greedy parse with one-step lazy matching, priced by `model`: a token is only
;; taken when it costs less than the literals it replaces.
(define (compiler-lzss-tokenize
  [source : (& str)]
  [model : (& model CompilerLzssModel)]) : (__tl_dyn-array CompilerLzssToken)
  (let
    [source-len : i64 (string.string-length source)]
    [data : (Ptr u8)
      (unsafe
        (string-data source))]
    [head : (__tl_dyn-array i64) (__tl_make-array i64 65536)]
    [previous : (__tl_dyn-array i64) (__tl_make-array i64 (+ source-len 2))]
    [head-slots : (MutPtr i64)
      (unsafe
        (__tl_array-data head))]
    [previous-slots : (MutPtr i64)
      (unsafe
        (__tl_array-data previous))]
    [head-view : (Ptr i64)
      (unsafe
        (ptr-cast head-slots : (Ptr i64)))]
    [previous-view : (Ptr i64)
      (unsafe
        (ptr-cast previous-slots : (Ptr i64)))]
    ;; `sums[j]` is the price of the first `j` literals, for exact gains.
    [sums : (__tl_dyn-array i64) (__tl_make-array i64 (+ source-len 1))]
    [tokens : (__tl_dyn-array CompilerLzssToken)
      (__tl_make-array CompilerLzssToken (+ source-len 1))]
    [tokens-len : i64 0]
    [reps : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [main-base : i64 (compiler-lzss-main-symbols)]
    ;; The lazy lookahead's match, kept for the next position.
    [pending-valid : bool false]
    [pending-offset : i64 0]
    [pending-length : i64 0]
    [lookahead-offset : i64 0]
    [lookahead-length : i64 0]
    [index : i64 0]
    (compiler-lzss-fill! (&mut head) -1)
    (set! (array-ref reps 0) 1)
    (set! (array-ref reps 1) 1)
    (set! (array-ref reps 2) 1)
    (set! (array-ref reps 3) 1)
    (set! (array-ref sums 0) 0)
    (while (< index source-len)
      (let
        [previous-byte : i64
          (if (> index 0)
            (compiler-lzss-byte data (- index 1))
            0)]
        (set!
          (array-ref sums (+ index 1))
          (+
            (array-ref sums index)
            (compiler-lzss-literal-price
              model
              (compiler-lzss-context previous-byte index)
              (compiler-lzss-byte data index)))))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index source-len)
      (let
        [previous-byte : i64
          (if (> index 0)
            (compiler-lzss-byte data (- index 1))
            0)]
        [context : i64 (compiler-lzss-context previous-byte index)]
        [avail : i64
          (let
            [rest : i64 (- source-len index)]
            (if (< rest (compiler-lzss-max-match))
              rest
              (compiler-lzss-max-match)))]
        [literal-gain : i64
          (- (array-ref sums (+ index 1)) (array-ref sums index))]
        [match : CompilerLzssMatch (CompilerLzssMatch 0 0)]
        [best-symbol : i64 -1]
        [best-length : i64 0]
        [best-distance : i64 0]
        [best-gain : i64 0]
        [rep0-len : i64 0]
        [k : i64 0]
        ;; A rejected lazy lookahead already found this position's match, so
        ;; the chain walk is not repeated here.
        (set!
          match
          (if pending-valid
            (CompilerLzssMatch pending-offset pending-length)
            (compiler-lzss-find data source-len head-view previous-view index 0)))
        (set! pending-valid false)
        (compiler-lzss-insert! data source-len head-slots previous-slots index)
        ;; Repeat offsets spend no distance bits, so they usually win.
        (while (< k 4)
          (let
            [length : i64
              (compiler-lzss-rep-len data index (array-ref reps k) avail)]
            (when (= k 0) (set! rep0-len length))
            (when
              (>= length (compiler-lzss-min-match))
              (let
                [gain : i64
                  (-
                    (- (array-ref sums (+ index length)) (array-ref sums index))
                    (compiler-lzss-match-price
                      model
                      context
                      (+ (compiler-lzss-match-rep) k)
                      length
                      0))]
                (when
                  (and (> gain 0) (> gain best-gain))
                  (set! best-symbol (+ (compiler-lzss-match-rep) k))
                  (set! best-length length)
                  (set! best-distance (array-ref reps k))
                  (set! best-gain gain))))
            (set! k (+ k 1))))
        (when
          (>= match.length (compiler-lzss-min-match))
          (let
            [gain : i64
              (-
                (-
                  (array-ref sums (+ index match.length))
                  (array-ref sums index))
                (compiler-lzss-match-price
                  model
                  context
                  (compiler-lzss-match-new)
                  match.length
                  match.offset))]
            (when
              (and (> gain 0) (> gain best-gain))
              (set! best-symbol (compiler-lzss-match-new))
              (set! best-length match.length)
              (set! best-distance match.offset)
              (set! best-gain gain))))
        ;; A one-byte repeat is cheaper than a literal when the model says so.
        (when
          (= rep0-len 1)
          (let
            [gain : i64
              (-
                literal-gain
                (compiler-lzss-symbol-price
                  model
                  (* context main-base)
                  (compiler-lzss-shortrep)))]
            (when
              (and (> gain 0) (> gain best-gain))
              (set! best-symbol (compiler-lzss-shortrep))
              (set! best-length 1)
              (set! best-distance (array-ref reps 0))
              (set! best-gain gain))))
        ;; One-step lazy matching: a longer match at the next position that
        ;; beats this one by more than the literal here wins.
        (let
          [lazy : bool
            (and
              (>= best-symbol 0)
              (< best-length (compiler-lzss-lazy-floor))
              (< (+ index 1) source-len))]
          (when
            lazy
            (let
              [next : CompilerLzssMatch
                (compiler-lzss-find
                  data
                  source-len
                  head-view
                  previous-view
                  (+ index 1)
                  best-length)]
              (if (> next.length best-length)
                (let
                  [next-gain : i64
                    (-
                      (-
                        (-
                          (array-ref sums (+ index 1 next.length))
                          (array-ref sums (+ index 1)))
                        (compiler-lzss-match-price
                          model
                          (compiler-lzss-context
                            (compiler-lzss-byte data index)
                            (+ index 1))
                          (compiler-lzss-match-new)
                          next.length
                          next.offset))
                      literal-gain)]
                  (set! lazy (> next-gain best-gain)))
                (set! lazy false))
              (set! lookahead-offset next.offset)
              (set! lookahead-length next.length)))
          (cond
            [lazy
              ;; The literal here is a token of its own; the lookahead match is
              ;; the next position's, so it is carried into the next iteration.
              (set!
                (array-ref tokens tokens-len)
                (CompilerLzssToken (compiler-lzss-byte data index) 1 0))
              (set! tokens-len (+ tokens-len 1))
              (set! pending-valid true)
              (set! pending-offset lookahead-offset)
              (set! pending-length lookahead-length)
              (set! index (+ index 1))]
            [(< best-symbol 0)
              (set!
                (array-ref tokens tokens-len)
                (CompilerLzssToken (compiler-lzss-byte data index) 1 0))
              (set! tokens-len (+ tokens-len 1))
              (set! index (+ index 1))]
            [else
              (set!
                (array-ref tokens tokens-len)
                (CompilerLzssToken best-symbol best-length best-distance))
              (set! tokens-len (+ tokens-len 1))
              (cond
                [(= best-symbol (compiler-lzss-shortrep)) unit]
                [(= best-symbol (compiler-lzss-match-new))
                  (set! (array-ref reps 3) (array-ref reps 2))
                  (set! (array-ref reps 2) (array-ref reps 1))
                  (set! (array-ref reps 1) (array-ref reps 0))
                  (set! (array-ref reps 0) best-distance)]
                [else
                  (let
                    [slot : i64 (- best-symbol (compiler-lzss-match-rep))]
                    [move : i64 slot]
                    [move-distance : i64 (array-ref reps slot)]
                    (while (> move 0)
                      (set! (array-ref reps move) (array-ref reps (- move 1)))
                      (set! move (- move 1)))
                    (set! (array-ref reps 0) move-distance))])
              (compiler-lzss-insert-range!
                data
                source-len
                head-slots
                previous-slots
                (+ index 1)
                (- best-length 1))
              (set! index (+ index best-length))]))))
    (let
      [trimmed : (__tl_dyn-array CompilerLzssToken)
        (__tl_make-array CompilerLzssToken tokens-len)]
      [copy : i64 0]
      (while (< copy tokens-len)
        (set! (array-ref trimmed copy) (array-ref tokens copy))
        (set! copy (+ copy 1)))
      trimmed)))

;; --- emit --------------------------------------------------------------------
;; Write the tokens of `source` under `model`. The bit position, the literal
;; context and the repeat distances follow from the tokens themselves, exactly
;; as the decoder derives them.
(define (compiler-lzss-emit
  [source : (& str)]
  [tokens : (& tokens (__tl_dyn-array CompilerLzssToken))]
  [model : (& model CompilerLzssModel)]
  [writer : (&mut writer CompilerLzssWriter)]) : unit
  (let
    [data : (Ptr u8)
      (unsafe
        (string-data source))]
    [main-base : i64 (compiler-lzss-main-symbols)]
    [count : i64 (array-length tokens)]
    [index : i64 0]
    [position : i64 0]
    (while (< index count)
      (let
        [token : CompilerLzssToken (array-ref tokens index)]
        [previous : i64
          (if (> position 0)
            (compiler-lzss-byte data (- position 1))
            0)]
        [context : i64 (compiler-lzss-context previous position)]
        [symbol : i64 token.symbol]
        (compiler-lzss-write-symbol! writer model (* context main-base) symbol)
        (when
          (and (>= symbol 256) (< symbol (compiler-lzss-shortrep)))
          (let
            [slot : i64 (compiler-lzss-length-slot token.length)]
            (compiler-lzss-write-symbol! writer model model.length-start slot)
            (compiler-lzss-write-bits!
              writer
              (- token.length (compiler-lzss-length-base slot))
              (compiler-lzss-length-extra slot))
            (when
              (= symbol (compiler-lzss-match-new))
              (let
                [bucket : i64 (compiler-lzss-length-bucket token.length)]
                [dslot : i64 (compiler-lzss-distance-slot token.distance)]
                (compiler-lzss-write-symbol!
                  writer
                  model
                  (+
                    model.distance-start
                    (* bucket (compiler-lzss-distance-symbols)))
                  dslot)
                (compiler-lzss-write-bits!
                  writer
                  (- token.distance (compiler-lzss-distance-base dslot))
                  (compiler-lzss-distance-extra dslot))))))
        (set! position (+ position token.length)))
      (set! index (+ index 1)))))

;; --- source frames -----------------------------------------------------------
;; A complete `include-str-lzss` payload for `source` under the fixed model.
(define (compiler-lzss-encode [source : (& str)]) : String
  (let
    [tokens : (__tl_dyn-array CompilerLzssToken)
      (compiler-lzss-tokenize source (& compiler-lzss-fixed-model))]
    [writer : CompilerLzssWriter (compiler-lzss-writer)]
    (compiler-lzss-emit
      source
      (& tokens)
      (& compiler-lzss-fixed-model)
      (&mut writer))
    (str_cat.str-cat
      (compiler-lzss-envelope-prefix)
      (string.int->string (string.string-length source))
      "\n"
      (compiler-lzss-finish-writer (&mut writer)))))

;; The code lengths of a stored model, read from `count` bytes at `start`.
(define (compiler-lzss-spec-string
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [count : i64]) : String
  (let
    [view : (__tl_dyn-array u8)
      (owned_view.compiler-owned-reference-shared-view payload)]
    (unsafe
      (string-from-bytes
        (ptr-cast
          (ptr-offset (ptr-cast (__tl_array-data view) : (Ptr u8)) start)
          : (Ptr u8))
        count))))

;; The model stored in `count` bytes at `start`.
(define (compiler-lzss-model-from-bytes
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [count : i64]) : CompilerLzssModel
  (let
    [spec : String (compiler-lzss-spec-string payload start count)]
    (compiler-lzss-model-from-spec (& spec))))

(define (compiler-lzss-reader [start : i64] [len : i64]) : CompilerLzssReader
  (CompilerLzssReader start len 0 0 1 1 1 1))

;; Advance a stream in the same output buffer. Publish the new bit cursor and
;; produced length only after reaching a complete token at or after `needed`.
(define (compiler-lzss-decode-through!
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]
  [out : (&mut out (__tl_dyn-array u8))]
  [needed : i64]
  [model : (& model CompilerLzssModel)]) : String
  (let
    [capacity : i64 (array-length out)]
    (when
      (or
        (< reader.produced 0)
        (> reader.produced capacity)
        (> needed capacity))
      (return "compiler lzss: token exceeds raw length"))
    (when
      (or
        (<= reader.rep0 0)
        (<= reader.rep1 0)
        (<= reader.rep2 0)
        (<= reader.rep3 0))
      (return "compiler lzss: invalid repeat distance"))
    (if (<= needed reader.produced)
      ""
      (compiler-lzss-decode-body
        payload
        reader
        (unsafe
          (__tl_array-data (deref out)))
        needed
        capacity
        model))))

(define (compiler-lzss-decode-range
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]
  [slack : i64]
  [check-tail? : bool]
  [model : (& model CompilerLzssModel)]) : CompilerLzssBytes
  (let
    [reader : CompilerLzssReader
      (compiler-lzss-reader start (- (array-length payload) start))]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (+ raw-len slack))]
    [error : String
      (compiler-lzss-decode-through!
        payload
        (&mut reader)
        (&mut out)
        raw-len
        model)]
    (cond
      [(> (string.string-length (& error)) 0) (Err error)]
      [(and check-tail? (not (compiler-lzss-tail-ok? payload (& reader))))
        (Err "compiler lzss: trailing compressed bytes")]
      [else (Ok out)])))

;; Decode a stream prefix that need not end on a token boundary: the token that
;; crosses `raw-len` finishes inside the extra space reserved for one match.
(define (compiler-lzss-decode-prefix-soft
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]
  [model : (& model CompilerLzssModel)]) : CompilerLzssBytes
  (compiler-lzss-decode-range
    payload
    start
    raw-len
    (compiler-lzss-max-match)
    false
    model))

;; Decode a stream prefix ending on a token boundary, without tail checks.
(define (compiler-lzss-decode-prefix
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]
  [model : (& model CompilerLzssModel)]) : CompilerLzssBytes
  (compiler-lzss-decode-range payload start raw-len 0 false model))

;; Decode one complete bitstream of `raw-len` bytes under `model`.
(define (compiler-lzss-decode-stream
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]
  [model : (& model CompilerLzssModel)]) : CompilerLzssBytes
  (compiler-lzss-decode-range payload start raw-len 0 true model))

;; Decode one `include-str-lzss` payload after bounded validation of its
;; envelope. The published seed writes the v2 envelope, so a compiler built by
;; it carries v2 frames and keeps this reader until the seed writes v3; the
;; encoder below only ever writes the current one.
(define (compiler-lzss-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerLzssBytes
  (when
    (compiler-lzss-prefix? payload (lzss_v2.compiler-lzss-v2-prefix))
    (return
      (match (lzss_v2.compiler-lzss-decode payload raw-limit)
        [(lzss_v2.CompilerLzssV2Bytes.Err message) (Err message)]
        [(lzss_v2.CompilerLzssV2Bytes.Ok bytes) (Ok bytes)])))
  (match (compiler-lzss-frame payload raw-limit)
    [(Err message) (Err message)]
    [(Ok raw-len compressed-start)
      (compiler-lzss-decode-stream
        payload
        compressed-start
        raw-len
        (& compiler-lzss-fixed-model))]))