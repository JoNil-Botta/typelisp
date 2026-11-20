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

(define (compiler-lzss-envelope-prefix) : String
  "__typelisp_embedded_stdlib_tlss_v3__")

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

(defstruct CompilerLzssLookup
  (bits i64)
  ;; symbol * 16 + length for a code of at most `bits` bits, 0 beyond that
  (entries (__tl_dyn-array i64))
  (code CompilerLzssDecode))

(defstruct CompilerLzssReader
  (start i64)
  (len i64)
  (pos i64)
  (buf i64)
  (count i64)
  (consumed i64))

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
  (main-lookup (__tl_dyn-array CompilerLzssLookup))
  (length-lookup CompilerLzssLookup)
  (dist-lookup (__tl_dyn-array CompilerLzssLookup)))

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

(define (compiler-lzss-lookup
  [lengths : (& lengths (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]
  [bits : i64]) : CompilerLzssLookup
  (let
    [limit : i64 (+ (compiler-lzss-max-code-bits) 1)]
    [entries : (__tl_dyn-array i64) (__tl_make-array i64 (shl 1 bits))]
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
              (set! (array-ref entries (+ first k)) (+ (* index 16) length))
              (set! k (+ k 1))))
          (set! (array-ref next length) (+ (array-ref next length) 1))))
      (set! index (+ index 1)))
    (CompilerLzssLookup
      bits
      entries
      (compiler-lzss-decode-table lengths start n))))

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

(define (compiler-lzss-model-from-lengths
  [lengths : (__tl_dyn-array i64)]) : CompilerLzssModel
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
    [main-lookup : (__tl_dyn-array CompilerLzssLookup)
      (__tl_make-array CompilerLzssLookup contexts)]
    [dist-lookup : (__tl_dyn-array CompilerLzssLookup)
      (__tl_make-array CompilerLzssLookup buckets)]
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
    (compiler-lzss-fill-codes! (& lengths) (&mut codes) length-start length-symbols)
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
        (array-ref main-lookup context)
        (compiler-lzss-lookup
          (& lengths)
          (* context main-symbols)
          main-symbols
          (compiler-lzss-main-lookup-bits)))
      (set! context (+ context 1)))
    (set! context 0)
    (while (< context buckets)
      (set!
        (array-ref dist-lookup context)
        (compiler-lzss-lookup
          (& lengths)
          (+ distance-start (* context distance-symbols))
          distance-symbols
          (compiler-lzss-distance-lookup-bits)))
      (set! context (+ context 1)))
    (let
      [length-lookup : CompilerLzssLookup
        (compiler-lzss-lookup
          (& lengths)
          length-start
          length-symbols
          (compiler-lzss-length-lookup-bits))]
      (CompilerLzssModel
        lengths
        codes
        length-start
        distance-start
        main-lookup
        length-lookup
        dist-lookup))))

(define (compiler-lzss-model-from-spec [spec : (& spec str)]) : CompilerLzssModel
  (compiler-lzss-model-from-lengths
    (compiler-lzss-spec-lengths spec)))

;; The model every source frame is coded under, built once per process.
(define compiler-lzss-fixed-model : CompilerLzssModel
  (compiler-lzss-model-from-spec (& compiler-lzss-fixed-spec)))

;; The context of the model for output position `position` after `previous`.
(define (compiler-lzss-context [previous : i64] [position : i64]) : i64
  (+
    (*
      2
      (-
        (cast
          (string.string-ref
            (& compiler-lzss-literal-classes)
            (bit-and previous 255))
          : i64)
        48))
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
;; The next bits of the stream, most significant first: `buf` holds the low
;; `count` bits not yet taken, `pos` is the next byte to load.
(define (compiler-lzss-refill!
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]) : unit
  (while (and (<= reader.count 48) (< reader.pos reader.len))
    (set!
      reader.buf
      (bit-or
        (shl reader.buf 8)
        (cast (array-ref payload (+ reader.start reader.pos)) : i64)))
    (set! reader.pos (+ reader.pos 1))
    (set! reader.count (+ reader.count 8))))

(define (compiler-lzss-peek [reader : (& reader CompilerLzssReader)] [n : i64]) : i64
  (if (>= reader.count n)
    (bit-and (shr reader.buf (- reader.count n)) (- (shl 1 n) 1))
    (bit-and (shl reader.buf (- n reader.count)) (- (shl 1 n) 1))))

;; Take `n` bits; false when the stream holds fewer.
(define (compiler-lzss-consume!
  [reader : (&mut reader CompilerLzssReader)]
  [n : i64]) : bool
  (if (> n reader.count)
    false
    (begin
      (set! reader.count (- reader.count n))
      (set! reader.buf (bit-and reader.buf (- (shl 1 reader.count) 1)))
      (set! reader.consumed (+ reader.consumed n))
      true)))

;; The next `n` raw bits, or -1 for a truncated stream.
(define (compiler-lzss-read-bits
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]
  [n : i64]) : i64
  (compiler-lzss-refill! payload reader)
  (let
    [value : i64 (compiler-lzss-peek reader n)]
    (if (compiler-lzss-consume! reader n)
      value
      -1)))

