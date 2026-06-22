;; compiler_intern.tl - process-global string interning table for identifiers.
;;
;; SELF-CONTAINED (no imports): every programmer-written identifier is interned
;; to a stable i64 id, so name comparisons become i64 `=`, id-keyed lookups
;; replace string hashing, and the AST stores ids instead of copied Strings.
;; Being import-free is deliberate -- this module is reached from the core
;; compiler_ast_types.tl (and from sym_i64_env.tl), which are imported by tiny
;; integration cases; pulling stdlib/hashmap here would ripple new transitive
;; deps onto every one of those cases.
;;
;; The table is PERSISTENT for a compile (ids stay valid across the loader's
;; per-file parse-arena destroy -- ids are integers, so they survive); it resets
;; between compiles (REPL/LSP and single-source smoke compiles) via intern-reset!.
;; It mirrors the node pools: two plain mutable globals (id->String array + count)
;; plus a fixed open-addressing dedup table, all PRE-SIZED so neither ever grows
;; (a grow! reassigns a global in the inlined hot path -> opt2 miscompile).
;;
;; IDs are assigned in INSERTION (parse) order, independent of the hash function,
;; so the emitted output is identical regardless of the probe's hash -- the hash
;; only affects bucket placement, never the id a string gets.
;: Local arena hooks keep this module import-free while letting persistent
;: intern entries survive scoped compile arenas.
(extern (intern-arena-make) : i64 (:symbol "tl_arena_make"))
(extern (intern-arena-current) : i64 (:symbol "tl_arena_current"))

(unsafe
  (extern (intern-arena-set [arg0 : i64]) : unit (:symbol "tl_arena_set")))

(unsafe
  (extern (intern-arena-destroy [arg0 : i64]) : unit (:symbol "tl_arena_destroy")))

(define (intern-private-string-length [text : String]) : i64
  (cfg
    feature-private-string-intrinsics
    (__tl_string_length text)
    (string-length text)))

(define (intern-private-string-ref [text : String] [index : i64]) : char
  (cfg
    feature-private-string-intrinsics
    (__tl_string_ref text index)
    (string-ref text index)))

(define (intern-private-string-eq [left : String] [right : String]) : bool
  (let
    [left-len : i64 (intern-private-string-length left)]
    [right-len : i64 (intern-private-string-length right)]
    (if (not (= left-len right-len))
      false
      (unsafe
        (let
          [lp : (Ptr u8) (string-data (& left))]
          [rp : (Ptr u8) (string-data (& right))]
          (if (= (ptr->int lp) (ptr->int rp))
            true
            (let
              [lw : (Ptr i64) (ptr-cast lp : (Ptr i64))]
              [rw : (Ptr i64) (ptr-cast rp : (Ptr i64))]
              [words : i64 (shr left-len 3)]
              [i : i64 0]
              [same : bool true]
              (begin
                (while (and same (< i words))
                  (if (=
                    (ptr-read (ptr-offset lw i))
                    (ptr-read (ptr-offset rw i)))
                    (set! i (+ i 1))
                    (set! same false)))
                (if same
                  (let
                    [j : i64 (* words 8)]
                    (begin
                      (while (and same (< j left-len))
                        (if (=
                          (cast (ptr-read (ptr-offset lp j)) : i64)
                          (cast (ptr-read (ptr-offset rp j)) : i64))
                          (set! j (+ j 1))
                          (set! same false)))
                      same))
                  false)))))))))

;: Capacity must stay a power of two so the bucket index is a mask, not a modulo.
(define (intern-capacity) : i64
  262144)

(defenum InternSlot
  (InternEmpty)
  (InternUsed String i64 i64))

(defenum InternLookup
  (InternLookupMissing)
  (InternLookupFound i64))

(define intern-pool-slots : (Array String)
  (make-array String 262144))
(define intern-pool-qualified-slots : (Array bool)
  (make-array bool 262144))
(define intern-pool-last-slash-slots : (Array i64)
  (make-array i64 262144))
(define intern-pool-first-dot-slots : (Array i64)
  (make-array i64 262144))
(define intern-pool-module-id-slots : (Array i64)
  (make-array i64 262144))
(define intern-pool-base-id-slots : (Array i64)
  (make-array i64 262144))
(define intern-pool-count : i64
  0)

(define (intern-pool-len) : i64
  intern-pool-count)

(define intern-map-slots : (Array InternSlot)
  (make-array InternSlot 262144))
