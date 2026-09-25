;# Bounded streaming unified diff between two in-memory texts.
;#
;# Each text is compared as its `\n`-separated segments, indexed by start
;# offset over the caller's borrowed buffer. The segment after the last `\n`
;# (empty when the text ends with one) is a line too, and every rendered line
;# ends with `\n`. Joining one side's rendered lines with `\n` therefore
;# reproduces its exact bytes: a missing final newline is the absence of that
;# trailing empty line, and `\r` and non-ASCII bytes are ordinary content.
;#
;# Resynchronization is deliberately bounded rather than a whole-file LCS.
;# Local edits resynchronize on a short run of equal lines, and equal runs
;# longer than two context windows split hunks. Work is linear in unchanged
;# spans and bounded by a small lookahead around each changed span, and every
;# choice depends only on line bytes and positions.
;#
;# Output streams to a caller-owned sink in chunks of at most `chunk-bytes`.
;# Beyond its inputs, a rendering allocates one line-start index per side and
;# one staging buffer; the complete diff is never materialized.
(import stdlib.byte_buf)
(import stdlib.string)

;: Caller policy for one rendering. `max-bytes` and `max-lines` cap the
;: output, headers included; `no-limit` disables a cap. Each sink call
;: receives at most `chunk-bytes` bytes, and never more than
;: `default-chunk-bytes`, which also bounds the staging buffer.
(defstruct UnifiedDiffOptions
  (max-bytes i64)
  (max-lines i64)
  (chunk-bytes i64))

(define no-limit : i64
  9223372036854775807)
(define default-chunk-bytes : i64
  65536)

(define (unbounded) : UnifiedDiffOptions
  (UnifiedDiffOptions no-limit no-limit default-chunk-bytes))

;: Why a rendering stopped; stable event vocabulary for #7280.
(defenum UnifiedDiffOutcome
  ;; Every line reached the sink.
  (Complete)
  ;; The cap stopped output before a line. The payload is the exact byte and
  ;; line count of the complete rendering's remainder.
  (Truncated i64 i64)
  ;; The sink returned this nonzero status (a host write error, a broken pipe,
  ;; or a caller-defined cancellation). The sink is never called again.
  (SinkFailed i64)
  ;; A negative cap or a non-positive chunk size; the sink was never called.
  (InvalidOptions))

;: Emitted counts cover only chunks the sink accepted. `emitted-lines` counts
;: complete output lines, so a failure can leave one partial line delivered.
(defstruct UnifiedDiffReport
  (outcome UnifiedDiffOutcome)
  (emitted-bytes i64)
  (emitted-lines i64))

(define context-lines : i64
  3)
(define lookahead-lines : i64
  64)
(define anchor-lines : i64
  3)

(define (ascii [c : char]) : u8
  (cast c : u8))

(define (newline-byte) : u8
  (ascii '\n'))

;; `starts[i]` is the offset of line `i` and `starts[count]` is one past the
;; text, so every line `i` spans `[starts[i], starts[i + 1] - 1)`.
(defstruct Side
  (:lifetimes t)
  (text (& t str))
  (starts (__tl_dyn-array i64))
  (count i64))

