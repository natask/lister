;;; lister.el --- Yet another list printer             -*- lexical-binding: t; -*-

;; Copyright (C) 2018-2021

;; Author:  <joerg@joergvolbers.de>
;; Version: 0.9.4
;; Package-Requires: ((emacs "26.1"))
;; Keywords: lisp
;; URL: https://github.com/publicimageltd/lister

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

;; A library for creating interactive list buffers.

;;; Code:

(require 'cl-lib)
(require 'ewoc)

;;; * Global Variables

(defcustom lister-mark-face-or-property
  '(:background "darkorange3"
                :foreground "white")
  "Text properties to be added when highlighting marked items.
Possible values are either a plist of face attributes or the name
of a face."
  :group 'lister
  :type '(choice (face :tag "Name of a face")
                 (plist :tag "Plist of face attributes")))

;;; * Buffer Local Variables

(defvar-local lister-local-left-margin 2
  "Default margin (integer length) for every item.")

(defvar-local lister-local-padding-string "  "
  "Padding string for indentation.
Each item is inserted padded with this string, n times for
indentation level n.")

(defvar-local lister-local-mapper nil
  "Buffer local mapper function for printing lister list items.
The mapper function converts a data object (any kind of list
object) to a list of strings, which will then be inserted as a
representation of that data.")

(defvar-local lister-local-ewoc nil
  "Buffer local store of the ewoc object.
This is useful for interactive functions called in the Lister
buffer.")

(defvar-local lister-local-filter nil
  "Buffer local filter predicate for Lister lists.
Do not set this directly; use `lister-set-filter' instead.")

(defvar-local lister-local-marking-predicate nil
  "Buffer local marking predicate.
Do not set this directly; use `lister-set-marking-predicate' instead.")
;;; * Data Types

(cl-defstruct (lister--item (:constructor lister--item-create))
  "The list item plus some additional extra informations.
The slot DATA contains the 'real' data, which is printed using
  the mapper."
  ;; do not add slots 'visible' and 'with-new-level', they
  ;; would interfere with the functions defined below
  level marked invisible beg end data)

(defun lister--item-visible (item-struct)
  "For ITEM-STRUCT, get negated value of of `lister--item-invisible'."
  (not (lister--item-invisible item-struct)))

;;; * Functions used as item accessors or for creating list items

(defun lister--item-with-new-level (item level)
  "Set the LEVEL of ITEM and return ITEM."
  (setf (lister--item-level item) level)
  item)

(defun lister--new-item-from-data (data &optional level)
  "Create a new lister item storing DATA and LEVEL."
  (lister--item-create :data data :level level))

(defun lister--cleaned-item (item)
  "Return ITEM cleaned of position and visibility information.
Returns ITEM cleaned of all information which will be overwritten
anyways when re-inserting the item."
  (setf (lister--item-beg item) nil
        (lister--item-end item) nil
        (lister--item-invisible item) nil)
  item)

;;; * Helper

;; use this instead of flatten-tree for emacsen < 27.1:
(defun lister--flatten (l)
  "Flatten the list L, removing any null values.
This is a simple copy of dash's `-flatten' using `seq'."
  (if (and (listp l) (listp (cdr l)))
      (seq-mapcat #'lister--flatten l)
    (list l)))

(defmacro lister-with-node (ewoc pos var &rest body)
  "Bind VAR to the node at POS and execute BODY if node exists.
EWOC is an ewoc structure."
  (declare (indent 3) (debug (sexp sexp symbolp body)))
  `(when-let ((,var (lister--parse-position ,ewoc ,pos)))
     ,@body))

(defmacro lister-with-node-or-error (ewoc pos var error &rest body)
  "Bind VAR to the node at POS and execute BODY if node exists.
Else, execute ERROR.  EWOC is an ewoc structure."
  (declare (indent 3))
  `(let ((,var (lister--parse-position ,ewoc ,pos)))
     (if (not ,var)
         ,error
       ,@body)))

(defmacro lister-save-current-node (ewoc &rest body)
  "In EWOC, save point, execute BODY and restore point.
Keep track of the position using the node's data object.  It is
safe to delete and reinsert the node in BODY.  Do not restore
point if the node's data object is invalid or not re-inserted
after BODY exits."
  (declare (indent 2) (debug (sexp body)))
  (let ((pos-var     (make-symbol "--pos--"))
        (item-var    (make-symbol "--item--"))
        (footerp-var (make-symbol "--footer-p--"))
        (eobp-var    (make-symbol "--eobp--")))
    `(let* ((,footerp-var  (lister-eolp))
            (,eobp-var     (eobp))
            (,item-var     (unless ,footerp-var
                             (ewoc-data (lister--parse-position ,ewoc :point)))))
       ,@body
       (if ,footerp-var
           (if ,eobp-var
               (goto-char (point-max))
             (ewoc-goto-node ,ewoc (ewoc--footer ,ewoc)))
         ;; this works because our custom ewoc printer always keeps the item
         ;; slots "beg" and "end" up to date:
         (when-let ((,pos-var (and ,item-var (lister--item-beg ,item-var))))
           (with-current-buffer (marker-buffer ,pos-var)
             (goto-char ,pos-var)))))))

;;; * Low-level printing / insertion:
;;;

;; Insert the item strings:

(defun lister--padding-string (margin level s)
  "Return string for padding.
Return a string which adds on a new string of MARGIN spaces LEVEL
times the string S.  If LEVEL is nil, use 0 instead."
  (concat
   (make-string margin ? )
   (string-join (make-list (or level 0) s))))

;; TODO Write tests
(defun lister--get-prop (string prop &optional start end)
  "Get all occurences of PROP between START and END of STRING."
  (let* (acc next-pos
         (start (or start 0))
         (end   (or end (length string)))
         (pos   start))
    (while (and pos (setq pos (if (get-text-property pos prop string)
                                  pos
                                (next-single-property-change pos prop string)))
                (< pos end))
      (setq next-pos (next-single-property-change pos prop string))
      (push `(,pos ,(or next-pos end)) acc)
      (setq pos next-pos))
    (nreverse acc)))

;;; TODO Write tests
(defun lister--make-string-intangible (string)
  "Make STRING intangible except where it has certain properties.
Do not make those parts of STRING intangible where the properties
`field' or `button' are non-nil."
  (add-text-properties 0 (length string) '(cursor-intangible t) string)
  (cl-dolist (prop '(field button))
    (pcase-dolist (`(,from ,to) (lister--get-prop string prop))
      (add-text-properties
       ;; The first field character is not tangible, even though
       ;; `describe-text-properties' says it has `cursor-intangible'
       ;; set to nil. So we correct that. I don't understand why this
       ;; works, however.  Something with stickiness, I think.
       (max 0 (1- from))
       to
       '(cursor-intangible nil) ;; maybe add a special field face?
       string)))
  string)

(defun lister--insert-intangible (strings padding-level)
  "In current buffer, insert all STRINGS with text property 'intangible'.
Insert a newline after each single string in STRINGS.  Pad all
strings according to PADDING-LEVEL and the buffer local value of
`lister-local-left-margin'."
  (when strings
    (let* ((padding-string (lister--padding-string lister-local-left-margin
                                                   padding-level
                                                   lister-local-padding-string))
           (strings        (mapcar (apply-partially #'concat padding-string)
                                   strings)))
      ;; Assumes rear-stickiness.
      (insert (lister--make-string-intangible
               (string-join strings "\n"))
              "\n")))) ;; <- this leaves the "tangible" gap for the next item!

;; Insert header / footer

;; The ewoc pretty printer does not know if it prints a header or a
;; footer, but we need to handle them differently for setting text
;; properties. So we wrap our own functions around.

;;; TODO Write tests
(defun lister--get-hf-strings (hf-data)
  "Use HF-DATA to get strings for a header or footer.
If HF-DATA is a function, call it with the current ewoc buffer
active and use the result.  Return HF-DATA if it is nil or a
list.  If HF-DATA is a string, wrap it into a list.  In any case,
flatten the list and return nil values.  If HF-DATA is not a
function, nor a string, nor a list, nor nil, throw an error."
  (when (functionp hf-data)
    (setq hf-data (funcall hf-data)))
  (cl-etypecase hf-data
    (stringp   (list hf-data))
    ;; this also catches nil:
    (listp     (lister--flatten hf-data))))

(defun lister--insert-as-hf (hf-data)
  "In current Lister buffer, insert HF-DATA as header or footer.
HF-DATA can be either a function, a string or a list of strings."
  (pcase-let ((`(,type ,data) hf-data))
    (when data
      (let* ((strings (lister--get-hf-strings data))
             (beg     (point))
             (lister-local-left-margin 0))
        ;; Propertize footer for eolp recognition:
        (when (and strings (eq type 'footer))
          (setq strings (mapcar (lambda (s) (propertize s 'footer t)) strings)))
        ;; insert...
        (lister--insert-intangible strings 0)
        ;; ..and close cursor gap in the header:
        (when (eq type 'header)
          (put-text-property beg (1+ beg) 'front-sticky t))))))

(defun lister--get-hf (ewoc)
  "Get header and footer of EWOC."
  (pcase-let ((`(,header . ,footer) (ewoc-get-hf ewoc)))
    ;; ewoc-create initializes with "" if header arg is nil
    (list (if (eq header "") (list 'header "") header)
          (if (eq footer "") (list 'footer "") footer))))

(defun lister-refresh-header-footer (ewoc)
  "Redisplay the header and the footer of EWOC.
Mostly makes sense if one them has a function as its data."
  (apply #'ewoc-set-hf ewoc (lister--get-hf ewoc)))

(defun lister-set-header (ewoc strings-or-fn)
  "Set STRINGS-OR-FN as a list header in EWOC.
Use STRINGS-OR-FN to determine the header.  It can be a function,
a string or a list of strings."
  (pcase-let ((`(_ ,footer) (lister--get-hf ewoc)))
    (ewoc-set-hf ewoc (list 'header strings-or-fn) footer)))

(defun lister-set-footer (ewoc strings-or-fn)
  "Set STRINGS-OR-FN as a list footer in EWOC.
Use STRINGS-OR-FN to determine the footer.  It can be a function,
a string or a list of strings."
  (pcase-let ((`(,header _) (lister--get-hf ewoc)))
    (ewoc-set-hf ewoc header (list 'footer strings-or-fn))))

;; Make the item invisible / visible:

(defun lister--invisibilize-item (item value)
  "For ITEM in current buffer, set the property 'invisible' to VALUE.
Respect the cursor gap so that the user cannot navigate to
invisible items.  The VALUE t hides the item, nil makes it
visible."
  (let* ((inhibit-read-only t)
         (beg   (lister--item-beg item))
         (end   (lister--item-end item))
         ;; we don't want to store any values, just t or nil:
         (value (not (not value))))
    ;;
    (put-text-property beg end 'invisible value)
    ;; this opens or closes the gap for the marker:
    (put-text-property beg (1+ beg) 'front-sticky value)
    ;; store the status in the lister item:
    (setf (lister--item-invisible item) value)))

(defun lister--invisibilize-node (node value)
  "For NODE in current buffer, set the property 'invisible' to VALUE.
Respect the cursor gap so that the user cannot navigate to
invisible items.  The VALUE t hides the item, nil makes it
visible."
  (lister--invisibilize-item (ewoc-data node) value))

;; Mark / unmark the item:

(defun lister--add-face-property (beg end value &optional append)
  "Add VALUE to the face property between BEG and END."
  (add-face-text-property beg end value append))

(defun lister--remove-face-property (beg end value)
  "Remove VALUE from the face property from BEG to END.
This is a slightly modified copy of `font-lock--remove-face-from-text-property'."
  (let ((beg (text-property-not-all beg end 'face nil))
        next prev)
    (while beg
      (setq next (next-single-property-change beg 'face nil end)
            prev (get-text-property beg 'face))
      (cond ((or (atom prev)
                 (keywordp (car prev))
                 (eq (car prev) 'foreground-color)
                 (eq (car prev) 'background-color))
             (when (eq value prev)
               (remove-list-of-text-properties beg next (list 'face))))
            ((memq value prev)		;Assume prev is not dotted.
             (let ((new (remq value prev)))
               (cond ((null new)
                      (remove-list-of-text-properties beg next (list 'face)))
                     ((= (length new) 1)
                      (put-text-property beg next 'face (car new)))
                     (t
                      (put-text-property beg next 'face new))))))
      (setq beg (text-property-not-all next end 'face nil)))))

(defun lister--update-mark-state (item)
  "Modify ITEM according to its marked state."
  (let* ((inhibit-read-only t)
         (beg (lister--item-beg item))
         (end (lister--item-end item)))
    (if (lister--item-marked item)
        (lister--add-face-property beg end lister-mark-face-or-property)
      (lister--remove-face-property beg end lister-mark-face-or-property))))

;; The actual printer for the ewoc:

;; NOTE Does storing three markers in each node
;; (ewoc--node-start-marker,beg and end) lead to a performance
;; problem?
(defun lister--ewoc-printer (item)
  "Insert pretty printed ITEM in the current buffer.
ITEM is a `lister--item', that is, the data hold in the local
Ewoc's node.  Note that the `lister--item' is thus not just the
data to be printed, but rather a structure with additional
information which also holds the actual data.  Build the item by
passing this data object to the buffer local mapper function,
which must return a string or a list of strings."
  (unless lister-local-mapper
    (error "No buffer local mapper function defined"))
  (let* ((inhibit-read-only t)
         (strings (funcall lister-local-mapper (lister--item-data item)))
         ;; make sure STRINGS is a list:
         (strings   (if (listp strings) strings (list strings)))
         ;; flatten it and remove nil values:
         (strings   (lister--flatten strings))
         (beg       (point-marker)))
    ;; FIXME If insertion happens before (!) on invisible overlay,
    ;; e.g. if refreshing the top node of a hidden sublist, the
    ;; ellipsis is not added at the end of this item, but rather
    ;; displayed on a separate line. Could not find a simple fix for
    ;; this.

    ;; actual printing: insert the strings at point
    (lister--insert-intangible strings (lister--item-level item))
    ;; store positions for post-insertion modifications
    (set-marker-insertion-type beg t)
    (setf (lister--item-beg item) beg
          (lister--item-end item) (point-marker))
    ;; maybe display marker:
    (when (lister--item-marked item)
      (lister--update-mark-state item))
    ;; maybe hide item:
    (when (and lister-local-filter
               (funcall lister-local-filter (lister--item-data item))
               (not (lister--item-invisible item)))
      (lister--invisibilize-item item t))))

(defun lister--parse-position (ewoc pos)
  "Return node according to POS in EWOC.
POS can be one of the symbols `:point', `:first', `:next',
`:prev', `:last', or an integer indicating the nth node counting
from 0.  All positions refer to the actual list; any filtering is
ignored.

If POS is a node, pass it through.

If POS is neither a node, nor an integer, nor one of the symbols
above, throw an error."
  (unless ewoc
    (error "%s is not a valid ewoc object" ewoc))
  ;; ewoc-locate uses (point) without setting the current buffer,
  ;; so we do it instead:
  (with-current-buffer (ewoc-buffer ewoc)
    (pcase pos
      (:first   (ewoc-nth ewoc 0))
      (:last    (ewoc-nth ewoc -1))
      (:point   (ewoc-locate ewoc))
      (:next    (ewoc-next ewoc (ewoc-locate ewoc)))
      (:prev    (ewoc-prev ewoc (ewoc-locate ewoc)))
      ((pred integerp) (or (ewoc-nth ewoc pos)
                           (error "Index out of bounds: %d" pos)))
      ;; I couldn't find any predicate ewoc--node-p or alike, even
      ;; though ewoc--node is defined as a cl struct. So we do some
      ;; very minimal testing only:
      ((pred vectorp)   pos)
      (_        (error "Unkown position argument: %s" pos)))))

;; TODO Write tests
(defun lister-eolp (&optional buf)
  "Return non-nil if point is after the last item in BUF.
Use the current buffer or BUF."
  (with-current-buffer (or buf (current-buffer))
    (or (eobp)
        (get-text-property (point) 'footer))))

(defun lister--determine-level (prev-level new-level)
  "Return the level for new items relative to PREV-LEVEL.
If PREV-LEVEL is nil, assume the new item to be a top item.
NEW-LEVEL can be nil or an integer requesting a level.  Return
the level value which is appropriate considering the value of
PREV-LEVEL."
  (max 0
       (cond
        ((null prev-level)         0) ;; top item: always indent with 0
        ((null new-level)          prev-level)
        ((> new-level prev-level) (1+ prev-level))
        (t                         new-level))))

(defun lister--debug-nodes (&rest nodes)
  "Return only the items contained in NODES."
  (mapcar #'ewoc-data (lister--flatten nodes)))

;;; * Low level list movement basics

(cl-defun lister--next-node-matching (ewoc node pred-fn
                                           &optional
                                           (move-fn #'ewoc-next)
                                           limit)
  "Starting from NODE, find the next node matching PRED-FN via MOVE-FN.
Return the next matching node or nil if there is none.
Optionally stop search unconditionally when reaching the node
LIMIT, returning nil.  To move backwards, set MOVE-FN to
`ewoc-prev'.  EWOC is an Ewoc object."
  (while (and node
              (setq node (funcall move-fn ewoc node))
              (or (not (eq limit node))
                  (setq node nil))
              (not (funcall pred-fn node))))
  node)

(cl-defun lister--next-or-this-node-matching (ewoc node pred-fn
                                                   &optional (move-fn #'ewoc-next)
                                                   limit)
  "In EWOC, check NODE against PRED-FN or find next match.
Return the matching node found by iterating MOVE-FN, or nil if
there is none.  Optionally stop search unconditionally when
reaching the node LIMIT, returning nil.  To move backwards, set
MOVE-FN to `ewoc-prev'."
  (while (and node
              (or (not (eq node limit))
                  (setq node nil))
              (not (funcall pred-fn node)))
    (setq node (funcall move-fn ewoc node)))
  node)

(defun lister--next-node-same-level (ewoc pos move-fn)
  "Find next node with POS's level, skipping items with bigger indentation.
In EWOC, use MOVE-FN to find the next node with the same level as
POS, skipping nodes with bigger indentation.  Return nil if no
next node is found."
  (lister-with-node ewoc pos node
    (let ((level   (lister-get-level-at ewoc node)))
      ;; this is actually a copy of lister--next-node-matching
      ;; but hey, it seems so awkward to define a lambda for that!
      (while (and node
                  (setq node (funcall move-fn ewoc node))
                  (> (lister--item-level (ewoc-data node)) level)))
      ;; now node is either nil or <= level
      (and node
           (and (= (lister--item-level (ewoc-data node)) level)
                node)))))

(cl-defun lister--next-visible-node (ewoc node &optional
                                       (move-fn #'ewoc-next))
  "In EWOC, move from NODE to next visible node via MOVE-FN.
Return the next node or nil if there is none.  To move backwards,
set MOVE-FN to `ewoc-prev'."
  (lister--next-node-matching ewoc node #'lister-node-visible-p move-fn))

(cl-defun lister--prev-visible-node (ewoc node)
  "In EWOC, move from NODE to previous visible node.
Return the next node or nil if there is none."
  (lister--next-node-matching ewoc node #'lister-node-visible-p #'ewoc-prev))

(defun lister--first-visible-node (ewoc &optional node)
  "Find the first visible node in EWOC, beginning with NODE.
If NODE is nil, return the first visible node of the EWOC."
  (lister--next-or-this-node-matching ewoc (or node (ewoc-nth ewoc 0))
                                   #'lister-node-visible-p))

(defun lister--last-visible-node (ewoc &optional node)
  "Find the last visible node in EWOC, searching backwards from NODE.
If NODE is nil, return the last visible node of the EWOC."
  (lister--next-or-this-node-matching ewoc (or node (ewoc-nth ewoc -1))
                                   #'lister-node-visible-p
                                   #'ewoc-prev))

;;; * Public API

(defun lister-get-ewoc (buf)
  "Get ewoc object associated with BUF."
  ;; see https://github.com/alphapapa/emacs-package-dev-handbook#accessing-buffer-local-variables
  (buffer-local-value 'lister-local-ewoc buf))

(defun lister-modified-p (ewoc)
  "Return non-nil if items in EWOC have been modified."
  (buffer-local-value 'lister-local-modified (ewoc-buffer ewoc)))

(defun lister-set-modified-p (ewoc &optional flag)
  "Mark EWOC as modified according to FLAG."
  (setf (buffer-local-value 'lister-local-modified (ewoc-buffer ewoc)) flag))

(defmacro lister-with-boundaries (ewoc beg-var end-var &rest body)
  "In EWOC, do BODY binding BEG-VAR and END-VAR to list nodes.
BEG and END have to be variable names.  When executing BODY, bind
BEG and END to the nodes indicated by the current value of these
variables.  All values understood by `lister--parse-position' are
accepted.  If either variable is nil at runtime or yet unbound,
bind it to very first or to the very last node, respectively.

Do nothing if list is empty."
  (declare (indent 3) (debug (sexp symbolp symbolp body)))
  (unless (and (symbolp beg-var) (not (keywordp beg-var)))
    (signal 'wrong-type-argument (list 'symbolp beg-var)))
  (unless (and (symbolp end-var) (not (keywordp end-var)))
    (signal 'wrong-type-argument (list 'symbolp end-var)))
  `(when-let ((,beg-var (lister--parse-position ,ewoc (or ,beg-var :first)))
              (,end-var (lister--parse-position ,ewoc (or ,end-var :last))))
       ,@body))

;; * Basic Loop Macros

(cl-defmacro lister-dolist-nodes ((ewoc var &optional beg end) &rest body)
  "In EWOC, execute BODY looping over a list of nodes.
The first argument is a list with the following arguments:

 EWOC  - An ewoc object.
 VAR   - A variable which is bound to the current node in the loop.
 [BEG] - Optionally a beginning node, or a position which can be
         parsed by `lister--parse-position'.
 [END] - Optionally a final node, or a position.

If BEG or END are not provided or nil, use the first or the last
item of the list, respectively.

The node bound to VAR can be safely destroyed without quitting
the loop.

BODY is wrapped in an implicit `cl-block'.  To quit it
immediately, use (cl-return).

\(fn (EWOC VAR [BEG] [END]) BODY...)"
  (declare (indent 1) (debug ((sexp symbolp &optional sexp sexp)
                              body)))
  (let ((temp-node (make-symbol "--temp-node--"))
        (last-var  (make-symbol "--last-node--")))
    `(let ((,var      (lister--parse-position ,ewoc (or ,beg :first)))
           (,last-var (lister--parse-position ,ewoc (or ,end :last))))
       (cl-block nil
         (while ,var
           ;; get the next node before BODY, since BODY might delete
           ;; the current node pointer:
           (let ((,temp-node (ewoc-next ,ewoc ,var)))
             ,@body
             (setq ,var (unless (eq ,var ,last-var)
                          ,temp-node))))))))

(cl-defmacro lister-dolist ((ewoc var &optional beg end node-var)
                            &rest body)
  "In EWOC, execute BODY looping over a list of item data.
The first argument is a list with the following arguments:

 EWOC  - An ewoc object.
 VAR   - A variable which is bound to the current data in the loop.
 [BEG] - Optionally a beginning node, or a position which can be
         parsed by `lister--parse-position'.
 [END] - Optionally a final node, or a position.
 [NODE-VAR] - Optionally bind the data's node.

If BEG or END are not provided or nil, use the first or the last
item of the list, respectively.

BODY is wrapped in an implicit `cl-block'.  To quit it
immediately, use (cl-return).

\(fn (EWOC VAR [BEG] [END] [NODE-VAR]) BODY...)"
  (declare (indent 1) (debug ((sexp symbolp &optional sexp sexp symbolp)
                              body)))
  (let ((node-sym (or node-var (make-symbol "--node--"))))
    `(lister-dolist-nodes (,ewoc ,node-sym ,beg ,end)
       (let ((,var (lister--item-data (ewoc-data ,node-sym))))
         ,@body))))

;; * More Specific Loop Functions

(defun lister-collect-list (ewoc &optional beg end pred-fn map-fn)
  "In EWOC, collect and optionally transform all data between BEG and END.
BEG and END are positions understood by `lister--parse-position'
and point to the first or the last node to be considered.  If
nil, use the first or the last node of the complete list instead.
If PRED-FN is set, only consider those nodes for which PRED-FN,
when called with the node's data, returns true.  If MAP-FN is
set, call MAP-FN on the node's data before collecting it."
  (let (acc)
    (lister-dolist (ewoc data beg end)
      (when (or (not pred-fn)
                (funcall pred-fn data))
        (push (funcall (or map-fn #'identity) data) acc)))
    (nreverse acc)))

(defun lister-collect-nodes (ewoc &optional beg end pred-fn map-fn)
  "In EWOC, collect and optionally transform all nodes between BEG and END.
Return all nodes between BEG and END.  BEG and END are positions
understood by `lister--parse-position' and point to the first or
the last node to be considered.  If nil, use the first or the
last node of the complete list instead.  When PRED-FN is set,
only return those nodes for which PRED-FN, called with the node,
returns true.  If MAP-FN is set, call MAP-FN on the node before
collecting it."
  (let (acc)
    (lister-dolist-nodes (ewoc node beg end)
      (when (or (not pred-fn)
                (funcall pred-fn node))
        (push (funcall (or map-fn #'identity) node) acc)))
    (nreverse acc)))

(defun lister-update-list (ewoc action-fn &optional beg end pred-fn)
  "Apply ACTION-FN on each item's data and redisplay it.
In EWOC, call ACTION-FN on each item data within the node
positions BEG and END.  If BEG or END is nil, use the first or
the last node instead.

ACTION-FN is called with one argument, the item's data.  Update
the item if ACTION-FN returns a non-nil value.  If PRED-FN is
set, restrict action only to matching nodes."
  (let (new-data)
    (lister-dolist (ewoc data beg end node)
      (when (and (or (not pred-fn)
                     (funcall pred-fn data))
                 (setq new-data (funcall action-fn (cl-copy-seq data))))
        (lister-replace-at ewoc node new-data)))))

        ;; (setf (lister--item-data (ewoc-data node)) new-data)
        ;; (ewoc-invalidate ewoc node)))))

;;; TODO Add return value counter for all calls to ACTION-FN
;;; TODO Document counter in lister-walk-marked-nodes
(defun lister-walk-nodes (ewoc action-fn &optional beg end pred-fn)
  "Call ACTION-FN on each item's node.
In EWOC, call ACTION-FN on each item's node within the node
positions BEG and END.  If BEG or END is nil, use the first or
the last node instead.

ACTION-FN is called with two arguments: the EWOC and the node.
It is up to ACTION-FN to redisplay the node.  If PRED-FN is set,
restrict action only to matching nodes."
  (lister-dolist-nodes (ewoc node beg end)
    (when (or (not pred-fn)
              (funcall pred-fn node))
      (funcall action-fn ewoc node))))

;; * Some stuff which does not fit anywhere else

(defun lister-empty-p (ewoc)
  "Return t if EWOC has no list."
  (null (ewoc-nth ewoc 0)))

(defun lister-node-in-region-p (node node-beg node-end)
  "Check if NODE is part of the list from nodes NODE-BEG to NODE-END.
Do only check the positions of the nodes, not their content."
  (and (>= (ewoc-location node) (ewoc-location node-beg))
       (<= (ewoc-location node) (ewoc-location node-end))))

;; * Goto Nodes

(defun lister-goto (ewoc pos)
  "In EWOC, move point to POS.
POS can be either an ewoc node, an index position, or one of the
symbols `:first', `:last', `:point' (sic!), `:next' or `:prev'.

Do nothing if position does not exist; throw an error if position
is invalid (i.e. index is out of bounds) or invisible."
  (lister-with-node ewoc pos node
    (if (lister--item-visible (ewoc-data node))
          (ewoc-goto-node ewoc node)
      (error "Cannot go to invisible item %s" pos))))

;; * Inspect Nodes

(defalias 'lister-get-node-at 'lister--parse-position)

(defun lister-node-get-level (node)
  "Get the indentation level of NODE."
  (lister--item-level (ewoc-data node)))

(defun lister-set-node-level (ewoc node level)
  "In EWOC, set indentation of NODE to LEVEL, refreshing it."
  (setf (lister--item-level (ewoc-data node)) level)
  (ewoc-invalidate ewoc node))

(defun lister-get-level-at (ewoc pos)
  "In EWOC, get the indentation level of the item at POS.
Do nothing if POS is nil."
  (lister-with-node ewoc pos node
    (lister-node-get-level node)))

(defun lister-set-level-at (ewoc pos level)
  "In EWOC, set indentation of node at POS to LEVEL, refreshing it.
Do nothing if POS is nil."
  (lister-with-node ewoc pos node
    (lister-set-node-level ewoc node level)))

(defun lister-node-get-data (node)
  "Get the item data stored in NODE."
  (lister--item-data (ewoc-data node)))

(defun lister-get-data-at (ewoc pos)
  "In EWOC, return the data of the lister node at POS.
POS can be either an ewoc node, an index position, or one of the
symbols `:first', `:last', `:point', `:next' or `:prev'."
  (lister-with-node-or-error ewoc pos node
    (error "No node or lister item at position %s" pos)
    (lister-node-get-data node)))

(defun lister-set-data-at (ewoc pos data)
  "In EWOC, replace the data at POS with DATA."
  (lister-with-node-or-error ewoc pos node
    (error "No node or lister item at position %s" pos)
    (lister-set-modified-p ewoc t)
    (setf (lister--item-data (ewoc-data node)) data)
    (ewoc-invalidate ewoc node)))

(defalias 'lister-replace-at 'lister-set-data-at)

(defun lister-node-visible-p (node)
  "In EWOC, test if NODE is visible."
  (lister--item-visible (ewoc-data node)))

(defalias 'lister-item-visible-p 'lister--item-visible)

(defun lister-node-marked-p (node)
  "In EWOC, test if NODE is in a marked state."
  (lister--item-marked (ewoc-data node)))

(defalias 'lister-item-marked-p 'lister--item-marked)

(defun lister-node-marked-and-visible-p (node)
  "In EWOC, test if NODE is marked and visible."
  (let ((item (ewoc-data node)))
    (and (lister--item-marked item)
         (lister--item-visible item))))

;; * Delete Items

(defun lister-delete-at (ewoc pos)
  "In EWOC, delete node specified by POS."
  (lister-set-modified-p ewoc t)
  (let* ((node (lister--parse-position ewoc pos))
         (inhibit-read-only t)
         (item  (ewoc-data node)))
    ;; deleting the marker saves memory and makes sure that
    ;; `lister-save-current-node' works well
    (setf (lister--item-beg item) nil
          (lister--item-end item) nil)
    (ewoc-delete ewoc node)))

(defun lister-delete-list (ewoc beg end)
  "In EWOC, delete all nodes from BEG up to END.
BEG and END is a node or a position, or nil standing for the
first or the last node, respectively."
  (lister-dolist-nodes (ewoc node beg end)
    (lister-delete-at ewoc node)))

(defun lister-delete-all (ewoc)
  "Delete all items in EWOC."
  (lister-delete-list ewoc :first :last))

;; * Redisplay items

(defun lister-refresh-at (ewoc pos-or-node)
  "In EWOC, redisplay the node at POS-OR-NODE."
  (lister-with-node ewoc pos-or-node node
    (ewoc-invalidate ewoc node)))

(defun lister-refresh-list (ewoc &optional beg end)
  "In EWOC, redisplay the nodes from BEG to END."
  (when-let ((nodes (lister-collect-nodes ewoc beg end)))
    (apply #'ewoc-invalidate ewoc nodes)))

;; * Marking
(defun lister-set-marking-predicate (ewoc pred)
  "Set PRED as a marking predicate in EWOC.
All items whose data matches PRED are markable. If the
PRED set to t, all items are markable."
  (with-current-buffer (ewoc-buffer ewoc)
    (setq-local lister-local-marking-predicate pred)
    (lister-dolist-nodes (ewoc node :first :last)
    (when-let* ((item     (ewoc-data node))
                (data (lister--item-data item))
                (pred (not (funcall lister-local-marking-predicate data))))
        (with-current-buffer (ewoc-buffer ewoc)
            (setf (lister--item-marked item) 'nil)
            (lister--update-mark-state item))))))

(defun lister--markable-p (ewoc node)
  "Check if NODE is markable in EWOC.
Return t if either there is no markable predicate set or if the
predicate returns t when called with the node's data."
  (with-current-buffer (ewoc-buffer ewoc)
    (or (not lister-local-marking-predicate)
        (funcall lister-local-marking-predicate (lister-node-get-data node)))))

(defun lister-set-marking-predicate (ewoc pred)
  "Set PRED as a marking predicate in EWOC.
All items whose data matches PRED are markable.  Delete existing
marks if they do not match PRED.  If the PRED set to nil, all
items are markable."
  (with-current-buffer (ewoc-buffer ewoc)
    (setq-local lister-local-marking-predicate pred)
    (when pred
      (lister-walk-marked-nodes ewoc
                                (lambda (ewoc node)
                                  (lister-mark-unmark-at ewoc node
                                                         (lister--markable-p ewoc node)))))))

(defun lister-count-marked-items (ewoc &optional beg end)
  "Count all marked items in EWOC.
Use BEG and END to restrict the items checked."
  (let ((n 0))
    (lister-dolist-nodes (ewoc node beg end)
      (when (lister-node-marked-p node)
        (cl-incf n)))
    n))

(defun lister-marked-at-p (ewoc pos)
  "Check if EWOC item at POS is marked."
  (lister-with-node ewoc pos node
    (lister-node-marked-p node)))

(defun lister-items-marked-p (ewoc &optional beg end)
  "Return non-nil if there are marked items in EWOC.
Use BEG and END to restrict the items checked."
  (lister-dolist-nodes (ewoc node beg end)
    (when (lister-node-marked-p node)
      (cl-return t))))

(defun lister-mark-unmark-at (ewoc pos state)
  "In EWOC, mark or unmark node at POS using boolean STATE."
  (lister-with-node ewoc pos node
    (let* ((item      (ewoc-data node))
           (data      (lister--item-data item))
           (old-state (lister--item-marked item)))
      (when (not (eq old-state state))
        (with-current-buffer (ewoc-buffer ewoc)
          ;; Can unmark after modifying `lister-local-marking-predicate'
          (when (or (lister--markable-p ewoc node)
                    old-state)
            (setf (lister--item-marked item) state)
            (lister--update-mark-state item)))))))

(defun lister-mark-unmark-list (ewoc beg end state)
  "In EWOC, mark or unmark the list between BEG and END.
If boolean STATE is true, the node are taken to be 'marked'.  BEG
and END can be nodes, positions such as `:first', `:point' or
`:last', or indices."
  (lister-dolist-nodes (ewoc node beg end)
    (lister-mark-unmark-at ewoc node state)))

(defun lister-get-marked-list (ewoc &optional beg end marker-pred-fn do-not-flatten-list)
  "In EWOC, get all items which are marked and visible.
BEG and END refer to the first and last node to be checked,
defaulting to the first and last node of the list.  Return a flat
list of all marked items unless DO-NOT-FLATTEN-LIST is non-nil.
Per default, return those items which are marked and visible.
Alternative node predicates can be passed to MARKER-PRED-FN."
  (let ((l (lister-get-list ewoc beg end 0
                            (or marker-pred-fn #'lister-node-marked-and-visible-p))))
    (if (not do-not-flatten-list)
        (lister--flatten l)
      l)))

(defun lister-walk-marked-nodes (ewoc action-fn &optional beg end marker-pred-fn)
  "In EWOC, call ACTION-FN on each node which is marked and visible.
BEG and END refer to the first and last node to be checked,
defaulting to the first and last node of the list.

Call ACTION-FN with the EWOC as its first and the current node as
the second argument.

Per default, only consider those items which are marked and
visible.  Alternative predicates can be passed to MARKER-PRED-FN."
  (lister-walk-nodes ewoc action-fn beg end
                     (or marker-pred-fn #'lister-node-marked-and-visible-p)))

(defun lister-walk-marked-list (ewoc action-fn &optional beg end marker-pred-fn)
  "In EWOC, call ACTION-FN on each data which is marked and visible.
BEG and END refer to the first and last node to be checked,
defaulting to the first and last node of the list.

Call ACTION-FN with the current list item's data as its sole
argument.

Per default, only consider those items which are marked and
visible.  Alternative predicates can be passed to MARKER-PRED-FN.

Note that unlike ACTION-FN, the predicate MARKER-PRED-FN is
called with the current node, not the data!"
  (let ((pred-fn (or marker-pred-fn #'lister-node-marked-and-visible-p)))
    (lister-dolist (ewoc data beg end node)
      (when (funcall pred-fn node)
        (funcall action-fn data)))))

(defun lister-delete-marked-list (ewoc &optional beg end marker-pred-fn)
  "In EWOC, delete marked and visible items between BEG and END.
BEG and END refer to the first and last node to be checked,
defaulting to the first and last node of the list.

Per default, only consider those items which are marked and
visible.  Alternative predicates can be passed to MARKER-PRED-FN."
  (let* ((inhibit-read-only t)
         (pred-fn (or marker-pred-fn #'lister-node-marked-and-visible-p))
         (nodes   (lister-collect-nodes ewoc beg end pred-fn)))
    (lister-set-modified-p ewoc t)
    (apply #'ewoc-delete ewoc nodes)))

;; * Insert Items

;; All higher level insertion function come in two variants: a private
;; function which inserts items, preserving marking state, and a
;; public function which inserts data, creating new unmarked items on
;; the fly. The function lister--insert-nested is the abstract core of
;; both.

(defun lister---walk-insert (ewoc tail level node item-fn)
  "In EWOC, recursively insert all elements of the list TAIL.
Insert each element of TAIL with indentation LEVEL.  If there are
lists in TAIL, recurse into them one level deeper.  Create
each inserted item by calling ITEM-FN with two arguments, the
current head of TAIL and the current level.  The items are
inserted from bottom to top, that is, they are 'stacked' either
on NODE or, if NODE is nil, on the bottom of the list."
  (let (item)
    (while tail
      (setq item (car tail)
            tail (cdr tail))
      (if (listp item)
          (lister---walk-insert ewoc item (1+ level) node item-fn)
        (setq item (funcall item-fn item level))
        (if node
            (ewoc-enter-before ewoc node item)
          (ewoc-enter-last ewoc item))))))

(defun lister--insert-nested (ewoc pos l level insert-after item-fn)
  "In EWOC, insert L at POS.
POS can be either an ewoc node, an index position, or one of the
symbols `:first', `:last', `:point', `:next' or `:prev'.  If
LEVEL is nil, align the new data item's level with its
predecessor.  If LEVEL is an integer value, indent the item LEVEL
times, but never more then one level than the previous item.
Items inserted at top always have level 0.  Create each inserted
item by calling ITEM-FN with two arguments, the current element
of the list and its assigned level.  Insert L before (or
visually 'above') the node at POS, unless INSERT-AFTER is set."
  (lister-set-modified-p ewoc t)
  (let* (;; determine the level:
         (node (lister--parse-position ewoc pos))
         (prev (if insert-after node (ewoc-prev ewoc node)))
         (prev-level (if prev (lister--item-level (ewoc-data prev))      0))
         (this-level (if prev (lister--determine-level prev-level level) 0)))
    ;; Per default, lister---walk-insert inserts before NODE. Adjust
    ;; the other cases to that scheme:
    (cond
     ((and (null node) insert-after)      ;; insert at top?
      (setq node (ewoc-nth ewoc 0)))      ;; => insert before the first item
     ((and node insert-after)             ;; insert after NODE?
      (setq node (ewoc-next ewoc node)))) ;; => insert before its next node
    ;;
    (lister---walk-insert ewoc l this-level node item-fn)))

(defun lister--insert-items (ewoc pos item-list level insert-after)
  "In EWOC, insert ITEM-LIST at POS.
POS can be either an ewoc node, an index position, or one of the
symbols `:first', `:last', `:point', `:next' or `:prev'.  If
LEVEL is nil, align the new data item's level with its
predecessor.  If LEVEL is an integer value, indent the item LEVEL
times, but never more then one level than the previous item.
Items inserted at top always have level 0. Insert L before (or
visually 'above') the node at POS, unless INSERT-AFTER is set.

ITEM-LIST must be a lists of `lister--item' objects."
  (lister--insert-nested ewoc pos item-list level insert-after
                         #'lister--item-with-new-level))

(defun lister-insert-list (ewoc pos data-list &optional level insert-after)
  "In EWOC, insert DATA-LIST at POS.
POS can be either an ewoc node, an index position, or one of the
symbols `:first', `:last', `:point', `:next' or `:prev'.  If
LEVEL is nil, align the new data item's level with its
predecessor.  If LEVEL is an integer value, indent the item LEVEL
times, but never more then one level than the previous item.
Items inserted at top always have level 0. Insert L before (or
visually 'above') the node at POS, unless INSERT-AFTER is set.

DATA-LIST must be a list of data elements which are accepted by
the buffer local mapper function."
  (lister--insert-nested ewoc pos data-list level insert-after
                         #'lister--new-item-from-data))

(defalias 'lister-insert-list-at 'lister-insert-list)

(defun lister-insert (ewoc pos data  &optional level insert-after)
  "In EWOC, insert DATA as a single item at POS.
POS can be either an ewoc node, an index position, or one of the
symbols `:first', `:last', `:point', `:next' or `:prev'.  If
LEVEL is nil, align the new data item's level with its
predecessor.  If LEVEL is an integer value, indent the item LEVEL
times, but never more then one level than the previous item.
Items inserted at top always have level 0.  Insert data item
before the node at POS, unless INSERT-AFTER is set."
 (lister-insert-list ewoc pos (list data) level insert-after))

(defalias 'lister-insert-at 'lister-insert)

(defun lister-add (ewoc data &optional level)
  "In EWOC, add DATA as printed item to the end of the list.
Optionally set its LEVEL explicitly, else it will inherit the
level of the previous last item."
  (lister-insert-list ewoc :last (list data) level t))

(defun lister-add-list (ewoc l &optional level)
  "In EWOC, add list L as printed items to the end of the list.
Optionally set their LEVEL explicitly, else they will inherit the
level of the previous last item."
  (lister-insert-list ewoc :last l level t))

(defun lister--replace-nested (ewoc l beg end level item-fn)
  "In EWOC, insert list L replacing the list from BEG to END.
BEG and END can be a node, a position symbol or an index value.
Indent the new items according to LEVEL.  Create the new items to
be inserted by calling ITEM-FN with two arguments, the list
element and its assigned level."
  (let (insert-at)
    (lister-with-boundaries ewoc beg end
      (setq insert-at (ewoc-next ewoc end))
      (lister-delete-list ewoc beg end))
    (lister--insert-nested ewoc (or insert-at :last) l
                           level
                           (null insert-at)
                           item-fn)))

(defun lister--replace-items (ewoc item-list beg end level)
  "In EWOC, insert ITEM-LIST replacing the list from BEG to END.
BEG and END can be a node, a position symbol or an index value.
Indent the new items according to LEVEL.  ITEM-LIST must be a
list of `lister--item' objects."
  (lister--replace-nested ewoc item-list beg end level
                          #'lister--item-with-new-level))

(defun lister-replace-list (ewoc data-list beg end &optional level)
  "In EWOC, insert DATA-LIST replacing the list from BEG to END.
BEG and END can be a node, a position symbol or an index value.
Optionally indent the new items according to LEVEL, else use the
level of the item before BEG.  DATA-LIST must be a list of data
objects understood by the buffer local mapper function."
  (lister--replace-nested ewoc data-list beg end level
                          #'lister--new-item-from-data))

(defun lister-set-list (ewoc l)
  "Insert data list L in EWOC, replacing any previous content.
Insert nested lists with nested indentation.  L must be a list of
data objects understood by the buffer local mapper function.

Note that in some cases, the complementary function
`lister-get-list' will not reproduce the exact list inserted.
Inserting the list `(A (B) (C))' produces two items B and C with
the same indentation level, which will be then treated as the
list '(A (B C))'."
  (lister-delete-all ewoc)
  (lister---walk-insert ewoc l 0 nil #'lister--new-item-from-data))

;; * Higher Level Functions to Find Nodes

;; These functions basically wrap their corresponding 'private'
;; equivalent so that positions instead of node objects can be passed
;; as arguments.  Also these functions apply PRED-FN to the data and
;; not the nodes.

;; TODO Add tests for using positions for LIMIT
(defun lister-next-matching (ewoc pos pred &optional limit)
  "In EWOC, find next match for PRED after POS.
PRED is checked against the node's data.  Begin searching from
POS, which is a position understood by `lister--parse-position'.
Optionally unconditoinally stop searching when reaching the
position LIMIT, returning nil.  Return the node found or nil."
  (lister-with-node ewoc pos node
    (lister--next-node-matching ewoc node
                                (lambda (n)
                                  (funcall pred (lister-node-get-data n)))
                                #'ewoc-next
                                (and limit (lister--parse-position ewoc limit)))))

;; TODO Add tests for using positions for LIMIT
(defun lister-first-matching (ewoc pos pred &optional limit)
  "In EWOC, find first match for PRED starting from (and including) POS.
PRED is checked against the node's data.  Begin searching at POS,
which is a position understood by `lister--parse-position'.
Optionally unconditionally stop searching when reaching the
position LIMIT, returning nil.  Return the node found or nil."
  (lister-with-node ewoc pos node
    (lister--next-or-this-node-matching ewoc node
                                        (lambda (n)
                                          (funcall pred (lister-node-get-data n)))
                                        #'ewoc-next
                                        (and limit (lister--parse-position ewoc limit)))))

;; NOTE Do we need the following function? It Seems to be useless
;; insofar it checks against item's data and ignores level. So what is
;; the point in checking a node only against visibility, and ignoring
;; that it might have another level? Better add a nesting predicate or
;; something....

;; TODO Add tests for using positions for LIMIT
(defun lister-next-visible-matching (ewoc pos pred &optional limit)
  "In EWOC, find the next visible match for PRED after POS.
PRED is checked against the node's data.  Begin searching from
POS, which is a position understood by `lister--parse-position'.
Optionally unconditionally stop searching when reaching the
position LIMIT, returning nil.  Return the node found or nil."
  (let ((node (lister--parse-position ewoc pos)))
    (lister--next-node-matching ewoc node
                                (lambda (n)
                                  (and (lister-node-visible-p n)
                                       (funcall pred (lister--item-data (ewoc-data n)))))
                                #'ewoc-next
                                (and limit (lister--parse-position ewoc limit)))))

;; TODO Add tests for using positions for LIMIT
(cl-defun lister-prev-matching (ewoc pos pred &optional limit)
  "Find the prev node in EWOC matching PRED before POS.
PRED is checked against the node's data.  Begin searching
backwards from POS, which is a position understood by
`lister--parse-position'.  Return the node found or nil."
  (lister-with-node ewoc pos node
    (lister--next-node-matching ewoc node
                                (lambda (n)
                                  (funcall pred (lister-node-get-data n)))
                                #'ewoc-prev
                                (and limit (lister--parse-position ewoc limit)))))

;; TODO Add tests for using positions for LIMIT
(defun lister-prev-visible-matching (ewoc pos pred &optional limit)
  "Find the prev visible node in EWOC matching PRED before POS.
PRED is checked against the node's data.  Begin searching
backwards from POS, which is a position understood by
`lister--parse-position'.  Return the node found or nil."
  (lister-with-node ewoc pos node
    (lister--next-node-matching ewoc node
                                (lambda (n)
                                  (and (lister-node-visible-p n)
                                       (funcall pred (lister-node-get-data n))))
                                #'ewoc-prev
                                (and limit (lister--parse-position ewoc limit)))))

;; * Getting items

;; All higher level functions which return the ewoc list come in two
;; variants: a private function which returns items, preserving
;; marking state, and a public function which returns the data only.
;; The function lister--get-nested is the abstract core of both.

(defun lister--get-nested (ewoc beg end start-level pred-fn key-fn)
  "Return the data from EWOC as a nested list.
Collect the data slots of all nodes between BEG and END.  BEG and
END can be any position understood by `lister--parse-position'.
If they are nil, traverse the whole list.  Restrict the result to
only those node matching PRED-FN.  Access the data slots by using
KEY-FN with the ewoc data as its sole argument.  Use START-LEVEL
as the level of the first node; higher node levels will result in
nested lists."
  (lister-with-boundaries ewoc beg end
    ;; make sure begin and end match pred-fn:
    (when pred-fn
      (setq beg (lister--next-or-this-node-matching ewoc beg pred-fn #'ewoc-next))
      (setq end (lister--next-or-this-node-matching ewoc end pred-fn #'ewoc-prev)))
    ;; We traverse the list recursively using 'node' as a global
    ;; pointer to the current item so that nested 'inner' functions
    ;; can move forward that global node which is also used by the
    ;; 'outer' function to which it returns.
    (let ((node beg))
      (cl-labels ((walk (ewoc acc prev-level)
                              (let (level)
                                (while (and node
                                            (>= (setq level (lister-node-get-level node))
                                                prev-level))
                                  (if (> level prev-level)
                                      (push (walk ewoc nil (1+ prev-level)) acc)
                                    (when (or (not pred-fn)
                                              (funcall pred-fn node))
                                      (push (funcall key-fn (ewoc-data node)) acc))
                                    (setq node (unless (eq node end)
                                                 (ewoc-next ewoc node)))))
                                (nreverse acc))))
        ;;
        (walk ewoc nil start-level)))))

(defun lister--get-items (ewoc beg end start-level pred-fn)
  "Return the items stored in the nodes of EWOC, preserving hierarchy.
Collect the item object of all nodes between BEG and END.  BEG
and END can be any position understood by
`lister--parse-position'.  If they are nil, traverse the whole
list.  Use START-LEVEL as the level of the first node; higher
node levels will result in nested lists.  Only consider nodes
matching PRED-FN."
  (lister--get-nested ewoc beg end
                      (or start-level 0)
                      (or pred-fn #'identity)
                      #'lister--cleaned-item))

(defun lister-map (ewoc fn &optional pred-fn beg end start-level)
  "Apply FN to the data tree in EWOC.
BEG and END can be any position understood by
`lister--parse-position'.  If they are nil, traverse the whole
list.  Restrict the result to items matching PRED-FN.  Use
START-LEVEL as the level of the first node; higher node levels
will result in nested lists."
  (let ((pred-fn (or pred-fn #'identity)))
    (cl-labels ((predicate-fn (node)
                              (funcall pred-fn
                                       (lister--item-data (ewoc-data node))))
                (key-fn       (data)
                              (funcall fn (lister--item-data data))))
      ;;
      (lister--get-nested ewoc beg end
                          (or start-level 0)
                          #'predicate-fn
                          #'key-fn))))

(defun lister-get-list (ewoc &optional beg end start-level pred-fn)
  "Return the data of EWOC as a list, preserving hierarchy.
Collect the data slots of all items between BEG and END.  BEG and
END can be any position understood by `lister--parse-position'.
If they are nil, traverse the whole list.  Use START-LEVEL as the
level of the first node; higher node levels will result in nested
lists.

If PRED-FN is set, only return matching nodes.  Note that the
predicate here is checking against the whole ewoc node, not the
item nor the item's data slot!"
  (lister--get-nested ewoc beg end
                      (or start-level 0)
                      (or pred-fn #'identity)
                      #'lister--item-data))

(defun lister-get-visible-list (ewoc &optional beg end start-level)
  "Like `lister-get-list', but only consider visible items.
Collect the data of all visible nodes in EWOC.  Nodes or
positions BEG and END set a specific limit.  Use START-LEVEL to
set an initial indentation level for the first item."
  (lister-get-list ewoc beg end start-level #'lister-node-visible-p))

;;; * Sublist handling

(defun lister--locate-sublist (ewoc pos &optional only-visible)
  "Return first and last node in EWOC with the same level as POS.
Return the nodes as a list `(first last)' or nil if the EWOC is
empty.

If ONLY-VISIBLE is non-nil, return the first and last visible
inner sublist node.  If the sublist has no visible items, return
the boundaries of the complete list.  If the list is completely
hidden, return nil.

This function implicitly defines a 'sublist' as a continuous list
of items with a nesting level identical to, or bigger than, the
item at POS.  A sublist must have a 'top' parent node with lesser
indentation, while it is optional to have a 'bottom' node.  If
there is no 'bottom' node, the last item marks the end of that
sublist.  If there is no parent node, effectively return the
boundaries of the complete list."
  (lister-with-node ewoc pos node
    (let* ((ref-level      (lister-node-get-level node))
           (pred-fn        (lambda (n)
                             (< (lister-node-get-level n)
                                ref-level)))
           (inner-pred-fn  (if only-visible
                               #'lister-node-visible-p
                             #'identity))
           ;; find upper and lower non-sublist boundaries:
           (upper (lister--next-node-matching ewoc node pred-fn #'ewoc-prev))
           (lower (lister--next-node-matching ewoc node pred-fn #'ewoc-next))
           ;; we want the first and last (visible) item of the sublist itself:
           (inner-first (when upper (lister--next-node-matching ewoc upper inner-pred-fn #'ewoc-next lower)))
           (inner-last  (when lower (lister--next-node-matching ewoc lower inner-pred-fn #'ewoc-prev upper)))
           ;; re-adjust the results if no boundaries were found:
           (inner-first (or inner-first (if only-visible
                                             (lister--first-visible-node ewoc)
                                           (ewoc-nth ewoc 0))))
           (inner-last  (or inner-last  (if only-visible
                                            (lister--last-visible-node ewoc)
                                          (ewoc-nth ewoc -1)))))
      ;; NOTE it would suffice to check for one boundary since it should
      ;; never happen that only one is not found, but well...
      (when (or inner-first inner-last)
        `(,inner-first ,inner-last)))))

(defmacro lister-with-sublist-at (ewoc pos beg-var end-var &rest body)
  "Execute BODY with BEG-VAR and END-VAR bound to the sublist at POS.
If there is no sublist, do not execute BODY and return nil.

POS can be any value understood by `lister--parse-position'.
BEG-VAR and END-VAR have to be symbol names; they will be bound
to the upper and lower limit of the sublist at POS.  EWOC is a
lister ewoc object."
  (declare (indent 4) (debug (sexp sexp symbolp symbolp body)))
  (unless (and (symbolp beg-var) (not (keywordp beg-var)))
    (signal 'wrong-type-argument (list 'symbolp beg-var)))
  (unless (and (symbolp end-var) (not (keywordp end-var)))
    (signal 'wrong-type-argument (list 'symbolp end-var)))
  (let ((boundaries-var (make-symbol "boundaries")))
    `(let* ((,boundaries-var (lister--locate-sublist ,ewoc ,pos))
            (,beg-var       (car ,boundaries-var))
            (,end-var       (cadr ,boundaries-var)))
       (when (and ,beg-var ,end-var)
         ,@body))))

(defmacro lister-with-sublist-below (ewoc pos beg end &rest body)
  "Executy BODY with BEG and END bound to the sublist below POS.
If there is no sublist, do not execute BODY and return nil.

POS can be any value understood by `lister--parse-position'.  BEG
and END have to be symbol names; they are bound to the upper and
lower limit of the sublist at POS.  EWOC is a lister ewoc object."
  (declare (indent 4) (debug (sexp sexp symbolp symbolp body)))
  (unless (and (symbolp beg) (not (keywordp beg)))
    (signal 'wrong-type-argument (list 'symbolp beg)))
  (unless (and (symbolp end) (not (keywordp end)))
    (signal 'wrong-type-argument (list 'symbolp end)))
  (let ((node-sym (make-symbol "--node--")))
    `(when-let* ((,node-sym (lister--parse-position ,ewoc ,pos)))
       (when (lister-sublist-below-p ewoc ,node-sym)
         (lister-with-sublist-at ewoc (ewoc-next ewoc ,node-sym)
                              ,beg ,end
           ,@body)))))

(defun lister-sublist-below-p (ewoc pos)
  "Check if in EWOC, there is an indented list below POS.
POS can be either an ewoc node, an index position, or one of the
symbols `:first', `:last', `:point', `:next' or `:prev'."
  (let* ((node (lister--parse-position ewoc pos))
         (next (ewoc-next ewoc node)))
    (when next
      (< (lister-node-get-level node)
         (lister-node-get-level next)))))

(defun lister-sublist-at-p (ewoc pos)
  "Check if in EWOC, there is a sublist at POS."
  (lister-with-sublist-at ewoc pos beg end
    (and (not (eq beg (lister--parse-position ewoc :first)))
         (not (eq end (lister--parse-position ewoc :last))))))

(defun lister-insert-sublist-below (ewoc pos l)
  "In EWOC, insert L as an indented list below POS."
  (lister-insert-list ewoc pos l 999 t))

(defun lister-delete-sublist-at (ewoc pos)
  "In EWOC, delete the sublist at POS."
  (lister-with-sublist-at ewoc pos first last
    (lister-delete-list ewoc first last)))

(defun lister-delete-sublist-below (ewoc pos)
  "In EWOC, delete the sublist below POS."
  (lister-with-sublist-below ewoc pos beg end
    (lister-delete-list ewoc beg end)))

(defun lister-replace-sublist-at (ewoc pos l)
  "In EWOC, replace sublist at POS with L."
  (lister-with-sublist-at ewoc pos beg end
    (let ((level (lister-node-get-level beg)))
      (lister-replace-list ewoc l beg end level))))

(defun lister-replace-sublist-below (ewoc pos l)
  "In EWOC, replace sublist below POS with L."
  (lister-with-sublist-below ewoc pos beg end
    (let ((level (lister-node-get-level beg)))
      (lister-replace-list ewoc l beg end level))))

(defun lister-mark-unmark-sublist-at (ewoc pos state)
  "In EWOC, mark or unmark the sublist at POS.
Use boolean STATE t to set the node as 'marked', else nil."
  (lister-with-sublist-at ewoc pos beg end
    (lister-mark-unmark-list ewoc beg end state)))

(defun lister-mark-unmark-sublist-below (ewoc pos state)
  "In EWOC, mark or unmark the sublist below POS.
Use boolean STATE t set the node as 'marked', else nil."
  (lister-with-sublist-below ewoc pos beg end
    (lister-mark-unmark-list ewoc beg end state)))

(defun lister-get-sublist-at (ewoc pos)
  "In EWOC, return the data of the sublist at POS as a list.
If no list is found, return nil."
  (lister-with-sublist-at ewoc pos beg end
    (let ((start-level (lister-node-get-level beg)))
      (lister-get-list ewoc beg end start-level))))

(defun lister-get-sublist-below (ewoc pos)
  "In EWOC, return the sublist below POS."
  (lister-with-sublist-below ewoc pos beg end
    (let ((start-level (lister-node-get-level (ewoc-next ewoc beg))))
      (lister-get-list ewoc beg end start-level))))

;;; * Sorting (or, more abstract, reordering)

(defun lister--wrap-list (l)
  "Wrap nested list L in a list, with sub-lists as its cdr.
Each list element must be either a nested list or a non-list
atom.  Throw an error if there is a sublist (a nested list)
without a previous non-nested list item."
  (declare (pure t) (side-effect-free t))
  (let (acc (tail l))
    (while tail
      (let ((item (car tail))
            (next (cadr tail)))
        (when (consp item)
          (error "Cannot wrap sublists w/o top heading item"))
        (push (cons item (when (consp next)
                           (setq tail (cdr tail))
                           (lister--wrap-list next)))
              acc)
        (setq tail (cdr tail))))
    (nreverse acc)))

(defun lister--reorder-wrapped-list (wrapped-l fn)
  "Reorder WRAPPED-L using FN and return result as a plain list.
WRAPPED-L is a wrapped list as returned by `lister--wrap-list'.
Return WRAPPED-L as an unwrapped (!) list in the new order
determined by FN.

A 'wrapped' list consists of pairs of CAR and CDR, where each car
contains the list item, and the cdr an associated sublist (or
nil).

FN has to reorder the elements of WRAPPED-L according to the car
of each element, but to leave the wrapped pairs themselves
untouched.  For a function that normally uses predicates on plain
lists, such as sorting functions, this can be done by filtering
the predicate argument with `car'.  Functions that work on plain
lists without inspecting their contents, such as `reverse', work
out of the box.

Example:
\(let* \(\(l   \(lister--wrap-list '\(\"b\" \"a\" \(\"bb\" \"ba\"\)\)\)\)
       \(fn  (apply-partially #'seq-sort-by #'car #'string<\)\)\)
  \(lister--reorder-wrapped-list l fn\)\)

 => \(\"a\" \(\"ba\" \"bb\"\) \"b\"\)"
  (declare (pure t) (side-effect-free t))
  (let (acc (tail   (funcall fn wrapped-l)))
    ;; test at the beginning to ensure that tail is not already empty
    (while tail
      (let ((item    (caar tail))
            (sublist (cdar tail)))
        (push item acc)
        (when (consp sublist)
          (push (lister--reorder-wrapped-list sublist fn) acc))
        (setq tail (cdr tail))))
    (nreverse acc)))

(defun lister--reorder (ewoc fn &optional beg end)
  "In EWOC, reorder all items from BEG to END using FN.
BEG and END are nodes or positions understood by
`lister--parse-position'.  If BEG or END are nil, use the
beginning or the end of the list as boundaries; that is, reorder
the complete list.  Retain the marking state of each item when
reordering.

Note that FN has to reorder a wrapped list (with `lister--item'
as elements) and must not undo the wrapping."
  (lister-with-boundaries ewoc beg end
    (let* ((level        (lister-node-get-level beg))
           ;; reorder the whole item structure, not just the data:
           (l            (lister--get-items ewoc beg end level #'identity))
           (wrapped-list (lister--wrap-list l))
           (new-list     (lister--reorder-wrapped-list wrapped-list fn)))
      (lister--replace-items ewoc new-list beg end level))))

(defun lister-reorder-sublist-at (ewoc pos pred)
  "Reorder the sublist at POS in EWOC by PRED."
    (lister-with-sublist-at ewoc pos beg end
    (lister--reorder ewoc pred beg end)))

(defun lister-reorder-sublist-below (ewoc pos pred)
  "Reorder the sublist below POS in EWOC by PRED."
  (lister-with-sublist-at ewoc pos beg end
    (lister--reorder ewoc pred beg end)))

(defun lister-reverse-list (ewoc &optional beg end)
  "Reverse the list in EWOC, preserving sublist associatios.
Use BEG and END to specify the first and the last item of the
list to be reversed."
  (lister--reorder ewoc #'reverse beg end))

(defun lister--sort-reduce (comps l)
  "Sort wrapped list L using all sort comparators COMPS.
Apply COMPS in sequence, using the result of applying the first
comperator as input for the second round, etc.  Even if L has to
be a 'wrapped' list, COMPS have direct access to the item data."
  (cl-labels ((key-fn (item)
                      (lister--item-data (car item)))
              (copy-sort (l comp)
                         (seq-sort-by #'key-fn comp (copy-sequence l))))
    (seq-reduce #'copy-sort (reverse comps) l)))

(defun lister-sort-list (ewoc comps &optional beg end)
  "In EWOC, sort the list and sublists using COMPS.
BEG and END specify the first and the last item of the list
range.  PREDS is either a single comperator function (like
`string>') or a list of comperators.  Apply all COMPS from first
to last on the list."
  (let ((comps (if (listp comps) comps (list comps))))
    (lister--reorder ewoc
                     (apply-partially #'lister--sort-reduce comps)
                     beg end)))

(defun lister-sort-sublist-at (ewoc pos pred)
  "In EWOC, sort the sublist at POS using PRED."
  (lister-with-sublist-at ewoc pos beg end
    (lister-sort-list ewoc pred beg end)))

(defun lister-sort-sublist-below (ewoc pos pred)
  "In EWOC, sort the sublist below POS using PRED."
  (lister-with-sublist-below ewoc pos beg end
    (lister-sort-list ewoc pred beg end)))

;;; * Filtering

(defun lister-filter-active-p (ewoc)
  "Return non-nil if filter in EWOC is active."
  (buffer-local-value 'lister-local-filter (ewoc-buffer ewoc)))

(defun lister-set-filter (ewoc pred)
  "Set PRED as a display filter in EWOC.
All items whose data matches PRED will be hidden from view.  The
PRED nil effectively removes any existing filter."
  (with-current-buffer (ewoc-buffer ewoc)
    (setq-local lister-local-filter pred)
    (lister-dolist (ewoc data :first :last node)
      (lister--invisibilize-item (ewoc-data node)
                              (and pred (funcall pred data))))))

;;; * Outline

;; Most of that code is adapted from outline.el.  I considered simply
;; adapting outline minor mode by changing outline-regexp, but there
;; are too many function keys in that mode which would have to be
;; either turned off or changed.  So just for getting the "cycle"
;; stuff, it would end up in a new minor mode and a lots of
;; modifications. Rather focus on that functionality here.

(defun lister--outline-invisible-p (ewoc pos)
  "Non-nil if the item at POS is hidden as part of an outline.
EWOC is a lister Ewoc object."
  (lister-with-node ewoc pos node
    (let* ((pos (lister--item-beg (ewoc-data node))))
      (eq (get-char-property pos 'invisible) 'outline))))

(defun lister--outline-reveal-at-point (_ovl)
  "In current buffer, reveal the outline item at point."
  (when-let ((ewoc lister-local-ewoc))
    (save-excursion
      (let ((node (lister-get-node-at ewoc :point)))
        (lister-with-sublist-at ewoc node beg end
          (lister--outline-hide-show ewoc beg end nil))))))

(defun lister--outline-hide-show (ewoc beg end state)
  "In EWOC, hide or show the outline from BEG to END.
If STATE is nil, show the items between BEG and END, else hide
them as an outline."
  (lister-with-boundaries ewoc beg end
    (with-current-buffer (ewoc-buffer ewoc)
      ;; we move the overlay one to the left, so that the first LF
      ;; remains visible (it is the cursor gap) and the last LF is
      ;; hidden (it is part of the last item to be made invisible)
      (let ((from (1- (lister--item-beg (ewoc-data beg))))
            (to   (1- (lister--item-end (ewoc-data end)))))
        (remove-overlays from to 'invisible 'outline)
        (when state
          (let ((o (make-overlay from to nil t t)))
            (overlay-put o 'evaporate t)
            (overlay-put o 'invisible 'outline)
            ;; the value of the property 'isearch-open-invisible
            ;; is called as a function when exiting isearch within
            ;; an invisible region:
            (overlay-put o 'isearch-open-invisible 'lister--outline-reveal-at-point)))))))

(defun lister-outline-hide-sublist-below (ewoc pos)
  "In EWOC, hide the sublist below POS as part of an outline."
  (lister-with-sublist-below ewoc pos beg end
    (lister--outline-hide-show ewoc beg end t)))

(defun lister-outline-show-sublist-below (ewoc pos)
  "In EWOC, unhide the sublist below POS as part of an outline."
  (lister-with-sublist-below ewoc pos beg end
    (lister--outline-hide-show ewoc beg end nil)))

(defun lister-outline-cycle-sublist-below (ewoc pos)
  "Toggle the outline visibility of the sublist below POS.
EWOC is a lister Ewoc object."
  (lister-with-sublist-below ewoc pos beg end
    (let* ((state (lister--outline-invisible-p ewoc beg)))
      (lister--outline-hide-show ewoc beg end (not state)))))

(defun lister-outline-show-all (ewoc)
  "In EWOC, show all hidden outlines."
  (lister--outline-hide-show ewoc :first :last nil))

;;; * Interactive Editing

;; Move sublists:

(defun lister--move-list (ewoc beg end target insert-after)
  "Insert items from BEG to END at TARGET according to INSERT-AFTER.
EWOC is a lister ewoc object.  Keep cursor at the node at point."
  (lister-save-current-node ewoc
    (let* ((level (lister-get-level-at ewoc beg))
           (l (lister--get-items ewoc beg end level #'identity)))
      (lister-delete-list ewoc beg end)
      (lister--insert-items ewoc target l level insert-after))))

(defun lister-move-sublist-up (ewoc pos)
  "In EWOC, move sublist at POS one up."
  (when (lister-filter-active-p ewoc)
    (error "Cannot move sublists when filter is active"))
  (lister-with-sublist-at ewoc pos beg end
    (let ((target (ewoc-prev ewoc beg)))
      (if (or (not target)
              (eq target (ewoc-nth ewoc 0)))
          (error "Cannot move sublist further up")
        (lister--move-list ewoc beg end target nil)))))

(defun lister-move-sublist-down (ewoc pos)
  "In EWOC, move sublist at POS one down."
  (when (lister-filter-active-p ewoc)
    (error "Cannot move sublists when filter is active"))
  (lister-with-sublist-at ewoc pos beg end
    (let ((target (ewoc-next ewoc end)))
      (if (not target)
          (error "Cannot move sublist further down")
        (lister--move-list ewoc beg end target t)))))

(defun lister-move-sublist-right (ewoc pos)
  "In EWOC, indent sublist at POS one level."
  (lister-with-sublist-at ewoc pos beg end
    (if (and (eq beg (ewoc-nth ewoc 0))
             (eq end (ewoc-nth ewoc -1)))
        (error "No sublist at this position")
      (lister-save-current-node ewoc
        (lister-dolist-nodes (ewoc node beg end)
          (cl-incf (lister--item-level (ewoc-data node)))
          (ewoc-invalidate ewoc node))))))

(defun lister-move-sublist-left (ewoc pos)
  "In EWOC, decrease level of sublist at POS."
  (lister-with-sublist-at ewoc pos beg end
    (if (eq 0 (lister-node-get-level beg))
        (error "Sublist cannot be moved further left"))
    (lister-save-current-node ewoc
      (lister-dolist-nodes (ewoc node beg end)
        (cl-decf (lister--item-level (ewoc-data node)))
        (ewoc-invalidate ewoc node)))))

;; Move item:

(defun lister--swap-item (ewoc pos1 pos2)
  "In EWOC, swap the items at POS1 and POS2, moving point to POS1."
  (let* ((node1 (lister--parse-position ewoc pos1))
         (node2 (lister--parse-position ewoc pos2)))
    (when (and node1 node2)
      (let* ((item1 (ewoc-data node1))
             (item2 (ewoc-data node2)))
        (setf (ewoc-data node1) item2
              (ewoc-data node2) item1)
        (ewoc-invalidate ewoc node1 node2))
      (lister-goto ewoc node2))))

(defun lister--move-item (ewoc pos move-fn up keep-level)
  "In EWOC, move item at POS up or down.
Move item to the next node in direction of MOVE-FN.  Set UP to a
non-nil value if MOVE-FN goes backwards (upwards).  If KEEP-LEVEL
is non-nil, only consider items with the same indentation level.
Throw an error if there is no next position."
  (let* ((from   (lister--parse-position ewoc pos))
         (next   (funcall move-fn ewoc from))
         (to     (if keep-level
                     (lister--next-node-same-level ewoc from move-fn)
                   next)))
    (unless to
      (error "No movement possible"))
    (if (eq next to)
        (lister--swap-item ewoc from to)
      (lister--move-list ewoc from from to up))))

(defun lister-move-item-up (ewoc pos &optional ignore-level)
  "Move item one up.
Move the item at POS in EWOC up to the next visible item,
swapping both.  Only move within the same indentation level
unless IGNORE-LEVEL is non-nil."
  (lister--move-item ewoc pos #'lister--prev-visible-node
                     t (not ignore-level)))

(defun lister-move-item-down (ewoc pos &optional ignore-level)
  "Move item one down.
Move the item at POS in EWOC down to the next visible item,
swapping both.  Only move within the same indentation level
unless IGNORE-LEVEL is non-nil."
  (lister--move-item ewoc pos #'lister--next-visible-node
                     nil (not ignore-level)))

(defun lister-move-item-right (ewoc pos)
  "In EWOC, increase indentation level of the item at POS."
  (lister-set-level-at ewoc pos (1+ (lister-get-level-at ewoc pos))))

(defun lister-move-item-left (ewoc pos)
  "In EWOC, decrease indentation level of the item at POS."
  (let ((level (lister-get-level-at ewoc pos)))
    (unless (eq level 0)
      (lister-set-level-at ewoc pos (1- level)))))

;;; * Find nodes within the hierarchy

(defun lister-top-sublist-node (ewoc pos)
  "Return the first visible node of the current sublist.
Search within EWOC, beginning from the node at POS."
  (pcase-let ((`(,upper ,_) (lister--locate-sublist ewoc pos :only-visible)))
    upper))

(defun lister-bottom-sublist-node (ewoc pos)
  "Return the last visible node of the current sublist.
Search within EWOC, beginning from the node at POS."
  (pcase-let ((`(,_ ,lower) (lister--locate-sublist ewoc pos :only-visible)))
    lower))

(defun lister-parent-node (ewoc pos)
  "In EWOC, find the first visible parent node of POS.
Return the node.  If POS is not in a sublist or if all parent
nodes are hidden, return the first visible top node.  Return nil
if POS if POS is already at the top, or if no final position can
be found."
  (lister-with-node ewoc pos node
    (let* ((ref-level (lister-node-get-level node))
           ;; if we ever have -compose, write that as a composition
           (pred-fn   (lambda (n)
                        (and (lister-node-visible-p n)
                             (< (lister-node-get-level n)
                                ref-level)))))
      (or
       ;; nil if pos is not in a visible sublist:
       (lister--next-node-matching ewoc node pred-fn #'ewoc-prev)
       ;; else find parent top node:
       (lister--next-or-this-node-matching
        ewoc (ewoc-nth ewoc 0)
        ;; if we ever have -compose, write that as a composition
        (lambda (n)
          (and (lister-node-visible-p n)
               (>= (lister-node-get-level n)
                   ref-level)))
        #'ewoc-next
        node)))))

(defun lister-first-sublist-node (ewoc pos direction)
  "Looking from the list at POS, find the first sublist node.
Return the node or nil if there is none.  DIRECTION must be
either the symbol `up' or `prev', or `down' or `next'.  EWOC is a
Lister EWOC object."
  (lister-with-node ewoc pos node
    (lister-with-sublist-at ewoc pos upper lower
      (let* ((move-fn   (pcase direction
                          ((or 'up 'prev) #'ewoc-prev)
                          ((or 'down 'next) #'ewoc-next)
                          (_ (error "Unknown direction %S" direction))))
             (ref-level (lister-node-get-level (lister--parse-position ewoc pos)))
             (pred-fn   (lambda (n)
                          (and (lister-node-visible-p n)
                               (> (lister-node-get-level n)
                                  ref-level))))
             (limit     (if (eq move-fn #'ewoc-prev) upper lower)))
        (lister--next-node-matching ewoc node pred-fn move-fn limit)))))

;;; * Set up buffer for display
;;;
;;;###autoload
(defun lister-setup (buf-or-name mapper &optional header footer)
  "Set up buffer BUF-OR-NAME for lister lists.  Return an ewoc object.
If BUF-OR-NAME is a buffer object, erase this buffer's content.
Else create a new buffer with the name BUF-OR-NAME.  You can
access this buffer with (ewoc-buffer).

Store MAPPER as a buffer local variable in BUF.

Optionally pass a HEADER or FOOTER string, or lists of strings,
or a function with no arguments returning a string or a lists of
strings."
  (with-current-buffer (get-buffer-create buf-or-name)
    ;; prepare buffer:
    (let ((inhibit-read-only t))
      (erase-buffer)
      (goto-char (point-min)))
    ;; Prepare for outline
    (set (make-local-variable 'line-move-ignore-invisible) t)
    (add-to-invisibility-spec '(outline . t))
    ;; Further settings:
    (setq-local buffer-undo-list t)
    (read-only-mode +1)
    (cursor-intangible-mode +1)
    (setq-local lister-local-mapper mapper)
    ;; create ewoc:
    (let ((ewoc (ewoc-create #'lister--ewoc-printer nil nil t)))
      ;; set separate pprinter for header and footer:
      (setq-local lister-local-ewoc ewoc)
      (setf (ewoc--hf-pp ewoc) #'lister--insert-as-hf)
      (lister-set-header ewoc header)
      (lister-set-footer ewoc footer)
      ewoc)))

(provide 'lister)
;;; lister.el ends here
