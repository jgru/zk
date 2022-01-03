;;; zk.el --- Functions to deal with link-connected notes, with no backend -*- lexical-binding: t; -*-

;; Copyright (C) 2021 Grant Rosson

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This set of functions aims to implement many (but not all) of the
;; features of the package 'Zetteldeft' while circumventing and
;; eliminating any dependency on 'Deft', or any other external
;; packages for that matter. It therefore eschews the use of any
;; backend cache or database, preferring instead to query a
;; directory of notes directly, thereby treating and utilizing that
;; directory as a sufficient database unto itself.

;; To that end, these functions rely, at the lowest level, on simple
;; calls to 'grep', which returns lists of files, links, and tags to
;; 'completing-read', from which files can be opened and links and
;; tags can be inserted into an open buffer.

;; The primary connector between notes is the simple link, which
;; takes the form of an ID number enclosed in double-brackets, eg,
;; [[202012091130]]. A note's ID number, by default, is a
;; twelve-digit string corresponding to the date and time the note
;; was originally created. For example, a note created on December
;; 9th, 2020 at 11:30 will have the ID "202012091130". Linking to
;; such a note involves nothing more than placing the string
;; [[202012091130]] into another note in the directory.

;; There are several ways to follow links. The most basic way, which
;; works in any mode, is to simply call the function
;; =zk-follow-id-at-point= with the point on an ID. This function
;; could be bound to a convenient key. Other ways of following links
;; rely on external packages. If notes are in =org-mode=, load the
;; file =zk-org.el= to enable click-to-follow links. If
;; 'Embark' (https://github.com/oantolin/embark) is installed, load
;; 'zk-embark.el' to enable 'embark-act' to target links at point as
;; well as filenames in a completion interface. If
;; 'link-hint.el' (https://github.com/noctuid/link-hint.el) is
;; installed, load 'zk-link-hint.el' to allow 'link-hint.el' to find
;; visible IDs in a buffer.

;; A note's filename is constructed as follows: the ID number
;; followed by the title of the note followed by the file extension,
;; e.g. "202012091130 On the origin of species.txt". A key
;; consequence of this ID/linking scheme is that a note's title can
;; change without any existing links to the note being broken,
;; wherever they might be in the directory.

;; The directory is a single folder containing all notes.

;; The structural simplicity of this set of functions is---one
;; hopes, at least---in line with the structural simplicity of the
;; so-called "Zettelkasten method," of which much can be read in
;; many places, including at https://www.zettelkasten.de.

;;; Code:

(require 'grep)

;;; Variables

(defvar zk-directory nil)
(defvar zk-file-extension nil)
(defvar zk-id-regexp "[0-9]\\{12\\}")
(defvar zk-id-format "%Y%m%d%H%M")
(defvar zk-insert-link-format "[%s] [[%s]]")
(defvar zk-link-format "[[%s]]")
(defvar zk-search-function 'zk--grep)
(defvar zk-tag-regexp "[#][[:alnum:]_-]+")
(defvar zk-tag-search-function 'zk--grep)
(defvar zk-insert-title-prompt nil)
(defvar zk-default-backlink nil)

;;; Low-Level Functions

(defun zk--generate-id ()
  "Generate and return a note ID.
The ID is created using `zk-id-format'."
  (let ((id (format-time-string zk-id-format)))
    (while (zk--id-unavailable-p id)
      (setq id (1+ (string-to-number id)))
      (setq id (number-to-string id)))
    id))

(defun zk--id-list ()
  "Return a list of IDs for all notes in 'zk-directory'."
  (let* ((files (directory-files zk-directory t zk-id-regexp))
         (all-ids))
    (dolist (file files)
      (progn
        (string-match zk-id-regexp file)
        (push (match-string 0 file) all-ids)))
    all-ids))

(defun zk--id-unavailable-p (str)
  "Return t if provided string STR is already in use as an id."
  (let ((all-ids (zk--id-list)))
    (member str all-ids)))

(defun zk--current-id ()
  "Return id of current note."
  (if (not (string=
            default-directory
            (expand-file-name (concat zk-directory "/"))))
      (error "Not a zk file")
    (string-match zk-id-regexp buffer-file-name))
  (match-string 0 buffer-file-name))

(defun zk--grep (regexp)
  "Wrapper around 'lgrep' to search for REGEXP in all notes.
Opens search results in a grep buffer."
  (grep-compute-defaults)
  (lgrep regexp (concat "*." zk-file-extension) zk-directory nil))

(defun zk--grep-file-list (str)
  "Return a list of files containing STR."
  (let* ((files (shell-command-to-string (concat
                                          "grep -lir -e "
                                          (regexp-quote str)
                                          " "
                                          zk-directory
                                          " 2>/dev/null")))
         (list (split-string files "\n" t)))
    (if (null list)
        (error (format "No results for \"%s\"" str))
      (mapcar
       (lambda (x)
         (abbreviate-file-name x))
       list))))

(defun zk--grep-tag-list ()
  "Return list of tags from all notes in zk directory."
  (let* ((files (shell-command-to-string (concat
                                          "grep -ohir -e '#[a-z0-9]\\+' "
                                          zk-directory " 2>/dev/null")))
         (list (split-string files "\n" t)))
    (delete-dups list)))

(defun zk--select-file (&optional list)
  "Wrapper around `completing-read' to select zk-file from LIST."
  (let* ((list (if list list
                 (directory-files zk-directory t zk-id-regexp)))
         (files (mapcar
                 (lambda (x)
                   (abbreviate-file-name x))
                 list)))
    (completing-read
     "Select File: "
     (lambda (string predicate action)
       (if (eq action 'metadata)
           `(metadata
             (category . zk-file))
         (complete-with-action action files string predicate))))))

(defun zk--parse-id (target id)
  "Return TARGET, either 'file-path, 'file-name, or 'title, from file with ID."
  (let ((file (car (directory-files zk-directory nil id)))
        (return (pcase target
                  ('file-path '0)
                  ('file-name '0)
                  ('title '2))))
    (if file
        (progn
          (string-match (concat "\\(?1:"
                              zk-id-regexp
                              "\\).\\(?2:.*?\\)\\..*")
                        file)
          (if (eq target 'file-path)
              (concat zk-directory "/" (match-string return file))
            (match-string return file)))
      (error (format "No file associated with %s" id)))))

(defun zk--parse-file (target file)
  "Return TARGET, either 'id or 'title, from FILE.

A note's title is understood to be the portion of its filename
following the ID, in the format 'zk-id-regexp', and preceding the
file extension."
  (let ((return (pcase target
                  ('id '1)
                  ('title '2))))
    (string-match (concat "\\(?1:"
                          zk-id-regexp
                          "\\).\\(?2:.*?\\)\\..*")
                  file)
    (match-string return file)))

;;; Note Functions

;;;###autoload
(defun zk-new-note (&optional title)
  "Create a new note, insert link at point, and backlink.
Optional argument TITLE."
  (interactive)
  (let* ((new-id (zk--generate-id))
         (orig-id (ignore-errors (zk--current-id)))
         (text (when (use-region-p)
                 (buffer-substring
                  (region-beginning)
                  (region-end))))
         (new-title (when (use-region-p)
                      (with-temp-buffer
                        (insert text)
                        (goto-char (point-min))
                        (push-mark)
                        (goto-char (line-end-position))
                        (buffer-substring
                         (region-beginning)
                         (region-end)))))
         (body (when (use-region-p)
                 (with-temp-buffer
                   (insert text)
                   (goto-char (point-min))
                   (forward-line 2)
                   (push-mark)
                   (goto-char (point-max))
                   (buffer-substring
                    (region-beginning)
                    (region-end))))))
    (cond ((and (not title) (not new-title))
           (setq title (read-string "Note title: ")))
          (new-title
           (setq title new-title)))
    (when (use-region-p)
      (kill-region (region-beginning) (region-end)))
    (insert (format zk-insert-link-format title new-id))
    (find-file (concat (format "%s/%s %s.%s"
                               zk-directory
                               new-id
                               title
                               zk-file-extension)))
    (insert (format "# [[%s]] %s \n===\ntags: \n" new-id title))
    (when (or orig-id zk-default-backlink)
      (if orig-id nil
        (setq orig-id zk-default-backlink))
      (progn
        (insert "===\n<- ")
        (zk-insert-link orig-id t)
        (newline)))
    (insert "===\n\n")
    (when body (insert body))
    (save-buffer)))

;;;###autoload
(defun zk-rename-note ()
  "Rename current note and replace original title in header, if found."
  (interactive)
  (let* ((id (zk--current-id))
         (orig-title (zk--parse-id 'title id))
         (new-title (read-string "New title: " orig-title))
         (new-file (concat
                    zk-directory "/"
                    id " "
                    new-title
                    "." zk-file-extension)))
    (save-excursion
      (rename-file buffer-file-name new-file t)
      (goto-char (point-min))
      (while (re-search-forward orig-title nil t 1)
        (progn
          (replace-match new-title)
          (goto-char (point-max))))
      (set-visited-file-name new-file t t))))

;;; Follow ID at Point

;;;###autoload
(defun zk-follow-id-at-point ()
  (interactive)
  (when (thing-at-point-looking-at zk-id-regexp)
    (find-file (zk--parse-id 'file-path (match-string-no-properties 0)))))

;;; Find File

;;;###autoload
(defun zk-find-file ()
  "Search and open file in 'zk-directory'."
  (interactive)
  (find-file (zk--select-file)))

;;;###autoload
(defun zk-find-file-by-id (id)
  "Open file associated with ID."
  (find-file (zk--parse-id 'file-path id)))

;;;###autoload
(defun zk-find-file-by-full-text-search (str)
  "Search for and open file containing STR."
  (interactive
   (list (read-string "Search string: ")))
  (let ((choice
         (completing-read
          (format "Files containing \"%s\": " str)
          (zk--grep-file-list str) nil t)))
    (find-file choice)))

;;; Insert Link

;;;###autoload
(defun zk-insert-link (id &optional incl-title)
  "Insert ID link to note using 'completing-read', with prompt to include title.
With prefix-argument, or when INCL-TITLE is non-nil, include the
title without prompting."
  (interactive (list (zk--parse-file 'id (zk--select-file))))
  (let* ((pref-arg current-prefix-arg)
         (title (zk--parse-id 'title id)))
    (if (or incl-title
            (unless (or pref-arg
                        (not zk-insert-title-prompt))
              (y-or-n-p "Include title? ")))
        (insert (format zk-insert-link-format title id))
      (insert (format zk-link-format id)))))

;;; Search

;;;###autoload
(defun zk-search (string)
  "Search for STRING using function set in 'zk-search-function'."
  (interactive "sSearch: ")
  (funcall zk-search-function string))

;;; List Backlinks

;;;###autoload
(defun zk-backlinks ()
  "Select from list of all notes that link to the current note."
  (interactive)
  (let* ((id (zk--current-id))
         (files (zk--grep-file-list id))
         (choice (zk--select-file (remove (zk--parse-id 'file-path id) files))))
    (find-file choice)))

;;; Tag Functions

;;;###autoload
(defun zk-tag-search (tag)
  "Open grep buffer containing results of search for TAG.
Select TAG, with completion, from list of all tags in zk notes."
  (interactive (list (completing-read "Tag: " (zk--grep-tag-list))))
  (funcall zk-tag-search-function tag))

;;;###autoload
(defun zk-tag-insert (tag)
  "Insert TAG at point.
Select TAG, with completion, from list of all tags in zk notes."
  (interactive (list (completing-read "Tag: " (zk--grep-tag-list))))
  (insert tag))

(provide 'zk)

;;; zk.el ends here
