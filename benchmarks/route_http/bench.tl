;# benchmarks/route_http/bench.tl - branchy web-request router workload.
;#
;# Equivalent to benchmarks/route_http/baseline.c. A route table is generated at
;# startup from static vocabulary data and a deterministic LCG: every route is a
;# sequence of two to four segments, each either a literal word or a `:param`
;# wildcard, plus a method bit mask (GET/POST/PUT/DELETE) and a handler id. The
;# table shape lives in plain arrays, so the branching happens in the router at
;# runtime rather than in an if-chain in the source.
;#
;# Each round assembles `requests` request paths from a 24-entry token
;# vocabulary (16 words the route table draws from and 8 words it never uses).
;# Roughly 70% of requests target a route picked from the table, filling literal
;# segments with that route's word and wildcard segments with a never-used word,
;# and pick a method the route accepts; the other 30% are arbitrary paths from
;# the whole vocabulary and usually miss. Roughly 20% of paths carry a query
;# string the router has to strip. Routing splits the path on `/` by scanning
;# bytes, compares literal segments byte-for-byte, hashes wildcard captures, and
;# takes the first route that matches in table order; a miss contributes a
;# distinct constant. Every request's contribution folds into a rolling
;# accumulator that stays in `[0, prime)`, so the printed decimal matches the C
;# baseline's `%lld`. Table size, requests per round, and round count are
;# runtime arguments, so nothing can be constant folded.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(define rt-modulus : i64
  1000000007)
(define rt-vocabulary-count : i64
  16)
(define rt-junk-base : i64
  16)
(define rt-junk-count : i64
  8)
(define rt-token-count : i64
  24)
(define rt-max-segments : i64
  4)

;; Contribution of a request that no route accepts.
(define rt-miss-mark : i64
  777767)

;; The 16 words the route table's literal segments are drawn from.
(define (rt-word-table) : (Array String)
  (make-array
    "users"
    "posts"
    "comments"
    "settings"
    "admin"
    "api"
    "v1"
    "v2"
    "search"
    "images"
    "billing"
    "orders"
    "profile"
    "health"
    "metrics"
    "reports"))

;; Request path segments, each already carrying its leading `/`. Entries 0-15
;; mirror the route vocabulary; entries 16-23 are words no route ever names, so
;; they only match wildcard segments.
(define (rt-token-table) : (Array String)
  (make-array
    "/users"
    "/posts"
    "/comments"
    "/settings"
    "/admin"
    "/api"
    "/v1"
    "/v2"
    "/search"
    "/images"
    "/billing"
    "/orders"
    "/profile"
    "/health"
    "/metrics"
    "/reports"
    "/quux"
    "/zzyzx"
    "/frobnicate"
    "/wobble"
    "/xyzzy"
    "/plugh"
    "/grault"
    "/thud"))

(define (rt-query-table) : (Array String)
  (make-array "" "?page=2&sort=desc"))

;; 64-bit LCG. The state advances over the full word and every drawn value comes
;; from the high bits, whose period is much longer than the low bits'.
(define (rt-next-state [state : i64]) : i64
  (+ (* state 6364136223846793005) 1442695040888963407))

(define (rt-draw [state : i64]) : i64
  (bit-and (shr state 33) 2147483647))

(define (rt-build-table
  [segment-kind : (Array i64)]
  [segment-word : (Array i64)]
  [route-start : (Array i64)]
  [route-length : (Array i64)]
  [route-mask : (Array i64)]
  [route-handler : (Array i64)]
  [routes : i64]) : unit
  (let
    [state : i64 20250727]
    [cursor : i64 0]
    [r : i64 0]
    (begin
      (while (< r routes)
        (begin
          (set! state (rt-next-state state))
          (let
            [length : i64 (+ 2 (% (rt-draw state) 3))]
            [k : i64 0]
            (begin
              (array-set! route-start r cursor)
              (array-set! route-length r length)
              (while (< k length)
                (begin
                  (set! state (rt-next-state state))
                  (if (= (% (rt-draw state) 5) 0)
                    (begin
                      (array-set! segment-kind (+ cursor k) 1)
                      (array-set! segment-word (+ cursor k) 0))
                    (begin
                      (array-set! segment-kind (+ cursor k) 0)
                      (array-set!
                        segment-word
                        (+ cursor k)
                        (% (rt-draw state) rt-vocabulary-count))))
                  (set! k (+ k 1))))
              (set! cursor (+ cursor length))))
          (set! state (rt-next-state state))
          (array-set! route-mask r (+ 1 (% (rt-draw state) 15)))
          (array-set! route-handler r (+ (* r 7) 13))
          (set! r (+ r 1))))
      unit)))

