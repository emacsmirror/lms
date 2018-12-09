;;; lms.el --- Squeezebox / Logitech Media Server frontend

;; Copyright (C) 2017 Free Software Foundation, Inc.
;; Time-stamp: <2018-12-09 17:52:38 inigo>

;; Author: Iñigo Serna <inigoserna@gmail.com>
;; URL: https://bitbucket.com/inigoserna/lms.el
;; Version: 0.9
;; Package-Requires: ((emacs "25.1"))
;; Keywords: multimedia

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; `lms.el' is a frontend for Squeezebox / Logitech Media Server.
;;
;; More information on what a "squeezebox controller" is at
;; https://inigo.katxi.org/blog/2017/07/31/lms_el.html
;;
;; Quick instructions: customize some basic parameters `lms-hostname',
;; `lms-telnet-port', `lms-html-port', `lms-username', `lms-password'
;; and run it with `lms-ui'.
;; Then, you could read complete documentation after pressing 'h' key.

;;; Major updates:

;; 2017/07/29 Initial version.
;; 2018/12/09 Added library browsing features.

;;; TODO:
;; . virtual library: library_id
;; . search:
;;   . click (artist, album, year)
;;   . b: browse (artist, album, year, genre)
;;   . /, C-s: search by
;;   . random album
;;   . r: random mix by (song, album, artist, year, genre)
;;
;; Doubts:
;; . mode key map with no inherited key bindings


