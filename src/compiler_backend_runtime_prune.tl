;; In a closed executable the generated text is the last word on helper
;; dependencies. In particular, an IR BoundsCheck may disappear in emission,
;; while a located abort, a copy thunk, or an allocator slow path can introduce
;; a reference after the IR call census. Only explicitly nominated fragments
;; are eligible for removal. All other text and data are roots.
(import stdlib.hashmap)
(import stdlib.vector)
(import stdlib.iterator)
(import stdlib.runtime)
(import stdlib.string)
(import compiler_str_cat as str_cat)
(import (hashmap.hashmap i64 i64) as label_map)

(define optional-begin : String
  "# typelisp optional runtime begin\n")
(define optional-end : String
  "# typelisp optional runtime end\n")
(define bundle-begin : String
  "# typelisp runtime bundle begin\n")
(define bundle-end : String
  "# typelisp runtime bundle end\n")

(define (optional-fragment [body : String]) : String
  (str_cat.str-cat optional-begin body optional-end))

(define (optional-bundle [body : String]) : String
  (str_cat.str-cat bundle-begin body bundle-end))

(define (literal-begin) : String
  "# typelisp literal bundle begin\n")

(define (literal-end) : String
  "# typelisp literal bundle end\n")

(define (literal-unit-end) : String
  "# typelisp literal unit end\n")

(defstruct RuntimeFragment
  (start i64)
  (end i64))

(import (vector.vector RuntimeFragment core) as fragment_vec)
(import (vector.vector i64 core) as i64_vec)

(define (line-end [data : (Ptr u8)] [start : i64] [limit : i64]) : i64
  (let
    [end : i64 start]
    (unsafe
      (while (and (< end limit) (!= (ptr-read (ptr-offset data end)) 10))
        (+= end 1)))
    (if (< end limit)
      (+ end 1)
      limit)))

(define (has-prefix?
  [data : (Ptr u8)]
  [start : i64]
  [limit : i64]
  [prefix : (& str)]) : bool
  (let
    [length : i64 (string.string-length prefix)]
    (when (> length (- limit start)) (return false))
    (unsafe
      (let
        [bytes : (Ptr u8) (string-data prefix)]
        (for [i (iterator.range 0 length)]
          (when
            (!=
              (ptr-read (ptr-offset data (+ start i)))
              (ptr-read (ptr-offset bytes i)))
            (return false)))))
    true))

(define (fast-entry? [data : (Ptr u8)] [start : i64] [end : i64]) : bool
  (and
    (or (= (- end start) 14) (= (- end start) 15))
    (has-prefix? data start end ".L_tl_alloc")
    (unsafe
      (let
        [digit : u8 (ptr-read (ptr-offset data (- end 3)))]
        (and
          (>= digit 48)
          (<= digit 57)
          (= (ptr-read (ptr-offset data (- end 2))) 58))))))

;; Runtime bundles supply one self-contained function per .globl line.
;; Allocator fast entries are object-local functions. Other labels belong to
;; the current function, including cross-entry branch targets.
(define (bundle-entry? [data : (Ptr u8)] [start : i64] [end : i64]) : bool
  (or
    (has-prefix? data start end "    .globl ")
    (fast-entry? data start end)
    (has-prefix? data start end ".L_tl_alloc_win_commit_to:")))

;; A label definition: the whole line before its newline is one symbol and a
;; colon.
(define (label-line? [data : (Ptr u8)] [start : i64] [end : i64]) : bool
  (and
    (> (- end start) 2)
    (=
      (unsafe
        (ptr-read (ptr-offset data (- end 2))))
      58)
    (= (tuple-ref (symbol-token data start end) 1) (- end 2))))

(define (record-range!
  [ranges : (&mut fragment_vec.Vec)]
  [start : i64]
  [end : i64]) : unit
  (when
    (>= start 0)
    (fragment_vec.push-ref! ranges (RuntimeFragment start end))))

