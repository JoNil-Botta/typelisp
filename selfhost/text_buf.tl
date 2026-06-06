;; text_buf.tl - Deterministic self-hosted text buffer utilities (#336).
;;
;; The buffer is intentionally monomorphic and list-backed: append is cheap
;; enough for current selfhost compiler slices, and render preserves append
;; order exactly by walking the reversed chunk list once.
(import "../stdlib/string.tl")

(defenum TextChunkList
  (TextChunkNil)
  (TextChunkCons String (Box TextChunkList)))

(defenum TextBuf
  (TextBuf TextChunkList i64))

(define (text-buf-empty) : TextBuf
  (TextBuf TextChunkNil 0))

(define (text-buf-append [buf : TextBuf] [chunk : String]) : TextBuf
  (match buf
    [(TextBuf chunks count)
      (TextBuf (TextChunkCons chunk (box chunks)) (+ count 1))]))

(define (text-chunk-list-concat [front : TextChunkList] [back : TextChunkList]) : TextChunkList
  (match front
    [(TextChunkNil) back]
    [(TextChunkCons chunk rest)
      (TextChunkCons chunk (box (text-chunk-list-concat (box-get rest) back)))]))

(define (text-buf-append-buffer [left : TextBuf] [right : TextBuf]) : TextBuf
  (match left
    [(TextBuf left-chunks left-count)
      (match right
        [(TextBuf right-chunks right-count)
          (TextBuf
            (text-chunk-list-concat right-chunks left-chunks)
            (+ left-count right-count))])]))

(define (text-chunks-render-rev [chunks : TextChunkList] [out : String]) : String
  (match chunks
    [(TextChunkNil) out]
    [(TextChunkCons chunk rest)
      (text-chunks-render-rev (box-get rest) (string-append chunk out))]))

(define (text-chunks-fill-array-rev
  [chunks : TextChunkList]
  [items : (Array String)]
  [index : i64]) : unit
  (match chunks
    [(TextChunkNil) unit]
    [(TextChunkCons chunk rest)
      (begin
        (array-set! items index chunk)
        (text-chunks-fill-array-rev (box-get rest) items (- index 1)))]))

(define (text-chunks-render-array-range
  [items : (Array String)]
  [lo : i64]
  [hi : i64]) : String
  (if (>= lo hi)
    ""
    (if (= (+ lo 1) hi)
      (array-ref items lo)
      (let
        [mid : i64 (/ (+ lo hi) 2)]
        (string-append
          (text-chunks-render-array-range items lo mid)
          (text-chunks-render-array-range items mid hi))))))

(define (text-chunks-render-balanced [chunks : TextChunkList] [count : i64]) : String
  (let
    [items : (Array String) (make-array String count)]
    (begin
      (text-chunks-fill-array-rev chunks items (- count 1))
      (text-chunks-render-array-range items 0 count))))

(define (text-buf-render [buf : TextBuf]) : String
  (match buf
    [(TextBuf chunks count)
      (if (> count 32)
        (text-chunks-render-balanced chunks count)
        (text-chunks-render-rev chunks ""))]))