;; Match one route against `path[0, path-end)`. Returns the rolling hash of the
;; wildcard captures on success and -1 on failure. The whole path must be
;; consumed, and a wildcard segment must capture at least one byte.
(define (rt-match-route
  [path : String]
  [path-end : i64]
  [words : (Array String)]
  [segment-kind : (Array i64)]
  [segment-word : (Array i64)]
  [base : i64]
  [length : i64]) : i64
  (let
    [pos : i64 0]
    [k : i64 0]
    [ok : bool true]
    [hash : i64 0]
    (begin
      (while (and (< k length) ok)
        (begin
          (if (or (>= pos path-end) (not (= (string.string-ref path pos) '/')))
            (set! ok false)
            (let
              [start : i64 (+ pos 1)]
              (begin
                (set! pos start)
                (while (and
                  (< pos path-end)
                  (not (= (string.string-ref path pos) '/')))
                  (set! pos (+ pos 1)))
                (let
                  [span : i64 (- pos start)]
                  (if (= (array-ref segment-kind (+ base k)) 1)
                    (if (= span 0)
                      (set! ok false)
                      (let
                        [b : i64 start]
                        (while (< b pos)
                          (begin
                            (set!
                              hash
                              (%
                                (+
                                  (* hash 131)
                                  (cast (string.string-ref path b) : i64))
                                rt-modulus))
                            (set! b (+ b 1))))))
                    (let
                      [word : i64 (array-ref segment-word (+ base k))]
                      (if (!=
                        span
                        (string.string-length (array-ref words word)))
                        (set! ok false)
                        (let
                          [b : i64 0]
                          (while (and (< b span) ok)
                            (if (=
                              (string.string-ref path (+ start b))
                              (string.string-ref (array-ref words word) b))
                              (set! b (+ b 1))
                              (set! ok false)))))))))))
          (set! k (+ k 1))))
      (if (and ok (= pos path-end))
        hash
        -1))))

(define (rt-route-request
  [path : String]
  [method : i64]
  [words : (Array String)]
  [segment-kind : (Array i64)]
  [segment-word : (Array i64)]
  [route-start : (Array i64)]
  [route-length : (Array i64)]
  [route-mask : (Array i64)]
  [route-handler : (Array i64)]
  [routes : i64]) : i64
  (let
    [path-end : i64 (string.string-length path)]
    [scan : i64 0]
    [scanning : bool true]
    [r : i64 0]
    [captures : i64 -1]
    [handler : i64 0]
    (begin
      (while (and (< scan path-end) scanning)
        (if (= (string.string-ref path scan) '?')
          (begin
            (set! path-end scan)
            (set! scanning false))
          (set! scan (+ scan 1))))
      (while (and (< r routes) (< captures 0))
        (begin
          (when
            (!= (bit-and (array-ref route-mask r) method) 0)
            (let
              [hash : i64
                (rt-match-route
                  path
                  path-end
                  words
                  segment-kind
                  segment-word
                  (array-ref route-start r)
                  (array-ref route-length r))]
              (when
                (>= hash 0)
                (begin
                  (set! captures hash)
                  (set! handler (array-ref route-handler r))))))
          (set! r (+ r 1))))
      (if (< captures 0)
        rt-miss-mark
        (% (+ (* handler 1000003) (* captures 31) method) rt-modulus)))))