;; A literal bundle holds string data and {ptr,len} headers. Each entry starts
;; at a label. The labels and `.ascii` records of one unit of shared bytes run
;; on until its end marker, so a unit is kept or dropped whole. A header is a
;; label and two `.quad`s.
;; Returns false when a marker is left open; nothing is pruned then.
(define (find-ranges!
  [data : (Ptr u8)]
  [length : i64]
  [ranges : (&mut fragment_vec.Vec)]) : bool
  (let
    [pos : i64 0]
    [start : i64 -1]
    [bundle : bool false]
    [literal : bool false]
    [continued : bool false]
    (while (< pos length)
      (let
        [end : i64 (line-end data pos length)]
        (cond
          [(has-prefix? data pos end (& optional-begin)) (set! start pos)]
          [(has-prefix? data pos end (& optional-end))
            (record-range! ranges start end)
            (set! start -1)]
          [(has-prefix? data pos end (& bundle-begin)) (set! bundle true)]
          [(has-prefix? data pos end (& bundle-end))
            (record-range! ranges start end)
            (set! start -1)
            (set! bundle false)]
          [(has-prefix? data pos end (& (literal-begin)))
            (set! literal true)
            (set! continued false)]
          [(has-prefix? data pos end (& (literal-unit-end)))
            (record-range! ranges start end)
            (set! start -1)
            (set! continued false)]
          [(has-prefix? data pos end (& (literal-end)))
            (record-range! ranges start pos)
            (set! start -1)
            (set! literal false)]
          [(and bundle (bundle-entry? data pos end))
            (record-range! ranges start pos)
            (set! start pos)]
          [literal
            (let
              [label? : bool (label-line? data pos end)]
              (when
                (and label? (not continued))
                (record-range! ranges start pos)
                (set! start pos))
              (set!
                continued
                (or label? (has-prefix? data pos end "    .ascii "))))]
          [else unit])
        (set! pos end)))
    (not (or bundle literal (>= start 0)))))

(define (symbol-byte? [byte : u8]) : bool
  (or
    (and (>= byte 65) (<= byte 90))
    (and (>= byte 97) (<= byte 122))
    (and (>= byte 48) (<= byte 57))
    (= byte 95)
    (= byte 46)
    (= byte 36)))

;; Only generated symbols can name a fragment. Quoted GAS symbols, including
;; argument entries containing colons, hash verbatim between their quotes.
;; A collision retains every matching fragment, so it cannot lose an edge.
(define (symbol-token [data : (Ptr u8)] [start : i64] [limit : i64]) : (Tuple
    i64
    i64)
  (unsafe
    (let
      [quoted : bool (= (ptr-read (ptr-offset data start)) 34)]
      [pos : i64
        (if quoted
          (+ start 1)
          start)]
      [hash : i64 0]
      (while (and
        (< pos limit)
        (if quoted
          (!= (ptr-read (ptr-offset data pos)) 34)
          (symbol-byte? (ptr-read (ptr-offset data pos)))))
        (set!
          hash
          (+ (* hash 131) (cast (ptr-read (ptr-offset data pos)) : i64)))
        (+= pos 1))
      (tuple
        hash
        (if (and quoted (< pos limit))
          (+ pos 1)
          pos)))))

;; Label hash -> 1 + the first entry of its chain in `owners`/`next`. A
;; colliding hash chains every fragment that defines it.
(define (index-labels!
  [data : (Ptr u8)]
  [range : RuntimeFragment]
  [fragment : i64]
  [labels : (&mut label_map.Map)]
  [owners : (&mut i64_vec.Vec)]
  [next : (&mut i64_vec.Vec)]) : unit
  (let
    [pos : i64 range.start]
    (while (< pos range.end)
      (let
        [end : i64 (line-end data pos range.end)]
        (when
          (label-line? data pos end)
          (let
            [hash : i64 (tuple-ref (symbol-token data pos end) 0)]
            (i64_vec.push-ref! owners fragment)
            (i64_vec.push-ref! next (label_map.get-value-or (& labels) hash 0))
            (label_map.insert-ref! labels hash (i64_vec.len (& owners)))))
        (set! pos end)))))

