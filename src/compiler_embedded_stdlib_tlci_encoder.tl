;; Build-only encoder: one Huffman model for the catalog envelope.
;;
;; The frame images are tokenized under the compiler's fixed model to collect
;; symbol frequencies; the lengths below turn those into the envelope's stored
;; model, which compiler_lzss then uses to code the whole stream.
(import stdlib.string)
(import stdlib.byte_buf_core as buf)
(import compiler_lzss as lzss)
(import compiler_abort as abort)

;; Symbol frequencies: every context table's main symbols, the length symbols,
;; then the four distance buckets.
(defstruct CompilerEmbeddedStdlibTlciEncoderFrequencies
  (main (__tl_dyn-array i64))
  (length (__tl_dyn-array i64))
  (dist (__tl_dyn-array i64)))

(define (compiler-embedded-stdlib-tlci-encoder-frequencies) : CompilerEmbeddedStdlibTlciEncoderFrequencies
  (CompilerEmbeddedStdlibTlciEncoderFrequencies
    (__tl_make-array
      i64
      (* (lzss.compiler-lzss-contexts) (lzss.compiler-lzss-main-symbols)))
    (__tl_make-array i64 (lzss.compiler-lzss-length-symbols))
    (__tl_make-array
      i64
      (*
        (lzss.compiler-lzss-length-buckets)
        (lzss.compiler-lzss-distance-symbols)))))

(define (compiler-embedded-stdlib-tlci-encoder-bump
  [counts : (&mut counts (__tl_dyn-array i64))]
  [index : i64]) : unit
  (set! (array-ref counts index) (+ (array-ref counts index) 1)))

;; Count the symbols of one frame's tokens, with the literal context of each
;; token read from the frame's own bytes.
(define (compiler-embedded-stdlib-tlci-encoder-count!
  [frequencies
    : (&mut frequencies CompilerEmbeddedStdlibTlciEncoderFrequencies)]
  [source : (& str)]
  [tokens : (& tokens (__tl_dyn-array lzss.CompilerLzssToken))]) : unit
  (let
    [main-base : i64 (lzss.compiler-lzss-main-symbols)]
    [count : i64 (array-length tokens)]
    [index : i64 0]
    [position : i64 0]
    (while (< index count)
      (let
        [token : lzss.CompilerLzssToken (array-ref tokens index)]
        [previous : i64
          (if (> position 0)
            (cast (string.string-ref source (- position 1)) : i64)
            0)]
        [context : i64 (lzss.compiler-lzss-context previous position)]
        (compiler-embedded-stdlib-tlci-encoder-bump
          (&mut frequencies.main)
          (+ (* context main-base) token.symbol))
        (when
          (and
            (>= token.symbol (lzss.compiler-lzss-match-new))
            (< token.symbol (lzss.compiler-lzss-shortrep)))
          (compiler-embedded-stdlib-tlci-encoder-bump
            (&mut frequencies.length)
            (lzss.compiler-lzss-length-slot token.length))
          (when
            (= token.symbol (lzss.compiler-lzss-match-new))
            (compiler-embedded-stdlib-tlci-encoder-bump
              (&mut frequencies.dist)
              (+
                (*
                  (lzss.compiler-lzss-length-bucket token.length)
                  (lzss.compiler-lzss-distance-symbols))
                (lzss.compiler-lzss-distance-slot token.distance)))))
        (set! position (+ position token.length)))
      (set! index (+ index 1))))
  unit)