(define (rt-build-path
  [tokens : (Array String)]
  [queries : (Array String)]
  [choice : (Array i64)]
  [segments : i64]
  [query : i64]) : String
  (if (= segments 2)
    (string.concat3-borrowed
      (array-ref tokens (array-ref choice 0))
      (array-ref tokens (array-ref choice 1))
      (array-ref queries query))
    (if (= segments 3)
      (string.concat4-borrowed
        (array-ref tokens (array-ref choice 0))
        (array-ref tokens (array-ref choice 1))
        (array-ref tokens (array-ref choice 2))
        (array-ref queries query))
      (string.concat5-borrowed
        (array-ref tokens (array-ref choice 0))
        (array-ref tokens (array-ref choice 1))
        (array-ref tokens (array-ref choice 2))
        (array-ref tokens (array-ref choice 3))
        (array-ref queries query)))))

(define (rt-bench [routes : i64] [requests : i64] [rounds : i64]) : i64
  (let
    [words : (Array String) (rt-word-table)]
    [tokens : (Array String) (rt-token-table)]
    [queries : (Array String) (rt-query-table)]
    [segment-kind : (Array i64)
      (array.make-array i64 (* routes rt-max-segments))]
    [segment-word : (Array i64)
      (array.make-array i64 (* routes rt-max-segments))]
    [route-start : (Array i64) (array.make-array i64 routes)]
    [route-length : (Array i64) (array.make-array i64 routes)]
    [route-mask : (Array i64) (array.make-array i64 routes)]
    [route-handler : (Array i64) (array.make-array i64 routes)]
    [choice : (Array i64) (array.make-array i64 rt-max-segments)]
    [state : i64 987654321]
    [acc : i64 0]
    [round : i64 0]
    [i : i64 0]
    [method : i64 0]
    [segments : i64 0]
    [query : i64 0]
    [route : i64 0]
    [base : i64 0]
    [k : i64 0]
    (begin
      (rt-build-table
        segment-kind
        segment-word
        route-start
        route-length
        route-mask
        route-handler
        routes)
      (while (< round rounds)
        (begin
          (set! i 0)
          (while (< i requests)
            (begin
              (set! state (rt-next-state state))
              (if (< (% (rt-draw state) 10) 7)
                (begin
                  (set! state (rt-next-state state))
                  (set! route (% (rt-draw state) routes))
                  (set! base (array-ref route-start route))
                  (set! segments (array-ref route-length route))
                  (set! k 0)
                  (while (< k segments)
                    (begin
                      (if (= (array-ref segment-kind (+ base k)) 1)
                        (begin
                          (set! state (rt-next-state state))
                          (array-set!
                            choice
                            k
                            (+ rt-junk-base (% (rt-draw state) rt-junk-count))))
                        (array-set!
                          choice
                          k
                          (array-ref segment-word (+ base k))))
                      (set! k (+ k 1))))
                  (set! state (rt-next-state state))
                  (set! method (shl 1 (% (rt-draw state) 4)))
                  (while (= (bit-and (array-ref route-mask route) method) 0)
                    (begin
                      (set! method (shl method 1))
                      (when (> method 8) (set! method 1)))))
                (begin
                  (set! state (rt-next-state state))
                  (set! segments (+ 2 (% (rt-draw state) 3)))
                  (set! k 0)
                  (while (< k segments)
                    (begin
                      (set! state (rt-next-state state))
                      (array-set! choice k (% (rt-draw state) rt-token-count))
                      (set! k (+ k 1))))
                  (set! state (rt-next-state state))
                  (set! method (shl 1 (% (rt-draw state) 4)))))
              (set! state (rt-next-state state))
              (if (< (% (rt-draw state) 10) 2)
                (set! query 1)
                (set! query 0))
              (let
                [path : String
                  (rt-build-path tokens queries choice segments query)]
                (set!
                  acc
                  (%
                    (+
                      (* acc 131)
                      (rt-route-request
                        path
                        method
                        words
                        segment-kind
                        segment-word
                        route-start
                        route-length
                        route-mask
                        route-handler
                        routes))
                    rt-modulus)))
              (set! i (+ i 1))))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [routes : i64 (string.>int (io.arg 1))]
    [requests : i64 (string.>int (io.arg 2))]
    [rounds : i64 (string.>int (io.arg 3))]
    (begin
      (io.print (rt-bench routes requests rounds))
      0)))