(define intern-map-ready : bool
  false)
(define intern-reset-generation : i64
  0)
(define intern-slice-cache0-name : String
  "")
(define intern-slice-cache0-id : i64
  -1)
(define intern-slice-cache0-ready : bool
  false)
(define intern-slice-cache1-name : String
  "")
(define intern-slice-cache1-id : i64
  -1)
(define intern-slice-cache1-ready : bool
  false)
(define intern-slice-cache2-name : String
  "")
(define intern-slice-cache2-id : i64
  -1)
(define intern-slice-cache2-ready : bool
  false)
(define intern-slice-cache3-name : String
  "")
(define intern-slice-cache3-id : i64
  -1)
(define intern-slice-cache3-ready : bool
  false)
(define intern-persistent-arena : i64
  (intern-arena-current))
(define intern-persistent-storage-enabled : bool
  false)

(define (intern-persistent-storage-enable!) : unit
  (set! intern-persistent-storage-enabled true))

(define (intern-persistent-storage-disable!) : unit
  (set! intern-persistent-storage-enabled false))

(define (intern-persistent-storage-on?) : bool
  intern-persistent-storage-enabled)

;: Word-at-a-time multiply-mix hash over the raw bytes. The hash only affects
;: bucket placement, never the id a string gets (ids are insertion-ordered),
;: so the function is free to change: byte-at-a-time djb2 was 18.6% of a
;: stage2 self-compile profile before the marker memos and still ~8% after.
;: Eight bytes are folded per step with a wrapping multiply; the byte tail is
;: assembled into one final word. Overflow wraps in i64; the result may be
;: negative, which is fine -- the bucket mask keeps only the low bits.
(define (intern-hash-words [src : (Ptr u8)] [start : i64] [len : i64]) : i64
  (let
    [h : i64 (+ 5381 len)]
    [i : i64 0]
    [words : i64 (- len 7)]
    (begin
      (while (< i words)
        (begin
          (set!
            h
            (*
              (bit-xor
                h
                (unsafe
                  (ptr-read (ptr-cast (ptr-offset src (+ start i)) : (Ptr i64)))))
              -7046029254386353131))
          (set! i (+ i 8))))
      (let
        [tail : i64 0]
        (begin
          (while (< i len)
            (begin
              (set!
                tail
                (+
                  (* tail 256)
                  (cast
                    (unsafe
                      (ptr-read (ptr-offset src (+ start i))))
                    : i64)))
              (set! i (+ i 1))))
          (set! h (* (bit-xor h tail) -7046029254386353131))
          (bit-xor h (cast (shr (cast h : u64) 29) : i64)))))))

(define (intern-hash [s : String]) : i64
  (intern-hash-words
    (unsafe
      (string-data (& s)))
    0
    (cfg
      feature-private-string-intrinsics
      (__tl_string_length s)
      (intern-private-string-length s))))

;: Hash over a source slice without first allocating a substring.
(define (intern-hash-slice [s : String] [start : i64] [len : i64]) : i64
  (intern-hash-words
    (unsafe
      (string-data (& s)))
    start
    len))

;: Mask `hash` into `[0, capacity)`; capacity is a power of two.
(define (intern-bucket [hash : i64] [capacity : i64]) : i64
  (bit-and hash (- capacity 1)))

(define (intern-substring [text : String] [start : i64] [len : i64]) : String
  (let
    [buf : (Array u8) (make-array u8 len)]
    [src : (Ptr u8)
      (unsafe
        (string-data (& text)))]
    [dst : (MutPtr u8)
      (unsafe
        (array-data buf))]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (unsafe
            (ptr-write!
              (ptr-offset dst i)
              (ptr-read (ptr-offset src (+ start i)))))
          (set! i (+ i 1))))
      (unsafe
        (string-from-bytes (ptr-cast dst : (Ptr u8)) len)))))

(define (intern-persistent-substring [text : String] [start : i64] [len : i64]) : String
  (let
    [prev-arena : i64 (intern-arena-current)]
    (if (= prev-arena intern-persistent-arena)
      (intern-substring text start len)
      (let
        [out : String
          (begin
            (unsafe
              (intern-arena-set intern-persistent-arena))
            (let
              [copied : String (intern-substring text start len)]
              (begin
                (unsafe
                  (intern-arena-set prev-arena))
                copied)))]
        out))))

