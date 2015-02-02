#lang racket/gui
; tox.rkt
; contains the tox instances and threads
(require libtoxcore-racket
         "config.rkt"
         "utils.rkt")

(provide (all-defined-out)
         TOX_PUBLIC_KEY_SIZE)

; proxy options
(define my-opts
  (make-Tox-Options (ipv6?) (udp-disabled?) (proxy-type) (proxy-address) (proxy-port)))

; av settings
(define my-csettings DefaultCSettings)
; instantiate Tox session
(define my-tox (tox-new my-opts))
(define my-av (av-new my-tox 1))
; is this kosher?
; beats asking for the pass every time we save...
(define encryption-pass (make-parameter ""))

; IMPORTANT! Load data-file before defining my-id-bytes and my-id-hex (obviously!)
; if data-file is empty, use default settings
(let ([data-bytes (file->bytes ((data-file)) #:mode 'binary)])
  (debug-prefix "Blight: ")
  (cond [(zero? (bytes-length data-bytes))
         ; set username
         (set-name! my-tox (my-name))
         ; set status message
         (set-status-message! my-tox (my-status-message))]
        ; data-file is not empty, load from encrypted data-file
        [(and (not (zero? (bytes-length data-bytes)))
              (data-encrypted? data-bytes))
         ; we've got an encrypted file, we should save it as encrypted
         (encrypted? #t)
         ; ask the user what the password is
         (dprint-wait "Loading encrypted data")
         (define loading-callback
           (λ ()
             (encryption-pass (send pass-tfield get-value))
             (let ([err (encrypted-load my-tox
                                        data-bytes
                                        (bytes-length data-bytes)
                                        (encryption-pass))])
               (cond [(zero? err)
                      (send pass-dialog show #f)
                      (displayln "Loading successful!")]
                     [else
                      (let ([mbox (message-box "Blight - Incorrect Passphrase"
                                               "Sorry! That was incorrect.")])
                        (when (eq? mbox 'ok)
                          (displayln "Incorrect password received, trying again.")
                          (send pass-tfield set-value "")))]))))
         (define pass-dialog (new dialog%
                                  [label "Blight - Enter Passphrase"]
                                  [height 50]
                                  [width 400]
                                  [style (list 'close-button)]))
         (define pass-tfield
           (new text-field%
                [label "Enter Passphrase: "]
                [parent pass-dialog]
                [style '(single password)]
                [callback (λ (l e)
                            (when (eq? (send e get-event-type) 'text-field-enter)
                              (loading-callback)))]))
         (define pass-hpanel
           (new horizontal-panel%
                [parent pass-dialog]
                [alignment '(right center)]))
         (define pass-cancel-button
           (new button%
                [label "Cancel"]
                [parent pass-hpanel]
                [callback (λ (button event)
                            (exit))]))
         (define pass-ok-button
           (new button%
                [label "OK"]
                [parent pass-hpanel]
                [callback (λ (button event)
                            (loading-callback))]))
         (send pass-dialog show #t)]
        ; data-file is not empty, load from data-file
        [(nor (zero? (bytes-length data-bytes))
              (data-encrypted? data-bytes))
         (define my-bytes data-bytes)
         (dprint-wait "Loading from data file")
         (let ([result (tox-load my-tox my-bytes)])
           (if (false? result)
               (begin
                 (displayln "Loading failed!")
                 (when (make-noise)
                   (play-sound (last sounds) #t))
                 (exit))
               (displayln "Done!")))]))

; obtain our tox id
(define my-id-bytes (get-self-address my-tox))
(define my-id-hex (make-parameter (bytes->hex-string my-id-bytes)))
