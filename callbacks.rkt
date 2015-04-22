#lang racket/gui
; callbacks.rkt
(require libtoxcore-racket
         libopenal-racket
         ffi/unsafe
         "audio.rkt"
         "blight.rkt"
         "config.rkt"
         "helpers.rkt"
         "history.rkt"
         "tox.rkt"
         "utils.rkt"
         "gui/chat.rkt"
         "gui/frame.rkt"
         "gui/friend-list.rkt"
         "gui/msg-history.rkt"
         "gui/smart-list.rkt")

(provide on-friend-status)

#| ################# START CALLBACK PROCEDURE DEFINITIONS ################# |#

; TODO:
; self-connection-status indicator of our connection status
; on-friend-read-receipt

; set all the callback functions
(define on-self-connection-status
  (λ (mtox connection-status userdata)
    (cond [(= connection-status (_TOX_CONNECTION 'NONE))
           (displayln "We're not connected to the network right now.")]
          [(= connection-status (_TOX_CONNECTION 'TCP))
           (displayln "We're connected to the network via TCP.")]
          [(= connection-status (_TOX_CONNECTION 'UDP))
           (displayln "We're connected to the network via UDP.")])))

(define on-friend-request
  (λ (mtox public-key message message-len userdata)
    (unless (>= (bytes-length public-key) TOX_ADDRESS_SIZE)
      ; make sure public-key is the correct size...
      (define pubkey (subbytes public-key 0 TOX_ADDRESS_SIZE))
      ; convert pubkey from bytes to string so we can display it
      (define id-hex (bytes->hex-string pubkey))
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
                (display "Adding friend... ")
                (define result (friend-add-norequest mtox pubkey))
                (define friendnumber (first result))
                (define err (bytes-ref (second result) 0))
                
                ; reused code to add friend on success
                (define (add-friend-success)
                  ; play a sound because we accepted
                  (when (make-noise)
                    (play-sound (sixth sounds) #f))
                  (printf "Added friend number ~a~n" friendnumber)
                  ; append new friend to the list
                  (create-buddy (format-anonymous id-hex)
                                (friend-key my-tox friendnumber))
                  
                  ; update friend list
                  ; add connection status icons to each friend
                  (for ([i (self-friend-list-size mtox)])
                    (status-checker i (first (friend-connection-status mtox i))))
                  ; the invite list needs to be updated for
                  ; the groupchat windows that still exist
                  (unless (zero? (hash-count cur-groups))
                    (update-invite-list))
                  ; save the tox data
                  (blight-save-data))
                
                ; catch errors
                (cond [(= err (_TOX_ERR_FRIEND_ADD 'OK)) (add-friend-success)]
                      [else
                       (display "There was an error accepting the friend request! ")
                       ; if we've failed, try again 3(?) more times
                       (let loop ([tries 0])
                         (cond [(= tries 3)
                                (displayln "Failed!")
                                (when (make-noise)
                                  (play-sound (last sounds) #t))]
                               [else
                                (display "Retrying... ")
                                (iterate mtox)
                                (sleep (/ (iteration-interval mtox) 1000))
                                (if (= (bytes-ref
                                        (second (friend-add-norequest mtox pubkey))
                                        0)
                                       (_TOX_ERR_FRIEND_ADD 'OK))
                                    (begin
                                      (displayln "Success!")
                                      (add-friend-success))
                                    (loop (add1 tries)))]))])
                (send fr-dialog show #f))]))
      
      (send fr-text insert (string-append
                            id-hex
                            "\nwould like to add you as a friend!\n"
                            "Message: " message))
      (send fr-dialog show #t))))

; message is a string
(define on-friend-message
  (λ (mtox friendnumber type message len userdata)
    (unless (zero? (string-length message))
      (let* ([window (get-contact-window friendnumber)]
             [msg-history (send window get-msg-history)]
             [name (send window get-name)])
        ; if the window isn't open, force it open
        (cond [(not (send window is-shown?)) (send window show #t)])
        
        (if (= type (_TOX_MESSAGE_TYPE 'NORMAL))
            (send msg-history add-recv-message (my-name) message name (get-time))
            (send msg-history add-recv-action message name (get-time)))
        
        ; make a noise
        (when (make-noise)
          (play-sound (first sounds) #t))
        ; add message to the history database
        (if (= type (_TOX_MESSAGE_TYPE 'NORMAL))
            (add-history (my-id-hex) (send window get-key) message 0)
            (add-history (my-id-hex) (send window get-key)
                         (string-append "ACTION: " message) 0))))))

(define on-friend-name
  (λ (mtox friendnumber newname newname-len userdata)
    (let ([sn (get-contact-snip friendnumber)])
      (send sml rename-entry sn newname))
    
    (let ([window (get-contact-window friendnumber)])
      ; update the name in the list
      (send window set-name newname)
      ; update the name in the window
      (send window set-new-label (string-append "Blight - " newname))
      ; add connection status icon
      (status-checker friendnumber (first (friend-connection-status mtox friendnumber))))))

(define on-friend-status-message
  (λ (mtox friendnumber status-message message-len userdata)
    ; from friend-list
    (update-contact-status-msg friendnumber status-message)))

(define on-friend-status
  (λ (mtox friendnumber status userdata)
    ; friend is online
    (cond [(= status (_TOX_USER_STATUS 'NONE))
           (send (get-contact-snip friendnumber) set-status 'available)
           (update-contact-status friendnumber 'available)]
          ; friend is away
          [(= status (_TOX_USER_STATUS 'AWAY))
           (send (get-contact-snip friendnumber) set-status 'away)
           (update-contact-status friendnumber 'away)]
          ; friend is busy
          [(= status (_TOX_USER_STATUS 'BUSY))
           (send (get-contact-snip friendnumber) set-status 'busy)
           (update-contact-status friendnumber 'busy)])))

(define on-friend-connection-status-change
  (λ (mtox friendnumber status userdata)
    ; add a thingie that shows the friend is online
    (cond [(zero? status)
           (send (get-contact-snip friendnumber) set-status 'offline)
           (update-contact-status friendnumber 'offline)
           (when (make-noise)
             (play-sound (third sounds) #t))]
          [else
           (send (get-contact-snip friendnumber) set-status 'available)
           (update-contact-status friendnumber 'available)
           (when (make-noise)
             (play-sound (second sounds) #t))])))

; a control action has been applied to a file transfer
(define on-file-recv-control
  (λ (mtox friendnumber filenumber control-type userdata)
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
        ; cue that we're going to be sending the data now
        (cond [(= control-type (_TOX_FILE_CONTROL 'RESUME))
               ; update file control sending list box
               (update-fc-sending)
               (send window send-data filenumber)]
              ; the transfer has been canceled, close everything up
              [(= control-type (_TOX_FILE_CONTROL 'CANCEL))
               ; remove transfer from list
               (close-output-port (rt-ref-fhandle filenumber))
               (rt-del! filenumber)
               (update-fc-receiving)]
              ; catch everything else and just update both of the list boxes
              [else
               (update-fc-receiving)
               (update-fc-sending)])))))

; our friend is requesting we send them a chunk of data
(define on-file-chunk-request
  (λ (mtox friendnumber filenumber position chunk-len userdata)
    (let* ([window (get-contact-window friendnumber)]
           [fc-sending-lb (send window get-fc-sending-lb)]
           [update-fc-sending (λ ()
                                (send fc-sending-lb set
                                      (sort (map (λ (x)
                                                   (number->string (car x)))
                                                 (hash->list st))
                                            string<?)))])
      (cond
        ; the transfer is complete, close transfer stuff
        [(zero? chunk-len) (st-del! filenumber) (update-fc-sending)]
        ; otherwise, send the chunk and update our position
        [else (file-send-chunk friendnumber filenumber position (st-ref-sent filenumber))
              (set-st-sent! filenumber position)]))))

; our friend wants to send us data
; needs to be in its own thread, otherwise we'll d/c(?)
; perhaps, instead of identifying file transfers by filenumber,
; they are identified by file-id
; (define fid (file-id mtox friendnumber filenumber))
(define on-file-recv
  (λ (mtox friendnumber filenumber kind filesize filename fname-len userdata)
    (thread
     (λ ()
       (when (and (= kind (_TOX_FILE_KIND 'DATA)) (make-noise))
         (play-sound (seventh sounds) #t))
       (if (= kind (_TOX_FILE_KIND 'DATA))
           ; regular data
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
             (cond
               [(eq? mbox 'ok)
                (let ([path (put-file "Select a file"
                                      #f
                                      download-path
                                      filename)]
                      [window (get-contact-window friendnumber)])
                  (unless (false? path)
                    (define control-id (_TOX_FILE_CONTROL 'RESUME))
                    (define receive-editor
                      (send window get-receive-editor))
                    (file-control mtox friendnumber filenumber control-id)
                    (send window set-gauge-pos 0)
                    (rt-add! path filenumber)
                    (send msg-history
                          begin-recv-file path (get-time))))]
               [else (file-control mtox friendnumber filenumber (_TOX_FILE_CONTROL 'CANCEL))]))
           ; auto-accept avatar data
           ; the name of the avatar is friend-public-key.ext
           (unless (false? filename)
             (let* ([window (contact-data-window (hash-ref cur-buddies friendnumber))]
                    [friend-id (send window get-key)]
                    [ext (bytes->string/utf-8 (filename-extension filename))]
                    ;[hash-file (build-path avatar-dir (string-append friend-id ".hash"))]
                    [avatar-path (build-path avatar-dir (string-append friend-id "." ext))])
               ;[img-hash (tox-hash mtox )
               #|(cond [(and (file-exists? hash-file) (file-exists png-file))
                    ; if both files exist and their hashes are identical, do nothing
                    (unless (bytes=? (file->bytes hash-file #:mode 'binary)|#
               (rt-add! avatar-path filenumber)
               (file-control mtox friendnumber filenumber (_TOX_FILE_CONTROL 'RESUME)))))))))

#;(define on-avatar-recv
    (λ (mtox friendnumber filename)
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
                 (close-output-port hash-port-out))]))))

; our friend has sent us a chunk of data
(define on-file-recv-chunk
  (λ (mtox friendnumber filenumber position chunk chunk-len userdata)
    (define window (get-contact-window friendnumber))
    (define msg-history (send window get-msg-history))
    
    (with-handlers
        ([exn:blight:rtransfer?
          (lambda (ex)
            (send msg-history send-file-recv-error (exn-message ex)))])
      (write-bytes chunk (rt-ref-fhandle filenumber))
      (set-rt-received! filenumber position)
      (send window set-gauge-pos
            (fl->exact-integer (truncate (* (exact->inexact
                                             (/ (rt-ref-received filenumber)
                                                chunk-len)) 100)))))))

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
                (call/cc
                 (λ (break)
                   ; my daft OpenAL test way
                   ; lots of static and clicking, nothing intelligible
                   #|(displayln 'on-av-cb)
                      (define albuf (car (gen-buffers 1)))
                      
                      (buffer-data albuf (if (= channels 1)
                                             AL_FORMAT_MONO16
                                             AL_FORMAT_STEREO16)
                                   pcm sample-rate)
                      ;(set-source-buffer! alsource albuf)
                      (source-queue-buffers! alsource (list albuf))
                      (play-source alsource)
                      (delete-buffers! (list albuf))|#
                   
                   ; the qtox way
                   ; is this making things segfault?
                   (define processed (source-buffers-processed alsource))
                   (define queued (source-buffers-queued alsource))
                   (define albuf #f)
                   
                   (set-source-looping! alsource AL_FALSE)
                   
                   (printf "join-av-cb: processed: ~a, queued: ~a "
                           processed queued)
                   
                   (cond [(not (zero? processed))
                          (define albufs (make-list processed 0))
                          ;(define albufs (gen-sources processed))
                          ;(define albuf-ptr (malloc processed 'atomic))
                          (define unqbufs (source-unqueue-buffers!! alsource processed albufs))
                          ;(source-unqueue-buffers! alsource albufs)
                          (printf "albufs: ~s unqbufs: ~s " albufs unqbufs)
                          (delete-buffers! unqbufs)
                          (set! albuf (car unqbufs))
                          (printf "albuf: ~a " albuf)]
                         [(< queued 16)
                          (set! albuf (car (gen-buffers 1)))
                          (printf "albuf: ~a " albuf)]
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
                     (play-source alsource))
                   
                   ; the libblight way (outsourced qtox way)
                   ; proven to work, but outsourced C library is soooo duuuuumb
                   ;(play-audio-buffer alsource pcm samples channels sample-rate)
                   
                   (iterate mtox-cb)
                   (sleep (/ (iteration-interval mtox-cb) 1000))))))))
        
        (define grp-number
          (cond [(= type (_TOX_GROUPCHAT_TYPE 'TEXT))
                 (join-groupchat mtox friendnumber data len)]
                [(= type (_TOX_GROUPCHAT_TYPE 'AV))
                 (join-av-groupchat mtox friendnumber data len join-av-cb)]))
        
        (cond [(false? grp-number)
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
           [name-bytes (group-peername mtox groupnumber peernumber)]
           [name (bytes->string/utf-8 name-bytes)]
           [msg-history (send window get-msg-history)])
      (send msg-history add-recv-message (my-name) message name (get-time)))))

(define on-group-action
  (λ (mtox groupnumber peernumber action len userdata)
    (let* ([window (contact-data-window (hash-ref cur-groups groupnumber))]
           [name-bytes (group-peername mtox groupnumber peernumber)]
           [msg-history (send window get-msg-history)]
           [name (bytes->string/utf-8 name-bytes)])
      
      (send msg-history add-recv-action action name (get-time)))))

(define on-group-title-change
  (λ (mtox groupnumber peernumber title len userdata)
    (let* ([window (contact-data-window (hash-ref cur-groups groupnumber))]
           [editor (send window get-receive-editor)]
           [gsnip (get-group-snip groupnumber)]
           [newtitle (bytes->string/utf-8 (subbytes title 0 len))])
      (unless (= -1 peernumber)
        (define name-bytes (group-peername mtox groupnumber peernumber))
        (define name (bytes->string/utf-8 name-bytes))
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
             (define name-bytes (group-peername mtox groupnumber peernumber))
             (define name (bytes->string/utf-8 name-bytes))
             (send lbox append name)
             (send lbox set-label
                   (format "~a Peers" (group-number-peers mtox groupnumber)))
             ; add an al source
             (unless (false? sources)
               (set-contact-data-alsources! grp (append sources (gen-sources 1))))]
            [(= change (_TOX_CHAT_CHANGE_PEER 'DEL))
             (send lbox delete peernumber)
             (send lbox set-label
                   (format "~a Peers" (group-number-peers mtox groupnumber)))
             ; delete an al source
             (unless (false? sources)
               (let-values ([(h t) (split-at sources peernumber)])
                 (delete-sources! (list (car t)))
                 (set-contact-data-alsources! grp (append h (cdr t)))))]
            [(= change (_TOX_CHAT_CHANGE_PEER 'NAME))
             (define name-bytes (group-peername mtox groupnumber peernumber))
             (define name (bytes->string/utf-8 name-bytes))
             (send lbox set-string peernumber name)]))))

(define on-friend-typing
  (λ (mtox friendnumber typing? userdata)
    (let ([window (contact-data-window (hash-ref cur-buddies friendnumber))])
      (send window is-typing? typing?))))

(define on-friend-read-receipt
  (λ (mtox friendnumber message-id userdata)
    ;(let ([window (contact-data-window (hash-ref cur-buddies friendnumber))])
    (printf "on-friend-read-receipt: friend ~a received message ~a\n"
            friendnumber message-id)))

; we are receiving a call, phone is ringing
(define on-audio-invite
  (λ (mav call-index arg)
    (displayln 'on-audio-invite)
    (printf "agent: ~a call-index: ~a arg: ~a~n"
            mav call-index arg)
    (when (make-noise)
      (play-sound (ninth sounds) #t))
    (av-answer my-av call-index my-csettings)))

; we are calling someone, phone is ringing
(define on-audio-ringing
  (λ (mav call-index arg)
    (displayln 'on-audio-ringing)
    (printf "agent: ~a call-index: ~a arg: ~a~n"
            mav call-index arg)
    (when (make-noise)
      (play-sound (tenth sounds) #t))))

; helper procedure to prepare our call
; type is ignored at the moment
(define prepare-call
  (λ (mav call-index friend-id csettings type)
    (debug-prefix "Audio: ")
    (dprintf "Preparing call ~a~n" call-index)
    (do-add-call call-index friend-id csettings type)))

; call has connected, rtp transmission has started
(define on-audio-start
  (λ (mav call-index arg)
    (let ([friend-id (get-peer-id mav call-index 0)])
      (unless (< friend-id 0)
        (define peer-csettings (get-peer-csettings mav call-index friend-id))
        (cond [(negative? (first peer-csettings))
               (debug-prefix "Audio: ")
               (dprintf "Problem starting audio; error code ~a~n" peer-csettings)]
              [else
               (prepare-call mav call-index friend-id
                             (second peer-csettings) (first peer-csettings))])))))

; the side that initiated the call has canceled the invite
(define on-audio-cancel
  (λ (mav call-index arg)
    (displayln 'on-audio-cancel)
    (debug-prefix "Audio: ")
    (dprintf "Call ~a cancelled.~n" call-index)))

; the side that was invited rejected the call
(define on-audio-reject
  (λ (mav call-index arg)
    (displayln 'on-audio-reject)
    (debug-prefix "Audio: ")
    (dprintf "Call ~a rejected.~n" call-index)))

; the call that was active has ended
(define on-audio-end
  (λ (mav call-index arg)
    (displayln 'on-audio-end)
    (debug-prefix "Audio: ")
    (dprintf "Deleting call ~a.~n" call-index)
    (do-delete-call call-index)))

; when the request didn't get a response in time
(define on-audio-request-timeout
  (λ (mav call-index arg)
    (displayln 'on-audio-request-timeout)))

; peer timed out, stop the call
(define on-audio-peer-timeout
  (λ (mav call-index arg)
    (displayln 'on-audio-peer-timeout)
    (debug-prefix "Audio: ")
    (dprintf "Peer timeout, deleting call ~a.~n" call-index)
    (do-delete-call call-index)))

; peer changed csettings. prepare for changed av
(define on-audio-peer-cschange
  (λ (mav call-index arg)
    (displayln 'on-audio-peer-cschange)))

; csettings change confirmation. once triggered, peer will be ready
; to receive changed av
(define on-audio-self-cschange
  (λ (mav call-index arg)
    (displayln 'on-audio-self-cschange)))

; we are receiving audio
(define on-audio-receive
  (λ (mav call-index pcm size data)
    (displayln 'on-audio-receive)
    (printf "on-audio-receive: agent: ~a call-index: ~a pcm: ~a size: ~a data: ~a~n"
            mav call-index pcm size data)))
#| ################# END CALLBACK PROCEDURE DEFINITIONS ################# |#

; register our callback functions
(callback-self-connection-status my-tox on-self-connection-status)
(callback-friend-request my-tox on-friend-request)
(callback-friend-message my-tox on-friend-message)
(callback-friend-name my-tox on-friend-name)
(callback-friend-status-message my-tox on-friend-status-message)
(callback-friend-status my-tox on-friend-status)
(callback-friend-connection-status my-tox on-friend-connection-status-change)
(callback-file-recv-control my-tox on-file-recv-control)
(callback-file-chunk-request my-tox on-file-chunk-request)
(callback-file-recv my-tox on-file-recv)
(callback-file-recv-chunk my-tox on-file-recv-chunk)
(callback-group-invite my-tox on-group-invite)
(callback-group-message my-tox on-group-message)
(callback-group-action my-tox on-group-action)
(callback-group-title my-tox on-group-title-change)
(callback-group-namelist-change my-tox on-group-namelist-change)
(callback-friend-typing my-tox on-friend-typing)
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
