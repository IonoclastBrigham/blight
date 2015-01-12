#!/usr/bin/env racket
#lang racket/gui
; blight.rkt
; GUI Tox client written in Racket
(require libtoxcore-racket ; wrapper
         rsound             ; play/record audio
         libopenal-racket
         "chat.rkt"         ; contains definitions for chat window
         "group.rkt"        ; contains definitions for group window
         "config.rkt"       ; default config file
         "helpers.rkt"      ; various useful functions
         ffi/unsafe         ; needed for neat pointer shenanigans
         ffi/vector         ; needed for make-s16vector
         json               ; for reading and writing to config file
         "history.rkt"      ; access sqlite db for stored history
         "utils.rkt"
         "toxdns.rkt"
         "msg-history.rkt"
         "smart-list.rkt"
         mrlib/aligned-pasteboard)

(define license-message
  "Blight - a Tox client written in Racket.
Copyright (C) 2014 Lehi Toskin.

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <http://www.gnu.org/licenses/>.


Tox's sounds are licensed under the \"Creative Commons Attribution 3.0
Unported\", all credit attributed to Adam Reid.")

(define get-help-message
  "Need more help? Try adding leahtwoskin@toxme.se (or leahtwoskin@utox.org)
and bug the dev! Alternatively, you could join #tox-dev on freenode and see
if people have a similar problem.")

#| #################### BEGIN TOX STUFF ######################## |#
; proxy options
(define my-opts
  (make-Tox-Options (ipv6?) (udp-disabled?) (proxy-type) (proxy-address) (proxy-port)))
; av settings
; defaults copied from astonex:
; https://github.com/Tox/jToxcore/blob/master/src/im/tox/jtoxcore/ToxCodecSettings.java
(define my-csettings
  (let ([type (_ToxAvCallType 'Audio)]
        [video-bitrate 500] ; in kbits/s
        [video-width 1280]
        [video-height 720]
        [audio-bitrate 32000] ; in bits/s - (64000 or 32000)
        [audio-frame-duration 20] ; in ms
        [audio-sample-rate 48000] ; in Hz
        [channels 1]) ; (2 or 1 for poor connection)
    (make-ToxAvCSettings type video-bitrate video-width video-height
                         audio-bitrate audio-frame-duration audio-sample-rate channels)))
; instantiate Tox session
(define my-tox (tox-new my-opts))
(define my-av (av-new my-tox 1))
; is this kosher?
; beats asking for the pass every time we save...
(define encryption-pass "")

; chat entity holding group or contact data
(define cur-groups (make-hash))
(define cur-buddies (make-hash))

(define device (open-device #f))
(define context (create-context device))
(set-current-context context)

#|
reusable procedure to save information to <profile>.json

1. read from <profile>.json to get the most up-to-date info
2. modify the hash
3. save the modified hash to <profile>.json

key is a symbol corresponding to the key in the hash
val is a value that corresponds to the value of the key
|#
(define blight-save-config
  (λ (key val)
    (let* ([new-input-port (open-input-file ((config-file))
                                            #:mode 'text)]
           [json (read-json new-input-port)]
           [modified-json (hash-set json key val)]
           [config-port-out (open-output-file ((config-file))
                                              #:mode 'text
                                              #:exists 'truncate/replace)])
      (display "Saving config... ")
      (json-null 'null)
      (write-json modified-json config-port-out)
      (write-json (json-null) config-port-out)
      (close-input-port new-input-port)
      (close-output-port config-port-out)
      (displayln "Done!"))))

; same as above, but for multiple saves at a time
(define-syntax blight-save-config*
  (syntax-rules ()
    ((_ k1 v1 k2 v2 ...)
     (let* ([new-input-port (open-input-file ((config-file))
                                             #:mode 'text)]
            [json (read-json new-input-port)]
            [modified-json (hash-set* json
                                      k1 v1
                                      k2 v2
                                      ...)]
            (config-port-out (open-output-file ((config-file))
                                               #:mode 'text
                                               #:exists 'truncate/replace)))
       (display "Saving config... ")
       (json-null 'null)
       (write-json modified-json config-port-out)
       (write-json (json-null) config-port-out)
       (close-input-port new-input-port)
       (close-output-port config-port-out)
       (displayln "Done!")))))

; data-file is empty, use default settings
(cond [(zero? (file-size ((data-file))))
       ; set username
       (set-name my-tox my-name)
       ; set status message
       (set-status-message my-tox my-status-message)]
      ; data-file is not empty, load from encrypted data-file
      [(and (not (zero? (file-size ((data-file)))))
            (data-encrypted? (file->bytes ((data-file)) #:mode 'binary)))
       ; we've got an encrypted file, we should save it as encrypted
       (encrypted? #t)
       ; ask the user what the password is
       (displayln "Loading encrypted data...")
       (define loading-callback
         (λ ()
           (set! encryption-pass (send pass-tfield get-value))
           (let ([err (encrypted-load my-tox
                                      (file->bytes data-file #:mode 'binary)
                                      (file-size data-file)
                                      encryption-pass)])
             (cond [(zero? err)
                    (send pass-dialog show #f)
                    (displayln "Loading successful!")]
                   [else
                    (let ([mbox (message-box "Blight - Incorrect Passphrase"
                                             "Sorry! That was incorrect.")])
                      (when (eq? mbox 'ok)
                        (displayln "Incorrect password received, trying again.")))]))))
       (define pass-dialog (new dialog%
                                [label "Blight - Enter Passphrase"]
                                [height 50]
                                [width 400]
                                [style (list 'close-button)]))
       (define pass-tfield
         (new text-field%
              [label "Enter Passphrase: "]
              [parent pass-dialog]
              [callback (λ (l e)
                          (when (eq? (send e get-event-type) 'text-field-enter)
                            (loading-callback)))]))
       (define pass-ok-button
         (new button%
              [label "OK"]
              [parent pass-dialog]
              [callback (λ (button event)
                          (loading-callback))]))
       (send pass-dialog show #t)]
      ; data-file is not empty, load from data-file
      [(nor (zero? (file-size ((data-file))))
            (data-encrypted? (file->bytes ((data-file)) #:mode 'binary)))
       (define size (file-size ((data-file))))
       (define my-bytes (file->bytes ((data-file)) #:mode 'binary))
       (display "Loading from data file... ")
       (let ([result (tox-load my-tox my-bytes size)])
         (if (zero? result)
             (displayln "Done!")
             (begin
               (displayln "Loading failed!")
               (when make-noise
                 (play-sound (last sounds) #t)))))])

; obtain our tox id
(define my-id-bytes (make-bytes TOX_FRIEND_ADDRESS_SIZE))
(get-address my-tox my-id-bytes)
(define my-id-hex (bytes->hex-string my-id-bytes))

; create initial avatar bitmap
(define my-avatar (make-bitmap 40 40))

; if we've already set an avatar, load from that file
(let* ([my-client-id (substring my-id-hex 0 (* TOX_CLIENT_ID_SIZE 2))]
        [my-avatar-location (build-path avatar-dir (string-append my-client-id ".png"))])
  (cond [(file-exists? my-avatar-location)
         ; create the bitmap
         (define avatar-bitmap (make-bitmap 40 40))
         ; load the file into the bitmap
         (send avatar-bitmap load-file my-avatar-location)
         ; turn it into a pict
         (define avatar-pict (bitmap avatar-bitmap))
         ; scale the pict to 40x40
         (define avatar-pict-small (scale-to-fit avatar-pict 40 40))
         ; set the avatar to the new one
         (set! my-avatar (pict->bitmap avatar-pict-small))]))

; connect to DHT
(display "Connecting to network... ")
(cond [(not (false? (bootstrap-from-address my-tox
                                            dht-address
                                            dht-port
                                            dht-public-key)))
       (when make-noise
         (play-sound (fourth sounds) #t))
       (displayln "Connected!")]
      [else (when make-noise
              (play-sound (last sounds) #t))
            (displayln "Connection failed!")])

; reusable procedure to save tox information to data-file
(define blight-save-data
  (λ ()
    (display "Saving data... ")
    (cond [(encrypted?)
           (define size (encrypted-size my-tox))
           (define data-bytes (make-bytes size))
           (define err (encrypted-save! my-tox
                                        data-bytes
                                        encryption-pass))
           (if (zero? err)
               (let ([data-port-out (open-output-file ((data-file))
                                                      #:mode 'binary
                                                      #:exists 'truncate/replace)])
                 (write-bytes data-bytes data-port-out)
                 (close-output-port data-port-out))
               (begin
                 (displayln "There was an error saving the encrypted data!")
                 (when make-noise
                   (play-sound (last sounds) #t))))]
          [else
           ; necessary for saving the messenger
           (define size (tox-size my-tox))
           (define data-bytes (make-bytes size))
           ; place all tox info into data-bytes
           (tox-save! my-tox data-bytes)
           ; SAVE INFORMATION TO DATA
           (let ([data-port-out (open-output-file ((data-file))
                                                  #:mode 'binary
                                                  #:exists 'truncate/replace)])
             (write-bytes data-bytes data-port-out)
             (close-output-port data-port-out))])
    (displayln "Done!")))

; little procedure to wrap things up for us
(define clean-up
  (λ ()
    ; save tox info to data-file
    (blight-save-data)
    ; disconnect from the database
    (disconnect sqlc)
    ; end any calls we might have
    (unless (zero? (get-active-calls my-av))
      (for ([i (get-active-calls my-av)])
        (av-hangup my-av i)))
    ; kill tox threads
    (kill-thread av-loop-thread)
    (kill-thread tox-loop-thread)
    ; kill REPL thread
    (exit-repl)
    ; clean up AL stuff
    ; for buddies
    #;(for ([i (in-range (hash-count cur-buddies))])
      (let ([alsources (contact-data-alsources (hash-ref cur-buddies i))])
        (delete-sources! alsources)))
    ; for groups
    (for ([i (in-range (hash-count cur-groups))])
      (let ([alsources (contact-data-alsources (hash-ref cur-groups i))])
        (unless (false? alsources)
          (delete-sources! alsources))))
    (set-current-context #f)
    (destroy-context! context)
    (close-device! device)
    ; kill av session
    (av-kill! my-av)
    ; this kills the tox
    (tox-kill! my-tox)
    ; log out sound
    (when make-noise
      (play-sound (fifth sounds) #f))))
#| ##################### END TOX STUFF ######################### |#

#| #################### BEGIN GUI STUFF ######################## |#
; create a new top-level window
; make a frame by instantiating the frame% class
(define frame (new frame%
                   [label "Blight - Friend List"]
                   [stretchable-width #t]
                   [height 600]))

; set the frame icon
(let ([icon-bmp (make-bitmap 32 32)])
  (send icon-bmp load-file logo)
  (send frame set-icon icon-bmp))

; make a static text message in the frame
(define frame-msg (new message%
                       [parent frame]
                       [label "Blight Friend List"]))

(define frame-hpanel (new horizontal-panel%
                          [parent frame]
                          [alignment '(left center)]))

(define frame-avatar-button
  (new button%
       [parent frame-hpanel]
       [label my-avatar]
       [callback
        (λ (button event)
          (thread
           (λ ()
             (let ([path (get-file "Select an avatar" ; message
                                   #f ; parent
                                   #f ; directory
                                   #f ; filename
                                   "png" ; extension (windows only)
                                   null ; style
                                   '(("PNG" "*.png")))]) ; filters
               (unless (false? path)
                 (let* ([img-data (file->bytes path)]
                        [my-client-id (substring my-id-hex 0 (* TOX_CLIENT_ID_SIZE 2))]
                        [avatar-file (build-path avatar-dir
                                                 (string-append my-client-id ".png"))]
                        [hash-file (build-path avatar-dir
                                               (string-append my-client-id ".hash"))])
                   (displayln "Setting avatar...")
                   ; create a temp bitmap
                   (define avatar-bitmap (make-bitmap 40 40))
                   ; load the file in to the bitmap
                   (send avatar-bitmap load-file path)
                   ; turn it into a pict
                   (define avatar-pict (bitmap avatar-bitmap))
                   ; scale the pict to 40x40
                   (define avatar-pict-small (scale-to-fit avatar-pict 40 40))
                   ; set the avatar in tox
                   (set-avatar my-tox
                               (_TOX_AVATAR_FORMAT 'PNG)
                               img-data
                               (bytes-length img-data))
                   ; set the avatar to the new one
                   (set! my-avatar (pict->bitmap avatar-pict-small))
                   ; save the avatar to avatar directory
                   (copy-file path avatar-file #t)
                   ; save the hash to the same dir
                   (let ([hash-port-out (open-output-file hash-file
                                                        #:mode 'binary
                                                        #:exists 'truncate/replace)]
                         [hash-buf (make-bytes TOX_HASH_LENGTH)])
                     (define len (tox-hash hash-buf img-data (bytes-length img-data)))
                     (define cropped-hash (subbytes hash-buf 0 len))
                     (write-bytes cropped-hash hash-port-out)
                     (close-output-port hash-port-out))
                   ; reset the avatar as this button's label
                   (send button set-label my-avatar)
                   ; broadcast to our friends we've changed our avatar
                   (displayln "Broadcasting our avatar change to online friends...")
                   (for ([count (hash-count cur-buddies)])
                     (when (= 1 (get-friend-connection-status my-tox count))
                       (send-avatar-info my-tox count)))))))))]))

(define frame-vpanel (new vertical-panel%
                          [parent frame-hpanel]
                          [alignment '(left center)]))

(define username-frame-message (new message%
                                    [parent frame-vpanel]
                                    [label my-name]))

(send username-frame-message auto-resize #t)

(define status-frame-message (new message%
                                  [parent frame-vpanel]
                                  [label my-status-message]))

(send status-frame-message auto-resize #t)

; choices for status type changes
(define status-choice
  (new choice%
       [parent frame]
       [label #f]
       [stretchable-width #t]
       [choices '("Available"
                  "Away"
                  "Busy")]
       [selection (get-self-user-status my-tox)]
       [callback (λ (choice control-event)
                   (set-user-status my-tox (send choice get-selection)))]))

#| ################## BEGIN FRIEND LIST STUFF #################### |#
(define cs-style (new cs-style-manager))

(define sml
  (new smart-list%))

(define sml-canvas
  (new aligned-editor-canvas%
       [parent frame]
       [editor sml]
       [style (list 'no-hscroll)]
       ; perfect minimum height
       ; needs to be set because of frame-vpanel and frame-hpanel
       [min-height 450]))

(define sml-km (init-smart-list-keymap))
(init-default-smartlist-keymap sml-km)
(send sml set-keymap sml-km)

(send sml set-delete-entry-cb
      (lambda (cd)
        (let ([friend-num (contact-data-tox-num cd)])
          (if (eq? (contact-data-type cd) 'buddy)
              (begin
                (delete-friend friend-num))
              
              (begin
                (do-delete-group! friend-num))))))

(define (get-contact-data friendnumber)
  (hash-ref cur-buddies friendnumber))

(define (get-group-data friendnumber)
  (hash-ref cur-groups friendnumber))

(define (get-contact-snip number)
  (send sml get-entry-by-key
        (contact-data-name (hash-ref cur-buddies number))))

(define (get-group-snip number)
  (send sml get-entry-by-key
        (contact-data-name (hash-ref cur-groups number))))

(define (get-contact-window friendnumber)
  (let* ([cd (get-contact-data friendnumber)])
    (contact-data-window cd)))

(define (get-contact-name friendnumber)
  (let* ([cd (get-contact-data friendnumber)])
    (contact-data-name cd)))

(define (update-contact-status friend-num con-status)
  (define status-msg
    (friend-status-msg my-tox friend-num))
  
  (define cd (get-contact-data friend-num))
  (define sn (get-contact-snip friend-num))
  (define window (get-contact-window friend-num))
  
  (send sn set-status con-status)
  (send sn set-status-msg status-msg)
  (send window set-status-msg status-msg))

; helper to avoid spamming notification sounds
(define status-checker
  (λ (friendnumber status)
    (let ([type (get-user-status my-tox friendnumber)])
      (cond [(zero? status)
             (send (get-contact-snip friendnumber) set-status 'offline)
             (update-contact-status friendnumber 'offline)]
            
            ; user is online, check his status type
            [else (on-status-type-change my-tox friendnumber type #f)]))))

;; helper to get friend name as return value
(define (friend-name tox num)
  (define buffer (make-bytes TOX_MAX_NAME_LENGTH))
  (define name-length (get-name tox num buffer))
  (bytes->string/utf-8 (subbytes buffer 0 name-length)))

; helper to get friend's status message as a return value
(define (friend-status-msg tox num)
  (define len (get-status-message-size tox num))
  (define buffer (make-bytes len))
  (get-status-message tox num buffer len)
  (bytes->string/utf-8 buffer))

;; helper to get friend key as return value
(define (friend-key tox num)
  (define buffer (make-bytes TOX_CLIENT_ID_SIZE))
  (get-client-id tox num buffer)
  (bytes->hex-string buffer))

;; helper to get friend number without ->bytes conversion
(define (friend-number tox key)
  (get-friend-number tox (hex-string->bytes key TOX_CLIENT_ID_SIZE)))

; nuke list-box and repopulate it
;; (define update-list-box
;;   (λ ()
;;     ; clear the current list-box so we can remake it
;;     (send list-box clear)
;;     ;; friends
;;     (for ([friend-num (friendlist-length my-tox)])
;;       (define name (friend-name my-tox friend-num))
;;       (define status-msg (friend-status-msg my-tox friend-num))
;;       (define key (friend-key my-tox friend-num))
;;       (define friend-item (list-ref friend-list friend-num))
;;       ; add the friend to the list-box
;;       (send list-box append (string-append "(X) " name "\n" status-msg) key)
;;       ; send information about our friend to the chat window object
;;       (send friend-item set-name name)
;;       (send friend-item set-key key)
;;       (send friend-item set-friend-num (friend-number my-tox key))
;;       ; modify window's frame message and add username
;;       (send friend-item set-new-label
;;             (string-append "Blight - " name))
;;       ; modify window's secondary frame message and add status
;;       (send friend-item set-status-msg status-msg)
;;       ; update our friend's status icon
;;       (status-checker friend-num (get-friend-connection-status my-tox friend-num)))
;;     ;; groups
;;     (for ([i (count-chatlist my-tox)])
;;       (send list-box append (format "Group Chat #~a" i) i))))

(define (update-invite-list)
  (for ([(num grp) cur-groups])
    (let ([cw (contact-data-window grp)])
      (send cw
            update-invite-list))))

(define (create-buddy name key)
  (let* ([avatar-file (build-path avatar-dir
                                  (string-append key ".png"))]
         [avatar-bitmap (if (file-exists? avatar-file)
                            (make-object bitmap% avatar-file)
                            #f)]
         [bitmap-height (if (false? avatar-bitmap)
                            300
                            (send avatar-bitmap get-height))]
         [bitmap-width (if (false? avatar-bitmap)
                           300
                           (send avatar-bitmap get-width))]
         [chat-window (new chat-window%
                           [this-label (format "Blight - ~a" name)]
                           [this-height 400]
                           [this-width 600]
                           [avatar-height bitmap-height]
                           [avatar-width bitmap-width]
                           [this-tox my-tox])]
         [friend-number (friend-number my-tox key)]
         [status-msg (friend-status-msg my-tox friend-number)]
         [cd (contact-data name 'offline status-msg 'buddy chat-window friend-number #f)]
         [ncs (new contact-snip% [smart-list sml]
                   [style-manager cs-style]
                   [contact cd])])
    (send ncs set-status 'offline)
    (send sml insert-entry ncs)
    
    (hash-set! cur-buddies friend-number cd)
    (send chat-window set-name name)
    (send chat-window set-key key)
    (send chat-window set-friend-num friend-number)
    (send chat-window set-friend-avatar
          (if (file-exists? avatar-file)
              avatar-file
              #f))
    
    (update-contact-status friend-number 'offline)))

(define (do-add-group name number type)
  (let* ([group-window (new group-window%
                            [this-label (format "Blight - ~a" name)]
                            [this-height 600]
                            [this-width 800]
                            [this-tox my-tox]
                            [group-number number])]
         [cd (contact-data name #f "" 'group group-window number
                           (if (= type (_TOX_GROUPCHAT_TYPE 'AV))
                               (gen-sources 1)
                               #f))]
         [ncs (new contact-snip% [smart-list sml]
                   [style-manager cs-style]
                   [contact cd])])
    (send ncs set-status 'groupchat)
    (send sml insert-entry ncs)
    (hash-set! cur-groups number cd)))

#|(define (add-new-group name)
  (let* ([number (add-groupchat my-tox)])
    (do-add-group (format "Groupchat #~a" number) number)))|#
(define (add-new-group name)
  (let ([number (count-chatlist my-tox)])
    (do-add-group name number (_TOX_GROUPCHAT_TYPE 'TEXT))
    (add-groupchat my-tox)))

(define (add-new-av-group name)
  (let ([number (count-chatlist my-tox)]
        [av-cb (λ (mtox groupnumber peernumber pcm samples channels sample-rate userdata)
                 (printf "av-cb: gnum: ~a pnum: ~a pcm: ~a samples: ~a channels: ~a~n"
                         groupnumber peernumber pcm samples channels)
                 (printf "av-cb: srate: ~a userdata: ~a~n~n" sample-rate userdata))])
    (do-add-group name number (_TOX_GROUPCHAT_TYPE 'AV))
    (add-av-groupchat my-tox av-cb)))

(define (initial-fill-sml)
  (define an-id 1)
    (for ([fn (friendlist-length my-tox)])
      (define name (friend-name my-tox fn))

      (when (string=? name "")
          (set! name (format "Anonymous #~a" an-id))
          (set! an-id (add1 an-id)))

      (define key (friend-key my-tox fn))

      (create-buddy name key)))

(initial-fill-sml)

; panel for choice and buttons
(define panel (new horizontal-panel%
                   [parent frame]
                   [stretchable-height #f]
                   [alignment (list 'right 'center)]))
#| ################## END FRIEND LIST STUFF #################### |#

#| ################### BEGIN MENU BAR STUFF #################### |#
; menu bar for the frame
(define frame-menu-bar (new menu-bar%
                            [parent frame]))

; menu File for menu bar
(define menu-file (new menu%
                       [parent frame-menu-bar]
                       [label "&File"]
                       [help-string "Open, Quit, etc."]))

; Copy ID to Clipboard item for File
(define menu-copy-id
  (new menu-item%
       [parent menu-file]
       [label "Copy My ID to Clipboard"]
       [help-string "Copies your Tox ID to the clipboard"]
       [callback (λ (button event)
                   ; copy id to clipboard
                   (send chat-clipboard set-clipboard-string
                         my-id-hex
                         (current-seconds)))]))

; dialog box when exiting
(define exit-dialog (new dialog%
                         [label "Exit Blight"]
                         [style (list 'close-button)]))

; Quit menu item for File
; uses message-box with 'ok-cancel
(define menu-quit
  (new menu-item%
       [parent menu-file]
       [label "&Quit"]
       [shortcut #\Q]
       [help-string "Quit Blight"]
       [callback (λ (button event)
                   (let ([mbox (message-box/custom
                                "Blight - Quit Blight"
                                "Are you sure you want to quit Blight?"
                                "&OK"
                                "&Cancel"
                                #f
                                exit-dialog
                                (list 'caution 'no-default))])
                     (cond [(= mbox 1) (clean-up) (exit)])))]))

; menu Edit for menu bar
(define menu-edit (new menu%
                       [parent frame-menu-bar]
                       [label "&Edit"]
                       [help-string "Modify Blight"]))

; Preferences menu item for Edit
(define menu-preferences (new menu-item%
                              [parent menu-edit]
                              [label "Preferences"]
                              [shortcut #\R]
                              [help-string "Modify Blight preferences"]
                              [callback (λ (button event)
                                          (thread
                                           (λ ()
                                             (send preferences-box show #t))))]))

(define menu-profile (new menu-item%
                          [parent menu-edit]
                          [label "Profiles"]
                          [shortcut #\P]
                          [help-string "Manage Tox profiles"]
                          [callback (λ (button event)
                                      (thread
                                       (λ ()
                                         (send profiles-box show #t))))]))

(define help-get-dialog (new dialog%
                             [label "Blight - Get Help"]
                             [style (list 'close-button)]))

(define help-get-text (new text%
                           [line-spacing 1.0]
                           [auto-wrap #t]))
(send help-get-text change-style black-style)
(send help-get-text insert get-help-message)

(define help-get-editor-canvas
  (new editor-canvas%
       [parent help-get-dialog]
       [min-height 100]
       [min-width 600]
       [vert-margin 10]
       [editor help-get-text]
       [style (list 'control-border 'no-hscroll
                    'auto-vscroll 'no-focus)]))

(define help-get-ok
  (new button%
       [parent help-get-dialog]
       [label "&OK"]
       [callback (λ (button event)
                   (send help-get-dialog show #f))]))

; dialog box when looking at Help -> About
(define help-about-dialog (new dialog%
                               [label "Blight - License"]
                               [style (list 'close-button)]))

(define help-about-text (new text%
                             [line-spacing 1.0]
                             [auto-wrap #t]))
(send help-about-text change-style black-style)
(send help-about-text insert license-message)

; canvas to print the license message
(define help-about-editor-canvas
  (new editor-canvas%
       [parent help-about-dialog]
       [min-height 380]
       [min-width 600]
       [vert-margin 10]
       [editor help-about-text]
       [style (list 'control-border 'no-hscroll
                    'auto-vscroll 'no-focus)]))

; button to close the About Blight window
(define help-about-ok
  (new button%
       [parent help-about-dialog]
       [label "&OK"]
       [callback (λ (button event)
                   (send help-about-dialog show #f))]))

; menu Help for menu bar
(define menu-help (new menu%
                       [parent frame-menu-bar]
                       [label "&Help"]
                       [help-string "Get information about Blight"]))

; About Blight menu item for Help
(define menu-help-get-help (new menu-item%
                                [parent menu-help]
                                [label "Get Help"]
                                [help-string "Get Help with Blight"]
                                [callback (λ (button event)
                                            (send help-get-dialog show #t))]))

; About Blight menu item for Help
(define menu-help-about (new menu-item%
                             [parent menu-help]
                             [label "About Blight"]
                             [help-string "Show information about Blight"]
                             [callback (λ (button event)
                                         (send help-about-dialog show #t))]))
#| #################### END MENU BAR STUFF ################## |#

#| #################### PREFERENCES STUFF ################### |#
(define preferences-box (new dialog%
                             [label "Blight - Edit Preferences"]
                             [style (list 'close-button)]
                             [height 200]
                             [width 400]))

(define tab-panel (new tab-panel%
                       [parent preferences-box]
                       [choices (list "Preferences"
                                      "Proxy")]
                       [callback (λ (l e)
                                   (cond [(zero? (send l get-selection))
                                          (send l delete-child proxy-panel)
                                          (send l add-child pref-panel)]
                                         [else
                                          (send l delete-child pref-panel)
                                          (send l add-child proxy-panel)]))]))

(define pref-panel (new vertical-panel%
                       [parent tab-panel]))

; remove proxy-panel from the window for now
(define proxy-panel (new vertical-panel%
                        [parent tab-panel]
                        [style '(deleted)]))

(define Username_msg (new message%
                          [parent pref-panel]
                          [label "New Username:"]))

;;Define a panel so stuff is aligned
(define User_panel (new horizontal-panel%
                        [parent pref-panel]
                        [alignment '(center center)]))

(define putfield (new text-field%
                      [parent User_panel]
                      [label #f]
                      [style (list  'single)]
                      [callback (λ (l e)
                                  (when (eq? (send e get-event-type)
                                             'text-field-enter)
                                    (let ([username (send l get-value)])
                                      ; refuse to set the status if it's empty
                                      (unless (string=? username "")
                                        ; set the new username
                                        (blight-save-config 'my-name-last username)
                                        (send username-frame-message set-label username)
                                        (set-name my-tox username)
                                        (blight-save-data)
                                        (send l set-value "")))))]))

(define putfield-set
  (new button% [parent User_panel]
       [label "Set"]
       [callback (λ (button event)
                   (let ([username (send putfield get-value)])
                     ; refuse to set the username if it's empty
                     (unless (string=? username "")
                       (blight-save-config 'my-name-last username)
                       (send username-frame-message set-label username)
                       (set-name my-tox username)
                       (blight-save-data)
                       (send putfield set-value ""))))]))

;;Status
(define Status_msg (new message%
                        [parent pref-panel]
                        [label "New Status:"]))

;;Same
(define Status_panel(new horizontal-panel%
                         [parent pref-panel]
                         [alignment '(center center)]))

(define pstfield (new text-field%
                      [parent Status_panel] 
                      [label #f] 
                      [style (list 'single)]
                      [callback (λ (l e)
                                  (let ([status (send l get-value)])
                                    (when (eq? (send e get-event-type)
                                               'text-field-enter)
                                      ; refuse to set the status if it's empty
                                      (unless (string=? status "")
                                        ; set the new status
                                        (blight-save-config 'my-status-last status)
                                        (send status-frame-message set-label status)
                                        (set-status-message my-tox status)
                                        (blight-save-data)
                                        (send l set-value "")))))]))

(define pstfield-set-button
  (new button%
       [parent Status_panel]
       [label "Set"]
       [callback (λ (button event)
                   (let ([status (send pstfield get-value)])
                     ; refuse to set status if it's empty
                     (unless (string=? status "")
                       (blight-save-config 'my-status-last status)
                       (send status-frame-message set-label status)
                       (set-status-message my-tox status)
                       (blight-save-data)
                       (send pstfield set-value ""))))]))

(define change-nospam-button
  (new button%
       [parent pref-panel]
       [label "Change nospam value"]
       [callback (λ (button event)
                   (let ([mbox (message-box "Blight - Change nospam"
                                            (string-append "Are you certain you want to"
                                                           " change your nospam value?")
                                            #f
                                            (list 'ok-cancel 'stop))])
                     (when (eq? mbox 'ok)
                       (set-nospam! my-tox
                                    ; largest (random) can accept
                                    ; corresponds to "FFFFFF2F"
                                    (random 4294967087))
                       ; save our changes
                       (blight-save-data)
                       ; set new tox id
                       (get-address my-tox my-id-bytes)
                       (set! my-id-hex
                             (bytes->hex-string my-id-bytes)))))]))

(define make-sounds-button
  (new check-box%
       [parent pref-panel]
       [label "Make sounds"]
       [value (not (false? make-noise))]
       [callback (λ (l e)
                   (let ([noise (send l get-value)])
                     (toggle-noise)
                     (blight-save-config 'make-noise-last noise)))]))

(define encrypted-save-button
  (new check-box%
       [parent pref-panel]
       [label "Encrypted save"]
       [value (encrypted?)]
       [callback
        (λ (l e)
          (let ([enc (send l get-value)])
            (if enc
                (let ([mbox
                       (message-box
                        "Blight - Encryption Warning"
                        (string-append
                         "WARNING! Encrypting your data file could be dangerous!\n"
                         "If even one byte is incorrect in the saved file,\n"
                         "it will be worthless!")
                        #f
                        (list 'ok-cancel 'stop))])
                  (cond [(eq? mbox 'ok)
                         (define enc-dialog
                           (new dialog%
                                [label "Blight - Encryption Passphrase"]
                                [height 50]
                                [width 400]))
                         (define enc-tfield
                           (new text-field%
                                [parent enc-dialog]
                                [label "New Passphrase: "]
                                [callback (λ (l e)
                                            (when (eq? (send e get-event-type)
                                                       'text-field-enter)
                                              (set! encryption-pass
                                                    (send l get-value))
                                              (send enc-dialog show #f)))]))
                         (define enc-ok-button
                           (new button%
                                [parent enc-dialog]
                                [label "OK"]
                                [callback (λ (button event)
                                            (set! encryption-pass
                                                  (send enc-tfield get-value))
                                            (send enc-dialog show #f))]))
                         (encrypted? enc)
                         (blight-save-config 'encrypted?-last enc)]
                        [(eq? mbox 'cancel)
                         (send l set-value #f)
                         (encrypted? #f)]))
                (begin
                  (encrypted? #f)
                  (blight-save-config 'encrypted?-last enc)))))]))

; Close button for preferences dialog box
(define preferences-close-button
  (new button%
       [parent pref-panel]
       [label "Close"]
       [callback (λ (button event)
                   (send preferences-box show #f))]))

; proxy options

(define ipv6-button (new check-box%
                         [parent proxy-panel]
                         [label "Enable IPv6"]
                         [value (ipv6?)]))

(define udp-button (new check-box%
                        [parent proxy-panel]
                        [label "Disable UDP"]
                        [value (udp-disabled?)]))

(define proxy-type-msg
  (new message%
       [parent proxy-panel]
       [label "Note: Proxy Type None will negate the other proxy options."]))

(define proxy-type-choice
  (new choice%
       [parent proxy-panel]
       [label "Proxy Type"]
       [choices '("None" "SOCKS5" "HTTP")]
       [selection (proxy-type)]))

(define proxy-address-port-panel
  (new horizontal-panel% [parent proxy-panel]))

(define proxy-address-tfield
  (new text-field%
       [parent proxy-address-port-panel]
       [label #f]
       [init-value (if (string=? "" (proxy-address))
                       "example.com"
                       (proxy-address))]
       [min-width 250]))

(define proxy-port-tfield
  (new text-field%
       [parent proxy-address-port-panel]
       [label #f]
       [init-value (if (zero? (proxy-port))
                       "0 ~ 60000"
                       (number->string (proxy-port)))]))

(define proxy-ok-cancel-hpanel
  (new horizontal-panel%
       [parent proxy-panel]
       [alignment '(right center)]))

(define proxy-cancel-button
  (new button%
       [parent proxy-ok-cancel-hpanel]
       [label "Cancel"]
       [callback (λ (button event)
                   ; reset all the old values
                   (send ipv6-button set-value (ipv6?))
                   (send udp-button set-value (udp-disabled?))
                   (send proxy-type-choice set-selection (proxy-type))
                   (send proxy-address-tfield set-value (proxy-address))
                   (send proxy-port-tfield set-value (number->string (proxy-port)))
                   ; close the window
                   (send preferences-box show #f))]))

(define proxy-ok-button
  (new button%
       [parent proxy-ok-cancel-hpanel]
       [label "OK"]
       [callback (λ (button event)
                   ; set all the new values
                   (ipv6? (send ipv6-button get-value))
                   (udp-disabled? (send udp-button get-value))
                   (proxy-type (send proxy-type-choice get-selection))
                   (proxy-address (send proxy-address-tfield get-value))
                   ; only integers allowed inside port tfield
                   (let ([num (string->number (send proxy-port-tfield get-value))]
                         [port-max 60000])
                     (cond [(and (integer? num) (<= num port-max) (positive? num))
                            (proxy-port num)
                            ; record the new values to the config file
                            (blight-save-config* 'ipv6?-last (ipv6?)
                                                 'udp-disabled?-last (udp-disabled?)
                                                 'proxy-type-last (proxy-type)
                                                 'proxy-address-last (proxy-address)
                                                 'proxy-port-last (proxy-port))
                            ; close the window
                            (send preferences-box show #f)]
                           [else
                            (printf "Invalid port number! Valid range: ~a ~~ ~a~n" 0 port-max)
                            (send proxy-port-tfield set-value
                                  (format "~a ~~ ~a" 0 port-max))])))]))
#| #################### END PREFERENCES STUFF ################### |#

#| #################### PROFILE STUFF #################### |#
(define profiles-box (new dialog%
                          [label "Blight - Manage Profiles"]
                          [style (list 'close-button)]
                          [height 100]
                          [width 400]))

(define profile-message (new message%
                             [parent profiles-box]
                             [label "Select a profile:"]))

(define profile-caveat (new message%
                            [parent profiles-box]
                            [label "(Profile will be selected upon program restart.)"]))

; choices for available profiles
(define profiles-choice
  (let ([profile-last (hash-ref json-info 'profile-last)])
    (new choice%
         [parent profiles-box]
         [label #f]
         [stretchable-width #t]
         [choices ((profiles))]))) ; list of available profiles

(define profiles-hpanel
  (new horizontal-panel%
       [parent profiles-box]
       [alignment '(right center)]))

(define profiles-cancel-button
  (new button%
       [parent profiles-hpanel]
       [label "Cancel"]
       [callback (λ (button event)
                   (send profiles-box show #f))]))

(define profiles-export-button
  (new button%
       [parent profiles-hpanel]
       [label "Export"]
       [callback (λ (button event)
                   (let ([path (get-directory "Blight - Export Data" ; label
                                              #f ; parent
                                              tox-path)] ; directory
                         [selection-str (send profiles-choice get-string-selection)])
                     (unless (false? path)
                       (printf "Exporting profile ~a to ~a... " selection-str path)
                       (copy-file ((data-file selection-str))
                                  (build-path path (file-name-from-path ((data-file)))))
                       (displayln "Done!"))
                     (send profiles-box show #f)))]))

; delete the selected profile
(define profiles-delete-button
  (new button%
       [parent profiles-hpanel]
       [label "Delete"]
       [callback
        (λ (button event)
          (let-values ([(mbox cbox) (message+check-box
                                     "Blight - Delete Profile" ; label
                                     "Are you certain you want to delete this profile?" ; msg
                                     "Delete History DB" ; cbox label
                                     #f ; parent
                                     '(ok-cancel stop))] ; style
                       [(selection-num) (send profiles-choice get-selection)]
                       [(selection-str) (send profiles-choice get-string-selection)])
            (when (eq? mbox 'ok)
              (printf "Deleting profile ~a... " selection-str)
              (send profiles-choice delete selection-num)
              (delete-file ((data-file selection-str)))
              (delete-file ((config-file selection-str)))
              ; if cbox is selected, also delete db-file
              (cond [(false? cbox)
                     (displayln "Done!")]
                    [else (delete-file ((db-file selection-str)))
                          (displayln "Done!")])
              (send profiles-box show #f))))]))

; Select button for preferences dialog box
(define profiles-ok-button
  (new button%
       [parent profiles-hpanel]
       [label "Select"]
       [callback (λ (button event)
                   (blight-save-config 'profile-last
                                       (send profiles-choice get-string-selection))
                   (send profiles-box show #f))]))
#| #################### END PROFILE STUFF #################### |#

#| #################### BEGIN FRIEND STUFF ####################### |#
(define add-friend-box (new dialog%
                            [label "Blight - Add a new Tox friend"]
                            [style (list 'close-button)]))

(define dns-msg (new message%
                     [parent add-friend-box]
                     [label "DNS nickname:"]))

(define dns-panel (new horizontal-panel%
                       [parent add-friend-box]
                       [alignment '(center center)]))

(define add-friend-txt-tfield (new text-field%
                                   [parent dns-panel]
                                   [label #f]
                                   [min-width 38]))

; choices for status type changes
(define dns-domain-choice
  (new choice%
       [parent dns-panel]
       [label #f]
       [choices '("toxme.se"
                  "utox.org")]))

(define hex-message (new message%
                         [parent add-friend-box]
                         [label "Friend ID(X):"]))

(define hex-panel (new horizontal-panel%
                       [parent add-friend-box]
                       [alignment '(center center)]))

; add friend with Tox ID
(define add-friend-hex-tfield (new text-field%
                                   [parent hex-panel]
                                   [label #f]
                                   [min-width 38]
                                   [callback (λ (l e)
                                               (if (tox-id? (send l get-value))
                                                   (send hex-message set-label
                                                         "Friend ID(✓):")
                                                   (send hex-message set-label
                                                         "Friend ID(X):")))]))

(define message-message (new message%
                             [parent add-friend-box]
                             [label "Message:"]))

(define message-panel (new horizontal-panel%
                           [parent add-friend-box]
                           [alignment '(center center)]))

; message to send as a friend request
(define add-friend-message-tfield
  (new text-field%
       [parent message-panel]
       [label #f]
       [min-width 38]
       [init-value "Please let me add you to my contact list"]))

; panel for the buttons
(define add-friend-panel (new horizontal-panel%
                              [parent add-friend-box]
                              [alignment '(right center)]))

(define add-friend-error-dialog (new dialog%
                                     [label "Invalid Tox ID"]
                                     [style (list 'close-button)]))

; don't actually want to add a friend right now
(define add-friend-cancel-button
  (new button%
       [parent add-friend-panel]
       [label "Cancel"]
       [callback (λ (button event)
                   (send add-friend-hex-tfield set-value "")
                   (send add-friend-txt-tfield set-value "")
                   (send add-friend-box show #f))]))

; OK button for add-friend dialog box
(define add-friend-ok-button
  (new button%
       [parent add-friend-panel]
       [label "OK"]
       [callback (λ (button event)
                   (let* ([nick-tfield (send add-friend-txt-tfield get-value)]
                          [hex-tfield (send add-friend-hex-tfield get-value)]
                          [message-bytes (string->bytes/utf-8
                                          (send add-friend-message-tfield get-value))]
                          [domain (send dns-domain-choice get-string-selection)])
                     ; add the friend to the friend list
                     (cond [(or
                             ; the hex field is empty, nick field cannot be empty
                             (and (string=? hex-tfield "")
                                  (and (not (string=? nick-tfield ""))
                                       ; make sure we get a response from the DNS
                                       (not (false? (tox-dns3 nick-tfield domain)))))
                             ; the nick field is empty, hex field cannot be empty
                             (and (string=? nick-tfield "")
                                  ; make sure hex field is a proper tox id
                                  (tox-id? hex-tfield)))
                            ; convert hex to bytes
                            (define nick-bytes (make-bytes TOX_FRIEND_ADDRESS_SIZE))
                            ; we're doing a direct friend add
                            (cond [(string=? nick-tfield "")
                                   ; obtain the byte form of the id
                                   (set! nick-bytes
                                         (hex-string->bytes
                                          hex-tfield
                                          TOX_FRIEND_ADDRESS_SIZE))]
                                  ; we're doing a dns lookup
                                  [(string=? hex-tfield "")
                                   ; obtain the id from the dns query
                                   (define friend-hex (tox-dns3 nick-tfield domain))
                                   ; obtain the byte form of the id
                                   (set! nick-bytes
                                         (hex-string->bytes
                                          friend-hex
                                          TOX_FRIEND_ADDRESS_SIZE))])
                            (cond [(> (bytes-length message-bytes)
                                      TOX_MAX_FRIENDREQUEST_LENGTH)
                                   (set! message-bytes
                                         (subbytes message-bytes
                                                   0
                                                   TOX_MAX_FRIENDREQUEST_LENGTH))])
                            (let ([err (add-friend my-tox
                                                   nick-bytes
                                                   message-bytes)])
                              ; check for all the friend add errors
                              (cond [(= err (_TOX_FAERR 'TOOLONG))
                                     (displayln "ERROR: TOX_FAERR_TOOLONG")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [(= err (_TOX_FAERR 'NOMESSAGE))
                                     (displayln "ERROR: TOX_FAERR_NOMESSAGE")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [(= err (_TOX_FAERR 'OWNKEY))
                                     (displayln "ERROR: TOX_FAERR_OWNKEY")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [(= err (_TOX_FAERR 'ALREADYSENT))
                                     (displayln "ERROR: TOX_FAERR_ALREADYSENT")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [(= err (_TOX_FAERR 'UNKNOWN))
                                     (displayln "ERROR: TOX_FAERR_UNKNOWN")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [(= err (_TOX_FAERR 'BADCHECKSUM))
                                     (displayln "ERROR: TOX_FAERR_BADCHECKSUM")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [(= err (_TOX_FAERR 'SETNEWNOSPAM))
                                     (displayln "ERROR: TOX_FAERR_SETNEWNOSPAM")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [(= err (_TOX_FAERR 'NOMEM))
                                     (displayln "ERROR: TOX_FAERR_NOMEM")
                                     (when make-noise
                                       (play-sound (last sounds) #t))]
                                    [else (displayln "All okay!")
                                          ; save the tox data
                                          (blight-save-data)
                                          
                                          (let* ([newfn (sub1 (friendlist-length my-tox))]
                                                 [key (friend-key my-tox newfn)])
                                            (if (string=? hex-tfield "")
                                                (create-buddy nick-tfield key)
                                                (create-buddy
                                                 (format "Anonymous (~a)"
                                                         (substring hex-tfield 0 5)) key)))
                                          
                                          ; update friend list, but don't mess up
                                          ; the numbering we already have
                                          
                                          ; zero-out some fields
                                          (send add-friend-hex-tfield set-value "")
                                          (send add-friend-txt-tfield set-value "")
                                          ; close the window
                                          (send add-friend-box show #f)
                                          ; the invite list needs to be updated for
                                          ; the groupchat windows that still exist
                                          (unless (zero? (hash-count cur-groups))
                                            (update-invite-list))]))]
                           ; something went wrong!
                           [else (when make-noise
                                   (play-sound (last sounds) #t))
                                 (let ([mbox (message-box
                                              "Blight - Invalid Tox ID"
                                              "Sorry, that is an invalid Tox ID or DNS nick."
                                              add-friend-error-dialog
                                              (list 'ok 'stop))])
                                   (when (eq? mbox 'ok)
                                     (send add-friend-error-dialog show #f)))])))]))

; send friend request
(define add-friend-button (new button%
                               [parent panel]
                               [label "Add friend"]
                               [callback (λ (button event)
                                           (send add-friend-box show #t))]))

; remove a friend
(define del-friend-dialog (new dialog%
                               [label "Remove a Tox friend"]
                               [style (list 'close-button)]))

(define (do-delete-friend friend-num)
                       ; delete from tox friend list
                       (del-friend! my-tox friend-num)
                       ; save the blight data
                       (blight-save-data)
                       ; remove from list-box

                       (send sml remove-entry (get-contact-snip friend-num))
                       (hash-remove! cur-buddies friend-num)

                       ; the invite list needs to be updated for
                       ; the groupchat windows that still exist
                       (unless (zero? (hash-count cur-groups))
                         (update-invite-list)))

(define (delete-friend friend-number)
  (let ([mbox (message-box "Blight - Deleting Friend"
                            "Are you sure you want to delete?"
                            del-friend-dialog
                            (list 'ok-cancel))])
    (when (eq? mbox 'ok)
      (do-delete-friend friend-number))))

; remove friend from list
(define delete-friend-button
  (new button%
       [parent panel]
       [label "Del friend"]
       [callback (λ (button event)
                    (let ([friend-num (contact-data-tox-num (send sml get-selection-cd))])
                     (delete-friend friend-num)))]))
#| ##################### END FRIEND STUFF ####################### |#

#| ####################### BEGIN GROUP STUFF ######################## |#
(define add-group-button
  (new button%
       [parent panel]
       [label "Add group"]
       [callback (λ (button event)
                   ; open a dialogue to optionally name the groupchat
                   (define add-group-frame (new frame% [label "Add Group"]))
                   
                   (define add-group-message
                     (new message%
                          [label "Please enter a(n optional) Group Chat name"]
                          [parent add-group-frame]))
                   
                   (define add-group-tfield
                     (new text-field%
                          [label "Group Chat name: "]
                          [parent add-group-frame]
                          [callback (λ (l e)
                                      (when (eq? (send e get-event-type) 'text-field-enter)
                                        (let* ([gcount (hash-count cur-groups)]
                                               [str (send l get-value)]
                                               [bstr (string->bytes/utf-8 str)]
                                               [no-name #"Group Chat"])
                                          ; no group name supplied, go with defaults
                                          (cond [(string=? str "")
                                                 (if (send add-group-av-check get-value)
                                                     (add-new-av-group
                                                      (format "Groupchat #~a" gcount))
                                                     (add-new-group
                                                      (format "Groupchat #~a" gcount)))
                                                 (group-set-title my-tox gcount no-name
                                                                  (bytes-length no-name))
                                                 (send l set-value "")
                                                 (send add-group-frame show #f)]
                                                ; group name supplied, use that
                                                [else
                                                 ; add group with number and name
                                                 (if (send add-group-av-check get-value)
                                                     (add-new-av-group
                                                      (format "Groupchat #~a" gcount))
                                                     (add-new-group
                                                      (format "Groupchat #~a" gcount)))
                                                 (define window (contact-data-window
                                                                 (hash-ref cur-groups gcount)))
                                                 ; set the group title we chose
                                                 (group-set-title my-tox
                                                                  gcount
                                                                  bstr
                                                                  (bytes-length bstr))
                                                 (send window set-new-label
                                                       (format "Blight - Groupchat #~a: ~a"
                                                               gcount str))
                                                 (send (get-group-snip gcount)
                                                       set-status-msg str)
                                                 (send l set-value "")
                                                 (send add-group-frame show #f)]))))]))
                   
                   (define add-group-av-check
                     (new check-box%
                          [parent add-group-frame]
                          [label "Enable Audio"]
                          [value #f]))
                   
                   ; TODO: tick box for audio capabilities
                   
                   (define add-group-hpanel (new horizontal-panel%
                                                 [parent add-group-frame]
                                                 [alignment '(right center)]))
                   
                   (define add-group-cancel-button
                     (new button%
                          [parent add-group-hpanel]
                          [label "Cancel"]
                          [callback (λ (button event)
                                      (send add-group-tfield set-value "")
                                      (send add-group-frame show #f))]))
                   
                   (define add-group-ok-button
                     (new button%
                          [parent add-group-hpanel]
                          [label "&OK"]
                          [callback
                           (λ (button event)
                             ; add the group
                             (let* ([str (send add-group-tfield get-value)]
                                    [bstr (string->bytes/utf-8 str)]
                                    [gcount (hash-count cur-groups)]
                                    [no-name #"Group Chat"])
                               ; no group name supplied, go with defaults
                               (cond [(string=? str "")
                                      (if (send add-group-av-check get-value)
                                          (add-new-av-group (format "Groupchat #~a" gcount))
                                          (add-new-group (format "Groupchat #~a" gcount)))
                                      (group-set-title my-tox gcount no-name
                                                       (bytes-length no-name))
                                      (send add-group-tfield set-value "")
                                      (send add-group-frame show #f)]
                                     ; group name supplied, use that
                                     [else
                                      ; add group with number and name
                                      (if (send add-group-av-check get-value)
                                          (add-new-av-group (format "Groupchat #~a" gcount))
                                          (add-new-group (format "Groupchat #~a" gcount)))
                                      (define window
                                        (contact-data-window (hash-ref cur-groups gcount)))
                                      ; set the group title we chose
                                      (group-set-title my-tox
                                                       gcount
                                                       bstr
                                                       (bytes-length bstr))
                                      (send (get-group-snip gcount)
                                            set-status-msg str)
                                      (send add-group-tfield set-value "")
                                      (send add-group-frame show #f)])))]))
                   
                   (send add-group-frame show #t))]))

(define (do-delete-group! grp-number)
  (let* ([grp (hash-ref cur-groups grp-number)]
         [sources (contact-data-alsources grp)])
    (for-each (λ (i) (stop-source i)) sources)
    (delete-sources! sources)
    (del-groupchat! my-tox grp-number)
    (send sml remove-entry (get-group-snip grp-number))
    (hash-remove! cur-groups grp-number)))

(define del-group-button
  (new button%
       [parent panel]
       [label "Del group"]
       [callback (λ (button event)
                   (send sml call-delete-entry-cb (send sml get-selection-cd)))]))
#| ####################### END GROUP STUFF ########################## |#

; show the frame by calling its show method
(send frame show #t)
#| ##################### END GUI STUFF ######################### |#

#| ################# START CALLBACK PROCEDURE DEFINITIONS ################# |#
; set all the callback functions
(define on-friend-request
  (λ (mtox public-key message len userdata)
    ;(define public-key (make-sized-byte-string key-ptr TOX_CLIENT_ID_SIZE))
    ; convert public-key from bytes to string so we can display it
    (define id-hex (bytes->hex-string public-key))
    ; friend request dialog
    (define fr-dialog
      (new dialog%
           [label "Blight - Friend Request"]
           [style (list 'close-button)]))
    
    ; friend request text with modified text size
    (define fr-text
      (new text%
           [line-spacing 1.0]
           [auto-wrap #t]))
    (send fr-text change-style black-style)
    
    ; canvas to print the friend request message
    (define fr-ecanvas
      (new editor-canvas%
           [parent fr-dialog]
           [min-height 150]
           [min-width 650]
           [vert-margin 10]
           [editor fr-text]
           [style (list 'control-border 'no-hscroll
                        'auto-vscroll 'no-focus)]))
    
    ; panel to right-align our buttons
    (define fr-hpanel
      (new horizontal-panel%
           [parent fr-dialog]
           [alignment (list 'right 'center)]))
    
    (define fr-cancel-button
      (new button%
           [parent fr-hpanel]
           [label "Cancel"]
           [callback (λ (button event)
                       ; close and reset the friend request dialog
                       (send fr-dialog show #f))]))
    
    (define fr-ok-button
      (new button%
           [parent fr-hpanel]
           [label "OK"]
           [callback
            (λ (button event)
              ; add the friend
              (define friendnumber (add-friend-norequest mtox public-key))
              (display "Adding friend... ")
              ; reused code to add friend on success
              (define (add-friend-success)
                ; play a sound because we accepted
                (when make-noise
                  (play-sound (sixth sounds) #f))
                (printf "Added friend number ~a~n" friendnumber)
                ; append new friend to the list
                (create-buddy (format-anonymous id-hex)
                              (friend-key my-tox friendnumber))
                
                ; update friend list
                ; add connection status icons to each friend
                (do ((i 0 (+ i 1)))
                  ((= i (friendlist-length mtox)))
                  (status-checker
                   i
                   (get-friend-connection-status mtox i)))
                ; the invite list needs to be updated for
                ; the groupchat windows that still exist
                (unless (zero? (hash-count cur-groups))
                  (update-invite-list))
                ; save the tox data
                (blight-save-data))
              ; catch errors
              (cond [(= -1 friendnumber)
                     (display "There was an error accepting the friend request! ")
                     ; if we've failed, try again 3(?) more times
                     (let loop ([tries 0])
                       (cond [(= tries 3)
                              (displayln "Failed!")
                              (when make-noise
                                (play-sound (last sounds) #t))]
                             [else
                              (display "Retrying... ")
                              (tox-do mtox)
                              (sleep (/ (tox-do-interval mtox) 1000))
                              (if (= -1 (add-friend-norequest mtox public-key))
                                  (loop (add1 tries))
                                  (begin
                                    (displayln "Success!")
                                    (add-friend-success)))]))]
                    [else (add-friend-success)])
              (send fr-dialog show #f))]))
    
    (send fr-text insert (string-append
                          id-hex
                          "\nwould like to add you as a friend!\n"
                          "Message: " message))
    (send fr-dialog show #t)))

(define on-friend-message
  (λ (mtox friendnumber message len userdata)
     (let* ([window (get-contact-window friendnumber)]
           [msg-history (send window get-msg-history)]
           [name (send window get-name)])
      
      ; if the window isn't open, force it open
      (cond [(not (send window is-shown?)) (send window show #t)])
      (send msg-history add-recv-message my-name message name (get-time))
      
      ; make a noise
      (when make-noise
        (play-sound (first sounds) #t))
      ; add message to the history database
      (add-history my-id-hex (send window get-key) message 0))))

(define on-friend-action
  (λ (mtox friendnumber action len userdata)
    (let* ([window (get-contact-window friendnumber)]
           [msg-history (send window get-msg-history)]
           [name (send window get-name)])
      ; if the window isn't open, force it open
      (cond [(not (send window is-shown?)) (send window show #t)])

      (send msg-history add-recv-action action name (get-time))
      
      ; make a noise
      (when make-noise
        (play-sound (first sounds) #t))
      ; add message to the history database
      (add-history my-id-hex (send window get-key) (string-append "ACTION: " action) 0))))

(define on-friend-name-change
  (λ (mtox friendnumber newname len userdata)
     (let ([sn (get-contact-snip friendnumber)])
       (send sml rename-entry sn newname))

    (let ([window (get-contact-window friendnumber)])
      ; update the name in the list
      (send window set-name newname)
      ; update the name in the window
      (send window set-new-label (string-append "Blight - " newname))
      ; add connection status icon
      (status-checker friendnumber (get-friend-connection-status mtox friendnumber)))))


(define on-status-type-change
  (λ (mtox friendnumber status userdata)
    ; friend is online
    (cond [(= status (_TOX_USERSTATUS 'NONE))
           (send (get-contact-snip friendnumber) set-status 'available)
           (update-contact-status friendnumber 'available)]
          ; friend is away
          [(= status (_TOX_USERSTATUS 'AWAY))
           (send (get-contact-snip friendnumber) set-status 'away)
           (update-contact-status friendnumber 'away)]
          ; friend is busy
          [(= status (_TOX_USERSTATUS 'BUSY))
           (send (get-contact-snip friendnumber) set-status 'busy)
           (update-contact-status friendnumber 'busy)])))

(define on-connection-status-change
  (λ (mtox friendnumber status userdata)
    ; add a thingie that shows the friend is online
    (cond [(zero? status)
           (send (get-contact-snip friendnumber) set-status 'offline)
           (update-contact-status friendnumber 'offline)
           (when make-noise
             (play-sound (third sounds) #t))]
          [else
           (send (get-contact-snip friendnumber) set-status 'available)
           (update-contact-status friendnumber 'available)
           (when make-noise
             (play-sound (second sounds) #t))])))

; needs to be in its own thread, otherwise we'll d/c(?)
(define on-file-send-request
  (λ (mtox friendnumber filenumber filesize filename len userdata)
    (thread
     (λ ()
       (when make-noise
         (play-sound (seventh sounds) #t))
       (let* ([cd (get-contact-data friendnumber)]
              (mbox (message-box "Blight - File Send Request"
                                 (string-append
                                  (contact-data-name cd)
                                  " wants to send you "
                                  "\"" filename "\"")
                                 #f
                                 (list 'ok-cancel 'caution)))
              [window (contact-data-window cd)]
              
              [msg-history (send window get-msg-history)])
         (cond [(eq? mbox 'ok)
                
                (let ([path (put-file "Select a file"
                                      #f
                                      download-path
                                      filename)]
                      [window (get-contact-window friendnumber)])
                  (unless (false? path)
                    (define message-id (_TOX_FILECONTROL 'ACCEPT))
                    (define receive-editor
                      (send window get-receive-editor))
                    (send-file-control mtox friendnumber #t filenumber message-id #f 0)
                    (send window set-gauge-pos 0)
                    (rt-add! path filenumber)
                    (send msg-history
                          begin-recv-file path (get-time))))]))))))

(define on-file-control
  (λ (mtox friendnumber sending? filenumber control-type data-ptr len userdata)
    (let* ([window (get-contact-window friendnumber)]
           [receive-editor (send window get-receive-editor)]
           [fc-receiving-lb (send window get-fc-receiving-lb)]
           [fc-sending-lb (send window get-fc-sending-lb)]
           [msg-history (send window get-msg-history)]
           [update-fc-receiving (λ ()
                                  (send fc-receiving-lb set
                                        (sort (map (λ (x)
                                                     (number->string (car x)))
                                                   (hash->list rt))
                                              string<?)))]
           [update-fc-sending (λ ()
                                (send fc-sending-lb set
                                      (sort (map (λ (x)
                                                   (number->string (car x)))
                                                 (hash->list st))
                                            string<?)))])
      (with-handlers
          ([exn:blight:rtransfer?
            (lambda (ex)
              (blight-handle-exception ex)
              (send msg-history send-file-recv-error (exn-message ex)))])
        ; we've finished receiving the file
        (cond [(and (= control-type (_TOX_FILECONTROL 'FINISHED))
                    (false? sending?))
               (define data-bytes (make-sized-byte-string data-ptr len))
               (write-bytes data-bytes (rt-ref-fhandle filenumber))
               ; close receive transfer
               (close-output-port (rt-ref-fhandle filenumber))
               ; notify user transfer has completed
               (send msg-history
                     end-recv-file (get-time) (rt-ref-received filenumber))
               ; remove transfer from list
               (rt-del! filenumber)
               ; update file control receiving list box
               (update-fc-receiving)]
              ; cue that we're going to be sending the data now
              [(and (= control-type (_TOX_FILECONTROL 'ACCEPT)) sending?)
               ; update file control sending list box
               (update-fc-sending)
               (send window send-data filenumber)]
              [(= control-type (_TOX_FILECONTROL 'KILL))
               ; remove transfer from list
               (cond [sending?
                      (st-del! filenumber)
                      (update-fc-sending)]
                     [else
                      (close-output-port (rt-ref-fhandle filenumber))
                      (rt-del! filenumber)
                      (update-fc-receiving)])]
              ; resume sending file
              [(and (= control-type (_TOX_FILECONTROL 'RESUME_BROKEN)) sending?)
               (send window resume-data filenumber)]
              ; catch everything else and just update both of the list boxes
              [else
               (update-fc-receiving)
               (update-fc-sending)])))))

(define on-file-data
  (λ (mtox friendnumber filenumber data-ptr len userdata)
    
    (define data-bytes (make-sized-byte-string data-ptr len))
    (define window (get-contact-window friendnumber))
    (define msg-history (send window get-msg-history))
    
    (with-handlers
        ([exn:blight:rtransfer?
          (lambda (ex)
            (send msg-history send-file-recv-error (exn-message ex)))])
      (write-bytes data-bytes (rt-ref-fhandle filenumber))
      (set-rt-received! filenumber len)
      (send window set-gauge-pos
            (fl->exact-integer (truncate (* (exact->inexact
                                             (/ (rt-ref-received filenumber)
                                                len)) 100)))))))

; cannot be threaded, group adding will fail if threaded
(define on-group-invite
  (λ (mtox friendnumber type data len userdata)
    (let* ([friendname (get-contact-name friendnumber)]
           [mbox (message-box "Blight - Groupchat Invite"
                              (string-append friendname
                                             " has invited you to a groupchat!")
                              #f
                              (list 'ok-cancel 'caution))])
      (when (eq? mbox 'ok)
        ; cannot have its own thread
        ; audio.cpp, line 257
        (define join-av-cb
          (λ (mtox-cb grpnum peernum pcm samples channels sample-rate userdata)
            (let ([window (contact-data-window (hash-ref cur-groups grpnum))]
                  [alsource
                   (list-ref (contact-data-alsources
                              (hash-ref cur-groups grpnum)) peernum)])
                 (unless (send window speakers-muted?)
                   ;(call/cc
                   ;(λ (break)
                   #|(define lst (build-list (* 2 samples channels)
                                          (λ (i) (ptr-ref data-ptr _int16 i))))
                  ; convert the vector to an rsound
                  (define snd (vec->rsound (list->s16vector lst) sample-rate))
                  ; play the rsound
                  (play snd)|#
                   
                   #|(buffer-data albuf (if (= channels 1)
                                         AL_FORMAT_MONO16
                                         AL_FORMAT_STEREO16)
                               data sample-rate)
                  (set-source-buffer! alsource albuf)
                  (play-source alsource)|#
                   
                   ; the qtox way
                   ; threaded processed , queued 
                   ; unthreaded processed , queued 
                   #|(define processed (source-buffers-processed alsource))
                        (define queued (source-buffers-queued alsource))
                        (define albuf #f)
                        
                        (set-source-looping! alsource AL_FALSE)
                        
                        (printf "join-av-cb: processed: ~a, queued: ~a "
                                processed queued)
                        
                        (cond [(> processed 0)
                               (define albufs (make-list processed 0))
                               ;(define albufs (gen-sources processed))
                               ;(define albuf-ptr (malloc processed 'atomic))
                               ;(source-unqueue-buffers!! alsource processed albufs)
                               (source-unqueue-buffers! alsource albufs)
                               #;(define albufs (build-list processed
                                                                 (λ (i)
                                                                 (ptr-ref albuf-ptr _int i))))
                               (printf "albufs: ~a " albufs)
                               (delete-buffers! albufs)
                               (set! albuf (car (gen-sources 1)))
                               ;(set! albuf (car (gen-sources 1)))
                               (printf "albuf: ~a " albuf)]
                              [(< queued 16)
                               (set! albuf (car (gen-sources 1)))]
                              [else
                               (displayln "Audio: frame dropped.")
                               (break)])
                        
                        (buffer-data albuf
                                     (if (= channels 1)
                                         AL_FORMAT_MONO16
                                         AL_FORMAT_STEREO16)
                                     data
                                     sample-rate)
                        (source-queue-buffers! alsource (list albuf))
                        (define state (source-source-state alsource))
                        (printf "state: ~a~n" state)
                        
                        (unless (= state AL_PLAYING)
                          (play-source alsource))|#
                   
                   ; the libblight way (outsourced qtox way)
                   (play-audio-buffer alsource pcm samples channels sample-rate)
                   
                   (tox-do mtox-cb)
                   (sleep (/ (tox-do-interval mtox-cb) 1000))))))
        
        (define grp-number
          (cond [(= type (_TOX_GROUPCHAT_TYPE 'TEXT))
                 (join-groupchat mtox friendnumber data len)]
                [(= type (_TOX_GROUPCHAT_TYPE 'AV))
                 (join-av-groupchat mtox friendnumber data len join-av-cb)]))
        
        (cond [(= grp-number -1)
               (message-box "Blight - Groupchat Failure"
                            "Failed to add groupchat!"
                            #f
                            (list 'ok 'stop))]
              [else
               (printf "adding GC: ~a\n" grp-number)
               (flush-output)
               (do-add-group (format "Groupchat #~a" (hash-count cur-groups))
                             grp-number (_TOX_GROUPCHAT_TYPE 'AV))])))))

(define on-group-message
  (λ (mtox groupnumber peernumber message len userdata)
    (let* ([window (contact-data-window (hash-ref cur-groups groupnumber))]
           [name-buf (make-bytes TOX_MAX_NAME_LENGTH)]
           [len (get-group-peername! mtox groupnumber peernumber name-buf)]
           [name (bytes->string/utf-8 (subbytes name-buf 0 len))]
           [msg-history (send window get-msg-history)])
      (send msg-history add-recv-message my-name message name (get-time)))))

(define on-group-action
  (λ (mtox groupnumber peernumber action len userdata)
    (let* ([window (contact-data-window (hash-ref cur-groups groupnumber))]
           [name-buf (make-bytes TOX_MAX_NAME_LENGTH)]
           [len (get-group-peername! mtox groupnumber peernumber name-buf)]
           [msg-history (send window get-msg-history)]
           [name (bytes->string/utf-8 (subbytes name-buf 0 len))])
      
      (send msg-history add-recv-action action name (get-time)))))

(define on-group-title-change
  (λ (mtox groupnumber peernumber title len userdata)
    (let* ([window (contact-data-window (hash-ref cur-groups groupnumber))]
           [editor (send window get-receive-editor)]
           [gsnip (get-group-snip groupnumber)]
           [newtitle (bytes->string/utf-8 (subbytes title 0 len))])
      (unless (= -1 peernumber)
        (define name-buf (make-bytes TOX_MAX_NAME_LENGTH))
        (define len (get-group-peername! mtox groupnumber peernumber name-buf))
        (define name (bytes->string/utf-8 (subbytes name-buf 0 len)))
        (send editor insert (format "** [~a]: ~a has set the title to `~a'~n"
                                    (get-time) name newtitle)))
      (send gsnip set-status-msg newtitle)
      (send window set-new-label
            (format "Blight - Groupchat #~a: ~a" groupnumber newtitle)))))

(define on-group-namelist-change
  (λ (mtox groupnumber peernumber change userdata)
     (let* ([grp (hash-ref cur-groups groupnumber)]
            [group-window (contact-data-window grp)]
            [lbox (send group-window get-list-box)]
            [sources (contact-data-alsources grp)])
       (cond [(= change (_TOX_CHAT_CHANGE_PEER 'ADD))
              (define name-buf (make-bytes TOX_MAX_NAME_LENGTH))
              (define len (get-group-peername! mtox groupnumber peernumber name-buf))
              (define name (bytes->string/utf-8 (subbytes name-buf 0 len)))
              (send lbox append name)
              (send lbox set-label
                    (format "~a Peers" (get-group-number-peers mtox groupnumber)))
              ; add an al source
              (set-contact-data-alsources! grp (append sources (gen-sources 1)))]
             [(= change (_TOX_CHAT_CHANGE_PEER 'DEL))
              (send lbox delete peernumber)
              (send lbox set-label
                    (format "~a Peers" (get-group-number-peers mtox groupnumber)))
              ; delete an al source
              (let-values ([(h t) (split-at sources peernumber)])
                (delete-sources! (list (car t)))
                (set-contact-data-alsources! grp (append h (cdr t))))]
             [(= change (_TOX_CHAT_CHANGE_PEER 'NAME))
              (define name-buf (make-bytes TOX_MAX_NAME_LENGTH))
              (define len (get-group-peername! mtox groupnumber peernumber name-buf))
              (define name (bytes->string/utf-8 (subbytes name-buf 0 len)))
              (send lbox set-string peernumber name)]))))

(define on-avatar-info
  (λ (mtox friendnumber img-format img-hash userdata)
    ; if the img-format is 'NONE or the image hash isn't the right size,
    ; ignore the whole thing and do nothing
    (unless (or (= (_TOX_AVATAR_FORMAT 'NONE) img-format)
                (< (bytes-length img-hash) TOX_HASH_LENGTH))
      (let* ([window (contact-data-window (hash-ref cur-buddies friendnumber))]
             [friend-id (send window get-key)]
             [hash-file (build-path
                         avatar-dir
                         (string-append friend-id ".hash"))]
             [png-file (build-path
                        avatar-dir
                        (string-append friend-id ".png"))]
             [cropped-hash (subbytes img-hash 0 TOX_HASH_LENGTH)])
        ; check if we have the avatar already
        (cond [(and (file-exists? hash-file)
                    (file-exists? png-file))
               ; if they both exist, do nothing if the hashes are identical
               (unless (bytes=? (file->bytes hash-file #:mode 'binary) cropped-hash)
                 (displayln "The avatar's hash hash changed! Updating...")
                 ; request the avatar's data
                 (request-avatar-data mtox friendnumber)
                 ; update the hash file
                 (let ([hash-port-out (open-output-file hash-file
                                                        #:mode 'binary
                                                        #:exists 'truncate/replace)])
                   (write-bytes cropped-hash hash-port-out)
                   (close-output-port hash-port-out)))]
              [else
               (displayln "We got a new avatar! Saving information...")
               ; request the avatar's data
               (request-avatar-data mtox friendnumber)
               ; update the hash file
               (let ([hash-port-out (open-output-file hash-file
                                                      #:mode 'binary
                                                      #:exists 'truncate/replace)])
                 (write-bytes cropped-hash hash-port-out)
                 (close-output-port hash-port-out))])))))

(define on-avatar-data
  (λ (mtox friendnumber img-format img-hash data-ptr datalen userdata)
    (unless (= img-format (_TOX_AVATAR_FORMAT 'NONE))
      (let* ([window (contact-data-window (hash-ref cur-buddies friendnumber))]
             [friend-id (send window get-key)]
             [png-file (build-path
                        avatar-dir
                        (string-append friend-id ".png"))]
             [png-port-out (open-output-file png-file
                                             #:mode 'binary
                                             #:exists 'truncate/replace)]
             [data-bytes (make-sized-byte-string data-ptr datalen)])
        ; write to file
        (write-bytes data-bytes png-port-out 0 datalen)
        ; close the output port
        (close-output-port png-port-out)
        ; tell the buddy window to update the avatar
        (send window set-friend-avatar png-file)))))

(define on-typing-change
  (λ (mtox friendnumber typing? userdata)
    (let ([window (contact-data-window (hash-ref cur-buddies friendnumber))])
      (send window is-typing? typing?))))

; we are receiving a call, phone is ringing
(define on-audio-invite
  (λ (mav call-idx arg)
    (displayln 'on-audio-invite)
    (printf "agent: ~a call-idx: ~a arg: ~a~n"
            mav call-idx arg)
    (when make-noise
      (play-sound (ninth sounds) #t))
    ;(av-answer my-av call-idx my-csettings)
    #;(set-contact-data-pstream! (hash-ref cur-buddies call-idx) (make-pstream))))

; we are calling someone, phone is ringing
(define on-audio-ringing
  (λ (mav call-idx arg)
    (displayln 'on-audio-ringing)
    (printf "agent: ~a call-idx: ~a arg: ~a~n"
            mav call-idx arg)
    (when make-noise
      (play-sound (tenth sounds) #t))))

; call has connected, rtp transmission has started
(define on-audio-start
  (λ (mav call-idx arg)
    (displayln 'on-audio-start)
    (printf "agent: ~a call-idx: ~a arg: ~a~n"
            mav call-idx arg)
    #;(set-contact-data-pstream! (hash-ref cur-buddies call-idx) (make-pstream))))

; the side that initiated the call has canceled the invite
(define on-audio-cancel
  (λ (mav call-idx arg)
    (displayln 'on-audio-cancel)))

; the side that was invited rejected the call
(define on-audio-reject
  (λ (mav call-idx arg)
    (displayln 'on-audio-reject)))

; the call that was active has ended
(define on-audio-end
  (λ (mav call-idx arg)
    (displayln 'on-audio-end)
    #;(set-contact-data-pstream! (hash-ref cur-buddies call-idx) #f)))

; when the request didn't get a response in time
(define on-audio-request-timeout
  (λ (mav call-idx arg)
    (displayln 'on-audio-request-timeout)))

; peer timed out, stop the call
(define on-audio-peer-timeout
  (λ (mav call-idx arg)
    (displayln 'on-audio-peer-timeout)))

; peer changed csettings. prepare for changed av
(define on-audio-peer-cschange
  (λ (mav call-idx arg)
    (displayln 'on-audio-peer-cschange)))

; csettings change confirmation. once triggered, peer will be ready
; to receive changed av
(define on-audio-self-cschange
  (λ (mav call-idx arg)
    (displayln 'on-audio-self-cschange)))

; we are receiving audio
(define on-audio-receive
  (λ (mav call-idx pcm size data)
    (displayln 'on-audio-receive)
    (printf "on-audio-receive: agent: ~a call-idx: ~a pcm: ~a size: ~a data: ~a~n"
            mav call-idx pcm size data)
    (define snd (rsound pcm 0 size 48000))
    (play snd)))
#| ################# END CALLBACK PROCEDURE DEFINITIONS ################# |#

#|
join-av-groupchat: grpnum: 0 peernum: 2
join-av-groupchat: pcm:  samples: 2880
channels: 2 sample-rate: 48000
|#

; register our callback functions
(callback-friend-request my-tox on-friend-request)
(callback-friend-message my-tox on-friend-message)
(callback-friend-action my-tox on-friend-action)
(callback-name-change my-tox on-friend-name-change)
(callback-user-status my-tox on-status-type-change)
(callback-connection-status my-tox on-connection-status-change)
(callback-file-send-request my-tox on-file-send-request)
(callback-file-control my-tox on-file-control)
(callback-file-data my-tox on-file-data)
(callback-group-invite my-tox on-group-invite)
(callback-group-message my-tox on-group-message)
(callback-group-action my-tox on-group-action)
(callback-group-title my-tox on-group-title-change)
(callback-group-namelist-change my-tox on-group-namelist-change)
(callback-avatar-info my-tox on-avatar-info)
(callback-avatar-data my-tox on-avatar-data)
(callback-typing-change my-tox on-typing-change)
(callback-callstate my-av on-audio-invite (_ToxAvCallbackID 'Invite))
(callback-callstate my-av on-audio-ringing (_ToxAvCallbackID 'Ringing))
(callback-callstate my-av on-audio-start (_ToxAvCallbackID 'Start))
(callback-callstate my-av on-audio-cancel (_ToxAvCallbackID 'Cancel))
(callback-callstate my-av on-audio-reject (_ToxAvCallbackID 'Reject))
(callback-callstate my-av on-audio-end (_ToxAvCallbackID 'End))
(callback-callstate my-av on-audio-request-timeout (_ToxAvCallbackID 'RequestTimeout))
(callback-callstate my-av on-audio-peer-timeout (_ToxAvCallbackID 'PeerTimeout))
(callback-callstate my-av on-audio-peer-cschange (_ToxAvCallbackID 'PeerCSChange))
(callback-callstate my-av on-audio-self-cschange (_ToxAvCallbackID 'SelfCSChange))
(callback-audio-recv my-av on-audio-receive)

#| ################# BEGIN REPL SERVER ################# |#
; code straight tooken from rwind
; https://github.com/Metaxal/rwind
(define-namespace-anchor server-namespace-anchor)

(define server-namespace (namespace-anchor->namespace server-namespace-anchor))

(define (start-blight-repl [continuous? #t])
  (dprint-wait "Opening listener")
  (define listener (tcp-listen blight-tcp-port 4 #t "127.0.0.1"))
  (dprint-ok)
  (dynamic-wind
   void
   (λ ()
     (let accept-loop ()
       (dprint-wait "Waiting for client")
       (define-values (in out) (tcp-accept/enable-break listener))
       (printf "Client is connected.\n")
       (dynamic-wind
        void
        (λ ()
          (dprint-wait "Waiting for data")
          (for ([e (in-port read in)]
                #:break (equal? e '(exit)))
            (printf "Received ~a\n" e)
            ; if it fails, simply return the message
            (with-handlers ([exn:fail? (λ (e)
                                         (define res (exn-message e))
                                         (dprintf "Sending exception: ~a" res)
                                         (write-data/flush res out))])
              (define res
                (begin
                  (dynamic-wind
                   void
                   (λ ()
                     (with-output-to-string
                      (λ ()
                        (define r (eval e server-namespace))
                        (unless (void? r)
                          (write r)))))
                   void)))
              (dprint-wait "Sending value: ~a" res)
              ; Printed in a string, to send a string,
              ; because the reader cannot read things like #<some-object>
              (write-data/flush res out))
            (dprint-ok)
            (dprint-wait "Waiting for data")))
        (λ ()
          (dprintf "Closing connection.\n")
          (close-input-port in)
          (close-output-port out)
          (when continuous?
            (accept-loop))))))
   ; out
   (λ ()
     (dprint-wait "Closing listener")
     (tcp-close listener)
     (dprint-ok))))

(define repl-thread #f)

(define (init-repl)
  ;; Start the server
  (set! repl-thread
        (parameterize ([debug-prefix "Srv: "])
          (thread start-blight-repl))))

(define (exit-repl)
  ; Call a break so that dynamic-wind can close the ports and the listener
  ;(break-thread server-thread)
  (kill-thread repl-thread))
#| ################# END REPL SERVER ################# |#

(define cur-ctx (tox-ctx my-tox my-id-bytes clean-up))

(define (blight-handle-exception unexn)
  (let ([res (show-error-unhandled-exn unexn cur-ctx)])
    (when (eq?  res 'quit)
      (clean-up)
      (exit))))

; tox loop that only uses tox-do and sleeps for some amount of time
(define tox-loop-thread
  (thread
   (λ ()
     (let loop ()
       (call-with-exception-handler
        (λ (exn) (blight-handle-exception exn))
        (λ () (tox-do my-tox)))
       
       (sleep (/ (tox-do-interval my-tox) 1000))
       (loop)))))

; tox av loop
(define av-loop-thread
  (thread
   (λ ()
     (let loop ()
       (call-with-exception-handler
        (λ (exn) (blight-handle-exception exn))
        (λ () (toxav-do my-av)))
       
       (sleep (/ (toxav-do-interval my-av) 1000))
       (loop)))))

; start REPL server
(init-repl)