(define (intern-persistent-copy [text : String]) : String
  (if (= (intern-arena-current) intern-persistent-arena)
    text
    (intern-persistent-substring
      text
      0
      (cfg
        feature-private-string-intrinsics
        (__tl_string_length text)
        (intern-private-string-length text)))))

(define (intern-string-slice-eq?
  [name : String]
  [text : String]
  [start : i64]
  [len : i64]) : bool
  (if (=
    (cfg
      feature-private-string-intrinsics
      (__tl_string_length name)
      (intern-private-string-length name))
    len)
    (let
      [name-ptr : (Ptr u8)
        (unsafe
          (string-data (& name)))]
      [text-ptr : (Ptr u8)
        (unsafe
          (string-data (& text)))]
      [i : i64 0]
      [ok : bool true]
      (begin
        (while (and (< i len) ok)
          (begin
            (if (=
              (unsafe
                (ptr-read (ptr-offset name-ptr i)))
              (unsafe
                (ptr-read (ptr-offset text-ptr (+ start i)))))
              unit
              (set! ok false))
            (set! i (+ i 1))))
        ok))
    false))

(define (intern-record-qualified-metadata [id : i64] [name : String]) : unit
  (let
    [i : i64 0]
    [n : i64
      (cfg
        feature-private-string-intrinsics
        (__tl_string_length name)
        (intern-private-string-length name))]
    [slash : i64 -1]
    [dot : i64 -1]
    (begin
      (while (< i n)
        (let
          [c : char
            (cfg
              feature-private-string-intrinsics
              (__tl_string_ref name i)
              (intern-private-string-ref name i))]
          (begin
            (if (= c '/')
              (set! slash i)
              unit)
            (if (and (< dot 0) (= c '.'))
              (set! dot i)
              unit)
            (set! i (+ i 1)))))
      (array-set! intern-pool-last-slash-slots id slash)
      (array-set! intern-pool-first-dot-slots id dot)
      (if (< slash 0)
        (begin
          (array-set! intern-pool-qualified-slots id false)
          (array-set! intern-pool-module-id-slots id -1)
          (array-set! intern-pool-base-id-slots id id))
        (let
          [base-start : i64 (+ slash 1)]
          [module-name : String (intern-substring name 0 slash)]
          [base-name : String
            (intern-substring
              name
              base-start
              (-
                (cfg
                  feature-private-string-intrinsics
                  (__tl_string_length name)
                  (intern-private-string-length name))
                base-start))]
          (begin
            (array-set! intern-pool-qualified-slots id true)
            (array-set! intern-pool-module-id-slots id (intern module-name))
            (array-set! intern-pool-base-id-slots id (intern base-name))))))))

;: Set slots `[index, count)` to InternEmpty.
(define (intern-fill-empty [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (array-set! intern-map-slots index (InternEmpty))
      (intern-fill-empty (+ index 1) count))))

(define (intern-reset-slice-cache!) : unit
  (begin
    (set! intern-slice-cache0-ready false)
    (set! intern-slice-cache1-ready false)
    (set! intern-slice-cache2-ready false)
    (set! intern-slice-cache3-ready false)))

(define (intern-map-insert-existing-from
  [name : String]
  [id : i64]
  [hash : i64]
  [cursor : i64]
  [steps : i64]
  [capacity : i64]) : unit
  (if (>= steps capacity)
    unit
    (match (array-ref intern-map-slots cursor)
      [(InternEmpty)
        (array-set! intern-map-slots cursor (InternUsed name id hash))]
      [_
        (intern-map-insert-existing-from
          name
          id
          hash
          (intern-bucket (+ cursor 1) capacity)
          (+ steps 1)
          capacity)])))

(define (intern-map-insert-existing! [id : i64]) : unit
  (let
    [name : String (array-ref intern-pool-slots id)]
    [hash : i64 (intern-hash name)]
    [capacity : i64 (array-length intern-map-slots)]
    (intern-map-insert-existing-from
      name
      id
      hash
      (intern-bucket hash capacity)
      0
      capacity)))

(define (intern-map-rebuild-prefix [index : i64] [count : i64]) : unit
  (if (>= index count)
    unit
    (begin
      (intern-map-insert-existing! index)
      (intern-map-rebuild-prefix (+ index 1) count))))

