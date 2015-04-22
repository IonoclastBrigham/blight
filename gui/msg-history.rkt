#lang racket/gui
; msg-history.rkt
; contains common message history functions and keymaps

(require "../utils.rkt")
(provide (all-defined-out))

(define (init-messages-keymap cw)
      (let ([km (new keymap%)])
        (send km add-function "copy"
              (lambda (editor kev)
                (send editor copy)))
        
        (send km add-function "backward-char"
              (lambda (editor kev)
                (send editor move-position 'left)))
        
        (send km add-function "select-all"
              (lambda (editor kev)
                (send editor move-position 'end)
                (send editor extend-position 0)))
        
        (send km add-function "backward-word"
              (lambda (editor kev)
                (send editor move-position 'left #f 'word)))
        
        (send km add-function "forward-char"
              (lambda (editor kev)
                (send editor move-position 'right)))
        
        (send km add-function "forward-word"
              (lambda (editor kev)
                (send editor move-position 'right #f 'word)))
        
        (send km add-function "previous-line"
              (lambda (editor kev)
                (send editor move-position 'up)))
        
        (send km add-function "next-line"
              (lambda (editor kev)
                (send editor move-position 'down)))
        
        (send km add-function "beginning-of-buffer"
              (lambda (editor kev)
                (send editor move-position 'home)))
        
        (send km add-function "end-of-buffer"
              (lambda (editor kev)
                (send editor move-position 'end)))
        
        ; replace with (send an-editor-canvas get-scroll-pos) ...
        ; scroll-to local-x local-y w h
        ; (define/public (get-pos)
        ;   (values x y w h))
        ; (define-values (x y w h) (send ecanvas get-pos))
        (send km add-function "wheel-up"
              (lambda (editor kev)
                (repeat
                 (λ () (send editor move-position 'up))
                 (send (send editor get-canvas) wheel-step))))
        
        ; replace with (send an-editor-canvas get-scroll-pos) ...
        (send km add-function "wheel-down"
              (lambda (editor kev)
                (repeat
                 (λ () (send editor move-position 'down))
                 (send (send editor get-canvas) wheel-step))))
        
        (send km add-function "menu"
              (λ (editor kev)
                (let ([evt (send kev get-key-code)])
                  (printf "kev: ~a; evt: ~a" kev evt)
                  (cond [(eq? evt 'right-up)
                         ; open the right-click menu
                         (let* ([x-mouse (send kev get-x)]
                                [y-mouse (send kev get-y)]
                                [ecanvas (send editor get-canvas)]
                                [top-frame (send ecanvas get-top-level-window)])
                           
                           (define popup
                             (new popup-menu% [title "Right Click Menu"]))
                           
                           (define copy-item
                             (new menu-item%
                                  [label "Copy"]
                                  [parent popup]
                                  [help-string "Copy this selection"]
                                  [callback (λ (l e)
                                              (send editor copy))]))
                           
                           (send top-frame popup-menu popup x-mouse (+ y-mouse 100)))]))))
        km))

(define (set-default-messages-bindings km)
  (send km map-function ":c:c" "copy")
  (send km map-function ":c:с" "copy") ;; russian cyrillic
  
  (send km map-function ":c:a" "select-all")
  (send km map-function ":c:ф" "select-all") ;; russian cyrillic
  
  (send km map-function ":left" "backward-char")
  (send km map-function ":right" "forward-char")
  (send km map-function ":c:left" "backward-word")
  (send km map-function ":c:right" "forward-word")
  (send km map-function ":up" "previous-line")
  (send km map-function ":down" "next-line")
  (send km map-function ":home" "beginning-of-buffer")
  (send km map-function ":end" "end-of-buffer")
  
  (send km map-function ":wheelup" "wheel-up")
  (send km map-function ":wheeldown" "wheel-down")
  (send km map-function ":rightbuttonseq" "menu"))

; normal black
(define color-black (make-object color% "black"))
; a darker green than "green", which looks nicer on a white background
(define color-green (make-object color% 35 135 0))

(define black-style (make-object style-delta% 'change-size 10))
; make this style black
(void (send black-style set-delta-foreground color-black))

(define green-style (make-object style-delta% 'change-size 10))
; make this style green, for the greentext
(void (send green-style set-delta-foreground color-green))

; if the current cursor position is not at the end, move there
(define (save-move-cursor editor)
  (send editor move-position 'end))

; procedure to imply things
(define message-history%
  (class object%
    (init-field editor)

    (super-new)

    #;(define (async-insert message [before-insert void] [after-insert void])
      (queue-callback
       (lambda ()
         (send editor begin-edit-sequence)
         (insert message before-insert after-insert)
         (send editor end-edit-sequence))))
    
    (define (async-insert tag message [implying? #f] [referral? #f])
      (queue-callback
       (λ ()
         (cond [implying?
                (send editor begin-edit-sequence)
                (save-move-cursor editor)
                (unset-imply-style)
                (send editor insert tag)
                (set-imply-style)
                (send editor insert (string-append message "\n"))
                (send editor end-edit-sequence)]
               [(and (not implying?) referral?)
                (send editor begin-edit-sequence)
                (save-move-cursor editor)
                (send editor insert tag)
                (set-refer-style)
                (send editor insert (string-append message "\n"))
                (unset-refer-style)
                (send editor end-edit-sequence)]
               [else
                (send editor begin-edit-sequence)
                (save-move-cursor editor)
                (unset-imply-style)
                (send editor insert tag)
                (send editor insert (string-append message "\n"))
                (send editor end-edit-sequence)]))))

    (define (set-imply-style)
      (send editor change-style green-style))

    (define (unset-imply-style)
      (send editor change-style black-style))
    
    (define (set-refer-style)
      (send black-style set-delta 'change-bold)
      (send editor change-style black-style))
    
    (define (unset-refer-style)
      (send black-style set-delta 'change-normal)
      (send black-style set-delta 'change-size 10)
      (send editor change-style black-style))

    (define (insert message [before-insert void] [after-insert void])
      (before-insert)
      (save-move-cursor editor)
      (send editor insert message)
      (after-insert))
    
    (define/public (send-file-recv-error msg)
      (insert (format "\n*** File transfer error: ~a ***\n\n" msg)))

    (define/public (begin-send-file path time)
      (send editor insert (format "\n*** Starting transfer: ~a ***\n\n" path)))

    (define/public (end-send-file path time)
      (send editor insert (format "\n*** Sent: ~a ***\n\n" path)))

    (define/public (begin-recv-file path time)
      (send editor insert (format "\n*** Starting download to ~a ***\n\n" path)))
    
    (define/public (end-recv-file time size)
      (send editor insert (format "\n*** Download complete (~a KB) ***\n\n" (real->decimal-string (/ size 1024) 1))))
    
    (define/public (add-recv-action action from time)
      (insert (string-append "** [" time "] " from " " action "\n")))

    (define/public (add-recv-message my-name message from time)
      (let ([tag (string-append "[" time "] " from ": ")])
        (cond [(string=? (substring message 0 1) ">")
               ; implying
               (async-insert tag message #t)]
              ; referring
              [(and (>= (string-length message) (string-length my-name))
                    (string=? (substring message 0 (string-length my-name))
                              (string-append my-name)))
               (async-insert tag message #f #t)]
              [else
               ; regular message
               (async-insert tag message)])))

    ; message is a string
    (define/public (get-msg-type message)
      (if (and (>= (string-length message) 3)
               (string=? (substring message 0 3) "/me"))
          'action
          'regular))
    
    ; message is a string
    (define/public (add-send-message message time)
      (define msg-type 'regular)
      (define pfx "")
      (define resmsg message)

      ; check for action
      (if (and (>= (string-length message) 3)
               (string=? (substring message 0 3) "/me"))
          (begin
            (set! msg-type 'action)
            (set! pfx (string-append "** [" time "] Me: "))
            (set! resmsg (substring message 3)))

          (set! pfx (string-append "[" time "] Me: ")))

      #;(if (string=? (substring message 0 1) ">")
          (insert (string-append pfx resmsg "\n") set-imply-style unset-imply-style)
          (insert (string-append pfx resmsg "\n")))
      
      ; check for imply
      (cond [(string=? (substring message 0 1) ">")
             (send editor begin-edit-sequence)
             (save-move-cursor editor)
             (unset-imply-style)
             (send editor insert pfx)
             (set-imply-style)
             (send editor insert (string-append resmsg "\n"))
             (send editor end-edit-sequence)]
            [else
             (send editor begin-edit-sequence)
             (save-move-cursor editor)
             (unset-imply-style)
             (send editor insert (string-append pfx resmsg "\n"))
             (send editor end-edit-sequence)])

      msg-type)))