;;; Code:
(require 'seq)
(require 'subr-x)
(require 'org)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Customization
(defgroup lms nil
  "MyNewspaper."
  :group 'multimedia)

(defcustom lms-hostname "localhost"
  "Logitech Media Server hostname or ip."
  :type 'string
  :group 'lms)

(defcustom lms-telnet-port 9090
  "Logitech Media Server telnet port."
  :type 'string
  :group 'lms)

(defcustom lms-html-port 80
  "Logitech Media Server www port."
  :type 'string
  :group 'lms)

(defcustom lms-username nil
  "Logitech Media Server username or nil."
  :type 'string
  :group 'lms)

(defcustom lms-password nil
  "Logitech Media Server password or nil."
  :type 'string
  :group 'lms)

(defcustom lms-default-player nil
  "Name of default player.  F.e. Squeezebox."
  :type 'string
  :group 'lms)

(defcustom lms-ui-cover-width 400
  "Cover image width."
  :type 'integer
  :group 'lms)

(defcustom lms-ui-update-interval nil
  "Time in seconds between UI updates.  Default nil, disabled.
Note that small values could freeze your Emacs use while refreshing window."
  :type 'integer
  :group 'lms)


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; Core

;;;;; Module internal variables
(defvar lms-process-name "LMS"
  "LMS process name.")

(defvar lms-buffer-name "*lms*"
  "LMS buffer name.")

(defvar lms--process nil
  "LMS process.")

(defvar lms--results nil
  "Internal LMS communications results list.")

(defvar lms--players nil
  "List of cached players.")

(defvar lms--default-playerid nil
  "Internal default player playerid.")

(defvar lms--temp nil
  "Internal string buffer for communications with LMS server.")

(defvar lms--ui-timer nil
  "LMS UI upgrade timer.")

(defvar lms--ui-last-id nil
  "LMS UI last track id shown in Playing Now.")

(defvar lms--ui-last-time nil
  "LMS UI last track time shown in Playing Now.")


;;;;; Auxiliar internal functions
(defun split-string-with-max (string delimiter max)
  "Split STRING by DELIMITER, returning no more than MAX substrings."
  (let* ((tmp (split-string string delimiter))
         (lst (seq-take tmp (1- max))))
    (add-to-list 'lst (string-join (seq-drop tmp (1- max)) delimiter) t)
    (seq-filter #'(lambda (x) (not (string-empty-p x))) lst)))

(defun lms--handle-server-reply (process content)
  "Gets invoked whenever the server PROCESS sends data CONTENT to the client."
  (setq lms--temp (concat lms--temp content))
  (when (string= (substring lms--temp -1) "\n")
    (push (string-trim lms--temp) lms--results)
    (setq lms--temp nil)))

(defun lms--sentinel-function (process event)
  "Gets called when the status of the network connection PROCESS change with EVENT."
  (message "LMS: %s" (string-trim (format "%S" event))))

(defun lms--running-status ()
  "Return LMS process status as string, or nil if not running."
  (let ((st (and lms--process (process-status lms--process))))
    (when st
      (string-trim (format "%S" st)))))

(defun lms--send-command (cmd)
  "Send command CMD to LMS."
  (process-send-string lms--process (concat cmd "\n")))

(defun lms--send-command-get-response (cmd)
  "Send command CMD to LMS and get response."
  (lms--send-command cmd)
  (when (string-suffix-p "?" cmd)
    (setq cmd (substring cmd 0 -1)))
  ;; LMS returns : char encoded
  (setq cmd (replace-regexp-in-string ":" "%3A" cmd))
  ;; LMS returns !'() chars not encoded
  (dolist (x '(("%21" . "!") ("%27" . "'") ("%28" . "(") ("%29" . ")")))
    (setq cmd (replace-regexp-in-string (car x) (cdr x) cmd)))
  (let* ((continue t)
         data)
    (while continue
      (setq data (pop lms--results))
      (if (string-prefix-p cmd data)
          (setq continue nil)
        (push data lms--results)
        (sleep-for .1)))
    (string-trim (string-remove-prefix cmd data))))

(defun lms--build-list-from-string-attrs (buf attrs)
  "Return a list of plist from BUF string and ATTRS."
  (let* (results
         (build-plist (lambda (attrs)
                       (let (tmp)
                         (dolist (a attrs tmp)
                           (setq tmp (append tmp (list (intern a) nil)))))))
         (vars (funcall build-plist attrs))
         (buf (substring buf (string-match (car attrs) buf))))
    (dolist (e (split-string buf))
      (dolist (attr attrs)
        (when (string-prefix-p attr e) ; found a valid attr
          (when (plist-get vars (intern attr)) ; element with same attr already exists -> new bundle
            (add-to-list 'results vars)
            (setq vars (funcall build-plist attrs)))
          (plist-put vars (intern attr) (cadr (split-string e "%3A"))))))
    (add-to-list 'results vars)
    (reverse results)))


;;;;; Players
(defun lms-get-players (&optional force-populate)
  "Return players from internal variable or ask server if FORCE-POPULATE is t."
  (if (and lms--players (not force-load-messages))
      lms--players
    (let* ((numplayers (string-to-number (lms--send-command-get-response "player count ?")))
           (cmd (format "players 0 %d" numplayers))
           (data (split-string (lms--send-command-get-response cmd)))
           players player)
      (unless (string= (car data) (url-hexify-string (format "count:%d" numplayers)))
        (error "LMS: undefined number of players"))
      (dolist (l (cdr data))
        (let* ((pair (split-string-with-max l "%3A" 2)) ; :-char
               (k (intern (url-unhex-string (car pair))))
               (v (url-unhex-string (cadr pair))))
          (when (and player (string= (car pair) "playerindex"))
            (push player players)
            (setq player nil))
          (setq player (plist-put player k v))))
      (when player
        (push player players))
      (reverse players))))

(defun lms-get-players-name ()
  "Get players name as a list."
  (mapcar (lambda (p) (plist-get p 'name)) (lms-get-players)))

(defun lms-get-playerid-from-name (name)
  "Get playerid from player NAME."
  (let ((players (lms-get-players))
        (playerid))
    (dolist (p players playerid)
      (when (string= (plist-get p 'name) name)
        (setq playerid (plist-get p 'playerid))))))

(defun lms-get-playername-from-id (playerid)
  "Get player name from PLAYERID."
  (let ((players (lms-get-players))
        (playername))
    (dolist (p players playername)
      (when (string= (plist-get p 'playerid) playerid)
        (setq playername (plist-get p 'name))))))

(defun lms-select-player-by-name (name)
  "Select player by NAME."
  (if (seq-some (lambda (x) (string= x name)) (lms-get-players-name))
      (setq lms--default-playerid (lms-get-playerid-from-name name))
    (error "LMS: No player found with '%s' name" name)))


;;;;; Connect / Quit
(defun lms-connect ()
  "Connect to LMS host."
  (interactive)
  (setq lms--results nil)
  (lms-quit)
  (ignore-errors
    (setq lms--process (open-network-stream lms-process-name lms-buffer-name
                                            lms-hostname lms-telnet-port)))
  (unless (processp lms--process)
    (error "ERROR: Can't connect to LMS server. Please verify you have customized hostname, port and credentials."))
  (set-process-coding-system lms--process 'utf-8 'utf-8)
  (set-process-filter lms--process 'lms--handle-server-reply)
  (set-process-sentinel lms--process 'lms--sentinel-function)
  (when (and lms-username lms-password)
    (lms--send-command (format "login %s %s" lms-username lms-password)))
  (setq lms--players (lms-get-players t))
  (setq lms--default-playerid (lms-get-playerid-from-name
                               (if (seq-some (lambda (x) (string= x lms-default-player)) (lms-get-players-name))
                                   lms-default-player
                                 nil)))
  (message "Connected to LMS server %s:%d, default player: %s" lms-hostname lms-telnet-port
           (if lms--default-playerid lms-default-player "[None selected]")))

(defun lms-quit ()
  "Quit LMS connection and close buffer."
  (interactive)
  (when lms--ui-timer
    (cancel-timer lms--ui-timer))
  (when (process-live-p lms--process)
    (delete-process lms--process)
    (when (bufferp lms-buffer-name)
      (kill-buffer lms-buffer-name))
    (setq lms--process nil)))


;;;;; Power
(defun lms-player-toggle-power (&optional playerid)
  "Toggle power for PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (message "LMS: toggle power for player '%s'" (lms-get-playername-from-id playerid))
  (lms--send-command (format "%s power" playerid)))

(defun lms-player-power-on (&optional playerid)
  "Power on PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (message "LMS: power on player '%s'" (lms-get-playername-from-id playerid))
  (lms--send-command (format "%s power 1" playerid)))

(defun lms-player-power-off (&optional playerid)
  "Power on PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (message "LMS: power off player '%s'" (lms-get-playername-from-id playerid))
  (lms--send-command (format "%s power 0" playerid)))


;;;;; Volume
(defun lms-player-toggle-mute (&optional playerid)
  "Toggle mute for PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (message "LMS: toggle mute for player '%s'" (lms-get-playername-from-id playerid))
  (lms--send-command (format "%s mixer muting toggle" playerid)))

(defun lms-player-get-volume (&optional playerid)
  "Get VOLUME as string (0..100) for PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command-get-response (format "%s mixer volume ?" playerid)))

(defun lms-player-set-volume (volume &optional playerid)
  "Set VOLUME for PLAYERID device or default.
VOLUME is a string which can be a relative value (ex +5 or -7) or absolute."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (message "LMS: set volume %s for player '%s'" volume (lms-get-playername-from-id playerid))
  (lms--send-command (format "%s mixer volume %s" playerid volume)))

(defun lms-player-volume-up (&optional playerid)
  "Up +5 volume for PLAYERID device or default."
  (interactive)
  (lms-player-set-volume "+5" playerid))

(defun lms-player-volume-down (&optional playerid)
  "Up -5 volume for PLAYERID device or default."
  (interactive)
  (lms-player-set-volume "-5" playerid))


;;;;; Playing control
(defun lms-playing-toggle-pause (&optional playerid)
  "Toggle play/pause for PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s pause" playerid)))

(defun lms-playing-play (&optional playerid)
  "Play PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s play" playerid)))

(defun lms-playing-pause (&optional playerid)
  "Pause PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s pause 1" playerid)))

(defun lms-playing-stop (&optional playerid)
  "Stop PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s stop" playerid)))

(defun lms-playing-seek (position &optional playerid)
  "Seek to POSITION PLAYERID device or default."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s time %f" playerid position)))


;;;;; Playlist track control
(defun lms-playlist-track-control (index &optional playerid)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s playlist index %s" playerid index)))

(defun lms-playlist-first (&optional playerid)
  "Play first track on playlist on PLAYERID."
  (interactive)
  (lms-playlist-track-control "0" playerid))

(defun lms-playlist-next (&optional playerid)
  "Play next track on playlist on PLAYERID."
  (interactive)
  (lms-playlist-track-control "+1" playerid))

(defun lms-playlist-prev (&optional playerid)
  "Play previous track on playlist on PLAYERID."
  (interactive)
  (lms-playlist-track-control "-1" playerid))

(defun lms-playlist-play-track (index &optional playerid)
  "Play track INDEX from playlist on PLAYERID."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s playlist index %s" lms--default-playerid index)))

(defun lms-playlist-delete-track (index &optional playerid)
  "Remove track INDEX from playlist on PLAYERID."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s playlist delete %s" lms--default-playerid index)))

(defun lms-playlist-clear (&optional playerid)
  "Clear playlist on PLAYERID."
  (interactive)
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s playlist clear" playerid)))

(defun lms-playlist-get-repeat (&optional playerid)
  "Get playlist repeat mode on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command-get-response (format "%s playlist repeat ?" lms--default-playerid)))

(defun lms-playlist-set-repeat (repeat &optional playerid)
  "Set playlist REPEAT mode on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s playlist repeat %s" lms--default-playerid repeat)))

(defun lms-playlist-get-shuffle (&optional playerid)
  "Get playlist shuffle mode on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command-get-response (format "%s playlist shuffle ?" lms--default-playerid)))

(defun lms-playlist-set-shuffle (shuffle &optional playerid)
  "Set playlist SHUFFLE mode on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s playlist shuffle %s" lms--default-playerid shuffle)))

(defun lms-get-playlist (&optional playerid)
  "Get playlist for PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (let* ((idx (string-to-number (lms--send-command-get-response (format "%s playlist index ?" playerid)))) ; 0-based
         (tot (string-to-number (lms--send-command-get-response (format "%s playlist tracks ?" playerid))))
         (buf (lms--send-command-get-response (format "%s status 0 1000 tags:alydt" playerid)))
         (lst (lms--build-list-from-string-attrs buf '("id" "title" "artist" "album" "year" "tracknum" "duration"))))
    (dotimes (i tot lst)
      (let ((track (nth i lst)))
        (setq track (plist-put track 'duration (string-to-number (plist-get track 'duration))))
        (setq track (plist-put track 'index i))
        (setq track (plist-put track 'current (eq idx i)))))))


;;;;; library
(defun lms-get-virtual-libraries ()
  "Get a list of virtual libraries."
  (let ((buf (lms--send-command-get-response "libraries 0 100")))
    (lms--build-list-from-string-attrs buf '("id" "name"))))

;; library_id?
(defun lms-get-artists (&optional max vlibid)
  "Get a list of 10000 or MAX artists.
If VLIBID is specified use only that virtual library."
  (unless max
    (setq max 10000))
  (let* ((vlib (if vlibid (format " library_id:%s" vlibid) ""))
         (buf (lms--send-command-get-response (format "artists 0 %d%s" max vlib))))
    (lms--build-list-from-string-attrs buf '("id" "artist"))))

(defun lms-get-albums (&optional max vlibid)
  "Get a list of 10000 or MAX albums.
If VLIBID is specified use only that virtual library."
  (unless max
    (setq max 10000))
  (let* ((vlib (if vlibid (format " library_id:%s" vlibid) ""))
         (buf (lms--send-command-get-response (format "albums 0 %d tags:lay sort:yearartistalbum%s" max vlib))))
    (lms--build-list-from-string-attrs buf '("id" "album" "artist" "year"))))

(defun lms-get-years (&optional max vlibid)
  "Get a list of 1000 or MAX years.
If VLIBID is specified use only that virtual library."
  (unless max
    (setq max 1000))
  (let* ((vlib (if vlibid (format " library_id:%s" vlibid) ""))
         (buf (lms--send-command-get-response (format "years 0 %d hasAlbums:1%s" max vlib)))
         (lst (lms--build-list-from-string-attrs buf '("year"))))
    (seq-sort #'string< (seq-filter #'stringp (apply #'append lst)))))

(defun lms-get-genres (&optional max vlibid)
  "Get a list of 1000 or MAX genres.
If VLIBID is specified use only that virtual library."
  (unless max
    (setq max 1000))
  (let* ((vlib (if vlibid (format " library_id:%s" vlibid) ""))
         (buf (lms--send-command-get-response (format "genres 0 %d%s" max vlib))))
    (lms--build-list-from-string-attrs buf '("id" "genre"))))

;; artists
(defun lms-get-artist-name-from-id (artistid)
  "Get artist name from ARTISTID."
   (let ((buf (lms--send-command-get-response (format "artists 0 1 artist_id:%s" artistid))))
     (plist-get (car (lms--build-list-from-string-attrs buf '("artist"))) 'artist)))

(defun lms-get-artist-id-from-name (artist)
  "Get artistid from ARTIST name."
  (let* ((buf (lms--send-command-get-response (format "artists 0 100 search:'%s'" (url-hexify-string artist))))
         (lst (lms--build-list-from-string-attrs buf '("id" "artist"))))
    (plist-get (seq-find #'(lambda (x) (string= (lms--unhex-encode (plist-get x 'artist)) artist)) lst) 'id)))

(defun lms-get-artist-id-from-trackid (trackid)
  "Get artistid from TRACKID."
   (let ((buf (lms--send-command-get-response (format "artists 0 1 track_id:%s" trackid))))
     (plist-get (car (lms--build-list-from-string-attrs buf '("id"))) 'id)))

;; albums
(defun lms-get-album-name-from-id (albumid)
  "Get album name from ALBUMID."
   (let ((buf (lms--send-command-get-response (format "albums 0 1 album_id:%s" albumid))))
    (plist-get (car (lms--build-list-from-string-attrs buf '("album"))) 'album)))

(defun lms-get-album-id-from-name (album &optional artist)
  "Get albumid name from ALBUM name and optional ARTIST."
  (let* ((buf (lms--send-command-get-response (format "albums 0 100 search:%s tags:aly" (url-hexify-string album))))
         (lst (lms--build-list-from-string-attrs buf '("id" "album" "year" "artist"))))
    (if artist
        (progn
          (plist-get (seq-find #'(lambda (x) (and
                                              (string= (lms--unhex-encode (plist-get x 'album)) album)
                                              (string= (lms--unhex-encode (plist-get x 'artist)) artist)))
                                   lst)
                     'id))
      (plist-get (seq-find #'(lambda (x) (string= (lms--unhex-encode (plist-get x 'album)) album)) lst) 'id))))

(defun lms-get-recent-albums (n)
  "Get most recent N albums."
  (let* ((cmd (format "albums 0 %d sort:new tags:la" n))
         (buf (lms--send-command-get-response cmd)))
    (lms--build-list-from-string-attrs buf '("id" "album" "artist"))))

(defun lms-get-albums-from-artistid (artistid)
  "Get a list with albums from ARTISTID."
  (let* ((cmd (format "albums 0 1000 artist_id:%s sort:yearartistalbum tags:aly" artistid))
         (buf (lms--send-command-get-response cmd)))
    (lms--build-list-from-string-attrs buf '("id" "album" "year" "artist"))))

(defun lms-get-albums-from-year (year)
  "Get a list with albums from YEAR."
  (let* ((cmd (format "albums 0 1000 year:%s sort:yearartistalbum tags:aly" year))
         (buf (lms--send-command-get-response cmd)))
    (lms--build-list-from-string-attrs buf '("id" "album" "year" "artist"))))

(defun lms-get-random-albums (&optional max vlibid)
  "Get a list of 50 or MAX random albums.
If VLIBID is specified use only that virtual library."
  (unless max
    (setq max 50))
   (let* ((vlib (if vlibid (format " library_id:%s" vlibid) ""))
          (buf (lms--send-command-get-response (format "albums 0 %d tags:lay sort:random%s" max vlib))))
    (lms--build-list-from-string-attrs buf '("id" "album" "artist" "year"))))

;; tracks
(defun lms-get-current-track ()
  "Get current track as a plist."
  (let ((st (lms--get-status)))
    (list
     'id (plist-get st 'id)
     'artist (plist-get st 'artist)
     'title (plist-get st 'title)
     'album (plist-get st 'album)
     'year (plist-get st 'year)
     'tracknum (plist-get st 'tracknum)
     'duration (string-to-number (plist-get st 'duration)) ; seconds
     'time (string-to-number (plist-get st 'time))         ; seconds
     'rating (string-to-number (plist-get st 'rating))     ; 0-100
     'playlist_idx (string-to-number (plist-get st 'playlist_cur_index)) ; 0-based
     'playlist_tot (string-to-number (plist-get st 'playlist_tracks)))))

(defun lms-get-track-info (trackid)
  "Get track TRACKID information as a plist."
  (let* ((cmd (format "songinfo 0 100 track_id:%s tags:alytgiqdROfuovrTImnDU" trackid))
         (data (split-string (lms--send-command-get-response cmd)))
         trackinfo)
    (dolist (l data trackinfo)
      (let* ((pair (split-string-with-max l "%3A" 2)) ; :-char
             (k (intern (url-unhex-string (car pair))))
             (v (url-unhex-string (cadr pair))))
        (setq trackinfo (plist-put trackinfo k v))))))

(defun lms-get-tracks-from-albumid (albumid)
  "Get a list of tracks from ALBUMID.  Sorted by discnum, then by tracknum."
  (let* ((cmd (format "tracks 0 1000 album_id:%s tags:altydi" albumid))
         (buf (lms--send-command-get-response cmd))
         (lst (lms--build-list-from-string-attrs buf '("id" "title" "artist" "album" "tracknum" "duration" "year" "disc"))))
    (seq-sort #'(lambda (x y) (let ((xdn (string-to-number (or (plist-get x 'disc) "")))
                                    (xtn (string-to-number (or (plist-get x 'tracknum) "")))
                                    (ydn (string-to-number (or (plist-get y 'disc) "")))
                                    (ytn (string-to-number (or (plist-get y 'tracknum) ""))))
                                (if (= xdn ydn)
                                    (< xtn ytn)
                                  (< xdn ydn))))
              lst)))

(defun lms-get-current-track-artistid (&optional playerid)
  "Return current track artistid on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (let ((buf (lms--send-command-get-response (format "%s status - 1 tags:s" playerid))))
    (plist-get (car (lms--build-list-from-string-attrs buf '("id" "artist_id"))) 'artist_id)))

(defun lms-get-current-track-albumid (&optional playerid)
  "Return current track albumid on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (let ((buf (lms--send-command-get-response (format "%s status - 1 tags:e" playerid))))
    (plist-get (car (lms--build-list-from-string-attrs buf '("id" "album_id"))) 'album_id)))

(defun lms-get-current-track-year (&optional playerid)
  "Return current track year on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (let ((buf (lms--send-command-get-response (format "%s status - 1 tags:y" playerid))))
    (plist-get (car (lms--build-list-from-string-attrs buf '("id" "year"))) 'year)))


;;;;; Misc
(defun lms--get-status (&optional playerid)
  (unless playerid
    (setq playerid lms--default-playerid))
  (let* ((cmd (format "%s status - 1 tags:adlRytK" playerid))
         (data (split-string (lms--send-command-get-response cmd)))
         status)
    (dolist (l data status)
      (let* ((pair (split-string-with-max l "%3A" 2)) ; :-char
             (k (intern (url-unhex-string (car pair))))
             (v (url-unhex-string (cadr pair))))
        (setq status (plist-put status k v))))))

(defun lms-get-library-totals ()
  "Get library totals as plist."
  (let (totals)
    (dolist (n '("songs" "artists" "albums" "duration") totals)
      (setq totals (plist-put totals (intern n)
                              (lms--send-command-get-response (format "info total %s ?" n)))))))

(defun lms-set-track-rating (trackid rating)
  "Set RATING (percent) to TRACKID."
  (lms--send-command (format "trackstat setratingpercent %s %s" trackid rating)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;;;; UI
(defvar lms-ui-docs "#+TITLE: lms.el Documentation
#+AUTHOR: Iñigo Serna
#+DATE: 2018/12/09

* Introduction
This is an *emacs* frontend to interact with Squeezebox Server / Logitech Media Server.
Released under GPL version 3 license or later.

It requires emacs version 25 or higher.

More information on what a *squeezebox controller* is at https://inigo.katxi.org/blog/2017/07/31/lms_el.html.

Quick instructions: customize some basic parameters 'lms-hostname', 'lms-telnet-port', 'lms-html-port', 'lms-username', 'lms-password' and run it with *lms-ui*.
From there, you could read complete documentation after pressing *h* key.

Package should appear in [[https://melpa.org][MELPA repository]], and the code is in [[https://bitbucket.com/inigoserna/lms.el][BitBucket code repository]] as well.

* Features
This is Squeezebox controller, i.e. a program which can handle your local music library.

Some of the features:
- Display song: title, artist, album, year, cover…
- Play, pause, stop, select next / previous song
- Control players: select player, power on/off, volume, repeat and shuffle modes
- Playlist control: list, select song, delete track, clear
- Show track information and change rating

It is not aimed to be a complete controller, as it can't - and won't - manage external sources such us BBC, Deezer, Pandora, Spotify, or TuneIn Radio.

* Configuration
There are some parameters you could customize:
|------------------------+---------------------------------------+----------|
| Parameter              | Description                           | Default  |
|------------------------+---------------------------------------+----------|
| lms-hostname           | Logitech Media Server hostname or ip  | hostname |
| lms-telnet-port        | Logitech Media Server telnet port     | 9090     |
| lms-html-port          | Logitech Media Server www port        | 80       |
| lms-username           | Logitech Media Server username or nil | nil      |
| lms-password           | Logitech Media Server password or nil | nil      |
| lms-default-player     | Name of default player                | nil      |
| lms-ui-cover-width     | Cover image width                     | 400      |
| lms-ui-update-interval | Time in seconds between UI updates    | nil      |
|------------------------+---------------------------------------+----------|
Notes:
(1) If *lms-default-player* is not defined or a player with that name does not exist, it will ask for one at start.
(2) It's recomendable not to change *lms-ui-cover-width*.
(3) Note that small values in *lms-ui-update-interval* could freeze your Emacs use while refreshing window.

* Playing now
Main window showing information about current track and player status.
The actions triggered by pressing keys refer to the current track.
** Key bindings
|------------+--------------------------------|
| Ctrl-w     | change player power state      |
| Ctrl-p     | select player                  |
| Ctrl-r     | change track rating            |
| <space>    | toggle play/pause              |
| P          | play                           |
| S          | stop playing                   |
| p, <left>  | play previous song in playlist |
| n, <right> | play next song in playlist     |
| m          | toggle mute volume             |
| +, =       | volume up +5                   |
| -          | volume down -5                 |
| r          | cycle repeat mode              |
| s          | cycle shuffle mode             |
| g          | update window contents         |
| i          | display track information      |
| l          | display playlist               |
| T          | show all tracks of album       |
| A          | show all albums by artist      |
| Y          | show all albums of this year   |
| h, ?       | show this documentation        |
| q          | quit LMS                       |
|------------+--------------------------------|

* Track information
Display track information.
** Key bindings
|------+-------------------------|
| C-r  | change track rating     |
| h, ? | show this documentation |
| q    | close window            |
|------+-------------------------|

* Playlist
Playlist view.
The actions triggered by pressing keys refer to the track under cursor.
** Key bindings
|--------------+------------------------------|
| <up>, <down> | move cursor                  |
| <enter>      | play track                   |
| i            | show track information       |
| d, <delete>  | remove track from playlist   |
| c            | clear playlist               |
| g            | update window contents       |
| T            | show all tracks of album     |
| A            | show all albums by artist    |
| Y            | show all albums of this year |
| h, ?         | show this documentation      |
| q            | close window                 |
|--------------+------------------------------|

* Year - Album - Artist list
View all albums of an artist, sorted by date/year.
The actions triggered by pressing keys refer to the album under cursor.
** Key bindings
|--------------+------------------------------|
| <up>, <down> | move cursor                  |
| <enter>, T   | show all tracks of album     |
| A            | show all albums by artist    |
| Y            | show all albums of this year |
| p            | add album to playlist        |
| h, ?         | show this documentation      |
| q            | close window                 |
|--------------+------------------------------|

* Tracks list
View list of tracks.
The actions triggered by pressing keys refer to the track under cursor.
** Key bindings
|--------------+------------------------------|
| <up>, <down> | move cursor                  |
| <enter>, i   | display track information    |
| A            | show all albums by artist    |
| Y            | show all albums of this year |
| p            | add songs to playlist        |
| P            | add all songs to playlist    |
| h, ?         | show this documentation      |
| q            | close window                 |
|--------------+------------------------------|
"
  "LMS documentation.")

;;;;; Module internal variables
(defvar lms--current-trackid nil
  "Temporal trackid variable while in 'playing now' view.")

(defvar lms--ui-track-info-trackid nil
  "Temporal trackid variable while in 'track info' view.")

(defvar lms--ui-pl-tracks nil
  "Temporal tracks list variable in 'playlist' view.")


;;;;; Auxiliar UI functions
(defun lms--unhex-encode (str)
  "Unhexify and encode STR in utf-8."
   (decode-coding-string (url-unhex-string str) 'utf-8))

(defun lms--retrieve-url (url)
  "Retrieve data file from URL."
  (with-current-buffer (url-retrieve-synchronously url)
    (prog1
        (progn
          (goto-char (point-min))
          (re-search-forward "^$")
          (forward-char)
          (delete-region (point) (point-min))
          (buffer-string))
      (kill-buffer))))

(defun lms--format-time (secs)
  "Format SECS to human readable form."
  (if (> secs 86400)
      (format-seconds "%d days %hh %mm %ss" secs)
    (format-seconds (if (> secs 3599 ) "%h:%.2m:%.2s" "%m:%.2s") secs)))

(defun lms--format-rating (rating)
  "Format RATING to human readable form."
  (let ((r (/ rating 10))
        str)
    (dotimes (i r)
      (setq str (concat str "★")))
    (dotimes (i (- 10 r) str)
      (setq str (concat str "☆")))))

(defun lms--format-filesize (filesize)
  "Format FILESIZE to human readable form."
  (if (> filesize 1048576)
      (format "%.2f MB" (/ filesize 1048576.0))
    (if (> filesize 1024)
        (format "%.2f KB" (/ filesize 1024.0))
      (format "%d Bytes" filesize))))

(defun lms--format-repeat-mode (repeat)
  "Format REPEAT mode to human readable form."
  (pcase repeat
    ("0" "No repeat")
    ("1" "Repeat song")
    ("2" "Repeat playlist")))

(defun lms--format-shuffle-mode (shuffle)
  "Format SHUFFLE mode to human readable form."
  (pcase shuffle
    ("0" "No shuffle")
    ("1" "Shuffle by song")
    ("2" "Shuffle by album")))

(defun lms--format-mode (powerp mode)
  "Format POWERP & MODE to human readable form."
  (if powerp
      (pcase mode
        ("stop" "■")
        ("play" "▶")
        ("pause" "▍▍"))
    "off"))

(defun lms--playlist-control (cmd object &optional playerid)
  "Return current track albumid on PLAYERID."
  (unless playerid
    (setq playerid lms--default-playerid))
  (lms--send-command (format "%s playlistcontrol cmd:%s %s" playerid cmd object)))

(defun lms--ask-playlistcontrol-action (&optional question)
  "Ask QUESTION about how to add/insert/replace tracks to playlist."
  (let* ((lst '("Add to end" "Play next" "Replace"))
         (action (ido-completing-read (or question "Add to playlist? ") lst)))
    (when (and action (seq-contains lst action))
      (pcase action
        ("Add to end" "add")
        ("Play next" "insert")
        ("Replace" "load")))))


;;;;; Main
;;;###autoload
(defun lms-ui ()
  "LMS UI entry point."
  (interactive)
  (lms-ui-playing-now)
  (switch-to-buffer "*LMS: Playing Now*")
  (when lms-ui-update-interval
    (setq lms--ui-timer (run-at-time nil lms-ui-update-interval 'lms-ui-playing-now-update))))

;;;###autoload
(defalias 'lms 'lms-ui)

(defun lms-ui-playing-now-update ()
  "Update Playing Now screen."
  (let* ((buf (lms--send-command-get-response (format "%s status - 1" lms--default-playerid)))
         (id (replace-regexp-in-string ".* id%3A\\(.*\\) .*" "\\1" buf))
         (time (string-to-number (replace-regexp-in-string ".* time%3A\\(.*\\) .*" "\\1" buf))))
    (unless (= time lms--ui-last-time)
      (if (string= id lms--ui-last-id)
          (progn
            (set-buffer (get-buffer-create "*LMS: Playing Now*"))
            (goto-char (point-min))
            (forward-line 6)
            (let ((inhibit-read-only t))
              (while (not (looking-at-p "/"))
                (delete-char 1))
              (insert (lms--format-time time))))
        (lms-ui-playing-now)))))


;;;;; Playing now
(defvar lms-ui-playing-now-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map nil)
    (define-key map (kbd "C-w")       'lms-ui-playing-now-change-player-power-state)
    (define-key map (kbd "C-p")       'lms-ui-playing-now-select-player)
    (define-key map (kbd "C-r")       'lms-ui-playing-now-change-rating)
    (define-key map (kbd "<SPC>")     'lms-ui-playing-now-play-pause)
    (define-key map (kbd "P")         'lms-ui-playing-now-play)
    (define-key map (kbd "S")         'lms-ui-playing-now-stop)
    (define-key map (kbd "n")         'lms-ui-playing-now-next)
    (define-key map (kbd "<right>")   'lms-ui-playing-now-next)
    (define-key map (kbd "p")         'lms-ui-playing-now-prev)
    (define-key map (kbd "<left>")    'lms-ui-playing-now-prev)
    (define-key map (kbd "+")         'lms-ui-playing-now-volume-up)
    (define-key map (kbd "=")         'lms-ui-playing-now-volume-up)
    (define-key map (kbd "-")         'lms-ui-playing-now-volume-down)
    (define-key map (kbd "m")         'lms-ui-playing-now-volume-mute)
    (define-key map (kbd "r")         'lms-ui-playing-now-cycle-repeat)
    (define-key map (kbd "s")         'lms-ui-playing-now-cycle-shuffle)
    (define-key map (kbd "g")         'lms-ui-playing-now-refresh)
    (define-key map (kbd "i")         'lms-ui-playing-now-show-track-info)
    (define-key map (kbd "l")         'lms-ui-playing-now-show-playlist)
    (define-key map (kbd "A")         'lms-ui-playing-now-artist-albums-list)
    (define-key map (kbd "Y")         'lms-ui-playing-now-year-albums-list)
    (define-key map (kbd "T")         'lms-ui-playing-now-album-tracks-list)
    (define-key map (kbd "h")         'lms-ui-playing-now-help)
    (define-key map (kbd "?")         'lms-ui-playing-now-help)
    (define-key map (kbd "q")         'lms-ui-playing-now-quit)
    map)
  "Local keymap for `lms-ui-playing-now-mode' buffers.")

(define-derived-mode lms-ui-playing-now-mode fundamental-mode "LMS Playing Now"
  "Major mode for LMS Playing now buffer.
Press 'h' or '?' keys for complete documentation")

(defun lms-ui-playing-now ()
  "Playing now."
  (interactive)
  (unless (string= (lms--running-status) "open")
    (lms-connect))
  (sleep-for 0.5)
  (unless (string= (lms--running-status) "open")
    (error "ERROR: Can't connect to LMS server. Please verify you have customized hostname, port and credentials."))
  (unless lms--default-playerid
    (setq lms--default-playerid (lms-get-playerid-from-name
                                 (ido-completing-read "Select player: " (lms-get-players-name)))))
  (unless lms--default-playerid
    (error "LMS: can't run without player"))
  (let* ((totals (lms-get-library-totals))
         (st (lms--get-status))
         (id (plist-get st 'id))
         (title (decode-coding-string (or (plist-get st 'title) "No title") 'utf-8))
         (artist (decode-coding-string (or (plist-get st 'artist) "No artist") 'utf-8))
         (album (decode-coding-string (or (plist-get st 'album) "No album") 'utf-8))
         (year (or (plist-get st 'year) "0000"))
         (tracknum (or (plist-get st 'tracknum) "0"))
         (duration (string-to-number (or (plist-get st 'duration) "0")))
         (time (string-to-number (or (plist-get st 'time) "0")))
         (rating (string-to-number (or (plist-get st 'rating) "0")))
         (playlist_idx (1+ (string-to-number (or (plist-get st 'playlist_cur_index) "0"))))
         (playlist_tot (string-to-number (or (plist-get st 'playlist_tracks) "0")))
         (playername (decode-coding-string (or (plist-get st 'player_name) "No player") 'utf-8))
         (powerp (string= (plist-get st 'power) "1"))
         (volume (string-to-number (or (plist-get st 'mixer\ volume) "0")))
         (mode (or (plist-get st 'mode) "stop"))
         (repeat (or (plist-get st 'playlist\ repeat) "0"))
         (shuffle (or (plist-get st 'playlist\ shuffle) "0")))
    (setq lms--ui-last-id id)
    (setq lms--ui-last-time time)
    ;; (switch-to-buffer "*LMS: Playing Now*")
    (set-buffer (get-buffer-create "*LMS: Playing Now*"))
    (lms-ui-playing-now-mode)
    (setq-local buffer-read-only nil)
    (erase-buffer)
    ; track info
    (insert (propertize title 'face '(variable-pitch (:height 1.5 :weight bold :slant italic)))
            (propertize "\n\n" 'face '(:height 0.1))
            (propertize artist 'face '(variable-pitch (:height 1.2 :weight bold)))
            (propertize "\n\n" 'face '(:height 0.1))
            (propertize album 'face '(variable-pitch  (:height 1.2)))
            (propertize (when year (format "  [%s]" year)) 'face '(variable-pitch  (:height 1.2)))
            (propertize (when tracknum (format "  (%s)" tracknum)) 'face '(variable-pitch (:height 1.2)))
            (propertize "\n\n" 'face '(:height 0.1))
            (format "%s/%s  -  %d/%d  -  %s"
                    (lms--format-time time) (lms--format-time duration)
                    playlist_idx playlist_tot
                    (lms--format-rating rating))
            (propertize "\n\n" 'face '(:height 0.5)))
    ; cover image
    (when window-system
      (let* ((imgdata (string-as-unibyte (lms--retrieve-url (format "http://%s:%s/music/%s/cover.jpg" lms-hostname lms-html-port id))))
             (img (if (image-type-available-p 'imagemagick)
                      (create-image imgdata 'imagemagick t :width lms-ui-cover-width)
                    (create-image imgdata 'jpeg t)))
	         (image-width (and img (car (image-size img))))
	         (window-width (window-width)))
        (when img
          (when (> window-width image-width)
	        ;; Center the image in the window.
	        ;; (insert (propertize " " 'display
			;;                     `(space :align-to (+ center (-0.5 . ,img)))))
	   	    (insert-image img)
            (insert (propertize "\n\n" 'face '(:height 0.5)))))))
    ;  player
    (insert (propertize (format " %s " playername)
                        'face '(:box '(:style pressed-button)))
            "  "
            (propertize (format " %s " (lms--format-mode powerp mode))
                        'face '(:box '(:style pressed-button)))
            "  "
            (propertize (if (> volume 0) (format " 🔈 %s " volume) " 🔇 ")
                        'face '(:box '(:style released-button)))
            "  "
            (propertize (format " %s " (lms--format-repeat-mode repeat))
                        'face '(:height 0.8 :box '(:style released-button)))
            "  "
            (propertize (format " %s " (lms--format-shuffle-mode shuffle))
                        'face '(:height 0.8 :box '(:style released-button)))
            (propertize "\n\n" 'face '(:height 0.5)))
    ; library numbers and help
    (insert (propertize
             (let ((buf))
               (dolist (n '("songs" "artists" "albums") buf)
                 (setq buf (concat buf (plist-get totals (intern n)) " " n "  "))))
             'face '(variable-pitch (:height 0.85 :slant italic))))
    (insert (propertize (format "-  %s\n" (lms--format-time (string-to-number (plist-get totals 'duration))))
                        'face '(variable-pitch (:height 0.85 :slant italic))))
    (insert (propertize "Press 'h' for help, 'q' to close." 'face '(variable-pitch (:height 0.85 :slant italic))))
    (hl-line-mode -1)
    (setq-local cursor-type nil)
    (setq-local buffer-read-only t)
    (setq-local lms--current-trackid id)
    (goto-char (point-max))))

(defun lms-ui-playing-now-quit ()
  "Quit LMS interface ans close connection."
  (interactive)
  (setq lms-default-player (lms-get-playername-from-id lms--default-playerid))
  (kill-buffer "*LMS: Playing Now*")
  (lms-quit))

(defun lms-ui-playing-now-help ()
  "Show LMS help."
  (interactive)
  (switch-to-buffer "*LMS: Help*")
  (erase-buffer)
  (insert lms-ui-docs)
  (goto-char (point-min))
  (org-mode)
  (org-content 3)
  (search-forward "* Introduction")
  (beginning-of-line)
  (org-show-entry)
  (view-mode 1))

(defun lms-ui-playing-now-show-track-info ()
  "Open track information buffer."
  (interactive)
  (when lms--current-trackid
    (lms-ui-track-info lms--current-trackid)))

(defun lms-ui-playing-now-show-playlist ()
  "Open playlits buffer."
  (interactive)
  (lms-ui-playlist))

(defun lms-ui-playing-now-refresh ()
  "Reload LMS interface."
  (interactive)
  (lms-ui-playing-now))

(defun lms-ui-playing-now-change-player-power-state ()
  "Change power state of current player."
  (interactive)
  (let* ((lst '("toggle" "on" "off"))
         (state (ido-completing-read "Change player power state: " lst)))
    (when (and state (seq-contains lst state))
      (if (string= state "toggle")
          (lms-player-toggle-power)
        (if (string= state "on")
            (lms-player-power-on)
          (lms-player-power-off)))
      (sleep-for .2)
      (lms-ui-playing-now-refresh))))

(defun lms-ui-playing-now-select-player ()
  "Select player."
  (interactive)
  (let ((playerid (lms-get-playerid-from-name (ido-completing-read "Select player: " (lms-get-players-name)))))
    (when playerid
      (setq lms--default-playerid playerid)
      (sleep-for .2)
      (lms-ui-playing-now-refresh))))

(defun lms-ui-playing-now-change-rating ()
  "Change rating of current track."
  (interactive)
  (when lms--current-trackid
    (let* ((lst '("0" "10" "20" "30" "40" "50" "60" "70" "80" "90" "100"))
           (rating (ido-completing-read "Rating: " lst)))
      (when (and rating (seq-contains lst rating))
        (lms-set-track-rating lms--current-trackid rating)
        (sleep-for .2)
        (lms-ui-playing-now-refresh)))))

(defun lms-ui-playing-now-play-pause ()
  "Toggle play/pause."
  (interactive)
  (when lms--current-trackid
    (lms-playing-toggle-pause)
    (sleep-for .2)
    (lms-ui-playing-now-refresh)))

(defun lms-ui-playing-now-play ()
  "Play."
  (interactive)
  (when lms--current-trackid
    (lms-playing-play)
    (sleep-for .2)
    (lms-ui-playing-now-refresh)))

(defun lms-ui-playing-now-stop ()
  "Stop."
  (interactive)
  (when lms--current-trackid
    (lms-playing-stop)
    (sleep-for .2)
    (lms-ui-playing-now-refresh)))

(defun lms-ui-playing-now-next ()
  "Jump to next song."
  (interactive)
  (when lms--current-trackid
    (lms-playlist-next)
    (sleep-for .2)
    (lms-ui-playing-now-refresh)))

(defun lms-ui-playing-now-prev ()
  "Jump to previous song."
  (interactive)
  (when lms--current-trackid
    (lms-playlist-prev)
    (sleep-for .2)
    (lms-ui-playing-now-refresh)))

(defun lms-ui-playing-now-volume-up ()
  "Volume up."
  (interactive)
  (lms-player-volume-up)
  (sleep-for .2)
  (lms-ui-playing-now-refresh))

(defun lms-ui-playing-now-volume-down ()
  "Volume up."
  (interactive)
  (lms-player-volume-down)
  (sleep-for .2)
  (lms-ui-playing-now-refresh))

(defun lms-ui-playing-now-cycle-repeat ()
  "Cycle repeat modes."
  (interactive)
  (let ((repeat (string-to-number (lms-playlist-get-repeat))))
    (setq repeat (if (eq repeat 2) 0 (1+ repeat)))
    (lms-playlist-set-repeat (number-to-string repeat)))
  (sleep-for .2)
  (lms-ui-playing-now-refresh))

(defun lms-ui-playing-now-cycle-shuffle ()
  "Cycle shuffle modes."
  (interactive)
  (let ((shuffle (string-to-number (lms-playlist-get-shuffle))))
    (setq shuffle (if (eq shuffle 2) 0 (1+ shuffle)))
    (lms-playlist-set-shuffle (number-to-string shuffle)))
  (sleep-for .2)
  (lms-ui-playing-now-refresh))

(defun lms-ui-playing-now-volume-mute ()
  "Volume up."
  (interactive)
  (lms-player-toggle-mute)
  (sleep-for .5)
  (lms-ui-playing-now-refresh))

(defun lms-ui-playing-now-artist-albums-list ()
  "Show list of albums by the artist of current track."
  (interactive)
  (let* ((artistid (lms-get-current-track-artistid))
         (buftitle (format "*LMS: Albums by %s*" (lms--unhex-encode (lms-get-artist-name-from-id artistid))))
         (lst (lms-get-albums-from-artistid artistid)))
    (lms-ui-year-album-artist-list buftitle lst)))

(defun lms-ui-playing-now-year-albums-list ()
  "Show list of albums by year of current track."
  (interactive)
  (let* ((year (lms-get-current-track-year))
         (buftitle (format "*LMS: Albums in year %s*" year))
         (lst (lms-get-albums-from-year year)))
    (lms-ui-year-album-artist-list buftitle lst)))

(defun lms-ui-playing-now-album-tracks-list ()
  "Show list of tracks in album of current track."
  (interactive)
  (let* ((albumid (lms-get-current-track-albumid))
         (buftitle (format "*LMS: Tracks in album '%s'*" (lms--unhex-encode (lms-get-album-name-from-id albumid))))
         (lst (lms-get-tracks-from-albumid albumid)))
    (lms-ui-tracks-list buftitle lst)))


;;;;; Song info
(defvar lms-ui-track-info-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-r")  'lms-ui-track-info-change-rating)
    (define-key map (kbd "h")    'lms-ui-playing-now-help)
    (define-key map (kbd "?")    'lms-ui-playing-now-help)
    (define-key map (kbd "q")    '(lambda () (interactive)
                                    (kill-buffer "*LMS: Track Information*")))
    map)
  "Local keymap for `lms-ui-track-info-mode' buffers.")

(define-derived-mode lms-ui-track-info-mode fundamental-mode "LMS Track Information"
  "Major mode for LMS Track Information buffer.")

(defun lms-ui-track-info (trackid)
  "Track information for TRACKID."
  (interactive)
  (let ((trackinfo (lms-get-track-info trackid))
        k v)
    (setq trackinfo (plist-put trackinfo 'title (decode-coding-string (plist-get trackinfo 'title) 'utf-8)))
    (setq trackinfo (plist-put trackinfo 'artist (decode-coding-string (plist-get trackinfo 'artist) 'utf-8)))
    (setq trackinfo (plist-put trackinfo 'album (decode-coding-string (plist-get trackinfo 'album) 'utf-8)))
    (setq trackinfo (plist-put trackinfo 'duration (lms--format-time (string-to-number (plist-get trackinfo 'duration)))))
    (setq trackinfo (plist-put trackinfo 'rating (lms--format-rating (string-to-number (plist-get trackinfo 'rating)))))
    (setq trackinfo (plist-put trackinfo 'filesize (lms--format-filesize (string-to-number (plist-get trackinfo 'filesize)))))
    (switch-to-buffer "*LMS: Track Information*")
    (lms-ui-track-info-mode)
    (setq-local buffer-read-only nil)
    (setq-local lms--ui-track-info-trackid (plist-get trackinfo 'id))
    (erase-buffer)
    (insert (propertize "Track information" 'face '(variable-pitch (:height 1.5 :weight bold :underline t))))
    (insert "\n\n")
    (while trackinfo
      (setq k (pop trackinfo))
      (setq v (pop trackinfo))
      (insert (propertize (format "%s: " (capitalize (symbol-name k))) 'face '(:weight bold)))
      (insert (format "%s\n" v)))
    (insert "\n")
    (insert (propertize "Press 'q' to close this window." 'face '(variable-pitch (:height 0.85 :slant italic))))
    (hl-line-mode -1)
    (setq-local buffer-read-only t)
    (setq-local cursor-type nil)
    (goto-char (point-max))))

(defun lms-ui-track-info-change-rating ()
  "Change track rating."
  (interactive)
  (let* ((lst '("0" "10" "20" "30" "40" "50" "60" "70" "80" "90" "100"))
         (rating (ido-completing-read "Rating: " lst)))
    (when (and rating (seq-contains lst rating))
      (lms-set-track-rating lms--ui-track-info-trackid rating)
      (sleep-for .2)
      (lms-ui-track-info lms--ui-track-info-trackid))))


;;;;; Playlist
(defvar lms-ui-playlist-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET")       'lms-ui-playlist-play)
    (define-key map (kbd "i")         'lms-ui-playlist-track-info)
    (define-key map (kbd "d")         'lms-ui-playlist-delete-track)
    (define-key map (kbd "<delete>")  'lms-ui-playlist-delete-track)
    (define-key map (kbd "c")         'lms-ui-playlist-clear)
    (define-key map (kbd "g")         'lms-ui-playlist)
    (define-key map (kbd "A")         'lms-ui-playlist-artist-albums-list)
    (define-key map (kbd "Y")         'lms-ui-playlist-year-albums-list)
    (define-key map (kbd "T")         'lms-ui-playlist-album-tracks-list)
    (define-key map (kbd "h")         'lms-ui-playing-now-help)
    (define-key map (kbd "?")         'lms-ui-playing-now-help)
    (define-key map (kbd "q")         '(lambda () (interactive)
                                         (kill-buffer "*LMS: Playlist*")))
    map)
  "Local keymap for `lms-ui-playlist-mode' buffers.")

(define-derived-mode lms-ui-playlist-mode tabulated-list-mode "LMS Playlist"
  "Major mode for LMS Playlist buffer.
Press 'h' or '?' keys for complete documentation."
  (setq tabulated-list-format [(" "        1  nil :right-align nil)
                               ("Title"   28    t :right-align nil)
                               ("Artist"  21    t :right-align nil)
                               ("Year"     4    t :right-align nil)
                               ("Album"   22    t :right-align nil)
                               ("Tr#"      3    t :right-align t)
                               ("Time"     0    t :right-align nil)])
  (setq tabulated-list-padding 0)
  (tabulated-list-init-header))

(defun lms-ui-playlist ()
  "Playlist."
  (interactive)
  (switch-to-buffer "*LMS: Playlist*" nil)
  (setq-local buffer-read-only nil)
  (erase-buffer)
  (lms-ui-playlist-mode)
  (let ((tracks (lms-get-playlist)))
    (setq tabulated-list-entries
          (mapcar (lambda (x)
                    (list (plist-get x 'index)
                          (vector
                           (propertize (if (plist-get x 'current) "♫" " ")
                                       'face '(:weight bold))
                           (propertize (lms--unhex-encode (plist-get x 'title))
                                       'face '(:slant italic))
                           (propertize (lms--unhex-encode (plist-get x 'artist))
                                       'face '(:weight bold))
                           (propertize (or (plist-get x 'year) "")
                                       'face '())
                           (propertize (lms--unhex-encode (plist-get x 'album))
                                       'face '())
                           (propertize (lms--unhex-encode (plist-get x 'tracknum))
                                       'face '())
                           (propertize (lms--format-time (plist-get x 'duration))
                                       'face '()))))
                  tracks))
    (setq-local lms--ui-pl-tracks tracks))
  (tabulated-list-print t)
  (goto-char (point-min))
  (hl-line-mode 1)
  (setq-local cursor-type nil)
  (search-forward "♫" nil t)
  (move-beginning-of-line nil))

(defun lms-ui-playlist-play ()
  "Play selected track."
  (interactive)
  (when (tabulated-list-get-id)
    (lms-playlist-play-track (tabulated-list-get-id))
    (sleep-for 0.5)
    (lms-ui-playlist)))

(defun lms-ui-playlist-delete-track ()
  "Remove selected track from playlist."
  (interactive)
  (when (tabulated-list-get-id)
    (lms-playlist-delete-track (tabulated-list-get-id))
    (lms-ui-playlist)))

(defun lms-ui-playlist-track-info ()
  "Open track information buffer for selected track."
  (interactive)
  (when (tabulated-list-get-id)
    (lms-ui-track-info (plist-get (nth (tabulated-list-get-id) lms--ui-pl-tracks) 'id))))

(defun lms-ui-playlist-clear ()
  "Clear playlist."
  (interactive)
  (when (and (tabulated-list-get-id) (y-or-n-p "Clear playlist? "))
    (lms-playlist-clear)
    (lms-ui-playlist)))

(defun lms-ui-playlist-artist-albums-list ()
  "Show list of albums by the artist of current track."
  (interactive)
  (when (tabulated-list-get-id)
    ;; (let* ((artistid (lms-get-artist-id-from-trackid (plist-get (nth (tabulated-list-get-id) lms--ui-pl-tracks) 'id)))
    ;;        (buftitle (format "*LMS: Albums by %s*" (lms--unhex-encode (lms-get-artist-name-from-id artistid))))
    ;;        (lst (lms-get-albums-from-artistid artistid)))
    ;;   (lms-ui-year-album-artist-list buftitle lst))))
    (let* ((artist (lms--unhex-encode (plist-get (nth (tabulated-list-get-id) lms--ui-pl-tracks) 'artist)))
           (artistid (lms-get-artist-id-from-name artist))
           (buftitle (format "*LMS: Albums by %s*" artist))
           (lst (lms-get-albums-from-artistid artistid)))
      (lms-ui-year-album-artist-list buftitle lst))))

(defun lms-ui-playlist-year-albums-list ()
  "Show list of albums by year of current track."
  (interactive)
    (when (tabulated-list-get-id)
      (let* ((year (plist-get (nth (tabulated-list-get-id) lms--ui-pl-tracks) 'year))
             (buftitle (format "*LMS: Albums in year %s*" year))
             (lst (lms-get-albums-from-year year)))
        (lms-ui-year-album-artist-list buftitle lst))))

(defun lms-ui-playlist-album-tracks-list ()
  "Show list of tracks in album of current track."
  (interactive)
    (when (tabulated-list-get-id)
      (let* ((album (lms--unhex-encode (plist-get (nth (tabulated-list-get-id) lms--ui-pl-tracks) 'album)))
             ;; (artist (lms--unhex-encode (plist-get (nth (tabulated-list-get-id) lms--ui-pl-tracks) 'artist)))
             ;; (albumid (lms-get-album-id-from-name album artist))
             (albumid (lms-get-album-id-from-name album))
             (buftitle (format "*LMS: Tracks in album '%s'*" album))
             (lst (lms-get-tracks-from-albumid albumid)))
        (lms-ui-tracks-list buftitle lst))))


;;;;; Year-Album-Artist
(defvar lms--ui-yaal-lst nil
  "Temporal list variable in 'year-album-artist' view.")

(defvar lms-ui-year-album-artist-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "Y")    'lms-ui-yaal-by-year)
    (define-key map (kbd "A")    'lms-ui-yaal-by-artist)
    (define-key map (kbd "T")    'lms-ui-yaal-by-album)
    (define-key map (kbd "RET")  'lms-ui-yaal-by-album)
    (define-key map (kbd "p")    'lms-ui-yaal-to-playlist)
    ;; TODO: Add all entries to playlist?
    ;; (define-key map (kbd "P")    'lms-ui-yaal-all-to-playlist)
    (define-key map (kbd "h")    'lms-ui-playing-now-help)
    (define-key map (kbd "?")    'lms-ui-playing-now-help)
    (define-key map (kbd "q")    '(lambda () (interactive) (kill-buffer)))
    map)
  "Local keymap for `lms-ui-year-album-artist-list-mode' buffers.")

(define-derived-mode lms-ui-year-album-artist-list-mode tabulated-list-mode "LMS Year-Artist-Album"
  "Major mode for LMS Year-Album-Artist buffer.
Press 'h' or '?' keys for complete documentation."
  (setq tabulated-list-format [("Year"     6   t :right-align nil)
                               ("Album"    40  t :right-align nil)
                               ("Artist"   0   t :right-align nil)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

(defun lms-ui-year-album-artist-list (buftitle lst)
  "Year-Album-Artist list with BUFTITLE and LST entries."
  (interactive)
  (switch-to-buffer buftitle nil)
  (setq-local buffer-read-only nil)
  (erase-buffer)
  (lms-ui-year-album-artist-list-mode)
  (setq tabulated-list-entries
        (mapcar (lambda (x)
                  (list (plist-get x 'id)
                        (vector
                         (propertize (or (plist-get x 'year) "")
                                     'face '())
                         (propertize (lms--unhex-encode (plist-get x 'album))
                                     'face '())
                         (propertize (or (lms--unhex-encode (plist-get x 'artist)) "No artist")
                                     'face '(:weight bold)))))
                lst))
  (setq-local lms--ui-yaal-lst lst)
  (tabulated-list-print t)
  (goto-char (point-min))
  (hl-line-mode 1)
  (setq-local cursor-type nil))

(defun lms-ui-yaal-to-playlist ()
  "Select and execute action for artist album list."
  (interactive)
  (when (tabulated-list-get-id)
    (let ((cmd (lms--ask-playlistcontrol-action)))
      (lms--playlist-control cmd (format "album_id:%s" (tabulated-list-get-id)))
      (kill-buffer))))

(defun lms-ui-yaal-by-artist ()
  "Browse list of albums by artist of album under cursor."
  (interactive)
  (when (tabulated-list-get-id)
    (let* ((artist (lms--unhex-encode (plist-get (seq-find #'(lambda (x) (string= (plist-get x 'id) (tabulated-list-get-id)))
                                                           lms--ui-yaal-lst)
                                                 'artist)))
           (artistid (lms-get-artist-id-from-name artist))
           (buftitle (format "*LMS: Albums by artist %s*" artist))
           (lst (lms-get-albums-from-artistid artistid)))
      (kill-buffer)
      (lms-ui-year-album-artist-list buftitle lst))))

(defun lms-ui-yaal-by-year ()
  "Browse list of albums by year of album under cursor."
  (interactive)
  (when (tabulated-list-get-id)
    (let* ((year (plist-get (seq-find #'(lambda (x) (string= (plist-get x 'id) (tabulated-list-get-id)))
                                      lms--ui-yaal-lst)
                            'year))
           (buftitle (format "*LMS: Albums in year %s*" year))
           (lst (lms-get-albums-from-year year)))
      (kill-buffer)
      (lms-ui-year-album-artist-list buftitle lst))))

(defun lms-ui-yaal-by-album ()
  "Browse list of tracks of album under cursor."
  (interactive)
  (when (tabulated-list-get-id)
    (let* ((album (lms--unhex-encode (plist-get (seq-find #'(lambda (x) (string= (plist-get x 'id) (tabulated-list-get-id)))
                                                          lms--ui-yaal-lst)
                                                'album)))
           (artist (lms--unhex-encode (plist-get (seq-find #'(lambda (x) (string= (plist-get x 'id) (tabulated-list-get-id)))
                                                           lms--ui-yaal-lst)
                                                 'artist)))
           ;; (albumid (lms-get-album-id-from-name album artist))
           (albumid (lms-get-album-id-from-name album))
           (buftitle (format "*LMS: Tracks in album '%s'*" (lms--unhex-encode (lms-get-album-name-from-id albumid))))
           (lst (lms-get-tracks-from-albumid albumid)))
      (kill-buffer)
      (lms-ui-tracks-list buftitle lst))))


;;;;; Tracks list view
(defvar lms--ui-tracks-lst nil
  "Temporal list variable in 'tracks' view.")

(defvar lms-ui-tracks-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "i")    'lms-ui-tl-track-info)
    (define-key map (kbd "RET")  'lms-ui-tl-track-info)
    (define-key map (kbd "Y")    'lms-ui-tl-by-year)
    (define-key map (kbd "A")    'lms-ui-tl-by-artist)
    (define-key map (kbd "p")    'lms-ui-tl-to-playlist)
    (define-key map (kbd "P")    'lms-ui-tl-all-to-playlist)
    (define-key map (kbd "h")    'lms-ui-playing-now-help)
    (define-key map (kbd "?")    'lms-ui-playing-now-help)
    (define-key map (kbd "q")    '(lambda () (interactive) (kill-buffer)))
    map)
  "Local keymap for `lms-ui-tracks-list-mode' buffers.")

(define-derived-mode lms-ui-tracks-list-mode tabulated-list-mode "LMS Tracks"
  "Major mode for LMS Tracks buffer.
Press 'h' or '?' keys for complete documentation."
  ;; TODO: tracknum?
  (setq tabulated-list-format [("Tr#"      3    t :right-align t)
                               ("Title"   32    t :right-align nil)
                               ("Artist"  24    t :right-align nil)
                               ("Year"     4    t :right-align nil)
                               ("Album"   25    t :right-align nil)
                               ("Time"     0    t :right-align nil)])
  (setq tabulated-list-padding 0)
  (tabulated-list-init-header))

(defun lms-ui-tracks-list (buftitle lst)
  "Tracks list with BUFTITLE and LST entries."
  (interactive)
  (switch-to-buffer buftitle nil)
  (setq-local buffer-read-only nil)
  (erase-buffer)
  (lms-ui-tracks-list-mode)
  (setq tabulated-list-entries
        (mapcar (lambda (x)
                  (list (plist-get x 'id)
                        (vector
                           (propertize (or (plist-get x 'tracknum) "")
                                       'face '())
                           (propertize (lms--unhex-encode (plist-get x 'title))
                                       'face '(:slant italic))
                           (propertize (lms--unhex-encode (plist-get x 'artist))
                                       'face '(:weight bold))
                           (propertize (or (plist-get x 'year) "")
                                       'face '())
                           (propertize (lms--unhex-encode (plist-get x 'album))
                                       'face '())
                           (propertize (lms--format-time (string-to-number (plist-get x 'duration)))
                                       'face '()))))
                lst))
  (setq-local lms--ui-tracks-lst lst)
  (tabulated-list-print t)
  (goto-char (point-min))
  (hl-line-mode 1)
  (setq-local cursor-type nil))

(defun lms-ui-tl-track-info ()
  "Open track information buffer for track under cursor."
  (interactive)
  (when (tabulated-list-get-id)
    (lms-ui-track-info (tabulated-list-get-id))))

(defun lms-ui-tl-to-playlist ()
  "Select and execute action for track list."
  (interactive)
  (when (tabulated-list-get-id)
    (let ((cmd (lms--ask-playlistcontrol-action)))
      (lms--playlist-control cmd (format "track_id:%s" (tabulated-list-get-id)))
      (kill-buffer))))

(defun lms-ui-tl-all-to-playlist ()
  "Select and execute action for all tracks in list."
  (interactive)
  (when (tabulated-list-get-id)
    (let ((cmd (lms--ask-playlistcontrol-action "Add all tracks to playlist? "))
          (tracks (string-join (mapcar #'(lambda (x) (plist-get x 'id)) lms--ui-tracks-lst) ",")))
      (lms--playlist-control cmd (format "track_id:%s" tracks))
      (kill-buffer))))

(defun lms-ui-tl-by-artist ()
  "Browse list of albums by artist of track under cursor."
  (interactive)
  (when (tabulated-list-get-id)
    (let* ((artist (lms--unhex-encode (plist-get (seq-find #'(lambda (x) (string= (plist-get x 'id) (tabulated-list-get-id)))
                                                           lms--ui-tracks-lst)
                                                 'artist)))
           (artistid (lms-get-artist-id-from-name artist))
           (buftitle (format "*LMS: Albums by artist %s*" artist))
           (lst (lms-get-albums-from-artistid artistid)))
      (kill-buffer)
      (lms-ui-year-album-artist-list buftitle lst))))

(defun lms-ui-tl-by-year ()
  "Browse list of albums by year of track under cursor."
  (interactive)
  (when (tabulated-list-get-id)
    (let* ((year (plist-get (seq-find #'(lambda (x) (string= (plist-get x 'id) (tabulated-list-get-id)))
                                      lms--ui-tracks-lst)
                            'year))
           (buftitle (format "*LMS: Albums in year %s*" year))
           (lst (lms-get-albums-from-year year)))
      (kill-buffer)
      (lms-ui-year-album-artist-list buftitle lst))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(provide 'lms)
;;; lms.el ends here