;: Reset the intern table for a fresh compile and (re)initialize the dedup slots
;: to Empty. `make-array` does not produce valid `Empty` enum slots, so the fill
;: is mandatory before the first probe; this runs it once (idempotent).
(define (intern-reset!) : unit
  (begin
    (set! intern-pool-count 0)
    (intern-fill-empty 0 (array-length intern-map-slots))
    (intern-reset-slice-cache!)
    (set! intern-reset-generation (+ intern-reset-generation 1))
    (set! intern-map-ready true)))

(define (intern-reset-to! [mark : i64]) : unit
  (begin
    (set! intern-pool-count mark)
    (intern-fill-empty 0 (array-length intern-map-slots))
    (intern-map-rebuild-prefix 0 mark)
    (intern-reset-slice-cache!)
    (set! intern-reset-generation (+ intern-reset-generation 1))
    (set! intern-map-ready true)))

(define (intern-slice-cache-lookup [text : String] [start : i64] [len : i64]) : i64
  (begin
    (when
      (and
        intern-slice-cache0-ready
        (intern-string-slice-eq? intern-slice-cache0-name text start len))
      (return intern-slice-cache0-id))
    (when
      (and
        intern-slice-cache1-ready
        (intern-string-slice-eq? intern-slice-cache1-name text start len))
      (return intern-slice-cache1-id))
    (when
      (and
        intern-slice-cache2-ready
        (intern-string-slice-eq? intern-slice-cache2-name text start len))
      (return intern-slice-cache2-id))
    (when
      (and
        intern-slice-cache3-ready
        (intern-string-slice-eq? intern-slice-cache3-name text start len))
      (return intern-slice-cache3-id))
    -1))

(define (intern-slice-cache-record [name : String] [id : i64]) : unit
  (if (and intern-slice-cache0-ready (= intern-slice-cache0-id id))
    unit
    (begin
      (set! intern-slice-cache3-name intern-slice-cache2-name)
      (set! intern-slice-cache3-id intern-slice-cache2-id)
      (set! intern-slice-cache3-ready intern-slice-cache2-ready)
      (set! intern-slice-cache2-name intern-slice-cache1-name)
      (set! intern-slice-cache2-id intern-slice-cache1-id)
      (set! intern-slice-cache2-ready intern-slice-cache1-ready)
      (set! intern-slice-cache1-name intern-slice-cache0-name)
      (set! intern-slice-cache1-id intern-slice-cache0-id)
      (set! intern-slice-cache1-ready intern-slice-cache0-ready)
      (set! intern-slice-cache0-name name)
      (set! intern-slice-cache0-id id)
      (set! intern-slice-cache0-ready true))))

;: Intern `name`, returning its stable i64 id. Equal strings map to equal ids.
;: Lazily initializes the dedup table so callers need not order intern-reset!.
(define (intern [name : String]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [capacity : i64 (array-length intern-map-slots)]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : i64 -1]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (match (array-ref intern-map-slots cursor)
            [(InternEmpty)
              (let
                [persistent-name : String
                  (if intern-persistent-storage-enabled
                    (intern-persistent-copy name)
                    name)]
                [id : i64 intern-pool-count]
                (begin
                  (array-set! intern-pool-slots id persistent-name)
                  (array-set!
                    intern-map-slots
                    cursor
                    (InternUsed persistent-name id hash))
                  (set! intern-pool-count (+ id 1))
                  (intern-record-qualified-metadata id persistent-name)
                  (set! out id)
                  (set! done true)))]
            [(InternUsed slot-key slot-id slot-hash)
              (if (if (= slot-hash hash)
                (intern-private-string-eq slot-key name)
                false)
                (begin
                  (set! out slot-id)
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))]))
        out))))

;: Intern a source slice without allocating unless the slice is a new name.
(define (intern-slice [text : String] [start : i64] [len : i64]) : i64
  (begin
    (if intern-map-ready
      unit
      (intern-reset!))
    (let
      [cached : i64 (intern-slice-cache-lookup text start len)]
      (if (>= cached 0)
        cached
        (let
          [capacity : i64 (array-length intern-map-slots)]
          [hash : i64 (intern-hash-slice text start len)]
          [cursor : i64 (intern-bucket hash capacity)]
          [steps : i64 0]
          [out : i64 -1]
          [done : bool false]
          (begin
            (while (if done
              false
              (< steps capacity))
              (match (array-ref intern-map-slots cursor)
                [(InternEmpty)
                  (let
                    [name : String
                      (if intern-persistent-storage-enabled
                        (intern-persistent-substring text start len)
                        (intern-substring text start len))]
                    [id : i64 intern-pool-count]
                    (begin
                      (array-set! intern-pool-slots id name)
                      (array-set!
                        intern-map-slots
                        cursor
                        (InternUsed name id hash))
                      (set! intern-pool-count (+ id 1))
                      (intern-record-qualified-metadata id name)
                      (intern-slice-cache-record name id)
                      (set! out id)
                      (set! done true)))]
                [(InternUsed slot-key slot-id slot-hash)
                  (if (if (= slot-hash hash)
                    (intern-string-slice-eq? slot-key text start len)
                    false)
                    (begin
                      (intern-slice-cache-record slot-key slot-id)
                      (set! out slot-id)
                      (set! done true))
                    (begin
                      (set! cursor (intern-bucket (+ cursor 1) capacity))
                      (set! steps (+ steps 1))))]))
            out))))))