(define (side [text : (& t str)]) : (Side t)
  (let
    [count : i64 1]
    [cursor : i64 (string.index-of-byte text 0 (newline-byte))]
    (begin
      (while (>= cursor 0)
        (set! count (+ count 1))
        (set! cursor (string.index-of-byte text (+ cursor 1) (newline-byte))))
      (let
        [starts : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
        [line : i64 1]
        [next : i64 (string.index-of-byte text 0 (newline-byte))]
        (begin
          (set! (array-ref starts 0) 0)
          (while (>= next 0)
            (set! (array-ref starts line) (+ next 1))
            (set! line (+ line 1))
            (set! next (string.index-of-byte text (+ next 1) (newline-byte))))
          (set! (array-ref starts count) (+ (string.string-length text) 1))
          (Side text starts count))))))

(define (line-start [lines : (& s (Side t))] [index : i64]) : i64
  (array-ref lines.starts index))

(define (line-length [lines : (& s (Side t))] [index : i64]) : i64
  (- (array-ref lines.starts (+ index 1)) (+ (array-ref lines.starts index) 1)))

(define (text-byte [text : (& t str)] [index : i64]) : i64
  (cast (string.string-ref text index) : i64))

;; Compare two lines in place. `substring-view` would retain a
;; process-lifetime record per call (#8080), making the probe loops allocate in
;; proportion to their work; return to `string.eq` over views once views are
;; allocation-free. Like `string.eq`, whole words are compared and the tail is
;; covered by one overlapping read. Soundness: `side` is the only producer of a
;; `Side`, and every offset it records lies in `[0, len(text) + 1]` with
;; `starts` nondecreasing, so each line range `[start, start + length)` is
;; inside its own text and every read below stays within both lines.
(define (same-line?
  [old : (& o (Side a))]
  [old-index : i64]
  [new : (& n (Side b))]
  [new-index : i64]) : bool
  (let
    [len : i64 (line-length old old-index)]
    (and
      (= len (line-length new new-index))
      (unsafe
        (let
          [lp : (Ptr u8)
            (ptr-offset (string-data old.text) (line-start old old-index))]
          [rp : (Ptr u8)
            (ptr-offset (string-data new.text) (line-start new new-index))]
          (cond
            [(>= len 8)
              (let
                [lw : (Ptr i64) (ptr-cast lp : (Ptr i64))]
                [rw : (Ptr i64) (ptr-cast rp : (Ptr i64))]
                [words : i64 (shr len 3)]
                [index : i64 0]
                (begin
                  (while (and
                    (< index words)
                    (=
                      (ptr-read (ptr-offset lw index))
                      (ptr-read (ptr-offset rw index))))
                    (set! index (+ index 1)))
                  (and
                    (= index words)
                    (=
                      (ptr-read
                        (ptr-cast (ptr-offset lp (- len 8)) : (Ptr i64)))
                      (ptr-read
                        (ptr-cast (ptr-offset rp (- len 8)) : (Ptr i64)))))))]
            [(>= len 4)
              (and
                (=
                  (ptr-read (ptr-cast lp : (Ptr u32)))
                  (ptr-read (ptr-cast rp : (Ptr u32))))
                (=
                  (ptr-read (ptr-cast (ptr-offset lp (- len 4)) : (Ptr u32)))
                  (ptr-read (ptr-cast (ptr-offset rp (- len 4)) : (Ptr u32)))))]
            [(>= len 2)
              (and
                (=
                  (ptr-read (ptr-cast lp : (Ptr u16)))
                  (ptr-read (ptr-cast rp : (Ptr u16))))
                (=
                  (ptr-read (ptr-cast (ptr-offset lp (- len 2)) : (Ptr u16)))
                  (ptr-read (ptr-cast (ptr-offset rp (- len 2)) : (Ptr u16)))))]
            [(= len 1) (= (ptr-read lp) (ptr-read rp))]
            [else true]))))))

(define (line-eq?
  [old : (& o (Side a))]
  [old-index : i64]
  [old-end : i64]
  [new : (& n (Side b))]
  [new-index : i64]
  [new-end : i64]) : bool
  (and
    (< old-index old-end)
    (< new-index new-end)
    (same-line? old old-index new new-index)))

(defenum Sync
  (SyncFound i64 i64)
  (SyncMissing))

(defstruct Hunk
  (old-start i64)
  (old-end i64)
  (new-start i64)
  (new-end i64)
  (next-old i64)
  (next-new i64))

(defenum HunkStep
  (NoHunk)
  (NextHunk Hunk))

;; Require three equal lines for an interior anchor so repeated blank or
;; delimiter-only lines do not resynchronize the streams spuriously. A shorter
;; run is sufficient only when it consumes both remaining tails. Every run
;; starts with an equal line, which is tested first because almost every
;; probed pair fails there.
(define (sync-run?
  [old : (& o (Side a))]
  [old-index : i64]
  [old-end : i64]
  [new : (& n (Side b))]
  [new-index : i64]
  [new-end : i64]) : bool
  (let
    [old-left : i64 (- old-end old-index)]
    [new-left : i64 (- new-end new-index)]
    [available : i64
      (if (< old-left new-left)
        old-left
        new-left)]
    [count : i64
      (if (< available anchor-lines)
        available
        anchor-lines)]
    [offset : i64 1]
    [same : bool true]
    (and
      (> count 0)
      (same-line? old old-index new new-index)
      (or
        (= count anchor-lines)
        (and (= (+ old-index count) old-end) (= (+ new-index count) new-end)))
      (begin
        (while (and same (< offset count))
          (set!
            same
            (same-line? old (+ old-index offset) new (+ new-index offset)))
          (set! offset (+ offset 1)))
        same))))

;; Search edit distance first, so a one-line insertion/deletion wins over a
;; larger replacement. The search area is capped independently of file size.
(define (find-sync
  [old : (& o (Side a))]
  [old-index : i64]
  [old-end : i64]
  [new : (& n (Side b))]
  [new-index : i64]
  [new-end : i64]) : Sync
  (let
    [old-left : i64 (- old-end old-index)]
    [new-left : i64 (- new-end new-index)]
    [max-old : i64
      (if (< old-left lookahead-lines)
        old-left
        lookahead-lines)]
    [max-new : i64
      (if (< new-left lookahead-lines)
        new-left
        lookahead-lines)]
    [distance : i64 1]
    [found : bool false]
    [found-old : i64 0]
    [found-new : i64 0]
    (begin
      (while (and (not found) (<= distance (+ max-old max-new)))
        (let
          [old-skip : i64
            (if (> distance max-new)
              (- distance max-new)
              0)]
          [old-limit : i64
            (if (< distance max-old)
              distance
              max-old)]
          (begin
            (while (and (not found) (<= old-skip old-limit))
              (let
                [new-skip : i64 (- distance old-skip)]
                (begin
                  ;; A length mismatch on the first line rejects the pair
                  ;; without a call; `sync-run?` decides every other pair.
                  (when
                    (and
                      (< (+ old-index old-skip) old-end)
                      (< (+ new-index new-skip) new-end)
                      (=
                        (line-length old (+ old-index old-skip))
                        (line-length new (+ new-index new-skip)))
                      (sync-run?
                        old
                        (+ old-index old-skip)
                        old-end
                        new
                        (+ new-index new-skip)
                        new-end))
                    (set! found true)
                    (set! found-old old-skip)
                    (set! found-new new-skip))
                  (set! old-skip (+ old-skip 1)))))
            (set! distance (+ distance 1)))))
      (if found
        (SyncFound found-old found-new)
        (SyncMissing)))))

(define (window-end [index : i64] [end : i64]) : i64
  (if (< (- end index) lookahead-lines)
    end
    (+ index lookahead-lines)))

(define (next-hunk
  [old : (& o (Side a))]
  [new : (& n (Side b))]
  [scan-old : i64]
  [scan-new : i64]) : HunkStep
  (let
    [old-len : i64 old.count]
    [new-len : i64 new.count]
    [old-index : i64 scan-old]
    [new-index : i64 scan-new]
    (begin
      (while (line-eq? old old-index old-len new new-index new-len)
        (set! old-index (+ old-index 1))
        (set! new-index (+ new-index 1)))
      (if (and (>= old-index old-len) (>= new-index new-len))
        (NoHunk)
        (let
          [old-start : i64
            (if (> old-index context-lines)
              (- old-index context-lines)
              0)]
          [new-start : i64
            (if (> new-index context-lines)
              (- new-index context-lines)
              0)]
          [finished : bool false]
          [split : bool false]
          [old-end : i64 old-len]
          [new-end : i64 new-len]
          (begin
            (while (not finished)
              (if (line-eq? old old-index old-len new new-index new-len)
                (let
                  [common-old : i64 old-index]
                  [common-new : i64 new-index]
                  (begin
                    (while (line-eq?
                      old
                      old-index
                      old-len
                      new
                      new-index
                      new-len)
                      (set! old-index (+ old-index 1))
                      (set! new-index (+ new-index 1)))
                    (cond
                      [(> (- old-index common-old) (* 2 context-lines))
                        (begin
                          (set! old-end (+ common-old context-lines))
                          (set! new-end (+ common-new context-lines))
                          (set! split true)
                          (set! finished true))]
                      [(and (>= old-index old-len) (>= new-index new-len))
                        (set! finished true)]
                      [else unit])))
                (match (find-sync old old-index old-len new new-index new-len)
                  [(SyncFound old-skip new-skip)
                    (begin
                      (set! old-index (+ old-index old-skip))
                      (set! new-index (+ new-index new-skip)))]
                  [(SyncMissing)
                    (begin
                      (set! old-index (window-end old-index old-len))
                      (set! new-index (window-end new-index new-len))
                      (when
                        (and (>= old-index old-len) (>= new-index new-len))
                        (set! finished true)))])))
            (NextHunk
              (Hunk
                old-start
                old-end
                new-start
                new-end
                (if split
                  old-end
                  old-len)
                (if split
                  new-end
                  new-len)))))))))

;; `admitted-*` counts lines accepted under the cap, whether still staged or
;; already delivered; `staged-lines` counts complete lines in `stage`.
(defstruct Output
  (stage byte_buf.ByteBuf)
  (chunk-bytes i64)
  (max-bytes i64)
  (max-lines i64)
  (admitted-bytes i64)
  (admitted-lines i64)
  (staged-lines i64)
  (emitted-bytes i64)
  (emitted-lines i64)
  (truncated bool)
  (omitted-bytes i64)
  (omitted-lines i64)
  (status i64))

(define (output [options : UnifiedDiffOptions]) : Output
  (let
    [chunk : i64
      (if (< options.chunk-bytes default-chunk-bytes)
        options.chunk-bytes
        default-chunk-bytes)]
    (Output
      (byte_buf.with-capacity chunk)
      chunk
      options.max-bytes
      options.max-lines
      0
      0
      0
      0
      0
      false
      0
      0
      0)))

;; Hand the staged bytes to the sink. After a failure nothing is staged or
;; offered again, so the sink sees at most one failing call.
(define (flush! [out : (&mut o Output)] [sink : (-> (& bytes) i64)]) : unit
  (when
    (and (= out.status 0) (> out.stage.len 0))
    (let
      [status : i64 (sink (byte_buf.as-bytes (& out.stage)))]
      (if (= status 0)
        (begin
          (set! out.emitted-bytes (+ out.emitted-bytes out.stage.len))
          (set! out.emitted-lines (+ out.emitted-lines out.staged-lines))
          (set! out.staged-lines 0)
          (set! out.stage.len 0))
        (set! out.status status)))))

(define (put-byte!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [value : u8]) : unit
  (begin
    (when (>= out.stage.len out.chunk-bytes) (flush! out sink))
    (when
      (= out.status 0)
      (let
        [offset : i64 out.stage.len]
        (begin
          (set! (array-ref out.stage.slots offset) value)
          (set! out.stage.len (+ offset 1)))))))

;; The stage holds `chunk-bytes` slots and is flushed before it is full, so
;; every copy stays inside it; the source range is checked once up front.
(define (put-text!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [text : (& t str)]
  [start : i64]
  [count : i64]) : unit
  (let
    [cursor : i64 start]
    [left : i64 count]
    (begin
      (string.substring-bounds-check text start count)
      (while (and (> left 0) (= out.status 0))
        (begin
          (when (>= out.stage.len out.chunk-bytes) (flush! out sink))
          (when
            (= out.status 0)
            (let
              [room : i64 (- out.chunk-bytes out.stage.len)]
              [n : i64
                (if (< left room)
                  left
                  room)]
              [offset : i64 out.stage.len]
              (begin
                (string.str-copy-bytes-into
                  (unsafe
                    (ptr-offset (string-data text) cursor))
                  (unsafe
                    (__tl_array-data out.stage.slots))
                  offset
                  n)
                (set! out.stage.len (+ offset n))
                (set! cursor (+ cursor n))
                (set! left (- left n))))))))))

(define (put-newline! [out : (&mut o Output)] [sink : (-> (& bytes) i64)]) : unit
  (begin
    (put-byte! out sink (newline-byte))
    (when (= out.status 0) (set! out.staged-lines (+ out.staged-lines 1)))))

;; Admit one output line of `size` bytes, or count it as omitted. Every line
;; of either input is rendered at most once, so all totals stay within a small
;; multiple of the input sizes; the cap test subtracts from the cap instead of
;; adding to the admitted total, so `no-limit` cannot overflow.
(define (admit! [out : (&mut o Output)] [size : i64]) : bool
  (cond
    [(!= out.status 0) false]
    [(and
        (not out.truncated)
        (< out.admitted-lines out.max-lines)
        (<= size (- out.max-bytes out.admitted-bytes)))
      (begin
        (set! out.admitted-bytes (+ out.admitted-bytes size))
        (set! out.admitted-lines (+ out.admitted-lines 1))
        true)]
    [else
      (begin
        (set! out.truncated true)
        (set! out.omitted-bytes (+ out.omitted-bytes size))
        (set! out.omitted-lines (+ out.omitted-lines 1))
        false)]))

(define (decimal-width [value : i64]) : i64
  (let
    [width : i64 1]
    [rest : i64 (/ value 10)]
    (begin
      (while (> rest 0)
        (set! width (+ width 1))
        (set! rest (/ rest 10)))
      width)))

(define (put-decimal!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [value : i64]) : unit
  (let
    [divisor : i64 1]
    [digit : i64 1]
    (begin
      (while (< digit (decimal-width value))
        (set! divisor (* divisor 10))
        (set! digit (+ digit 1)))
      (while (> divisor 0)
        (put-byte!
          out
          sink
          (cast (+ (cast '0' : i64) (% (/ value divisor) 10)) : u8))
        (set! divisor (/ divisor 10))))))

;: Header paths use Git's C-style quoting when they contain a control byte,
;: DEL, `"` or `\`: the whole `a/` or `b/` name is wrapped in `"` and those
;: bytes are written as `\a \b \t \n \v \f \r \" \\` or three-digit octal.
;: Bytes >= 0x80 stay raw. Any other path is written verbatim, so an unquoted
;: name never starts with `"` and the rule is reversible.
(define (escape-width [byte : i64]) : i64
  (cond
    [(or (= byte (cast '"' : i64)) (= byte (cast '\\' : i64))) 2]
    [(and (>= byte 7) (<= byte 13)) 2]
    [(or (< byte 32) (= byte 127)) 4]
    [else 1]))

(define (escaped-path-width [path : (& p str)]) : i64
  (let
    [index : i64 0]
    [width : i64 0]
    (begin
      (while (< index (string.string-length path))
        (set! width (+ width (escape-width (text-byte path index))))
        (set! index (+ index 1)))
      width)))

(define (put-escaped-byte!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [byte : i64]) : unit
  (let
    [width : i64 (escape-width byte)]
    (cond
      [(= width 1) (put-byte! out sink (cast byte : u8))]
      [(= width 2)
        (begin
          (put-byte! out sink (ascii '\\'))
          (put-byte!
            out
            sink
            (if (< byte 32)
              (cast (string.string-ref "abtnvfr" (- byte 7)) : u8)
              (cast byte : u8))))]
      [else
        (begin
          (put-byte! out sink (ascii '\\'))
          (put-byte!
            out
            sink
            (cast (+ (cast '0' : i64) (bit-and (shr byte 6) 7)) : u8))
          (put-byte!
            out
            sink
            (cast (+ (cast '0' : i64) (bit-and (shr byte 3) 7)) : u8))
          (put-byte! out sink (cast (+ (cast '0' : i64) (bit-and byte 7)) : u8)))])))

;; One `--- a/path` or `+++ b/path` header line.
(define (put-file-header!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [lead : u8]
  [side-letter : u8]
  [path : (& p str)]) : unit
  (let
    [escaped : i64 (escaped-path-width path)]
    [quoted : bool (!= escaped (string.string-length path))]
    [size : i64
      (+
        escaped
        (if quoted
          9
          7))]
    (when
      (admit! out size)
      (put-byte! out sink lead)
      (put-byte! out sink lead)
      (put-byte! out sink lead)
      (put-byte! out sink (ascii ' '))
      (when quoted (put-byte! out sink (ascii '"')))
      (put-byte! out sink side-letter)
      (put-byte! out sink (ascii '/'))
      (let
        [index : i64 0]
        (while (< index (string.string-length path))
          (put-escaped-byte! out sink (text-byte path index))
          (set! index (+ index 1))))
      (when quoted (put-byte! out sink (ascii '"')))
      (put-newline! out sink))))

(define (put-hunk-header!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [hunk : Hunk]) : unit
  (let
    [old-first : i64 (+ hunk.old-start 1)]
    [old-count : i64 (- hunk.old-end hunk.old-start)]
    [new-first : i64 (+ hunk.new-start 1)]
    [new-count : i64 (- hunk.new-end hunk.new-start)]
    [size : i64
      (+
        12
        (decimal-width old-first)
        (decimal-width old-count)
        (decimal-width new-first)
        (decimal-width new-count))]
    (when
      (admit! out size)
      (put-text! out sink "@@ -" 0 4)
      (put-decimal! out sink old-first)
      (put-byte! out sink (ascii ','))
      (put-decimal! out sink old-count)
      (put-text! out sink " +" 0 2)
      (put-decimal! out sink new-first)
      (put-byte! out sink (ascii ','))
      (put-decimal! out sink new-count)
      (put-text! out sink " @@" 0 3)
      (put-newline! out sink))))

(define (put-range!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [marker : u8]
  [lines : (& s (Side t))]
  [from : i64]
  [to : i64]) : unit
  (let
    [index : i64 from]
    (while (and (< index to) (= out.status 0))
      (let
        [len : i64 (line-length lines index)]
        (begin
          (when
            (admit! out (+ len 2))
            (put-byte! out sink marker)
            (put-text! out sink lines.text (line-start lines index) len)
            (put-newline! out sink))
          (set! index (+ index 1)))))))

(define (put-hunk!
  [out : (&mut o Output)]
  [sink : (-> (& bytes) i64)]
  [old : (& o (Side a))]
  [new : (& n (Side b))]
  [hunk : Hunk]) : unit
  (let
    [old-index : i64 hunk.old-start]
    [new-index : i64 hunk.new-start]
    (begin
      (put-hunk-header! out sink hunk)
      (while (and
        (= out.status 0)
        (or (< old-index hunk.old-end) (< new-index hunk.new-end)))
        (if (line-eq? old old-index hunk.old-end new new-index hunk.new-end)
          (begin
            (put-range! out sink (ascii ' ') old old-index (+ old-index 1))
            (set! old-index (+ old-index 1))
            (set! new-index (+ new-index 1)))
          (match (find-sync
            old
            old-index
            hunk.old-end
            new
            new-index
            hunk.new-end)
            [(SyncFound old-skip new-skip)
              (begin
                (put-range!
                  out
                  sink
                  (ascii '-')
                  old
                  old-index
                  (+ old-index old-skip))
                (put-range!
                  out
                  sink
                  (ascii '+')
                  new
                  new-index
                  (+ new-index new-skip))
                (set! old-index (+ old-index old-skip))
                (set! new-index (+ new-index new-skip)))]
            [(SyncMissing)
              ;; Keep probing after a bounded unmatched window. A whole-file
              ;; line-ending change can otherwise hide a short equal tail
              ;; beyond the first lookahead and render it as remove/add text
              ;; instead of the hunk's final unchanged context.
              (let
                [old-next : i64 (window-end old-index hunk.old-end)]
                [new-next : i64 (window-end new-index hunk.new-end)]
                (begin
                  (put-range! out sink (ascii '-') old old-index old-next)
                  (put-range! out sink (ascii '+') new new-index new-next)
                  (set! old-index old-next)
                  (set! new-index new-next)))]))))))

(define (report [out : (& o Output)]) : UnifiedDiffReport
  (UnifiedDiffReport
    (cond
      [(!= out.status 0) (SinkFailed out.status)]
      [out.truncated (Truncated out.omitted-bytes out.omitted-lines)]
      [else (Complete)])
    out.emitted-bytes
    out.emitted-lines))

;: Stream the unified diff from `old-text` to `new-text`, headed `a/path` and
;: `b/path`, to `sink`. Identical texts render nothing. The sink returns 0 to
;: accept a chunk; each chunk borrow ends when the call returns, and a line
;: may span chunks. Once a cap is reached no later line is emitted, but
;: rendering continues without output so the omitted counts are exact.
(define (render
  [path : (& p str)]
  [old-text : (& o str)]
  [new-text : (& n str)]
  [options : UnifiedDiffOptions]
  [sink : (-> (& bytes) i64)]) : UnifiedDiffReport
  (if (or
    (< options.max-bytes 0)
    (< options.max-lines 0)
    (< options.chunk-bytes 1))
    (UnifiedDiffReport (InvalidOptions) 0 0)
    (let
      [old : (Side o) (side old-text)]
      [new : (Side n) (side new-text)]
      [out : Output (output options)]
      [scan-old : i64 0]
      [scan-new : i64 0]
      [headed : bool false]
      [finished : bool false]
      (begin
        (while (and (not finished) (= out.status 0))
          (match (next-hunk (& old) (& new) scan-old scan-new)
            [(NoHunk) (set! finished true)]
            [(NextHunk hunk)
              (begin
                (unless
                  headed
                  (set! headed true)
                  (put-file-header!
                    (&mut out)
                    sink
                    (ascii '-')
                    (ascii 'a')
                    path)
                  (put-file-header!
                    (&mut out)
                    sink
                    (ascii '+')
                    (ascii 'b')
                    path))
                (put-hunk! (&mut out) sink (& old) (& new) hunk)
                (set! scan-old hunk.next-old)
                (set! scan-new hunk.next-new))]))
        (flush! (&mut out) sink)
        (report (& out))))))