;; Marks every fragment that defines a symbol named in [start, limit) and
;; queues the newly live ones.
(define (mark-references!
  [data : (Ptr u8)]
  [start : i64]
  [limit : i64]
  [labels : (& label_map.Map)]
  [owners : (& i64_vec.Vec)]
  [next : (& i64_vec.Vec)]
  [live : (MutPtr u8)]
  [work : (&mut i64_vec.Vec)]) : unit
  (unsafe
    (let
      [pos : i64 start]
      (while (< pos limit)
        (let
          [end : i64 (line-end data pos limit)]
          [cursor : i64 pos]
          (while (and
            (< cursor end)
            (<= (ptr-read (ptr-offset data cursor)) 32))
            (+= cursor 1))
          ;; Abort rows record the uses of each handler in the .irp list.
          (unless
            (or
              (has-prefix? data cursor end ".extern ")
              (has-prefix? data cursor end ".globl ")
              (has-prefix? data cursor end ".type ")
              (has-prefix? data cursor end ".size ")
              (has-prefix? data cursor end ".irp "))
            (while (< cursor end)
              (let
                [byte : u8 (ptr-read (ptr-offset data cursor))]
                (cond
                  [(= byte 35) (set! cursor end)]
                  [(or (= byte 34) (and (!= byte 36) (symbol-byte? byte)))
                    (let
                      [token : (Tuple i64 i64) (symbol-token data cursor end)]
                      [entry : i64
                        (label_map.get-value-or labels (tuple-ref token 0) 0)]
                      (while (> entry 0)
                        (let
                          [fragment : i64 (i64_vec.get owners (- entry 1) 0)]
                          (when
                            (= (ptr-read (ptr-offset live fragment)) 0)
                            (ptr-write! (ptr-offset live fragment) 1)
                            (i64_vec.push-ref! work fragment))
                          (set! entry (i64_vec.get next (- entry 1) 0))))
                      (set! cursor (tuple-ref token 1)))]
                  [else (+= cursor 1)]))))
          (set! pos end))))))

;; Marks the fragments reachable from the text outside every fragment and
;; returns how many are live.
(define (reachable-fragments
  [data : (Ptr u8)]
  [length : i64]
  [ranges : (& fragment_vec.Vec)]
  [live : (MutPtr u8)]) : i64
  (let
    [count : i64 (fragment_vec.len ranges)]
    [labels : label_map.Map (label_map.with-capacity (* 2 count))]
    [owners : i64_vec.Vec (i64_vec.with-capacity count)]
    [next : i64_vec.Vec (i64_vec.with-capacity count)]
    [work : i64_vec.Vec (i64_vec.with-capacity count)]
    [cursor : i64 0]
    [kept : i64 0]
    (for [index (iterator.range 0 count)]
      (index-labels!
        data
        (array-ref (fragment_vec.slots ranges) index)
        index
        (&mut labels)
        (&mut owners)
        (&mut next)))
    (for [index (iterator.range 0 count)]
      (let
        [range : RuntimeFragment (array-ref (fragment_vec.slots ranges) index)]
        (mark-references!
          data
          cursor
          range.start
          (& labels)
          (& owners)
          (& next)
          live
          (&mut work))
        (set! cursor range.end)))
    (mark-references!
      data
      cursor
      length
      (& labels)
      (& owners)
      (& next)
      live
      (&mut work))
    (while (> (i64_vec.len (& work)) 0)
      (let
        [fragment : i64 (i64_vec.get (& work) (- (i64_vec.len (& work)) 1) 0)]
        [range : RuntimeFragment
          (array-ref (fragment_vec.slots ranges) fragment)]
        (set! work.len (- work.len 1))
        (+= kept 1)
        (mark-references!
          data
          range.start
          range.end
          (& labels)
          (& owners)
          (& next)
          live
          (&mut work))))
    kept))

(unsafe
  (extern (copy-range! [dst : (MutPtr u8)] [src : (Ptr u8)] [length : i64]) : unit (:symbol "tl_memcpy_fresh")))

(define (render-kept
  [data : (Ptr u8)]
  [length : i64]
  [ranges : (& fragment_vec.Vec)]
  [live : (MutPtr u8)]) : String
  (unsafe
    (let
      [count : i64 (fragment_vec.len ranges)]
      [kept-length : i64 length]
      [start : i64 0]
      [written : i64 0]
      (for [index (iterator.range 0 count)]
        (when
          (= (ptr-read (ptr-offset live index)) 0)
          (let
            [range : RuntimeFragment
              (array-ref (fragment_vec.slots ranges) index)]
            (-= kept-length (- range.end range.start)))))
      (let
        [out : (MutPtr u8) (runtime.runtime-alloc (+ kept-length 1))]
        (for [index (iterator.range 0 count)]
          (when
            (= (ptr-read (ptr-offset live index)) 0)
            (let
              [range : RuntimeFragment
                (array-ref (fragment_vec.slots ranges) index)]
              [span : i64 (- range.start start)]
              (copy-range!
                (ptr-offset out written)
                (ptr-offset data start)
                span)
              (+= written span)
              (set! start range.end))))
        (copy-range!
          (ptr-offset out written)
          (ptr-offset data start)
          (- length start))
        (ptr-write! (ptr-offset out kept-length) 0)
        (string-from-bytes (ptr-cast out : (Ptr u8)) kept-length)))))