;: Look up an already-interned name without mutating the table. This lets later
;: compiler phases use id-keyed indexes without interning backend-generated
;: probe strings as a side effect.
(define (intern-lookup [name : String]) : InternLookup
  (if intern-map-ready
    (let
      [capacity : i64 (array-length intern-map-slots)]
      [hash : i64 (intern-hash name)]
      [cursor : i64 (intern-bucket hash capacity)]
      [steps : i64 0]
      [out : InternLookup InternLookupMissing]
      [done : bool false]
      (begin
        (while (if done
          false
          (< steps capacity))
          (match (array-ref intern-map-slots cursor)
            [(InternEmpty)
              (begin
                (set! out (InternLookupMissing))
                (set! done true))]
            [(InternUsed slot-key slot-id slot-hash)
              (if (if (= slot-hash hash)
                (intern-private-string-eq slot-key name)
                false)
                (begin
                  (set! out (InternLookupFound slot-id))
                  (set! done true))
                (begin
                  (set! cursor (intern-bucket (+ cursor 1) capacity))
                  (set! steps (+ steps 1))))]))
        out))
    (InternLookupMissing)))

;: Recover the original String for an interned id.
(define (intern-str [id : i64]) : String
  (array-ref intern-pool-slots id))

(define (intern-generation) : i64
  intern-reset-generation)

(define (intern-qualified? [id : i64]) : bool
  (array-ref intern-pool-qualified-slots id))

(define (intern-qualified-last-slash [id : i64]) : i64
  (array-ref intern-pool-last-slash-slots id))

(define (intern-first-dot [id : i64]) : i64
  (array-ref intern-pool-first-dot-slots id))

(define (intern-dotted? [id : i64]) : bool
  (>= (intern-first-dot id) 0))

(define (intern-qualified-module-id [id : i64]) : i64
  (array-ref intern-pool-module-id-slots id))

(define (intern-qualified-base-id [id : i64]) : i64
  (array-ref intern-pool-base-id-slots id))

(define (intern-qualified-module [id : i64]) : String
  (let
    [module-id : i64 (intern-qualified-module-id id)]
    (if (< module-id 0)
      ""
      (intern-str module-id))))

(define (intern-qualified-base [id : i64]) : String
  (intern-str (intern-qualified-base-id id)))

(define (intern-name-qualified? [name : String]) : bool
  (intern-qualified? (intern name)))

(define (intern-name-last-slash [name : String]) : i64
  (intern-qualified-last-slash (intern name)))

(define (intern-name-first-dot [name : String]) : i64
  (intern-first-dot (intern name)))

(define (intern-name-dotted? [name : String]) : bool
  (intern-dotted? (intern name)))

(define (intern-name-module [name : String]) : String
  (intern-qualified-module (intern name)))

(define (intern-name-base [name : String]) : String
  (intern-qualified-base (intern name)))

(define (intern-qualified-metadata-case-ok?
  [id : i64]
  [qualified : bool]
  [last-slash : i64]
  [module-name : String]
  [base-name : String]) : bool
  (and
    (= (intern-qualified-last-slash id) last-slash)
    (= (intern-qualified? id) qualified)
    (intern-private-string-eq (intern-qualified-module id) module-name)
    (intern-private-string-eq (intern-qualified-base id) base-name)))

