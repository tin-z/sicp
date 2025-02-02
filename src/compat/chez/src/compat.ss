;;; Copyright 2020 Mitchell Kember. Subject to the MIT License.

#!r6rs

(library (src compat)
  (export current-output-port extended-define-syntax format make-mutex
          open-output-string parallel-execute parameterize random
          run-with-short-timeout runtime seed-rng string-contains?
          syntax->location with-output-to-string)
  (import (rnrs base (6))
          (rename (only (rnrs base (6)) define-syntax)
                  (define-syntax extended-define-syntax))
          (only (rnrs control (6)) unless when)
          (only (chezscheme)
                annotation-source call/1cc condition-signal condition-wait
                current-output-port current-time fork-thread format
                locate-source-object-source make-condition make-time
                mutex-acquire mutex-release open-output-string parameterize
                random random-seed set-timer sleep syntax->annotation
                time-nanosecond time-second timer-interrupt-handler with-mutex
                with-output-to-string)
          (prefix (only (chezscheme) make-mutex) chez-))

(define (syntax->location s)
  (locate-source-object-source
   (annotation-source (syntax->annotation s))
   #t   ; get the start, not end
   #t)) ; use the cache

(define (runtime)
  (let ((t (current-time 'time-monotonic)))
    (+ (time-second t)
       (/ (time-nanosecond t) 1e9))))

(define (seed-rng)
  (random-seed
   (+ 1 (mod (time-second (current-time))
             (- (expt 2 32) 1)))))

(define (make-mutex)
  (let ((mutex (chez-make-mutex)))
    (lambda (op)
      (cond ((eq? op 'acquire) (mutex-acquire mutex))
            ((eq? op 'release) (mutex-release mutex))
            (else (error 'make-mutex "unknown operation" op))))))

(define (parallel-execute . thunks)
  (let ((mutex (chez-make-mutex))
        (finished (make-condition))
        (remaining (length thunks)))
    (for-each
     (lambda (proc)
       (fork-thread
        (lambda ()
          ;; Sleep for up to 1ms to ensure nondeterminism shows up.
          (sleep (make-time 'time-duration (random 1000000) 0))
          (proc)
          (with-mutex mutex
            (set! remaining (- remaining 1))
            (when (zero? remaining)
              (condition-signal finished))))))
     thunks)
    (with-mutex mutex
      (let loop ()
        (unless (zero? remaining)
          (condition-wait finished mutex)
          (loop))))))

(define (run-with-short-timeout thunk)
  (call/1cc
   (lambda (return)
     (let ((old-handler (timer-interrupt-handler)))
       (timer-interrupt-handler (lambda () (return '())))
       ;; Set the timer for 1000 ticks. A tick is roughly one procedure call.
       (set-timer 1000)
       (let ((result (thunk)))
         ;; Cancel the timer and reset the handler before returning the result.
         (set-timer 0)
         (timer-interrupt-handler old-handler)
         (list result))))))

;; Rabin-Karp string search algorithm. Assumes ASCII.
(define (string-contains? s1 s2)
  (define byte-base 256)
  (define prime-modulus 101)
  (define (mult x) (* x byte-base))
  (define (modp x) (mod x prime-modulus))
  (define (hash s len)
    (let loop ((h 0) (i 0))
      (if (= i len)
          h
          (loop (modp (+ (modp (mult h))
                         (char->integer (string-ref s i))))
                (+ i 1)))))
  (define (roll h msd-value remove add)
    (modp (+ (mult (- (+ h prime-modulus)
                      (modp (* (char->integer remove) msd-value))))
             (char->integer add))))
  (define (calc-msd-value)
    (let loop ((i (string-length s2))
               (val 1))
      (if (= i 1)
          val
          (loop (- i 1) (modp (mult val))))))
  (define (substring=? s1 i1 s2 i2 len)
    (define (iter offset)
      (cond ((= offset len) #t)
            ((not (char=? (string-ref s1 (+ i1 offset))
                          (string-ref s2 (+ i2 offset))))
             #f)
            (else (iter (+ offset 1)))))
    (cond ((< (string-length s1) len) #f)
          ((< (string-length s2) len) #f)
          (else (iter 0))))
  (let ((n (string-length s1))
        (m (string-length s2)))
    (cond ((< n m) #f)
          ((zero? m) #t)
          (else
           (let ((end (- n m))
                 (hs2 (hash s2 m))
                 (msd-value (calc-msd-value)))
             (let loop ((i 0)
                        (h (hash s1 m)))
               (cond ((and (= h hs2) (substring=? s1 i s2 0 m)) #t)
                     ((= i end) #f)
                     (else (loop (+ i 1)
                                 (roll h
                                       msd-value
                                       (string-ref s1 i)
                                       (string-ref s1 (+ i m))))))))))))
) ; end of library