(define (prune [asm : String]) : String
  (let
    [data : (Ptr u8)
      (unsafe
        (string-data (& asm)))]
    [length : i64 (string.string-length (& asm))]
    [ranges : fragment_vec.Vec (fragment_vec.with-capacity 64)]
    [closed : bool (find-ranges! data length (&mut ranges))]
    [count : i64 (fragment_vec.len (& ranges))]
    (if (or (not closed) (= count 0))
      asm
      (let
        [live : (MutPtr u8) (runtime.runtime-alloc count)]
        (for [index (iterator.range 0 count)]
          (unsafe
            (ptr-write! (ptr-offset live index) 0)))
        (let
          [kept : i64
            (with-arena
              scratch
              (reachable-fragments data length (& ranges) live))]
          (if (= kept count)
            asm
            (render-kept data length (& ranges) live)))))))

;; -Os cross-function epilogue interning. A return tail is the run of
;; stack-releasing instructions (`addq $N, %rsp`, `popq %reg`, `leave`) that
;; ends in `ret`, with no label or directive inside: no branch enters it
;; part-way and its effect does not depend on where it sits. The first copy
;; of each tail gains a label and every later identical tail becomes a `jmp`
;; to it, so only a tail longer than the 5-byte `jmp` is shared. Unwind
;; tables would describe a shared copy with its first function's frame, so the
;; caller runs this only on ELF text without debug info. Crypto scrub
;; functions keep their own epilogues, whose reclaim intervals are audited in
;; the emitted text.
(define epilogue-label : String
  ".L_tl_epi_")

(define (line-is? [data : (Ptr u8)] [start : i64] [end : i64] [line : (& str)]) : bool
  (and
    (= (- end start) (string.string-length line))
    (has-prefix? data start end line)))

(define (digit-byte? [byte : u8]) : bool
  (and (>= byte 48) (<= byte 57)))

;; Encoded bytes of one return-tail instruction line, 0 for any other line.
(define (epilogue-size [data : (Ptr u8)] [start : i64] [end : i64]) : i64
  (unsafe
    (cond
      [(or
          (line-is? data start end "    ret\n")
          (line-is? data start end "    leave\n"))
        1]
      [(has-prefix? data start end "    popq %r")
        (let
          [reg : i64 (+ start 11)]
          [cursor : i64 reg]
          (while (and
            (< cursor end)
            (symbol-byte? (ptr-read (ptr-offset data cursor))))
            (+= cursor 1))
          (cond
            [(or
                (= cursor reg)
                (!= cursor (- end 1))
                (!= (ptr-read (ptr-offset data cursor)) 10))
              0]
            [(digit-byte? (ptr-read (ptr-offset data reg))) 2]
            [else 1]))]
      [(has-prefix? data start end "    addq $")
        (let
          [cursor : i64 (+ start 10)]
          [value : i64 0]
          (while (and
            (< cursor end)
            (digit-byte? (ptr-read (ptr-offset data cursor))))
            (set!
              value
              (+
                (* value 10)
                (- (cast (ptr-read (ptr-offset data cursor)) : i64) 48)))
            (+= cursor 1))
          (cond
            [(or
                (= cursor (+ start 10))
                (> value 2147483647)
                (not (line-is? data cursor end ", %rsp\n")))
              0]
            [(< value 128) 4]
            [else 7]))]
      [else 0])))

(define (scrub-function? [data : (Ptr u8)] [start : i64] [end : i64]) : bool
  (and
    (has-prefix? data start end "_tl_stdlib_crypto_")
    (let
      [found : bool false]
      [cursor : i64 start]
      (while (and (not found) (< cursor (- end 7)))
        (set! found (has-prefix? data cursor end "_scrub_"))
        (+= cursor 1))
      found)))

(define (range-hash [data : (Ptr u8)] [start : i64] [end : i64]) : i64
  (let
    [hash : i64 0]
    (unsafe
      (for [i (iterator.range start end)]
        (set! hash (+ (* hash 131) (cast (ptr-read (ptr-offset data i)) : i64)))))
    hash))

(define (same-range?
  [data : (Ptr u8)]
  [left : i64]
  [right : i64]
  [length : i64]) : bool
  (unsafe
    (let
      [same : bool true]
      [i : i64 0]
      (while (and same (< i length))
        (set!
          same
          (=
            (ptr-read (ptr-offset data (+ left i)))
            (ptr-read (ptr-offset data (+ right i)))))
        (+= i 1))
      same)))