(define (intern-slice-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [slice-source : String "alpha beta alpha pkg/name"]
      [slice-alpha : i64 (intern-slice slice-source 0 5)]
      [slice-beta : i64 (intern-slice slice-source 6 4)]
      [slice-alpha-again : i64 (intern-slice slice-source 11 5)]
      [slice-qualified : i64 (intern-slice slice-source 17 8)]
      [long-slice-source : String "xxmultiword-hash-namezz"]
      [long-full : i64 (intern "multiword-hash-name")]
      [long-slice : i64 (intern-slice long-slice-source 2 19)]
      [ok : bool
        (and
          (= slice-alpha slice-alpha-again)
          (not (= slice-alpha slice-beta))
          (= long-full long-slice)
          (intern-private-string-eq
            (intern-str long-slice)
            "multiword-hash-name")
          (intern-private-string-eq (intern-str slice-alpha) "alpha")
          (intern-qualified-metadata-case-ok?
            slice-qualified
            true
            3
            "pkg"
            "name"))]
      (begin
        (intern-reset!)
        ok))))

(define (intern-persistent-arena-tests-ok?) : bool
  (begin
    (intern-reset!)
    (intern-persistent-storage-enable!)
    (let
      [home : i64 (intern-arena-current)]
      [scratch : i64 (intern-arena-make)]
      [id : i64
        (begin
          (unsafe
            (intern-arena-set scratch))
          (let
            [name : String (intern-substring "persist/entry" 0 13)]
            [stored : i64 (intern name)]
            (begin
              (unsafe
                (intern-arena-set home))
              (unsafe
                (intern-arena-destroy scratch))
              stored)))]
      [again : i64 (intern "persist/entry")]
      [ok : bool
        (and
          (= id again)
          (intern-private-string-eq (intern-str id) "persist/entry")
          (intern-qualified-metadata-case-ok? id true 7 "persist" "entry"))]
      (begin
        (intern-reset!)
        (intern-persistent-storage-disable!)
        ok))))

(define (intern-reset-to-tests-ok?) : bool
  (begin
    (intern-reset!)
    (intern-persistent-storage-enable!)
    (let
      [kept : i64 (intern "keep/name")]
      [plain : i64 (intern "plain")]
      [mark : i64 (intern-pool-len)]
      [_drop : i64 (intern "drop/name")]
      [ok : bool true]
      (begin
        (intern-reset-to! mark)
        (unless (= (intern-pool-len) mark) (set! ok false))
        (unless (= (intern "keep/name") kept) (set! ok false))
        (unless (= (intern "plain") plain) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? kept true 4 "keep" "name")
          (set! ok false))
        (match (intern-lookup "drop/name")
          [(InternLookupMissing) unit]
          [(InternLookupFound _) (set! ok false)])
        (unless (= (intern "drop/name") mark) (set! ok false))
        (intern-reset!)
        (intern-persistent-storage-disable!)
        ok))))

(define (intern-qualified-metadata-tests-ok?) : bool
  (begin
    (intern-reset!)
    (let
      [plain : i64 (intern "name")]
      [qualified : i64 (intern "module/name")]
      [nested : i64 (intern "pkg/sub/name")]
      [leading : i64 (intern "/name")]
      [trailing : i64 (intern "module/")]
      [slash : i64 (intern "/")]
      [dotted : i64 (intern "point.x")]
      [nested-dotted : i64 (intern "point.inner.x")]
      [ok : bool true]
      (begin
        (unless
          (intern-qualified-metadata-case-ok? plain false -1 "" "name")
          (set! ok false))
        (unless (= (intern-qualified-base-id plain) plain) (set! ok false))
        (unless (= (intern-qualified-module-id plain) -1) (set! ok false))
        (unless (= (intern-first-dot plain) -1) (set! ok false))
        (unless (not (intern-dotted? plain)) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? qualified true 6 "module" "name")
          (set! ok false))
        (unless (= (intern-first-dot qualified) -1) (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? nested true 7 "pkg/sub" "name")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? leading true 0 "" "name")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? trailing true 6 "module" "")
          (set! ok false))
        (unless
          (intern-qualified-metadata-case-ok? slash true 0 "" "")
          (set! ok false))
        (unless (= (intern-first-dot dotted) 5) (set! ok false))
        (unless (intern-dotted? dotted) (set! ok false))
        (unless (= (intern-first-dot nested-dotted) 5) (set! ok false))
        (unless (intern-name-dotted? "point.x") (set! ok false))
        (unless (= (intern-name-first-dot "point.x") 5) (set! ok false))
        (unless (intern-slice-tests-ok?) (set! ok false))
        (unless (intern-persistent-arena-tests-ok?) (set! ok false))
        (unless (intern-reset-to-tests-ok?) (set! ok false))
        (intern-reset!)
        ok))))