;; Optimal code lengths for one table, limited to the codec's maximum. Every
;; symbol keeps a frequency of at least one, so every symbol stays codable.
(define (compiler-embedded-stdlib-tlci-encoder-table-lengths
  [frequencies : (& frequencies (__tl_dyn-array i64))]
  [start : i64]
  [n : i64]) : (__tl_dyn-array i64)
  (let
    [max-bits : i64 (lzss.compiler-lzss-max-code-bits)]
    [nodes : i64 (* 2 n)]
    [weight : (__tl_dyn-array i64) (__tl_make-array i64 nodes)]
    [parent : (__tl_dyn-array i64) (__tl_make-array i64 nodes)]
    [alive : (__tl_dyn-array bool) (__tl_make-array bool nodes)]
    [lengths : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [index : i64 0]
    [next : i64 n]
    [open : i64 n]
    ;; Every node starts without a parent; the sentinel `nodes` ends the depth
    ;; walk at the root.
    (while (< index nodes)
      (set! (array-ref parent index) nodes)
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index n)
      (set!
        (array-ref weight index)
        (+ (array-ref frequencies (+ start index)) 1))
      (set! (array-ref alive index) true)
      (set! index (+ index 1)))
    (while (> open 1)
      (let
        [first : i64 -1]
        [second : i64 -1]
        [cursor : i64 0]
        (while (< cursor next)
          (when
            (array-ref alive cursor)
            (if (or
              (= first -1)
              (< (array-ref weight cursor) (array-ref weight first)))
              (begin
                (set! second first)
                (set! first cursor))
              (if (or
                (= second -1)
                (< (array-ref weight cursor) (array-ref weight second)))
                (set! second cursor)
                unit)))
          (set! cursor (+ cursor 1)))
        (set!
          (array-ref weight next)
          (+ (array-ref weight first) (array-ref weight second)))
        (set! (array-ref parent first) next)
        (set! (array-ref parent second) next)
        (set! (array-ref alive first) false)
        (set! (array-ref alive second) false)
        (set! (array-ref alive next) true)
        (set! next (+ next 1))
        (set! open (- open 1))))
    (set! index 0)
    (while (< index n)
      (let
        [depth : i64 0]
        [cursor : i64 (array-ref parent index)]
        (while (< cursor next)
          (set! depth (+ depth 1))
          (set! cursor (array-ref parent cursor)))
        (set! (array-ref lengths index) depth))
      (set! index (+ index 1)))
    ;; Limit the code lengths: clamp the deep ones first, then lengthen the
    ;; cheapest short codes until the Kraft sum fits, which costs the least.
    (let
      [limit : i64 (shl 1 max-bits)]
      [total : i64 0]
      (set! index 0)
      (while (< index n)
        (when
          (> (array-ref lengths index) max-bits)
          (set! (array-ref lengths index) max-bits))
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index n)
        (+= total (shl 1 (- max-bits (array-ref lengths index))))
        (set! index (+ index 1)))
      (while (> total limit)
        (let
          [pick : i64 -1]
          [cursor : i64 0]
          (while (< cursor n)
            (when
              (and
                (< (array-ref lengths cursor) max-bits)
                (or
                  (= pick -1)
                  (< (array-ref weight cursor) (array-ref weight pick))))
              (set! pick cursor))
            (set! cursor (+ cursor 1)))
          (when
            (= pick -1)
            (abort.compiler-abort
              "tl: embedded stdlib tlci encoder: cannot limit code lengths\n"))
          (-= total (shl 1 (- (- max-bits (array-ref lengths pick)) 1)))
          (set! (array-ref lengths pick) (+ (array-ref lengths pick) 1))))
      lengths)))

(define (compiler-embedded-stdlib-tlci-encoder-lengths
  [frequencies : (& frequencies CompilerEmbeddedStdlibTlciEncoderFrequencies)]) : (__tl_dyn-array
    i64)
  (let
    [contexts : i64 (lzss.compiler-lzss-contexts)]
    [main-symbols : i64 (lzss.compiler-lzss-main-symbols)]
    [length-symbols : i64 (lzss.compiler-lzss-length-symbols)]
    [distance-symbols : i64 (lzss.compiler-lzss-distance-symbols)]
    [buckets : i64 (lzss.compiler-lzss-length-buckets)]
    [length-start : i64 (* contexts main-symbols)]
    [distance-start : i64 (+ length-start length-symbols)]
    [lengths : (__tl_dyn-array i64)
      (__tl_make-array i64 (+ distance-start (* buckets distance-symbols)))]
    [context : i64 0]
    (while (< context contexts)
      (let
        [table
          (compiler-embedded-stdlib-tlci-encoder-table-lengths
            (& frequencies.main)
            (* context main-symbols)
            main-symbols)]
        [index : i64 0]
        (while (< index main-symbols)
          (set!
            (array-ref lengths (+ (* context main-symbols) index))
            (array-ref table index))
          (set! index (+ index 1))))
      (set! context (+ context 1)))
    (let
      [table
        (compiler-embedded-stdlib-tlci-encoder-table-lengths
          (& frequencies.length)
          0
          length-symbols)]
      [index : i64 0]
      (while (< index length-symbols)
        (set!
          (array-ref lengths (+ length-start index))
          (array-ref table index))
        (set! index (+ index 1))))
    (set! context 0)
    (while (< context buckets)
      (let
        [table
          (compiler-embedded-stdlib-tlci-encoder-table-lengths
            (& frequencies.dist)
            (* context distance-symbols)
            distance-symbols)]
        [index : i64 0]
        (while (< index distance-symbols)
          (set!
            (array-ref
              lengths
              (+ distance-start (* context distance-symbols) index))
            (array-ref table index))
          (set! index (+ index 1))))
      (set! context (+ context 1)))
    lengths))

;; The model's code lengths as the codec's 'A' + length characters.
(define (compiler-embedded-stdlib-tlci-encoder-spec
  [lengths : (& lengths (__tl_dyn-array i64))]) : String
  (let
    [out : buf.ByteBufBuilder (buf.byte-buf-builder-new)]
    [index : i64 0]
    [n : i64 (array-length lengths)]
    (while (< index n)
      (buf.byte-buf-builder-push
        (&mut out)
        (cast (+ 65 (array-ref lengths index)) : u8))
      (set! index (+ index 1)))
    (buf.byte-buf-builder-to-string (& out))))