;; Appends `length` bytes from `src` when writing; returns the new length.
(define (emit-bytes!
  [out : (MutPtr u8)]
  [write? : bool]
  [written : i64]
  [src : (Ptr u8)]
  [length : i64]) : i64
  (when
    write?
    (unsafe
      (copy-range! (ptr-offset out written) src length)))
  (+ written length))

(define (emit-text!
  [out : (MutPtr u8)]
  [write? : bool]
  [written : i64]
  [text : String]) : i64
  (emit-bytes!
    out
    write?
    written
    (unsafe
      (string-data (& text)))
    (string.string-length (& text))))

;; One deterministic scan serves both the sizing and the writing pass.
(define (intern-epilogues-into
  [data : (Ptr u8)]
  [length : i64]
  [out : (MutPtr u8)]
  [write? : bool]) : i64
  (let
    [anchors : label_map.Map (label_map.with-capacity 1024)]
    [anchor-starts : i64_vec.Vec (i64_vec.with-capacity 256)]
    [anchor-ends : i64_vec.Vec (i64_vec.with-capacity 256)]
    [pos : i64 0]
    [copied : i64 0]
    [written : i64 0]
    [run : i64 -1]
    [bytes : i64 0]
    [skip : bool false]
    (while (< pos length)
      (let
        [end : i64 (line-end data pos length)]
        [size : i64 (epilogue-size data pos end)]
        (if (= size 0)
          (begin
            (set! run -1)
            (when
              (and
                (label-line? data pos end)
                (!=
                  (unsafe
                    (ptr-read (ptr-offset data pos)))
                  46))
              (set! skip (scrub-function? data pos end))))
          (begin
            (when (< run 0) (set! run pos) (set! bytes 0))
            (+= bytes size)
            (when
              (line-is? data pos end "    ret\n")
              (when
                (and (> bytes 5) (not skip))
                (let
                  [hash : i64 (range-hash data run end)]
                  [entry : i64 (label_map.get-value-or (& anchors) hash 0)]
                  (cond
                    [(= entry 0)
                      (i64_vec.push-ref! (&mut anchor-starts) run)
                      (i64_vec.push-ref! (&mut anchor-ends) end)
                      (label_map.insert-ref!
                        (&mut anchors)
                        hash
                        (i64_vec.len (& anchor-starts)))
                      (set!
                        written
                        (emit-bytes!
                          out
                          write?
                          written
                          (unsafe
                            (ptr-offset data copied))
                          (- run copied)))
                      (set!
                        written
                        (emit-text!
                          out
                          write?
                          written
                          (str_cat.str-cat
                            epilogue-label
                            (string.int->string (i64_vec.len (& anchor-starts)))
                            ":\n")))
                      (set! copied run)]
                    [(let
                      [anchor : i64
                        (i64_vec.get (& anchor-starts) (- entry 1) 0)]
                      [anchor-end : i64
                        (i64_vec.get (& anchor-ends) (- entry 1) 0)]
                      (and
                        (= (- anchor-end anchor) (- end run))
                        (same-range? data anchor run (- end run))))
                      (set!
                        written
                        (emit-bytes!
                          out
                          write?
                          written
                          (unsafe
                            (ptr-offset data copied))
                          (- run copied)))
                      (set!
                        written
                        (emit-text!
                          out
                          write?
                          written
                          (str_cat.str-cat
                            "    jmp "
                            epilogue-label
                            (string.int->string entry)
                            "\n")))
                      (set! copied end)]
                    [else unit])))
              (set! run -1))))
        (set! pos end)))
    (emit-bytes!
      out
      write?
      written
      (unsafe
        (ptr-offset data copied))
      (- length copied))))

(define (intern-epilogues [asm : String]) : String
  (let
    [data : (Ptr u8)
      (unsafe
        (string-data (& asm)))]
    [length : i64 (string.string-length (& asm))]
    [probe : (MutPtr u8) (runtime.runtime-alloc 1)]
    [size : i64
      (with-arena scratch (intern-epilogues-into data length probe false))]
    [out : (MutPtr u8) (runtime.runtime-alloc (+ size 1))]
    (with-arena scratch (intern-epilogues-into data length out true))
    (unsafe
      (ptr-write! (ptr-offset out size) 0)
      (string-from-bytes (ptr-cast out : (Ptr u8)) size))))