;; The next symbol of `lookup`'s code, or -1 for a truncated or unassigned code.
(define (compiler-lzss-read-symbol
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]
  [lookup : (& lookup CompilerLzssLookup)]) : i64
  (compiler-lzss-refill! payload reader)
  (let
    [entry : i64
      (array-ref lookup.entries (compiler-lzss-peek reader lookup.bits))]
    (if (> entry 0)
      (if (compiler-lzss-consume! reader (bit-and entry 15))
        (shr entry 4)
        -1)
      ;; A code longer than the table: finish it canonically.
      (let
        [len : i64 (+ lookup.bits 1)]
        [found : i64 -1]
        (while (and (< found 0) (<= len (compiler-lzss-max-code-bits)))
          (let
            [index : i64
              (-
                (compiler-lzss-peek reader len)
                (array-ref lookup.code.firsts len))]
            (when
              (and (>= index 0) (< index (array-ref lookup.code.counts len)))
              (set!
                found
                (if (compiler-lzss-consume! reader len)
                  (array-ref
                    lookup.code.symbols
                    (+ (array-ref lookup.code.starts len) index))
                  -2))))
          (set! len (+ len 1)))
        (if (< found 0)
          -1
          found)))))

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
;; Copy one back-reference: `length` bytes starting `distance` bytes before
;; `out-index` to `out-index`, in the output buffer whose data pointer is
;; `out-data`. The caller has already checked that both ranges lie inside the
;; buffer. A source at least eight bytes back is final for a whole word ahead,
;; so words copy it exactly as the byte loop would; a nearer, overlapping source
;; and the tail go byte by byte. Shared by source frames and the catalog stream.
(defmacro (compiler-lzss-copy-match!
  [out-data : Expr]
  [out-index : Expr]
  [distance : Expr]
  [length : Expr]) : unit
  `(let
    [dst : (MutPtr u8)
      (unsafe
        (ptr-offset ,out-data ,out-index))]
    [copied : i64 0]
    (when
      (>= ,distance 8)
      (let
        [words : i64 (- ,length 7)]
        (while (< copied words)
          (unsafe
            (ptr-write!
              (ptr-cast (ptr-offset dst copied) : (MutPtr i64))
              (ptr-read
                (ptr-cast (ptr-offset dst (- copied ,distance)) : (Ptr i64)))))
          (set! copied (+ copied 8)))))
    (while (< copied ,length)
      (unsafe
        (ptr-write!
          (ptr-offset dst copied)
          (ptr-read (ptr-offset dst (- copied ,distance)))))
      (set! copied (+ copied 1)))))

;; --- decode ------------------------------------------------------------------
;; Decode `raw-len` bytes into `out` from `out-start` under `model`; a match may
;; reach back before `out-start` into the catalog stream's earlier frames.
;; Returns "" on success, else a diagnostic. Every code, length, distance and
;; output range is checked before it is used.
(define (compiler-lzss-decode-body
  [payload : (& payload (__tl_dyn-array u8))]
  [reader : (&mut reader CompilerLzssReader)]
  [data : (MutPtr u8)]
  [out-start : i64]
  [raw-len : i64]
  [model : (& model CompilerLzssModel)]) : String
  (let
    [window : i64 (compiler-lzss-window)]
    [main-base : i64 (compiler-lzss-main-symbols)]
    [reps : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [out-index : i64 out-start]
    [end : i64 (+ out-start raw-len)]
    (set! (array-ref reps 0) 1)
    (set! (array-ref reps 1) 1)
    (set! (array-ref reps 2) 1)
    (set! (array-ref reps 3) 1)
    (while (< out-index end)
      (let
        [previous : i64
          (if (> out-index 0)
            (compiler-lzss-byte
              (unsafe
                (ptr-cast data : (Ptr u8)))
              (- out-index 1))
            0)]
        [context : i64 (compiler-lzss-context previous out-index)]
        [symbol : i64
          (compiler-lzss-read-symbol
            payload
            reader
            (& (array-ref model.main-lookup context)))]
        [kind : i64 0]
        [slot : i64 0]
        [extra : i64 0]
        [length : i64 0]
        [distance : i64 0]
        [move : i64 1]
        (when (< symbol 0) (return "compiler lzss: truncated symbol"))
        (cond
          [(< symbol 256)
            (unsafe
              (ptr-write! (ptr-offset data out-index) (cast symbol : u8)))
            (set! out-index (+ out-index 1))]
          [(>= symbol (compiler-lzss-shortrep))
            (set! distance (array-ref reps 0))
            (when
              (or (<= distance 0) (> distance out-index) (> distance window))
              (return "compiler lzss: invalid repeat distance"))
            (compiler-lzss-copy-match! data out-index distance 1)
            (set! out-index (+ out-index 1))]
          [else
            (set! kind (- symbol (compiler-lzss-match-new)))
            (set!
              slot
              (compiler-lzss-read-symbol payload reader (& model.length-lookup)))
            (when (< slot 0) (return "compiler lzss: truncated length"))
            (set!
              extra
              (compiler-lzss-read-bits
                payload
                reader
                (compiler-lzss-length-extra slot)))
            (when (< extra 0) (return "compiler lzss: truncated length"))
            (set! length (+ (compiler-lzss-length-base slot) extra))
            (when
              (or
                (< length (compiler-lzss-min-match))
                (> length (compiler-lzss-max-match)))
              (return "compiler lzss: invalid match length"))
            (when
              (> length (- end out-index))
              (return "compiler lzss: token exceeds raw length"))
            (cond
              [(= kind 0)
                (set!
                  slot
                  (compiler-lzss-read-symbol
                    payload
                    reader
                    (&
                      (array-ref
                        model.dist-lookup
                        (compiler-lzss-length-bucket length)))))
                (when (< slot 0) (return "compiler lzss: truncated distance"))
                (set!
                  extra
                  (compiler-lzss-read-bits
                    payload
                    reader
                    (compiler-lzss-distance-extra slot)))
                (when (< extra 0) (return "compiler lzss: truncated distance"))
                (set! distance (+ (compiler-lzss-distance-base slot) extra))
                (when
                  (<= distance 0)
                  (return "compiler lzss: invalid match distance"))
                (when
                  (or (> distance out-index) (> distance window))
                  (return "compiler lzss: backreference before output"))
                (set! (array-ref reps 3) (array-ref reps 2))
                (set! (array-ref reps 2) (array-ref reps 1))
                (set! (array-ref reps 1) (array-ref reps 0))
                (set! (array-ref reps 0) distance)]
              [else
                (set! distance (array-ref reps (- kind 1)))
                (when
                  (or (> distance out-index) (> distance window))
                  (return "compiler lzss: backreference before output"))
                (set! move kind)
                (while (> move 1)
                  (set! (array-ref reps (- move 1)) (array-ref reps (- move 2)))
                  (set! move (- move 1)))
                (set! (array-ref reps 0) distance)])
            (compiler-lzss-copy-match! data out-index distance length)
            (set! out-index (+ out-index length))])))
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
        [match : CompilerLzssMatch
          (compiler-lzss-find data source-len head-view previous-view index 0)]
        [best-symbol : i64 -1]
        [best-length : i64 0]
        [best-distance : i64 0]
        [best-gain : i64 0]
        [rep0-len : i64 0]
        [k : i64 0]
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
                (set! lazy false))))
          (cond
            [lazy
              (set!
                (array-ref tokens tokens-len)
                (CompilerLzssToken (compiler-lzss-byte data index) 1 0))
              (set! tokens-len (+ tokens-len 1))
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
          (ptr-offset
            (ptr-cast (__tl_array-data view) : (Ptr u8))
            start)
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

;; Decode one complete bitstream of `raw-len` bytes under `model`.
(define (compiler-lzss-decode-stream
  [payload : (& payload (__tl_dyn-array u8))]
  [start : i64]
  [raw-len : i64]
  [model : (& model CompilerLzssModel)]) : CompilerLzssBytes
  (let
    [reader : CompilerLzssReader
      (CompilerLzssReader start (- (array-length payload) start) 0 0 0 0)]
    [out : (__tl_dyn-array u8) (__tl_make-array u8 raw-len)]
    [error : String
      (if (= raw-len 0)
        ""
        (compiler-lzss-decode-body
          payload
          (&mut reader)
          (unsafe
            (__tl_array-data out))
          0
          raw-len
          model))]
    (cond
      [(> (string.string-length (& error)) 0) (Err error)]
      [(not (compiler-lzss-tail-ok? payload (& reader)))
        (Err "compiler lzss: trailing compressed bytes")]
      [else (Ok out)])))

;: Decode one `include-str-lzss` payload after bounded validation of its
;: envelope. A compiler built by a previous release embeds the earlier envelope,
;; so its reader stays until that release is superseded; the encoder below only
;; ever writes the current one.
(define (compiler-lzss-decode
  [payload : (& payload (__tl_dyn-array u8))]
  [raw-limit : i64]) : CompilerLzssBytes
  (when
    (or
      (compiler-lzss-prefix? payload (lzss_v2.compiler-lzss-v2-prefix))
      (compiler-lzss-prefix? payload (lzss_v2.compiler-lzss-envelope-prefix)))
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