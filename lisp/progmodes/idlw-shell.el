;;; idlw-shell.el --- Run IDL or WAVE as an inferior process of Emacs.
;; Copyright (c) 1994-1996 Chris Chase
;; Copyright (c) 1999 Carsten Dominik
;; Copyright (c) 1999 Free Software Foundation

;; Author: Chris Chase <chase@att.com>
;; Maintainer: Carsten Dominik <dominik@strw.leidenuniv.nl>
;; Version: 3.11
;; Date: $Date: 2000/01/03 14:19:10 $
;; Keywords: processes

;; This file is part of GNU Emacs.

;; GNU Emacs is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:

;; This mode is for IDL version 4 or later.  It should work on Emacs
;; or XEmacs version 19 or later.

;; Runs IDL as an inferior process of Emacs, much like the emacs
;; `shell' or `telnet' commands.  Provides command history and
;; searching.  Provides debugging commands available in buffers
;; visiting IDL procedure files, e.g., breakpoint setting, stepping,
;; execution until a certain line, printing expressions under point,
;; visual line pointer for current execution line, etc.
;;
;; Documentation should be available online with `M-x idlwave-info'.

;; INSTALLATION:
;; =============
;; 
;; Follow the instructions in the INSTALL file of the distribution.
;; In short, put this file on your load path and add the following
;; lines to your .emacs file:
;;
;; (autoload 'idlwave-shell "idlw-shell" "IDLWAVE Shell" t)
;;
;;
;; SOURCE
;; ======
;;
;;   The newest version of this file can be found on the maintainers
;;   web site.
;; 
;;     http://www.strw.leidenuniv.el/~dominik/Tools/idlwave
;; 
;; DOCUMENTATION
;; =============
;;
;; IDLWAVE is documented online in info format.
;; A printable version of the documentation is available from the
;; maintainers webpage (see under SOURCE)
;;
;;
;; KNOWN PROBLEMS
;; ==============
;;
;; The idlwave-shell buffer seems to occasionally lose output from the IDL
;; process.  I have not been able to consistently observe this.  I
;; do not know if it is a problem with idlwave-shell, comint, or Emacs
;; handling of subprocesses.
;; 
;; I don't plan on implementing directory tracking by watching the IDL
;; commands entered at the prompt, since too often an IDL procedure
;; will change the current directory. If you want the the idl process
;; buffer to match the IDL current working just execute `M-x
;; idlwave-shell-resync-dirs' (bound to "\C-c\C-d\C-w" by default.)
;;
;; The stack motion commands `idlwave-shell-stack-up' and
;; `idlwave-shell-stack-down' only display the calling frame but
;; cannot show the values of variables in higher frames correctly.  I
;; just don't know how to get these values from IDL.  Anyone knows the 
;; magic word to do this?
;; Also, the stack pointer stays at the level where is was and is not
;; reset correctly when you type executive commands in the shell buffer
;; yourself.  However, using the executive commands bound to key sequences
;; does the reset correctly.  As a workaround, just jump down when needed.
;; 
;; Under XEmacs the Debug menu in the shell does not display the
;; keybindings in the prefix map.  There bindings are available anyway - so
;; it is a bug in XEmacs.
;; The Debug menu in source buffers does display the bindings correctly.
;;
;; 
;; CUSTOMIZATION VARIABLES
;; =======================
;;
;; IDLWAVE has customize support - so if you want to learn about
;; the variables which control the behavior of the mode, use
;; `M-x idlwave-customize'.
;;
;;--------------------------------------------------------------------------
;;
;;

;;; Code:

(require 'comint)
(require 'idlwave)

(eval-when-compile (require 'cl))

(defvar idlwave-shell-have-new-custom nil)
(eval-and-compile
  ;; Kludge to allow `defcustom' for Emacs 19.
  (condition-case () (require 'custom) (error nil))
  (if (and (featurep 'custom)
	   (fboundp 'custom-declare-variable)
	   (fboundp 'defface))	   
      ;; We've got what we needed
      (setq idlwave-shell-have-new-custom t)
    ;; We have the old or no custom-library, hack around it!
    (defmacro defgroup (&rest args) nil)
    (defmacro defcustom (var value doc &rest args) 
      (` (defvar (, var) (, value) (, doc))))))

;;; Customizations: idlwave-shell group

(defgroup idlwave-shell-general-setup nil
  "Indentation options for IDL/WAVE mode."
  :prefix "idlwave"
  :group 'idlwave)

(defcustom idlwave-shell-prompt-pattern "^ ?IDL> "
  "*Regexp to match IDL prompt at beginning of a line. 
For example, \"^IDL> \" or \"^WAVE> \". 
The \"^\" means beginning of line.
This variable is used to initialise `comint-prompt-regexp' in the 
process buffer.

This is a fine thing to set in your `.emacs' file."
  :group 'idlwave-shell-general-setup
  :type 'regexp)

(defcustom idlwave-shell-process-name "idl"
  "*Name to be associated with the IDL process.  The buffer for the
process output is made by surrounding this name with `*'s."
  :group 'idlwave-shell-general-setup
  :type 'string)

(defcustom idlwave-shell-automatic-start nil
  "*If non-nil attempt invoke idlwave-shell if not already running.
This is checked when an attempt to send a command to an
IDL process is made."
  :group 'idlwave-shell-general-setup
  :type 'boolean)

(defcustom idlwave-shell-initial-commands "!more=0"
  "Initial commands, separated by newlines, to send to IDL.
This string is sent to the IDL process by `idlwave-shell-mode' which is
invoked by `idlwave-shell'."
  :group 'idlwave-shell-initial-commands
  :type 'string)

(defcustom idlwave-shell-use-dedicated-frame nil
  "*Non-nil means, IDLWAVE should use a special frame to display shell buffer."
  :group 'idlwave-shell-general-setup
  :type 'boolean)

(defcustom idlwave-shell-frame-parameters
  '((height . 30) (unsplittable . nil))
  "The frame parameters for a dedicated idlwave-shell frame.
See also `idlwave-shell-use-dedicated-frame'.
The default makes the frame splittable, so that completion works correctly."
  :group 'idlwave-shell-general-setup
  :type '(repeat
	  (cons symbol sexp)))

(defcustom idlwave-shell-use-toolbar t
  "Non-nil means, use the debugging toolbar in all IDL related buffers.
Available on XEmacs and on Emacs 21.x or later.
Needs to be set at load-time, so don't try to do this in the hook."
  :group 'idlwave-shell-general-setup
  :type 'boolean)

(defcustom idlwave-shell-temp-pro-prefix "/tmp/idltemp"
  "*The prefix for temporary IDL files used when compiling regions.
It should be an absolute pathname.
The full temporary file name is obtained by to using `make-temp-name'
so that the name will be unique among multiple Emacs processes."
  :group 'idlwave-shell-general-setup
  :type 'string)

(defvar idlwave-shell-fix-inserted-breaks nil
  "*OBSOLETE VARIABLE, is no longer used.

The documentation of this variable used to be:
If non-nil then run `idlwave-shell-remove-breaks' to clean up IDL messages.")

(defcustom idlwave-shell-prefix-key "\C-c\C-d"
  "*The prefix key for the debugging map `idlwave-shell-mode-prefix-map'.
This variable must already be set when idlwave-shell.el is loaded.
Seting it in the mode-hook is too late."
  :group 'idlwave-shell-general-setup
  :type 'string)

(defcustom idlwave-shell-activate-prefix-keybindings t
  "Non-nil means, the debug commands will be bound to the prefix key.
The prefix key itself is given in the option `idlwave-shell-prefix-key'.
So by default setting a breakpoint will be on C-c C-d C-b."
  :group 'idlwave-shell-general-setup
  :type 'boolean)

(defcustom idlwave-shell-activate-alt-keybindings nil
  "Non-nil means, the debug commands will be bound to alternate keys.
So for example setting a breakpoint will be on A-b."
  :group 'idlwave-shell-general-setup
  :type 'boolean)

(defcustom idlwave-shell-use-truename nil
  "*Non-nil means, use use `file-truename' when looking for buffers.
If this variable is non-nil, Emacs will use the function `file-truename' to
resolve symbolic links in the file paths printed by e.g., STOP commands.
This means, unvisited files will be loaded under their truename.
However, when a file is already visited under a deffernet name, IDLWAVE will
reuse that buffer.
This option was once introduced in order to avoid multiple buffers visiting
the same file.  However, IDLWAVE no longer makes this mistake, so it is safe
to set this option to nil."
  :group 'idlwave-shell-general-setup
  :type 'boolean)

(defcustom idlwave-shell-file-name-chars "~/A-Za-z0-9+@:_.$#%={}-"
  "The characters allowed in file names, as a string.
Used for file name completion. Must not contain `'', `,' and `\"'
because these are used as separators by IDL."
  :group 'idlwave-shell-general-setup
  :type 'string)

(defcustom idlwave-shell-mode-hook '()
  "*Hook for customising `idlwave-shell-mode'."
  :group 'idlwave-shell-general-setup
  :type 'hook)

;;; Breakpoint Overlays etc

(defgroup idlwave-shell-highlighting-and-faces nil
  "Indentation options for IDL/WAVE mode."
  :prefix "idlwave"
  :group 'idlwave)

(defcustom idlwave-shell-mark-stop-line t
  "*Non-nil means, mark the source code line where IDL is currently stopped.
Value decides about the method which is used to mark the line.  Legal values
are:

nil       Do not mark the line
'arrow    Use the overlay arrow
'face     Use `idlwave-shell-stop-line-face' to highlight the line.
t         Use what IDLWAVE things is best.  Will be a face where possible,
          otherwise the overlay arrow.
The overlay-arrow has the disadvantage to hide the first chars of a line.
Since many people do not have the main block of IDL programs indented,
a face highlighting may be better.
On Emacs 21, the overlay arrow is displayed in a special area and never
hides any code, so setting this to 'arrow on Emacs 21 sounds like a good idea."
  :group 'idlwave-shell-highlighting-and-faces
  :type '(choice
	  (const :tag "No marking" nil)
	  (const :tag "Use overlay arrow" arrow)
	  (const :tag "Highlight with face" face)
	  (const :tag "Face or arrow." t)))

(defcustom idlwave-shell-overlay-arrow ">"
  "*The overlay arrow to display at source lines where execution halts.
We use a single character by default, since the main block of IDL procedures
often has no indentation.  Where possible, IDLWAVE will use overlays to
display the stop-lines.  The arrow is only used on character-based terminals.
See also `idlwave-shell-use-overlay-arrow'."
  :group 'idlwave-shell-highlighting-and-faces
  :type 'string)

(defcustom idlwave-shell-stop-line-face 'highlight
  "*The face for `idlwave-shell-stop-line-overlay'.
Allows you to choose the font, color and other properties for
line where IDL is stopped.  See also `idlwave-shell-mark-stop-line'."
  :group 'idlwave-shell-highlighting-and-faces
  :type 'symbol)

(defcustom idlwave-shell-expression-face 'secondary-selection
  "*The face for `idlwave-shell-expression-overlay'.
Allows you to choose the font, color and other properties for
the expression printed by IDL."
  :group 'idlwave-shell-highlighting-and-faces
  :type 'symbol)

(defcustom idlwave-shell-mark-breakpoints t
  "*Non-nil means, mark breakpoints in the source files.
Legal values are:
nil        Do not mark breakpoints.
'face      Highlight line with `idlwave-shell-breakpoint-face'.
'glyph     Red dot at the beginning of line.  If the display does not
           support glyphs, will use 'face instead.
t          Glyph when possible, otherwise face (same effect as 'glyph)."
  :group 'idlwave-shell-highlighting-and-faces
  :type '(choice
	  (const :tag "No marking" nil)
	  (const :tag "Highlight with face" face)
	  (const :tag "Display glyph (red dot)" glyph)
	  (const :tag "Glyph or face." t)))

(defvar idlwave-shell-use-breakpoint-glyph t
  "Obsolete variable.   See `idlwave-shell-mark-breakpoints.")

(defcustom idlwave-shell-breakpoint-face 'idlwave-shell-bp-face
  "*The face for breakpoint lines in the source code.
Allows you to choose the font, color and other properties for
lines which have a breakpoint.  See also `idlwave-shell-mark-breakpoints'."
  :group 'idlwave-shell-highlighting-and-faces
  :type 'symbol)

(if idlwave-shell-have-new-custom
    ;; We have the new customize - use it to define a customizable face
    (defface idlwave-shell-bp-face
      '((((class color)) (:foreground "Black" :background "Pink"))
	(t (:underline t)))
      "Face for highlighting lines-with-breakpoints."
      :group 'idlwave-shell-highlighting-and-faces)
  ;; Just copy the underline face to be on the safe side.
  (copy-face 'underline 'idlwave-shell-bp-face))

;;; End user customization variables

;;; External variables
(defvar comint-last-input-start)
(defvar comint-last-input-end)

;; Other variables

(defvar idlwave-shell-temp-pro-file nil
  "Absolute pathname for temporary IDL file for compiling regions")

(defvar idlwave-shell-dirstack-query "printd"
  "Command used by `idlwave-shell-resync-dirs' to query IDL for 
the directory stack.")

(defvar idlwave-shell-default-directory nil
  "The default directory in the idlwave-shell buffer, of outside use.")

(defvar idlwave-shell-last-save-and-action-file nil
  "The last file which was compiled with `idlwave-shell-save-and-...'.")

;; Highlighting uses overlays.  When necessary, require the emulation.
(if (not (fboundp 'make-overlay))
    (condition-case nil
	(require 'overlay)
      (error nil)))

(defvar idlwave-shell-stop-line-overlay nil
  "The overlay for where IDL is currently stopped.")
(defvar idlwave-shell-expression-overlay nil
  "The overlay for where IDL is currently stopped.")
;; If these were already overlays, delete them.  This probably means that we
;; are reloading this file.
(if (overlayp idlwave-shell-stop-line-overlay)
    (delete-overlay idlwave-shell-stop-line-overlay))
(if (overlayp idlwave-shell-expression-overlay)
    (delete-overlay idlwave-shell-expression-overlay))
;; Set to nil initially
(setq idlwave-shell-stop-line-overlay nil
      idlwave-shell-expression-overlay nil)

;; Define the shell stop overlay.  When left nil, the arrow will be used.
(cond
 ((or (null idlwave-shell-mark-stop-line)
      (eq idlwave-shell-mark-stop-line 'arrow))
  ;; Leave the overlay nil
  nil)

 ((eq idlwave-shell-mark-stop-line 'face)
  ;; Try to use a face.  If not possible, arrow will be used anyway
  ;; So who can display faces?
  (when (or (featurep 'xemacs)            ; XEmacs can do also ttys
	    (fboundp 'tty-defined-colors) ; Emacs 21 as well
	    window-system)                ; Window systems always
    (progn
      (setq idlwave-shell-stop-line-overlay (make-overlay 1 1))
      (overlay-put idlwave-shell-stop-line-overlay 
		   'face idlwave-shell-stop-line-face))))

 (t
  ;; IDLWAVE may decide.  Will use a face on window systems, arrow elsewhere
  (if window-system
      (progn
	(setq idlwave-shell-stop-line-overlay (make-overlay 1 1))
	(overlay-put idlwave-shell-stop-line-overlay 
		     'face idlwave-shell-stop-line-face)))))

;; Now the expression overlay
(setq idlwave-shell-expression-overlay (make-overlay 1 1))
(overlay-put idlwave-shell-expression-overlay
	     'face idlwave-shell-expression-face)

(defvar idlwave-shell-bp-query "help,/breakpoints"
  "Command to obtain list of breakpoints")

(defvar idlwave-shell-command-output nil
  "String for accumulating current command output.")

(defvar idlwave-shell-post-command-hook nil
  "Lisp list expression or function to run when an IDL command is finished.
The current command is finished when the IDL prompt is displayed.
This is evaluated if it is a list or called with funcall.")

(defvar idlwave-shell-hide-output nil
  "If non-nil the process output is not inserted into the output
  buffer.")

(defvar idlwave-shell-accumulation nil
  "Accumulate last line of output.")

(defvar idlwave-shell-command-line-to-execute nil)
(defvar idlwave-shell-cleanup-hook nil
  "List of functions to do cleanup when the shell exits.")

(defvar idlwave-shell-pending-commands nil
  "List of commands to be sent to IDL.
Each element of the list is list of \(CMD PCMD HIDE\), where CMD is a
string to be sent to IDL and PCMD is a post-command to be placed on
`idlwave-shell-post-command-hook'. If HIDE is non-nil, hide the output
from command CMD. PCMD and HIDE are optional.")

(defun idlwave-shell-buffer ()
  "Name of buffer associated with IDL process.
The name of the buffer is made by surrounding `idlwave-shell-process-name
with `*'s."
  (concat "*" idlwave-shell-process-name "*"))

(defvar idlwave-shell-ready nil
  "If non-nil can send next command to IDL process.")

;;; The following are the types of messages we attempt to catch to
;;; resync our idea of where IDL execution currently is.
;;; 

(defvar idlwave-shell-halt-frame nil
  "The frame associated with halt/breakpoint messages.")

(defvar idlwave-shell-step-frame nil
  "The frame associated with step messages.")

(defvar idlwave-shell-trace-frame nil
  "The frame associated with trace messages.")

(defconst idlwave-shell-halt-messages
  '("^% Execution halted at"
    "^% Interrupted at:"
    "^% Stepped to:"
    "^% At "
    "^% Stop encountered:"
    )
  "*A list of regular expressions matching IDL messages.
These are the messages containing file and line information where
IDL is currently stopped.")

(defconst idlwave-shell-halt-messages-re
  (mapconcat 'identity idlwave-shell-halt-messages "\\|")
  "The regular expression computed from idlwave-shell-halt-messages")

(defconst idlwave-shell-trace-messages
  '("^% At "    ;; First line of a trace message
    )
  "*A list of regular expressions matching IDL trace messages.
These are the messages containing file and line information where
IDL will begin looking for the next statement to execute.")

(defconst idlwave-shell-step-messages
  '("^% Stepped to:"
    )
  "*A list of regular expressions matching stepped execution messages.
These are IDL messages containing file and line information where
IDL has currently stepped.")

(defvar idlwave-shell-break-message "^% Breakpoint at:"
  "*Regular expression matching an IDL breakpoint message line.")


(defvar idlwave-shell-bp-alist)
;(defvar idlwave-shell-post-command-output)
(defvar idlwave-shell-sources-alist)
(defvar idlwave-shell-menu-def)
(defvar idlwave-shell-mode-menu)
(defvar idlwave-shell-initial-commands)
(defvar idlwave-shell-syntax-error)
(defvar idlwave-shell-other-error)
(defvar idlwave-shell-error-buffer)
(defvar idlwave-shell-error-last)
(defvar idlwave-shell-bp-buffer)
(defvar idlwave-shell-sources-query)
(defvar idlwave-shell-mode-map)

(defun idlwave-shell-mode ()
  "Major mode for interacting with an inferior IDL process.

1. Shell Interaction
   -----------------
   RET after the end of the process' output sends the text from the
   end of process to the end of the current line.  RET before end of
   process output copies the current line (except for the prompt) to the
   end of the buffer.

   Command history, searching of previous commands, command line
   editing are available via the comint-mode key bindings, by default
   mostly on the key `C-c'.

2. Completion
   ----------

   TAB and M-TAB do completion of IDL routines and keywords - similar
   to M-TAB in `idlwave-mode'.  In executive commands and strings,
   it completes file names.

3. Routine Info
   ------------
   `\\[idlwave-routine-info]' displays information about an IDL routine near point,
   just like in `idlwave-mode'.  The module used is the one at point or
   the one whose argument list is being edited.
   To update IDLWAVE's knowledge about compiled or edited modules, use 
   \\[idlwave-update-routine-info].
   \\[idlwave-find-module] find the source of a module.
   \\[idlwave-resolve] tells IDL to compile an unresolved module.

4. Debugging
   ---------
   A complete set of commands for compiling and debugging IDL programs
   is available from the menu.  Also keybindings starting with a 
   `C-c C-d' prefix are available for most commands in the *idl* buffer
   and also in source buffers.  The best place to learn about the
   keybindings is again the menu.

   On Emacs versions where this is possible, a debugging toolbar is
   installed.

   When IDL is halted in the middle of a procedure, the corresponding
   line of that procedure file is displayed with an overlay in another
   window.  Breakpoints are also highlighted in the source.

   \\[idlwave-shell-resync-dirs] queries IDL in order to change Emacs current directory
   to correspond to the IDL process current directory.

5. Hooks
   -----
   Turning on `idlwave-shell-mode' runs `comint-mode-hook' and
   `idlwave-shell-mode-hook' (in that order).

6. Documentation and Customization
   -------------------------------
   Info documentation for this package is available.  Use \\[idlwave-info]
   to display (complain to your sysadmin if that does not work).
   For Postscript and HTML versions of the documentation, check IDLWAVE's
   homepage at `http://www.strw.leidenuniv.nl/~dominik/Tools/idlwave'.
   IDLWAVE has customize support - see the group `idlwave'.

7. Keybindings
   -----------
\\{idlwave-shell-mode-map}"

  (interactive)
  (setq comint-prompt-regexp idlwave-shell-prompt-pattern)
  (setq comint-process-echoes t)
  ;; Can not use history expansion because "!" is used for system variables.
  (setq comint-input-autoexpand nil)
  (setq comint-input-ring-size 64)
  (make-local-variable 'comint-completion-addsuffix)
  (set (make-local-variable 'completion-ignore-case) t)
  (setq comint-completion-addsuffix '("/" . ""))
  (setq comint-input-ignoredups t)
  (setq major-mode 'idlwave-shell-mode)
  (setq mode-name "IDL-Shell")
  ;; (make-local-variable 'idlwave-shell-bp-alist)
  (setq idlwave-shell-halt-frame nil
        idlwave-shell-trace-frame nil
        idlwave-shell-command-output nil
        idlwave-shell-step-frame nil)
  (idlwave-shell-display-line nil)
  ;; Make sure comint-last-input-end does not go to beginning of
  ;; buffer (in case there were other processes already in this buffer).
  (set-marker comint-last-input-end (point))
  (setq idlwave-shell-ready nil)
  (setq idlwave-shell-bp-alist nil)
  (idlwave-shell-update-bp-overlays) ; Throw away old overlays
  (setq idlwave-shell-sources-alist nil)
  (setq idlwave-shell-default-directory default-directory)
  ;; (make-local-variable 'idlwave-shell-temp-pro-file)
  (setq idlwave-shell-hide-output nil
        idlwave-shell-temp-pro-file
        (concat (make-temp-name idlwave-shell-temp-pro-prefix) ".pro"))
  (make-local-hook 'kill-buffer-hook)
  (add-hook 'kill-buffer-hook 'idlwave-shell-kill-shell-buffer-confirm
	    nil 'local)
  (use-local-map idlwave-shell-mode-map)
  (easy-menu-add idlwave-shell-mode-menu idlwave-shell-mode-map)
  (run-hooks 'idlwave-shell-mode-hook)
  (idlwave-shell-send-command idlwave-shell-initial-commands nil 'hide)
  )

(if (not (fboundp 'idl-shell))
    (fset 'idl-shell 'idlwave-shell))

(defvar idlwave-shell-idl-wframe nil
  "Frame for displaying the idl shell window.")
(defvar idlwave-shell-display-wframe nil
  "Frame for displaying the idl source files.")

(defvar idlwave-shell-last-calling-stack nil
  "Caches the last calling stack, so that we can compare.")
(defvar idlwave-shell-calling-stack-index 0)

(defun idlwave-shell-source-frame ()
  "Return the frame to be used for source display."
  (if idlwave-shell-use-dedicated-frame
      ;; We want separate frames for source and shell
      (if (frame-live-p idlwave-shell-display-wframe)
	  ;; The frame exists, so we use it.
	  idlwave-shell-display-wframe
	;; The frame does not exist.  We use the current frame.
	;; However, if the current is the shell frame, we make a new frame.
	(setq idlwave-shell-display-wframe
	      (if (eq (selected-frame) idlwave-shell-idl-wframe)
		  (make-frame)
		(selected-frame))))))

(defun idlwave-shell-shell-frame ()
  "Return the frame to be used for the shell buffer."
  (if idlwave-shell-use-dedicated-frame
      ;; We want a dedicated frame
      (if (frame-live-p idlwave-shell-idl-wframe)
	  ;; It does exist, so we use it.
	  idlwave-shell-idl-wframe
	;; It does not exist.  Check if we have a source frame.
	(if (not (frame-live-p idlwave-shell-display-wframe))
	    ;; We do not have a source frame, so we use this one.
	    (setq idlwave-shell-display-wframe (selected-frame)))
	;; Return a new frame
	(setq idlwave-shell-idl-wframe 
	      (make-frame idlwave-shell-frame-parameters)))))
  
;;;###autoload
(defun idlwave-shell (&optional arg)
  "Run an inferior IDL, with I/O through buffer `(idlwave-shell-buffer)'.
If buffer exists but shell process is not running, start new IDL.
If buffer exists and shell process is running, just switch to the buffer.

When called with a prefix ARG, or when `idlwave-shell-use-dedicated-frame'
is non-nil, the shell buffer and the source buffers will be in
separate frames.

The command to run comes from variable `idlwave-shell-explicit-file-name'.

The buffer is put in `idlwave-shell-mode', providing commands for sending
input and controlling the IDL job.  See help on `idlwave-shell-mode'.
See also the variable `idlwave-shell-prompt-pattern'.

\(Type \\[describe-mode] in the shell buffer for a list of commands.)"
  (interactive "P")

  ;; A non-nil arg means, we want a dedicated frame.  This will last
  ;; for the current editing session.
  (if arg (setq idlwave-shell-use-dedicated-frame t))
  (if (equal arg '(16)) (setq idlwave-shell-use-dedicated-frame nil))

  ;; Check if the process still exists.  If not, create it.
  (unless (comint-check-proc (idlwave-shell-buffer))
    (let* ((prg (or idlwave-shell-explicit-file-name "idl"))
	   (buf (apply 'make-comint
		       idlwave-shell-process-name prg nil
		       idlwave-shell-command-line-options))
	   ;; FIXME: the next line can go?
	   ;(buf (make-comint idlwave-shell-process-name prg))
	   (process (get-buffer-process buf)))
      (set-process-filter process 'idlwave-shell-filter)
      (set-process-sentinel process 'idlwave-shell-sentinel)
      (set-buffer buf)
      (idlwave-shell-mode)))
  (let ((window (idlwave-display-buffer (idlwave-shell-buffer) nil
					(idlwave-shell-shell-frame)))
	(current-window (selected-window)))
    (select-window window)
    (goto-char (point-max))
    (select-window current-window)    
    (raise-frame (window-frame window))
    (if (eq (selected-frame) (window-frame window))
	(select-window window))
    ))

(defun idlwave-shell-recenter-shell-window (&optional arg)
  "Run `idlwave-shell', but make sure the current window stays selected."
  (interactive "P")
  (let ((window (selected-window)))
    (idlwave-shell arg)
    (select-window window)))

(defun idlwave-shell-send-command (&optional cmd pcmd hide preempt)
  "Send a command to IDL process.

\(CMD PCMD HIDE\) are placed at the end of `idlwave-shell-pending-commands'.
If IDL is ready the first command, CMD, in
`idlwave-shell-pending-commands' is sent to the IDL process.  If optional
second argument PCMD is non-nil it will be placed on
`idlwave-shell-post-command-hook' when CMD is executed.  If the optional
third argument HIDE is non-nil, then hide output from CMD.
If optional fourth argument PREEMPT is non-nil CMD is put at front of
`idlwave-shell-pending-commands'.

IDL is considered ready if the prompt is present
and if `idlwave-shell-ready' is non-nil."

  ;(setq hide nil)  ;  FIXME: turn this on for debugging only
  (let (buf proc)
    ;; Get or make the buffer and its process
    (if (or (not (setq buf (get-buffer (idlwave-shell-buffer))))
	    (not (setq proc (get-buffer-process buf))))
	(if (not idlwave-shell-automatic-start)
	    (error
	     (substitute-command-keys
	      "You need to first start an IDL shell with \\[idlwave-shell]"))
	  (idlwave-shell-recenter-shell-window)
	  (setq buf (get-buffer (idlwave-shell-buffer)))
	  (if (or (not (setq buf (get-buffer (idlwave-shell-buffer))))
		  (not (setq proc (get-buffer-process buf))))
	      ;; Still nothing
	      (error "Problem with autostarting IDL shell"))))

    (save-excursion
      (set-buffer buf)
      (goto-char (process-mark proc))
      ;; To make this easy, always push CMD onto pending commands
      (if cmd
          (setq idlwave-shell-pending-commands
                (if preempt
                    ;; Put at front.
                    (append (list (list cmd pcmd hide))
                            idlwave-shell-pending-commands)
                  ;; Put at end.
                  (append idlwave-shell-pending-commands 
                          (list (list cmd pcmd hide))))))
      ;; Check if IDL ready
      (if (and idlwave-shell-ready
               ;; Check for IDL prompt
               (save-excursion
                 (beginning-of-line)
                 (looking-at idlwave-shell-prompt-pattern)))
          ;; IDL ready for command
          (if idlwave-shell-pending-commands
              ;; execute command
              (let* ((lcmd (car idlwave-shell-pending-commands))
		     (cmd (car lcmd))
                     (pcmd (nth 1 lcmd))
                     (hide (nth 2 lcmd)))
		;; If this is an executive command, reset the stack pointer
		(if (eq (string-to-char cmd) ?.)
		    (setq idlwave-shell-calling-stack-index 0))
                ;; Set post-command
                (setq idlwave-shell-post-command-hook pcmd)
                ;; Output hiding
;;; Debug code          
;;;             (setq idlwave-shell-hide-output nil)
                (setq idlwave-shell-hide-output hide)
                ;; Pop command
                (setq idlwave-shell-pending-commands
                      (cdr idlwave-shell-pending-commands))
                ;; Send command for execution
                (set-marker comint-last-input-start (point))
                (set-marker comint-last-input-end (point))
                (comint-simple-send proc cmd)
                (setq idlwave-shell-ready nil)))))))

;; There was a report that a newer version of comint.el changed the
;; name of comint-filter to comint-output-filter.  Unfortunately, we
;; have yet to upgrade.

(defun idlwave-shell-comint-filter (process string) nil)
(if (fboundp 'comint-output-filter)
    (fset 'idlwave-shell-comint-filter (symbol-function 'comint-output-filter))
  (fset 'idlwave-shell-comint-filter (symbol-function 'comint-filter)))

(defun idlwave-shell-is-running ()
  "Return t if the shell process is running."
  (eq (process-status idlwave-shell-process-name) 'run))

(defun idlwave-shell-filter (proc string)
  "Replace Carriage returns in output. Watch for prompt.
When the IDL prompt is received executes `idlwave-shell-post-command-hook'
and then calls `idlwave-shell-send-command' for any pending commands."
  ;; We no longer do the cleanup here - this is done by the process sentinel
  (when (eq (process-status idlwave-shell-process-name) 'run)
    ;; OK, process is still running, so we can use it.
    (let ((data (match-data)))
      (unwind-protect
          (progn
            ;; May change the original match data.
            (let (p)
              (while (setq p (string-match "\C-M" string))
                (aset string p ?  )))
;;; Test/Debug code
;;          (save-excursion (set-buffer (get-buffer-create "*test*"))
;;                          (goto-char (point-max))
;;                          (insert "%%%" string))
            ;;
            ;; Keep output

; Should not keep output because the concat is costly.  If hidden put
; the output in a hide-buffer.  Then when the output is needed in post
; processing can access either the hide buffer or the idlwave-shell
; buffer.  Then watching for the prompt is easier.  Furthermore, if it
; is hidden and there is no post command, could throw away output.
;           (setq idlwave-shell-command-output
;                 (concat idlwave-shell-command-output string))
            ;; Insert the string. Do this before getting the
            ;; state. 
            (if idlwave-shell-hide-output
                (save-excursion
                  (set-buffer
                   (get-buffer-create "*idlwave-shell-hidden-output*"))
                  (goto-char (point-max))
                  (insert string))
              (idlwave-shell-comint-filter proc string))
            ;; Watch for prompt - need to accumulate the current line
            ;; since it may not be sent all at once.
            (if (string-match "\n" string)
                (setq idlwave-shell-accumulation
                      (substring string 
                                 (progn (string-match "\\(.*\n\\)*" string)
                                        (match-end 0))))
              (setq idlwave-shell-accumulation
                    (concat idlwave-shell-accumulation string)))
            ;; Check for prompt in current line 
            (if (setq idlwave-shell-ready
                      (string-match idlwave-shell-prompt-pattern
                                    idlwave-shell-accumulation))
                (progn
                  (if idlwave-shell-hide-output
                      (save-excursion
                        (set-buffer "*idlwave-shell-hidden-output*")
                        (goto-char (point-min))
                        (re-search-forward idlwave-shell-prompt-pattern nil t)
                        (setq idlwave-shell-command-output
                              (buffer-substring (point-min) (point)))
                        (delete-region (point-min) (point)))
                    (setq idlwave-shell-command-output
                          (save-excursion
                            (set-buffer
                             (process-buffer proc))
                            (buffer-substring
                             (progn
                               (goto-char (process-mark proc))
                               (beginning-of-line nil)
                               (point))
                             comint-last-input-end))))
;;; Test/Debug code
;;                (save-excursion (set-buffer
;;                                 (get-buffer-create "*idlwave-shell-output*"))
;;                                (goto-char (point-max))
;;                                (insert "%%%" string))
                  ;; Scan for state and do post command - bracket them
                  ;; with idlwave-shell-ready=nil since they
                  ;; may call idlwave-shell-send-command.
                  (let ((idlwave-shell-ready nil))
                    (idlwave-shell-scan-for-state)
                    ;; Unset idlwave-shell-ready to prevent sending
                    ;; commands to IDL while running hook.
                    (if (listp idlwave-shell-post-command-hook)
                        (eval idlwave-shell-post-command-hook)
                      (funcall idlwave-shell-post-command-hook))
                    ;; Reset to default state for next command.
                    ;; Also we do not want to find this prompt again.
                    (setq idlwave-shell-accumulation nil
                          idlwave-shell-command-output nil
                          idlwave-shell-post-command-hook nil
                          idlwave-shell-hide-output nil))
                  ;; Done with post command. Do pending command if
                  ;; any.
                  (idlwave-shell-send-command))))
        (store-match-data data)))))

(defun idlwave-shell-sentinel (process event)
  "The sentinel function for the IDLWAVE shell process."
  (let* ((buf (idlwave-shell-buffer))
	 (win (get-buffer-window buf)))
    (when (get-buffer buf)
      (save-excursion
	(set-buffer (idlwave-shell-buffer))
	(goto-char (point-max))
	(insert (format "\n\n  Process %s %s" process event))))
    (when (and (> (length (frame-list)) 1)
	       (frame-live-p idlwave-shell-idl-wframe))
      (delete-frame idlwave-shell-idl-wframe)
      (setq idlwave-shell-idl-wframe nil
	    idlwave-shell-display-wframe nil))
    (when (window-live-p win)
      (delete-window win))
    (idlwave-shell-cleanup)))

(defun idlwave-shell-scan-for-state ()
  "Scan for state info.
Looks for messages in output from last IDL command indicating where
IDL has stopped. The types of messages we are interested in are
execution halted, stepped, breakpoint, interrupted at and trace
messages.  We ignore error messages otherwise.
For breakpoint messages process any attached count or command
parameters.
Update the windows if a message is found."
  (let (update)
    (cond
     ;; Make sure we have output
     ((not idlwave-shell-command-output))

     ;; Various types of HALT messages.
     ((string-match idlwave-shell-halt-messages-re
		    idlwave-shell-command-output)
      ;; Grab the file and line state info.
      (setq idlwave-shell-halt-frame
            (idlwave-shell-parse-line 
             (substring idlwave-shell-command-output (match-end 0)))
            update t))

     ;; Handle breakpoints separately
     ((string-match idlwave-shell-break-message
                    idlwave-shell-command-output)
      (setq idlwave-shell-halt-frame 
            (idlwave-shell-parse-line 
             (substring idlwave-shell-command-output (match-end 0)))
            update t)
      ;; We used to to counting hits on breakpoints
      ;; this is no longer supported since IDL breakpoints
      ;; have learned counting.
      ;; Do breakpoint command processing
      (let ((bp (assoc 
                 (list
                  (nth 0 idlwave-shell-halt-frame)
                  (nth 1 idlwave-shell-halt-frame))
                 idlwave-shell-bp-alist)))
        (if bp
            (let ((cmd (idlwave-shell-bp-get bp 'cmd)))
              (if cmd
                  ;; Execute command
                  (if (listp cmd)
                      (eval cmd)
                    (funcall cmd))))
          ;; A breakpoint that we did not know about - perhaps it was
          ;; set by the user or IDL isn't reporting breakpoints like
          ;; we expect.  Lets update our list.
          (idlwave-shell-bp-query)))))

    ;; Handle compilation errors in addition to the above
    (if (and idlwave-shell-command-output
             (or (string-match
                  idlwave-shell-syntax-error idlwave-shell-command-output)
                 (string-match
                  idlwave-shell-other-error idlwave-shell-command-output)))
	(progn
	  (save-excursion
	    (set-buffer
	     (get-buffer-create idlwave-shell-error-buffer))
	    (erase-buffer)
	    (insert idlwave-shell-command-output)
	    (goto-char (point-min))
	    (setq idlwave-shell-error-last (point)))
          (idlwave-shell-goto-next-error)))
    
    ;; Do update
    (when update
      (idlwave-shell-display-line (idlwave-shell-pc-frame)))))


(defvar idlwave-shell-error-buffer
  "*idlwave-shell-errors*"
  "Buffer containing syntax errors from IDL compilations.")

;; FIXME: the following two variables do not currently allow line breaks
;; in module and file names.  I am not sure if it will be necessary to
;; change this.  Currently it seems to work the way it is.
(defvar idlwave-shell-syntax-error
  "^% Syntax error.\\s-*\n\\s-*At:\\s-*\\(.*\\),\\s-*Line\\s-*\\(.*\\)"  
  "A regular expression to match an IDL syntax error.
The first \(..\) pair should match the file name.  The second pair
should match the line number.")

(defvar idlwave-shell-other-error
  "^% .*\n\\s-*At:\\s-*\\(.*\\),\\s-*Line\\s-*\\(.*\\)"
  "A regular expression to match any IDL error.
The first \(..\) pair should match the file name.  The second pair
should match the line number.")

(defvar idlwave-shell-file-line-message
  (concat 
   "\\("                                 ; program name group (1)
   "\\<[a-zA-Z][a-zA-Z0-9_$:]*"          ; start with a letter, followed by [..]
   "\\([ \t]*\n[ \t]*[a-zA-Z0-9_$:]+\\)*"; continuation lines program name (2)
   "\\)"                                 ; end program name group (1)
   "[ \t\n]+"                            ; white space
   "\\("                                 ; line number group (3)
   "[0-9]+"                              ; the line number (the fix point)
   "\\([ \t]*\n[ \t]*[0-9]+\\)*"         ; continuation lines number (4)
   "\\)"                                 ; end line number group (3)
   "[ \t\n]+"                            ; white space
   "\\("                                 ; file name group (5)
   "[^ \t\n]+"                           ; file names can contain any non-white
   "\\([ \t]*\n[ \t]*[^ \t\n]+\\)*"      ; continuation lines file name (6)
   "\\)"                                 ; end line number group (5)
   )
  "*A regular expression to parse out the file name and line number.
The 1st group should match the subroutine name.  
The 3rd group is the line number.
The 5th group is the file name.
All parts may contain linebreaks surrounded by spaces.  This is important
in IDL5 which inserts random linebreaks in long module and file names.")

(defun idlwave-shell-parse-line (string)
  "Parse IDL message for the subroutine, file name and line number.
We need to work hard here to remove the stupid line breaks inserted by
IDL5.  These line breaks can be right in the middle of procedure
or file names.
It is very difficult to come up with a robust solution.  This one seems
to be pretty good though.  

Here is in what ways it improves over the previous solution:

1. The procedure name can be split and will be restored.
2. The number can be split.  I have never seen this, but who knows.
3. We do not require the `.pro' extension for files.

This function can still break when the file name ends on a end line
and the message line contains an additional line with garbage.  Then
the first part of that garbage will be added to the file name.
However, the function checks the existence of the files with and
without this last part - thus the function only breaks if file name
plus garbage match an existing regular file.  This is hopefully very
unlikely."

  (let (number procedure file)
    (when (string-match idlwave-shell-file-line-message string)
      (setq procedure (match-string 1 string)
	    number (match-string 3 string)
	    file (match-string 5 string))
	
      ;; Repair the strings
      (setq procedure (idlwave-shell-repair-string procedure))
      (setq number (idlwave-shell-repair-string number))
      (setq file (idlwave-shell-repair-file-name file))

      ;; If we have a file, return the frame list
      (if file
	  (list (idlwave-shell-file-name file)
		(string-to-int number)
		procedure)
	;; No success finding a file
	nil))))

(defun idlwave-shell-repair-string (string)
  "Repair a string by taking out all linebreaks.  This is destructive!"
  (while (string-match "[ \t]*\n[ \t]*" string)
    (setq string (replace-match "" t t string)))
  string)

(defun idlwave-shell-repair-file-name (file)
  "Repair a file name string by taking out all linebreaks.
The last line of STRING may be garbage - we check which one makes a valid
file name."
  (let ((file1 "") (file2 "") (start 0))
    ;; We scan no further than to the next "^%" line
    (if (string-match "^%" file) 
	(setq file (substring file 0 (match-beginning 0))))
    ;; Take out the line breaks
    (while (string-match "[ \t]*\n[ \t]*" file start)
      (setq file1 (concat file1 (substring file start (match-beginning 0)))
	    start (match-end 0)))
    (setq file2 (concat file1 (substring file start)))
    (cond
     ((file-regular-p file2) file2)
     ((file-regular-p file1) file1)
     ;; If we cannot veryfy the existence of the file, we return the shorter
     ;; name.  The idea behind this is that this may be a relative file name
     ;; and our idea about the current working directory may be wrong.
     ;; If it is a relative file name, it hopefully is short.
     ((not (string= "" file1)) file1)
     ((not (string= "" file2)) file2)
     (t nil))))

(defun idlwave-shell-cleanup ()
  "Do necessary cleanup for a terminated IDL process."
  (setq idlwave-shell-step-frame nil
        idlwave-shell-halt-frame nil
        idlwave-shell-pending-commands nil
	idlwave-shell-command-line-to-execute nil
	idlwave-shell-bp-alist nil
	idlwave-shell-calling-stack-index 0)
  (idlwave-shell-display-line nil)
  (idlwave-shell-update-bp-overlays) ; kill old overlays
  (idlwave-shell-kill-buffer "*idlwave-shell-hidden-output*")
  (idlwave-shell-kill-buffer idlwave-shell-bp-buffer)
  (idlwave-shell-kill-buffer idlwave-shell-error-buffer)
  ;; (idlwave-shell-kill-buffer (idlwave-shell-buffer))
  (and (get-buffer (idlwave-shell-buffer))
       (bury-buffer (get-buffer (idlwave-shell-buffer))))
  (run-hooks 'idlwave-shell-cleanup-hook))

(defun idlwave-shell-kill-buffer (buf)
  "Kill buffer BUF if it exists."
  (if (setq buf (get-buffer buf))
      (kill-buffer buf)))

(defun idlwave-shell-kill-shell-buffer-confirm ()
  (when (idlwave-shell-is-running)
    (ding)
    (unless (y-or-n-p "IDL shell is running.  Are you sure you want to kill the buffer? ")
      (error "Abort"))
    (message "Killing buffer *idl* and the associated process")))

(defun idlwave-shell-resync-dirs ()
  "Resync the buffer's idea of the current directory stack.
This command queries IDL with the command bound to 
`idlwave-shell-dirstack-query' (default \"printd\"), reads the
output for the new directory stack."
  (interactive)
  (idlwave-shell-send-command idlwave-shell-dirstack-query
			      'idlwave-shell-filter-directory
			      'hide))

(defun idlwave-shell-retall (&optional arg)
  "Return from the entire calling stack."
  (interactive "P")
  (idlwave-shell-send-command "retall"))

(defun idlwave-shell-closeall (&optional arg)
  "Close all open files."
  (interactive "P")
  (idlwave-shell-send-command "close,/all"))

(defun idlwave-shell-quit (&optional arg)
  "Exit the idl process after confirmation.
With prefix ARG, exit without confirmation."
  (interactive "P")
  (if (not (idlwave-shell-is-running))
      (error "Shell is not running")
    (if (or arg (y-or-n-p "Exit the IDLWAVE Shell? "))
	(condition-case nil
	    (idlwave-shell-send-command "exit")
	  (error nil)))))

(defun idlwave-shell-reset (&optional visible)
  "Reset IDL.  Return to main level and destroy the leaftover variables.
This issues the following commands:  
RETALL
WIDGET_CONTROL,/RESET
CLOSE, /ALL
HEAP_GC, /VERBOSE"
  ;; OBJ_DESTROY, OBJ_VALID()  FIXME: should this be added?
  (interactive "P")
  (message "Resetting IDL")
  (idlwave-shell-send-command "retall" nil (not visible))
  (idlwave-shell-send-command "widget_control,/reset" nil (not visible))
  (idlwave-shell-send-command "close,/all" nil (not visible))
  ;; (idlwave-shell-send-command "obj_destroy, obj_valid()" nil (not visible))
  (idlwave-shell-send-command "heap_gc,/verbose" nil (not visible))
  (setq idlwave-shell-calling-stack-index 0))

(defun idlwave-shell-filter-directory ()
  "Get the current directory from `idlwave-shell-command-output'.
Change the default directory for the process buffer to concur."
  (save-excursion
    (set-buffer (idlwave-shell-buffer))
    (if (string-match "Current Directory: *\\(\\S-*\\) *$"
		      idlwave-shell-command-output)
	(let ((dir (substring idlwave-shell-command-output 
			      (match-beginning 1) (match-end 1))))
	  (message "Setting Emacs wd to %s" dir)
	  (setq idlwave-shell-default-directory dir)
	  (setq default-directory (file-name-as-directory dir))))))

(defun idlwave-shell-complete (&optional arg)
  "Do completion in the idlwave-shell buffer.
Calls `idlwave-shell-complete-filename' after some executive commands or
in strings.  Otherwise, calls `idlwave-complete' to complete modules and
keywords."
;;FIXME: batch files?
  (interactive "P")
  (let (cmd)
    (cond
     ((setq cmd (idlwave-shell-executive-command))
      ;; We are in a command line with an executive command
      (if (member (upcase cmd)
		  '(".R" ".RU" ".RUN" ".RN" ".RNE" ".RNEW"
		    ".COM" ".COMP" ".COMPI" ".COMPIL" ".COMPILE"))
	  ;; This command expects file names
	  (idlwave-shell-complete-filename)))
     ((idlwave-shell-filename-string)
      ;; In a string, could be a file name to here
      (idlwave-shell-complete-filename))
     (t
      ;; Default completion of modules and keywords
      (idlwave-complete)))))

(defun idlwave-shell-complete-filename (&optional arg)
  "Complete a file name at point if after a file name.
We assume that we are after a file name when completing one of the
args of an executive .run, .rnew or .compile.  Also, in a string
constant we complete file names.  Otherwise return nil, so that
other completion functions can do thier work."
  (let* ((comint-file-name-chars idlwave-shell-file-name-chars)
	 (completion-ignore-case (default-value 'completion-ignore-case)))
    (comint-dynamic-complete-filename)))

(defun idlwave-shell-executive-command ()
  "Return the name of the current executive command, if any."
  (save-excursion
    (idlwave-beginning-of-statement)
    (if (looking-at "[ \t]*\\([.][^ \t\n\r]*\\)")
	(match-string 1))))

(defun idlwave-shell-filename-string ()
  "Return t if in a string and after what could be a file name."
  (let ((limit (save-excursion (beginning-of-line) (point))))
    (save-excursion
      ;; Skip backwards over file name chars
      (skip-chars-backward idlwave-shell-file-name-chars limit)
      ;; Check of the next char is a string delimiter
      (memq (preceding-char) '(?\' ?\")))))

;;;
;;; This section contains code for debugging IDL programs. --------------------
;;;

(defun idlwave-shell-redisplay (&optional hide)
  "Tries to resync the display with where execution has stopped.
Issues a \"help,/trace\" command followed by a call to 
`idlwave-shell-display-line'.  Also updates the breakpoint
overlays."
  (interactive)
  (idlwave-shell-send-command
   "help,/trace"
   '(idlwave-shell-display-line
     (idlwave-shell-pc-frame))
   hide)
  (idlwave-shell-bp-query))

(defun idlwave-shell-display-level-in-calling-stack (&optional hide)
  (idlwave-shell-send-command 
   "help,/trace"
   'idlwave-shell-parse-stack-and-display
   hide))

(defun idlwave-shell-parse-stack-and-display ()
  (let* ((lines (delete "" (idlwave-split-string
			    idlwave-shell-command-output "^%")))
	 (stack (delq nil (mapcar 'idlwave-shell-parse-line lines)))
	 (nmax (1- (length stack)))
	 (nmin 0) message)
;    ;; Reset the stack to zero if it is a new stack.
;    (if (not (equal stack idlwave-shell-last-calling-stack))
;	(setq idlwave-shell-calling-stack-index 0))
;    (setq idlwave-shell-last-calling-stack stack)
    (cond
     ((< nmax nmin)
      (setq idlwave-shell-calling-stack-index 0)      
      (error "Problem with calling stack"))
     ((> idlwave-shell-calling-stack-index nmax)
      (setq idlwave-shell-calling-stack-index nmax
	    message (format "%d is the highest level on the calling stack"
			    nmax)))
     ((< idlwave-shell-calling-stack-index nmin)
      (setq idlwave-shell-calling-stack-index nmin
	    message (format "%d is the lowest level on the calling stack"
			    nmin))))    
    (idlwave-shell-display-line 
     (nth idlwave-shell-calling-stack-index stack))
    (message (or message 
		 (format "On stack level %d"
			 idlwave-shell-calling-stack-index)))))

(defun idlwave-shell-stack-up ()
  "Display the source code one step up the calling stack."
  (interactive)
  (incf idlwave-shell-calling-stack-index)
  (idlwave-shell-display-level-in-calling-stack 'hide))
(defun idlwave-shell-stack-down ()
  "Display the source code one step down the calling stack."
  (interactive)
  (decf idlwave-shell-calling-stack-index)
  (idlwave-shell-display-level-in-calling-stack 'hide))

(defun idlwave-shell-goto-frame (&optional frame)
  "Set buffer to FRAME with point at the frame line.
If the optional argument FRAME is nil then idlwave-shell-pc-frame is
used.  Does nothing if the resulting frame is nil."
  (if frame ()
    (setq frame (idlwave-shell-pc-frame)))
  (cond
   (frame
    (set-buffer (idlwave-find-file-noselect (car frame)))
    (widen)
    (goto-line (nth 1 frame)))))

(defun idlwave-shell-pc-frame ()
  "Returns the frame for IDL execution."
  (and idlwave-shell-halt-frame
       (list (nth 0 idlwave-shell-halt-frame) 
	     (nth 1 idlwave-shell-halt-frame))))

(defun idlwave-shell-valid-frame (frame)
  "Check that frame is for an existing file."
  (file-readable-p (car frame)))

(defun idlwave-shell-display-line (frame &optional col)
  "Display FRAME file in other window with overlay arrow.

FRAME is a list of file name, line number, and subroutine name.
If FRAME is nil then remove overlay."
  (if (not frame)
      ;; Remove stop-line overlay from old position
      (progn 
        (setq overlay-arrow-string nil)
        (if idlwave-shell-stop-line-overlay
            (delete-overlay idlwave-shell-stop-line-overlay)))
    (if (not (idlwave-shell-valid-frame frame))
        (error (concat "Invalid frame - unable to access file: " (car frame)))
;;;
;;; buffer : the buffer to display a line in.
;;; select-shell: current buffer is the shell.
;;; 
      (let* ((buffer (idlwave-find-file-noselect (car frame)))
             (select-shell (equal (buffer-name) (idlwave-shell-buffer)))
             window pos)

	;; First make sure the shell window is visible
	(idlwave-display-buffer (idlwave-shell-buffer)
				nil (idlwave-shell-shell-frame))

	;; Now display the buffer and remember which window it is.
	(setq window (idlwave-display-buffer buffer
					     nil (idlwave-shell-source-frame)))

	;; Enter the buffer and mark the line
        (save-excursion
          (set-buffer buffer)
          (save-restriction
            (widen)
            (goto-line (nth 1 frame))
            (setq pos (point))
            (if idlwave-shell-stop-line-overlay
                ;; Move overlay
		(move-overlay idlwave-shell-stop-line-overlay
			      (point) (save-excursion (end-of-line) (point))
			      (current-buffer))
	      ;; Use the arrow instead, but only if marking is wanted.
	      (if idlwave-shell-mark-stop-line
		  (setq overlay-arrow-string idlwave-shell-overlay-arrow))
              (or overlay-arrow-position  ; create the marker if necessary
                  (setq overlay-arrow-position (make-marker)))
              (set-marker overlay-arrow-position (point) buffer)))
	  
	  ;; If the point is outside the restriction, widen the buffer.
          (if (or (< pos (point-min)) (> pos (point-max)))
	      (progn
		(widen)
		(goto-char pos)))

	  ;; If we have the column of the error, move the cursor there.
          (if col (move-to-column col))
          (setq pos (point)))

	;; Make sure pos is really displayed in the window.
        (set-window-point window pos)

	;; FIXME: the following frame redraw was taken out because it
        ;; flashes.  I think it is not needed.  The code is left here in
	;; case we have to put it back in.
	;; (redraw-frame (window-frame window))

	;; If we came from the shell, go back there.  Otherwise select 
	;; the window where the error is displayed.
        (if (and (equal (buffer-name) (idlwave-shell-buffer)) 
		 (not select-shell))
            (select-window window))))))


(defun idlwave-shell-step (arg)
  "Step one source line. If given prefix argument ARG, step ARG source lines."
  (interactive "p")
  (or (not arg) (< arg 1)
      (setq arg 1))
  (idlwave-shell-send-command 
   (concat ".s " (if (integerp arg) (int-to-string arg) arg))))

(defun idlwave-shell-stepover (arg)
  "Stepover one source line.
If given prefix argument ARG, step ARG source lines. 
Uses IDL's stepover executive command which does not enter called functions."
  (interactive "p")
  (or (not arg) (< arg 1)
      (setq arg 1))
  (idlwave-shell-send-command 
   (concat ".so " (if (integerp arg) (int-to-string arg) arg))))

(defun idlwave-shell-break-here (&optional count cmd)
  "Set breakpoint at current line.  

If Count is nil then an ordinary breakpoint is set.  We treat a count
of 1 as a temporary breakpoint using the ONCE keyword.  Counts greater
than 1 use the IDL AFTER=count keyword to break only after reaching
the statement count times.

Optional argument CMD is a list or function to evaluate upon reaching 
the breakpoint."
  
  (interactive "P")
  (if (listp count)
      (setq count nil))
  (idlwave-shell-set-bp
   ;; Create breakpoint
   (idlwave-shell-bp (idlwave-shell-current-frame)
		     (list count cmd)
		     (idlwave-shell-current-module))))

(defun idlwave-shell-set-bp-check (bp)
  "Check for failure to set breakpoint.
This is run on `idlwave-shell-post-command-hook'.
Offers to recompile the procedure if we failed.  This usually fixes
the problem with not being able to set the breakpoint."
  ;; Scan for message
  (if (and idlwave-shell-command-output
           (string-match "% BREAKPOINT: *Unable to find code"
                         idlwave-shell-command-output))
      ;; Offer to recompile
      (progn
        (if (progn
              (beep)
              (y-or-n-p 
               (concat "Okay to recompile file "
                       (idlwave-shell-bp-get bp 'file) " ")))
            ;; Recompile
            (progn
              ;; Clean up before retrying
              (idlwave-shell-command-failure)
              (idlwave-shell-send-command
               (concat ".run " (idlwave-shell-bp-get bp 'file)) nil nil)
              ;; Try setting breakpoint again
              (idlwave-shell-set-bp bp))
          (beep)
          (message "Unable to set breakpoint.")
          (idlwave-shell-command-failure)
          )
        ;; return non-nil if no error found
        nil)
    'okay))

(defun idlwave-shell-command-failure ()
  "Do any necessary clean up when an IDL command fails.
Call this from a function attached to `idlwave-shell-post-command-hook'
that detects the failure of a command.
For example, this is called from `idlwave-shell-set-bp-check' when a
breakpoint can not be set."
  ;; Clear pending commands
  (setq idlwave-shell-pending-commands nil))

(defun idlwave-shell-cont ()
  "Continue executing."
  (interactive)
  (idlwave-shell-send-command ".c" '(idlwave-shell-redisplay 'hide)))

(defun idlwave-shell-go ()
  "Run .GO.  This starts the main program of the last compiled file."
  (interactive)
  (idlwave-shell-send-command ".go" '(idlwave-shell-redisplay 'hide)))

(defun idlwave-shell-return ()
  "Run .RETURN (continue to next return, but stay in subprogram)."
  (interactive)
  (idlwave-shell-send-command ".return" '(idlwave-shell-redisplay 'hide)))

(defun idlwave-shell-skip ()
  "Run .SKIP (skip one line, then step)."
  (interactive)
  (idlwave-shell-send-command ".skip" '(idlwave-shell-redisplay 'hide)))

(defun idlwave-shell-clear-bp (bp)
  "Clear breakpoint BP.
Clears in IDL and in `idlwave-shell-bp-alist'."
  (let ((index (idlwave-shell-bp-get bp)))
    (if index
        (progn
          (idlwave-shell-send-command
           (concat "breakpoint,/clear," 
		   (if (integerp index) (int-to-string index) index)))
	  (idlwave-shell-bp-query)))))

(defun idlwave-shell-current-frame ()
  "Return a list containing the current file name and line point is in.
If in the IDL shell buffer, returns `idlwave-shell-pc-frame'."
  (if (eq (current-buffer) (get-buffer (idlwave-shell-buffer)))
      ;; In IDL shell
      (idlwave-shell-pc-frame)
    ;; In source
    (list (idlwave-shell-file-name (buffer-file-name))
          (save-restriction
            (widen)
            (save-excursion
              (beginning-of-line)
              (1+ (count-lines 1 (point))))))))

(defun idlwave-shell-current-module ()
  "Return the name of the module for the current file.
Returns nil if unable to obtain a module name."
  (if (eq (current-buffer) (get-buffer (idlwave-shell-buffer)))
      ;; In IDL shell
      (nth 2 idlwave-shell-halt-frame)
    ;; In pro file
    (save-restriction
      (widen)
      (save-excursion
        (if (idlwave-prev-index-position)
            (upcase (idlwave-unit-name)))))))

(defun idlwave-shell-clear-current-bp ()
  "Remove breakpoint at current line.
This command can be called from the shell buffer if IDL is currently stopped
at a breakpoint."
  (interactive)
  (let ((bp (idlwave-shell-find-bp (idlwave-shell-current-frame))))
    (if bp (idlwave-shell-clear-bp bp)
      ;; Try moving to beginning of statement
      (save-excursion
        (idlwave-shell-goto-frame)
        (idlwave-beginning-of-statement)
        (setq bp (idlwave-shell-find-bp (idlwave-shell-current-frame)))
        (if bp (idlwave-shell-clear-bp bp)
          (beep)
          (message "Cannot identify breakpoint for this line"))))))

(defun idlwave-shell-to-here ()
  "Set a breakpoint with count 1 then continue."
  (interactive)
  (idlwave-shell-break-here 1)
  (idlwave-shell-cont))

(defun idlwave-shell-break-in (&optional module)
  "Look for a module name near point and set a break point for it.
The command looks for an identifier near point and sets a breakpoint
for the first line of the corresponding module."
  (interactive)
  ;; get the identifier
  (let (module)
    (save-excursion
      (skip-chars-backward "a-zA-Z0-9_$")
      (if (looking-at idlwave-identifier)
	  (setq module (match-string 0))
	(error "No identifier at point")))
    (idlwave-shell-send-command
     idlwave-shell-sources-query
     `(progn
	(idlwave-shell-sources-filter)
	(idlwave-shell-set-bp-in-module ,module))
     'hide)))

(defun idlwave-shell-set-bp-in-module (module)
  "Set breakpoint in module.  Assumes that `idlwave-shell-sources-alist'
contains an entry for that module."
  (let ((source-file (car-safe 
		      (cdr-safe
		       (assoc (upcase module)
			      idlwave-shell-sources-alist))))
	buf)
    (if (or (not source-file)
	    (not (file-regular-p source-file))
	    (not (setq buf
		       (or (idlwave-get-buffer-visiting source-file)
			   (find-file-noselect source-file)))))
	(progn
	  (message "The source file for module %s is probably not compiled"
		   module)
	  (beep))
      (save-excursion
	(set-buffer buf)
	(save-excursion
	  (goto-char (point-min))
	  (let ((case-fold-search t))
	    (if (re-search-forward 
		 (concat "^[ \t]*\\(pro\\|function\\)[ \t]+"
			 (downcase module)
			 "[ \t\n,]") nil t)
		(progn
		  (goto-char (match-beginning 1))
		  (message "Setting breakpoint for module %s" module)
		  (idlwave-shell-break-here))
	      (message "Cannot find module %s in file %s" module source-file)
	      (beep))))))))

(defun idlwave-shell-up ()
  "Run to end of current block.
Sets a breakpoint with count 1 at end of block, then continues."
  (interactive)
  (if (idlwave-shell-pc-frame)
      (save-excursion
        (idlwave-shell-goto-frame)
        ;; find end of subprogram
        (let ((eos (save-excursion
                     (idlwave-beginning-of-subprogram)
                     (idlwave-forward-block)
                     (point))))
          (idlwave-backward-up-block -1)
          ;; move beyond end block line - IDL will not break there.
          ;; That is, you can put a breakpoint there but when IDL does
          ;; break it will report that it is at the next line.
          (idlwave-next-statement)
          (idlwave-end-of-statement)
          ;; Make sure we are not beyond subprogram
          (if (< (point) eos)
              ;; okay
              ()
            ;; Move back inside subprogram
            (goto-char eos)
            (idlwave-previous-statement))
          (idlwave-shell-to-here)))))

(defun idlwave-shell-out ()
  "Attempt to run until this procedure exits.
Runs to the last statement and then steps 1 statement.  Use the .out command."
  (interactive)
  (idlwave-shell-send-command (concat ".o")))

(defun idlwave-shell-help-expression ()
  "Print help on current expression.  See `idlwave-shell-print'."
  (interactive)
  (idlwave-shell-print 'help))

(defun idlwave-shell-mouse-print (event)
  "Call `idlwave-shell-print' at the mouse position."
  (interactive "e")
  (mouse-set-point event)
  (idlwave-shell-print))

(defun idlwave-shell-mouse-help (event)
  "Call `idlwave-shell-print' at the mouse position."
  (interactive "e")
  (mouse-set-point event)
  (idlwave-shell-help-expression))

(defun idlwave-shell-print (&optional help special)
  "Print current expression.  With are HELP, show help on expression.
An expression is an identifier plus 1 pair of matched parentheses
directly following the identifier - an array or function
call.  Alternatively, an expression is the contents of any matched
parentheses when the open parentheses is not directly preceded by an
identifier. If point is at the beginning or within an expression
return the inner-most containing expression, otherwise, return the
preceding expression."
  (interactive "P")
  (save-excursion
    (let (beg end)
      ;; Move to beginning of current or previous expression
      (if (looking-at "\\<\\|(")
          ;; At beginning of expression, don't move backwards unless
          ;; this is at the end of an indentifier.
          (if (looking-at "\\>")
              (backward-sexp))
        (backward-sexp))
      (if (looking-at "\\>")
          ;; Move to beginning of identifier - must be an array or
          ;; function expression.
          (backward-sexp))
      ;; Move to end of expression
      (setq beg (point))
      (forward-sexp)
      (while (looking-at "\\>(\\|\\.")
        ;; an array
        (forward-sexp))
      (setq end (point))
      (when idlwave-shell-expression-overlay
	(move-overlay idlwave-shell-expression-overlay beg end)
	(add-hook 'pre-command-hook 'idlwave-shell-delete-expression-overlay))
      (if special
	  (idlwave-shell-send-command 
	   (concat (if help "help," "print,") (buffer-substring beg end))
	   `(idlwave-shell-process-print-output ,(buffer-substring beg end) 
						idlwave-shell-command-output
						,special)
	   'hide)
	(idlwave-shell-recenter-shell-window)
	(idlwave-shell-send-command 
	 (concat (if help "help," "print,") (buffer-substring beg end)))))))

(defun idlwave-shell-delete-expression-overlay ()
  (condition-case nil
      (if idlwave-shell-expression-overlay
	  (delete-overlay idlwave-shell-expression-overlay))
    (error nil))
  (remove-hook 'pre-command-hook 'idlwave-shell-delete-expression-overlay))

(defvar idlwave-shell-bp-alist nil
  "Alist of breakpoints.
A breakpoint is a cons cell \(\(file line\) . \(\(index module\) data\)\)

The car is the frame for the breakpoint:
file - full path file name.
line - line number of breakpoint - integer.

The first element of the cdr is a list of internal IDL data:
index - the index number of the breakpoint internal to IDL.
module - the module for breakpoint internal to IDL.

Remaining elements of the cdr:
data - Data associated with the breakpoint by idlwave-shell currently
contains two items:

count - number of times to execute breakpoint. When count reaches 0
the breakpoint is cleared and removed from the alist.
command - command to execute when breakpoint is reached, either a 
lisp function to be called with `funcall' with no arguments or a
list to be evaluated with `eval'.")

(defun idlwave-shell-run-region (beg end &optional n)
  "Compile and run the region using the IDL process.
Copies the region to a temporary file `idlwave-shell-temp-pro-file'
and issues the IDL .run command for the file.  Because the
region is compiled and run as a main program there is no
problem with begin-end blocks extending over multiple
lines - which would be a problem if `idlwave-shell-evaluate-region'
was used.  An END statement is appended to the region if necessary.

If there is a prefix argument, display IDL process."
  (interactive "r\nP")
  (let ((oldbuf (current-buffer)))
    (save-excursion
      (set-buffer (idlwave-find-file-noselect
		   idlwave-shell-temp-pro-file))
      (erase-buffer)
      (insert-buffer-substring oldbuf beg end)
      (if (not (save-excursion
                 (idlwave-previous-statement)
                 (idlwave-look-at "\\<end\\>")))
          (insert "\nend\n"))
      (save-buffer 0)))
  (idlwave-shell-send-command (concat ".run " idlwave-shell-temp-pro-file))
  (if n
      (idlwave-display-buffer (idlwave-shell-buffer) 
			      nil (idlwave-shell-shell-frame))))

(defun idlwave-shell-evaluate-region (beg end &optional n)
  "Send region to the IDL process.
If there is a prefix argument, display IDL process.
Does not work for a region with multiline blocks - use
`idlwave-shell-run-region' for this."
  (interactive "r\nP")
  (idlwave-shell-send-command (buffer-substring beg end))
  (if n
      (idlwave-display-buffer (idlwave-shell-buffer) 
			      nil (idlwave-shell-shell-frame))))

(defun idlwave-display-buffer (buf not-this-window-p &optional frame)
  (if (or (< emacs-major-version 20)
	  (and (= emacs-major-version 20)
	       (< emacs-minor-version 3)))
      ;; Only two args.
      (display-buffer buf not-this-window-p)
    ;; Three ares possible.
    (display-buffer buf not-this-window-p frame)))

(defvar idlwave-shell-bp-buffer "*idlwave-shell-bp*"
  "Scratch buffer for parsing IDL breakpoint lists and other stuff.")

(defun idlwave-shell-bp-query ()
  "Reconcile idlwave-shell's breakpoint list with IDL's.
Queries IDL using the string in `idlwave-shell-bp-query'."
  (interactive)
  (idlwave-shell-send-command idlwave-shell-bp-query
			      'idlwave-shell-filter-bp
			      'hide))

(defun idlwave-shell-bp-get (bp &optional item)
  "Get a value for a breakpoint.
BP has the form of elements in idlwave-shell-bp-alist.
Optional second arg ITEM is the particular value to retrieve.
ITEM can be 'file, 'line, 'index, 'module, 'count, 'cmd, or 'data.
'data returns a list of 'count and 'cmd.
Defaults to 'index."
  (cond
   ;; Frame
   ((eq item 'line) (nth 1 (car bp)))
   ((eq item 'file) (nth 0 (car bp)))
   ;; idlwave-shell breakpoint data
   ((eq item 'data) (cdr (cdr bp)))
   ((eq item 'count) (nth 0 (cdr (cdr bp))))
   ((eq item 'cmd) (nth 1 (cdr (cdr bp))))
   ;; IDL breakpoint info
   ((eq item 'module) (nth 1 (car (cdr bp))))
   ;;    index - default
   (t (nth 0 (car (cdr bp))))))

(defun idlwave-shell-filter-bp ()
  "Get the breakpoints from `idlwave-shell-command-output'.
Create `idlwave-shell-bp-alist' updating breakpoint count and command data
from previous breakpoint list."
  (save-excursion
    (set-buffer (get-buffer-create idlwave-shell-bp-buffer))
    (erase-buffer)
    (insert idlwave-shell-command-output)
    (goto-char (point-min))
    (let ((old-bp-alist idlwave-shell-bp-alist))
      (setq idlwave-shell-bp-alist (list nil))
      (if (re-search-forward "^\\s-*Index.*\n\\s-*-" nil t)
          (while (and
                  (not (progn (forward-line) (eobp)))
                  ;; Parse breakpoint line.
                  ;; Breakpoints have the form:
                  ;;  Index Module Line File
                  ;;  All seperated by whitespace.
                  ;;
                  ;;  Add the breakpoint info to the list
                  (re-search-forward
                   "\\s-*\\(\\S-+\\)\\s-+\\(\\S-+\\)\\s-+\\(\\S-+\\)\\s-+\\(\\S-+\\)" nil t))
            (nconc idlwave-shell-bp-alist
                   (list
                    (cons
                     (list
                      (save-match-data
                        (idlwave-shell-file-name
                         (buffer-substring ; file
                          (match-beginning 4) (match-end 4))))
                      (string-to-int    ; line
                       (buffer-substring
                        (match-beginning 3) (match-end 3))))
                     (list
                      (list
                       (buffer-substring ; index
                        (match-beginning 1) (match-end 1))
                       (buffer-substring ; module
                        (match-beginning 2) (match-end 2)))
                      ;; idlwave-shell data: count, command
                      nil nil))))))
      (setq idlwave-shell-bp-alist (cdr idlwave-shell-bp-alist))
      ;; Update count, commands of breakpoints
      (mapcar 'idlwave-shell-update-bp old-bp-alist)))
  ;; Update the breakpoint overlays
  (idlwave-shell-update-bp-overlays)
  ;; Return the new list
  idlwave-shell-bp-alist)

(defun idlwave-shell-update-bp (bp)
  "Update BP data in breakpoint list.
If BP frame is in `idlwave-shell-bp-alist' updates the breakpoint data."
  (let ((match (assoc (car bp) idlwave-shell-bp-alist)))
    (if match (setcdr (cdr match) (cdr (cdr bp))))))

(defun idlwave-shell-set-bp-data (bp data)
  "Set the data of BP to DATA."
  (setcdr (cdr bp) data))

(defun idlwave-shell-bp (frame &optional data module)
  "Create a breakpoint structure containing FRAME and DATA.  Second
and third args, DATA and MODULE, are optional.  Returns a breakpoint
of the format used in `idlwave-shell-bp-alist'.  Can be used in commands
attempting match a breakpoint in `idlwave-shell-bp-alist'."
  (cons frame (cons (list nil module) data)))

(defvar idlwave-shell-old-bp nil
  "List of breakpoints previous to setting a new breakpoint.")

(defun idlwave-shell-sources-bp (bp)
  "Check `idlwave-shell-sources-alist' for source of breakpoint using BP.
If an equivalency is found, return the IDL internal source name.
Otherwise return the filename in bp."
  (let*
      ((bp-file (idlwave-shell-bp-get bp 'file))
       (bp-module (idlwave-shell-bp-get bp 'module))
       (internal-file-list (cdr (assoc bp-module idlwave-shell-sources-alist))))
    (if (and internal-file-list
	     (equal bp-file (nth 0 internal-file-list)))
        (nth 1 internal-file-list)
      bp-file)))

(defun idlwave-shell-set-bp (bp)
  "Try to set a breakpoint BP.

The breakpoint will be placed at the beginning of the statement on the
line specified by BP or at the next IDL statement if that line is not
a statement.
Determines IDL's internal representation for the breakpoint which may
have occured at a different line then used with the breakpoint
command."
  
  ;; Get and save the old breakpoints
  (idlwave-shell-send-command 
   idlwave-shell-bp-query
   '(progn
      (idlwave-shell-filter-bp)
      (setq idlwave-shell-old-bp idlwave-shell-bp-alist))
   'hide)
  ;; Get sources for IDL compiled procedures followed by setting
  ;; breakpoint.
  (idlwave-shell-send-command
   idlwave-shell-sources-query
   (` (progn
	(idlwave-shell-sources-filter)
	(idlwave-shell-set-bp2 (quote (, bp)))))
   'hide))

(defun idlwave-shell-set-bp2 (bp)
  "Use results of breakpoint and sources query to set bp.
Use the count argument with IDLs breakpoint command.
We treat a count of 1 as a temporary breakpoint. 
Counts greater than 1 use the IDL AFTER=count keyword to break
only after reaching the statement count times."
  (let*
      ((arg (idlwave-shell-bp-get bp 'count))
       (key (cond
             ((not (and arg (numberp arg))) "")
             ((= arg 1)
              ",/once")
             ((> arg 1)
              (format ",after=%d" arg))))
       (line (idlwave-shell-bp-get bp 'line)))
    (idlwave-shell-send-command
     (concat "breakpoint,'" 
	     (idlwave-shell-sources-bp bp) "',"
	     (if (integerp line) (setq line (int-to-string line)))
	     key)
     ;; Check for failure and look for breakpoint in IDL's list
     (` (progn
          (if (idlwave-shell-set-bp-check (quote (, bp)))
              (idlwave-shell-set-bp3 (quote (, bp)))))
        )
     ;; do not hide output 
     nil
     'preempt)))

(defun idlwave-shell-set-bp3 (bp)
  "Find the breakpoint in IDL's internal list of breakpoints."
  (idlwave-shell-send-command idlwave-shell-bp-query
			      (` (progn
				   (idlwave-shell-filter-bp)
				   (idlwave-shell-new-bp (quote (, bp)))))
			      'hide
			      'preempt))

(defun idlwave-shell-find-bp (frame)
  "Return breakpoint from `idlwave-shell-bp-alist' for frame.
Returns nil if frame not found."
  (assoc frame idlwave-shell-bp-alist))

(defun idlwave-shell-new-bp (bp)
  "Find the new breakpoint in IDL's list and update with DATA.
The actual line number for a breakpoint in IDL may be different than
the line number used with the IDL breakpoint command.
Looks for a new breakpoint index number in the list.  This is
considered the new breakpoint if the file name of frame matches."
  (let ((obp-index (mapcar 'idlwave-shell-bp-get idlwave-shell-old-bp))
        (bpl idlwave-shell-bp-alist))
    (while (and (member (idlwave-shell-bp-get (car bpl)) obp-index)
                (setq bpl (cdr bpl))))
    (if (and
         (not bpl)
         ;; No additional breakpoint.
         ;; Need to check if we are just replacing a breakpoint.
         (setq bpl (assoc (car bp) idlwave-shell-bp-alist)))
        (setq bpl (list bpl)))
    (if (and bpl
             (equal (idlwave-shell-bp-get (setq bpl (car bpl)) 'file)
                    (idlwave-shell-bp-get bp 'file)))
        ;; Got the breakpoint - add count, command to it.
        ;; This updates `idlwave-shell-bp-alist' because a deep copy was
        ;; not done for bpl.
        (idlwave-shell-set-bp-data bpl (idlwave-shell-bp-get bp 'data))
      (beep)
      (message "Failed to identify breakpoint in IDL"))))

(defvar idlwave-shell-bp-overlays nil
  "List of overlays marking breakpoints")

(defun idlwave-shell-update-bp-overlays ()
  "Update the overlays which mark breakpoints in the source code.
Existing overlays are recycled, in order to minimize consumption."
  ;; FIXME: we could cache them all, but that would be more work.
  (when idlwave-shell-mark-breakpoints
    (let ((bp-list idlwave-shell-bp-alist)
	  (ov-list idlwave-shell-bp-overlays)
	  ov bp)
      ;; Delete the old overlays from their buffers
      (while (setq ov (pop ov-list))
	(delete-overlay ov))
      (setq ov-list idlwave-shell-bp-overlays
	    idlwave-shell-bp-overlays nil)
      (while (setq bp (pop bp-list))
	(save-excursion
	  (idlwave-shell-goto-frame (car bp))
	  (let* ((end (progn (end-of-line 1) (point)))
		 (beg (progn (beginning-of-line 1) (point)))
		 (ov (or (pop ov-list)
			 (idlwave-shell-make-new-bp-overlay))))
	    (move-overlay ov beg end)
	    (push ov idlwave-shell-bp-overlays)))))))

(defvar idlwave-shell-bp-glyph)
(defun idlwave-shell-make-new-bp-overlay ()
  "Make a new overlay for highlighting breakpoints.
This stuff is stringly dependant upon the version of Emacs."
  (let ((ov (make-overlay 1 1)))
    (if (featurep 'xemacs)
	;; This is XEmacs
	(progn
	  (cond 
	   ((eq (console-type) 'tty)
	    ;; tty's cannot display glyphs
	    (set-extent-property ov 'face 'idlwave-shell-bp-face))
	   ((and (memq idlwave-shell-mark-breakpoints '(t glyph))
		 idlwave-shell-bp-glyph)
	    ;; use the glyph
	    (set-extent-property ov 'begin-glyph idlwave-shell-bp-glyph))
	   (idlwave-shell-mark-breakpoints
	    ;; use the face
	    (set-extent-property ov 'face 'idlwave-shell-bp-face))
	   (t 
	    ;; no marking
	    nil))
	  (set-extent-priority ov -1))  ; make stop line face prevail
      ;; This is Emacs
      (cond
       (window-system
	(if (and (memq idlwave-shell-mark-breakpoints '(t glyph))
		 idlwave-shell-bp-glyph)   ; this var knows if glyph's possible
	    ;; use a glyph
	    (let ((string "@"))
	      (put-text-property 0 1
				 'display (cons nil idlwave-shell-bp-glyph)
				 string)
	      (overlay-put ov 'before-string string))
	  (overlay-put ov 'face 'idlwave-shell-bp-face)))
       (idlwave-shell-mark-breakpoints
	;; use a face
	(overlay-put ov 'face 'idlwave-shell-bp-face))
       (t 
	;; No marking
	nil)))
    ov))

(defun idlwave-shell-edit-default-command-line (arg)
  "Edit the current execute command."
  (interactive "P")
  (setq idlwave-shell-command-line-to-execute
	(read-string "IDL> " idlwave-shell-command-line-to-execute)))

(defun idlwave-shell-execute-default-command-line (arg)
  "Execute a command line.  On first use, ask for the command.
Also with prefix arg, ask for the command.  You can also uase the command
`idlwave-shell-edit-default-command-line' to edit the line."
  (interactive "P")
  (if (or (not idlwave-shell-command-line-to-execute)
	  arg)
      (setq idlwave-shell-command-line-to-execute 
	    (read-string "IDL> " idlwave-shell-command-line-to-execute)))
  (idlwave-shell-reset nil)
  (idlwave-shell-send-command idlwave-shell-command-line-to-execute
			      '(idlwave-shell-redisplay 'hide)))

(defun idlwave-shell-save-and-run ()
  "Save file and run it in IDL.
Runs `save-buffer' and sends a '.RUN' command for the associated file to IDL.
When called from the shell buffer, re-run the file which was last handled by
one of the save-and-.. commands."  
  (interactive)
  (idlwave-shell-save-and-action 'run))

(defun idlwave-shell-save-and-compile ()
  "Save file and run it in IDL.
Runs `save-buffer' and sends '.COMPILE' command for the associated file to IDL.
When called from the shell buffer, re-compile the file which was last handled by
one of the save-and-.. commands."
  (interactive)
  (idlwave-shell-save-and-action 'compile))

(defun idlwave-shell-save-and-batch ()
  "Save file and batch it in IDL.
Runs `save-buffer' and sends a '@file' command for the associated file to IDL.
When called from the shell buffer, re-batch the file which was last handled by
one of the save-and-.. commands."  
  (interactive)
  (idlwave-shell-save-and-action 'batch))

(defun idlwave-shell-save-and-action (action)
  "Save file and compile it in IDL.
Runs `save-buffer' and sends a '.RUN' command for the associated file to IDL.
When called from the shell buffer, re-compile the file which was last
handled by this command."
  ;; Remove the stop overlay.
  (if idlwave-shell-stop-line-overlay
      (delete-overlay idlwave-shell-stop-line-overlay))
  (setq overlay-arrow-string nil)
  (let (buf)
    (cond
     ((eq major-mode 'idlwave-mode)
      (save-buffer)
      (setq idlwave-shell-last-save-and-action-file (buffer-file-name)))
     (idlwave-shell-last-save-and-action-file
      (if (setq buf (idlwave-get-buffer-visiting
		     idlwave-shell-last-save-and-action-file))
	  (save-excursion
	    (set-buffer buf)
	    (save-buffer))))
     (t (setq idlwave-shell-last-save-and-action-file
	      (read-file-name "File: ")))))
  (if (file-regular-p idlwave-shell-last-save-and-action-file)
      (progn
	(idlwave-shell-send-command
	 (concat (cond ((eq action 'run)     ".run ")
		       ((eq action 'compile) ".compile ")
		       ((eq action 'batch)   "@")
		       (t (error "Unknown action %s" action)))
		 idlwave-shell-last-save-and-action-file)
	 nil nil)
	(idlwave-shell-bp-query))
    (let ((msg (format "No such file %s" 
		       idlwave-shell-last-save-and-action-file)))
      (setq idlwave-shell-last-save-and-action-file nil)
      (error msg))))

(defvar idlwave-shell-sources-query "help,/source"
  "IDL command to obtain source files for compiled procedures.")

(defvar idlwave-shell-sources-alist nil
  "Alist of IDL procedure names and compiled source files.
Elements of the alist have the form:

  (module name . (source-file-truename idlwave-internal-filename)).")

(defun idlwave-shell-sources-query ()
  "Determine source files for IDL compiled procedures.
Queries IDL using the string in `idlwave-shell-sources-query'."
  (interactive)
  (idlwave-shell-send-command idlwave-shell-sources-query
			      'idlwave-shell-sources-filter
			      'hide))

(defun idlwave-shell-sources-filter ()
  "Get source files from `idlwave-shell-sources-query' output.
Create `idlwave-shell-sources-alist' consisting of 
list elements of the form:
 (module name . (source-file-truename idlwave-internal-filename))."
  (save-excursion
    (set-buffer (get-buffer-create idlwave-shell-bp-buffer))
    (erase-buffer)
    (insert idlwave-shell-command-output)
    (goto-char (point-min))
    (let (cpro cfun)
      (if (re-search-forward "Compiled Procedures:" nil t)
          (progn
            (forward-line) ; Skip $MAIN$
            (setq cpro (point))))
      (if (re-search-forward "Compiled Functions:" nil t)
          (progn
            (setq cfun (point))
            (setq idlwave-shell-sources-alist
                  (append
                   ;; compiled procedures
                   (progn
                     (beginning-of-line)
                     (narrow-to-region cpro (point))
                     (goto-char (point-min))
                     (idlwave-shell-sources-grep))
                   ;; compiled functions
                   (progn
                     (widen)
                     (goto-char cfun)
                     (idlwave-shell-sources-grep)))))))))

(defun idlwave-shell-sources-grep ()
  (save-excursion
    (let ((al (list nil)))
      (while (and
              (not (progn (forward-line) (eobp)))
              (re-search-forward
               "\\s-*\\(\\S-+\\)\\s-+\\(\\S-+\\)" nil t))
        (nconc al
               (list
                (cons
                 (buffer-substring      ; name
                  (match-beginning 1) (match-end 1))
                 (let ((internal-filename
                        (buffer-substring       ; source
                         (match-beginning 2) (match-end 2))))
                   (list
                    (idlwave-shell-file-name internal-filename)
                    internal-filename))
		 ))))
      (cdr al))))


(defun idlwave-shell-clear-all-bp ()
  "Remove all breakpoints in IDL."
  (interactive)
  (idlwave-shell-send-command
   idlwave-shell-bp-query
   '(progn
      (idlwave-shell-filter-bp)
      (mapcar 'idlwave-shell-clear-bp idlwave-shell-bp-alist))
   'hide))

(defun idlwave-shell-list-all-bp ()
  "List all breakpoints in IDL."
  (interactive)
  (idlwave-shell-send-command
   idlwave-shell-bp-query))

(defvar idlwave-shell-error-last 0
  "Position of last syntax error in `idlwave-shell-error-buffer'.")

(defun idlwave-shell-goto-next-error ()
  "Move point to next IDL syntax error."
  (interactive)
  (let (frame col)
    (save-excursion
      (set-buffer idlwave-shell-error-buffer)
      (goto-char idlwave-shell-error-last)
      (if (or (re-search-forward idlwave-shell-syntax-error nil t)
              (re-search-forward idlwave-shell-other-error nil t))
          (progn
            (setq frame
                  (list
                   (save-match-data
                     (idlwave-shell-file-name
                      (buffer-substring (match-beginning 1) (match-end 1))))
                   (string-to-int
                    (buffer-substring (match-beginning 2)
                                      (match-end 2)))))
            ;; Try to find the column of the error
            (save-excursion
              (setq col
                    (if (re-search-backward "\\^" nil t)
                        (current-column)
                      0)))))
      (setq idlwave-shell-error-last (point)))
    (if frame
        (progn
          (idlwave-shell-display-line frame col))
      (beep)
      (message "No more errors."))))

(defun idlwave-shell-file-name (name)
  "If idlwave-shell-use-truename is non-nil, convert file name to true name.
Otherwise, just expand the file name."
  (let ((def-dir (if (eq major-mode 'idlwave-shell-mode)
		     default-directory
		   idlwave-shell-default-directory)))
    (if idlwave-shell-use-truename 
	(file-truename name def-dir) 
      (expand-file-name name def-dir))))


;; Keybindings --------------------------------------------------------------

(defvar idlwave-shell-mode-map (copy-keymap comint-mode-map)
  "Keymap for idlwave-mode.")
(defvar idlwave-shell-mode-prefix-map (make-sparse-keymap))
(fset 'idlwave-shell-mode-prefix-map idlwave-shell-mode-prefix-map)

;(define-key idlwave-shell-mode-map "\M-?" 'comint-dynamic-list-completions)
;(define-key idlwave-shell-mode-map "\t" 'comint-dynamic-complete)
(define-key idlwave-shell-mode-map "\t"       'idlwave-shell-complete)
(define-key idlwave-shell-mode-map "\M-\t"    'idlwave-shell-complete)
(define-key idlwave-shell-mode-map "\C-c\C-s" 'idlwave-shell)
(define-key idlwave-shell-mode-map "\C-c?"    'idlwave-routine-info)
(define-key idlwave-shell-mode-map "\C-c\C-i" 'idlwave-update-routine-info)
(define-key idlwave-shell-mode-map "\C-c="    'idlwave-resolve)
(define-key idlwave-shell-mode-map "\C-c\C-v" 'idlwave-find-module)
(define-key idlwave-shell-mode-map idlwave-shell-prefix-key
  'idlwave-shell-debug-map)

;; The following set of bindings is used to bind the debugging keys.
;; If `idlwave-shell-activate-prefix-keybindings' is non-nil, the first key
;; in the list gets bound the C-c C-d prefix map.
;; If `idlwave-shell-activate-alt-keybindings' is non-nil, the second key
;; in the list gets bound directly in both idlwave-mode-map and 
;; idlwave-shell-mode-map.

;; Used keys:   abcde  hi klmnopqrs u wxyz 
;; Unused keys:      fg  j         t v  
(let ((specs
 '(([(control ?b)]   [(alt ?b)]   idlwave-shell-break-here)
   ([(control ?i)]   [(alt ?i)]   idlwave-shell-break-in)
   ([(control ?d)]   [(alt ?d)]   idlwave-shell-clear-current-bp)
   ([(control ?a)]   [(alt ?a)]   idlwave-shell-clear-all-bp)
   ([(control ?s)]   [(alt ?s)]   idlwave-shell-step)
   ([(control ?n)]   [(alt ?n)]   idlwave-shell-stepover)
   ([(control ?k)]   [(alt ?k)]   idlwave-shell-skip)
   ([(control ?u)]   [(alt ?u)]   idlwave-shell-up)
   ([(control ?o)]   [(alt ?o)]   idlwave-shell-out)
   ([(control ?m)]   [(alt ?m)]   idlwave-shell-return)
   ([(control ?h)]   [(alt ?h)]   idlwave-shell-to-here)
   ([(control ?r)]   [(alt ?r)]   idlwave-shell-cont)
   ([(control ?y)]   [(alt ?y)]   idlwave-shell-execute-default-command-line)
   ([(control ?z)]   [(alt ?z)]   idlwave-shell-reset)
   ([(control ?q)]   [(alt ?q)]   idlwave-shell-quit)
   ([(control ?p)]   [(alt ?p)]   idlwave-shell-print)
   ([(??)]           [(alt ??)]   idlwave-shell-help-expression)
   ([(control ?c)]   [(alt ?c)]   idlwave-shell-save-and-run)
   ([(        ?@)]   [(alt ?@)]   idlwave-shell-save-and-batch)
   ([(control ?x)]   [(alt ?x)]   idlwave-shell-goto-next-error)
   ([(control ?e)]   [(alt ?e)]   idlwave-shell-run-region)
   ([(control ?w)]   [(alt ?w)]   idlwave-shell-resync-dirs)
   ([(control ?l)]   [(alt ?l)]   idlwave-shell-redisplay)
   ([(control ?t)]   [(alt ?t)]   idlwave-shell-toggle-toolbar)
   ([(control up)]   [(alt up)]   idlwave-shell-stack-up)
   ([(control down)] [(alt down)] idlwave-shell-stack-down)))   
      s k1 k2 cmd)
  (while (setq s (pop specs))
    (setq k1  (nth 0 s)
	  k2  (nth 1 s)
	  cmd (nth 2 s))
    (when idlwave-shell-activate-prefix-keybindings
      (and k1 (define-key idlwave-shell-mode-prefix-map k1 cmd)))
    (when idlwave-shell-activate-alt-keybindings
      (and k2 (define-key idlwave-mode-map       k2 cmd))
      (and k2 (define-key idlwave-shell-mode-map k2 cmd)))))

;; Enter the prefix map at the two places.
(fset 'idlwave-debug-map       idlwave-shell-mode-prefix-map)
(fset 'idlwave-shell-debug-map idlwave-shell-mode-prefix-map)

;; The Menus --------------------------------------------------------------

(defvar idlwave-shell-menu-def
  '("Debug"
    ["Save and .RUN" idlwave-shell-save-and-run
     (or (eq major-mode 'idlwave-mode)
	 idlwave-shell-last-save-and-action-file)]
    ["Save and .COMPILE" idlwave-shell-save-and-compile
     (or (eq major-mode 'idlwave-mode)
	 idlwave-shell-last-save-and-action-file)]
    ["Save and @Batch" idlwave-shell-save-and-batch
     (or (eq major-mode 'idlwave-mode)
	 idlwave-shell-last-save-and-action-file)]
    ["Goto Next Error" idlwave-shell-goto-next-error t]
    "--"
    ["Execute Default Cmd" idlwave-shell-execute-default-command-line t]
    ["Edit Default Cmd" idlwave-shell-edit-default-command-line t]
    "--"
    ["Set Breakpoint" idlwave-shell-break-here
     (eq major-mode 'idlwave-mode)]
    ["Break in Module" idlwave-shell-break-in t]
    ["Clear Breakpoint" idlwave-shell-clear-current-bp t]
    ["Clear All Breakpoints" idlwave-shell-clear-all-bp t]
    ["List  All Breakpoints" idlwave-shell-list-all-bp t]
    "--"
    ["Step (into)" idlwave-shell-step t]
    ["Step (over)" idlwave-shell-stepover t]
    ["Skip One Statement" idlwave-shell-skip t]
    ["Continue" idlwave-shell-cont t]
    ("Continue to"
     ["End of Block" idlwave-shell-up t]
     ["End of Subprog" idlwave-shell-return t]
     ["End of Subprog+1" idlwave-shell-out t]
     ["Here (Cursor Line)" idlwave-shell-to-here
      (eq major-mode 'idlwave-mode)])
    "--"
    ["Print expression" idlwave-shell-print t]
    ["Help on expression" idlwave-shell-help-expression t]
    ["Evaluate Region" idlwave-shell-evaluate-region 
     (eq major-mode 'idlwave-mode)]
    ["Run Region" idlwave-shell-run-region (eq major-mode 'idlwave-mode)]
    "--"
    ["Redisplay" idlwave-shell-redisplay t]
    ["Stack Up" idlwave-shell-stack-up t]
    ["Stack Down" idlwave-shell-stack-down t]
    "--"
    ["Update Working Dir" idlwave-shell-resync-dirs t]
    ["Reset IDL" idlwave-shell-reset t]
    "--"
    ["Toggle Toolbar" idlwave-shell-toggle-toolbar t]
    ["Exit IDL" idlwave-shell-quit t]))

(if (or (featurep 'easymenu) (load "easymenu" t))
    (progn
      (easy-menu-define
       idlwave-shell-mode-menu idlwave-shell-mode-map "IDL shell menus"
       idlwave-shell-menu-def)
      (easy-menu-define 
       idlwave-mode-debug-menu idlwave-mode-map "IDL debugging menus"
       idlwave-shell-menu-def)
      (save-excursion
	(mapcar (lambda (buf)
		  (set-buffer buf)
		  (if (eq major-mode 'idlwave-mode)
		      (progn
			(easy-menu-remove idlwave-mode-debug-menu)
			(easy-menu-add idlwave-mode-debug-menu))))
		(buffer-list)))))

;; The Breakpoint Glyph -------------------------------------------------------

(defvar idlwave-shell-bp-glyph nil
  "The glyph to mark breakpoint lines in the source code.")

(let ((image-string "/* XPM */
static char * file[] = {
\"14 12 3 1\",
\" 	c #FFFFFFFFFFFF s backgroundColor\",
\".	c #4B4B4B4B4B4B\",
\"R	c #FFFF00000000\",
\"              \",
\"              \",
\"    RRRR      \",
\"   RRRRRR     \",
\"  RRRRRRRR    \",
\"  RRRRRRRR    \",
\"  RRRRRRRR    \",
\"  RRRRRRRR    \",
\"   RRRRRR     \",
\"    RRRR      \",
\"              \",
\"              \"};"))
      
  (setq idlwave-shell-bp-glyph
	(cond ((and (featurep 'xemacs)
		    (featurep 'xpm))
	       (make-glyph image-string))
	      ((and (not (featurep 'xemacs))
		    (fboundp 'image-type-available-p)
		    (image-type-available-p 'xpm))
	       (list 'image :type 'xpm :data image-string))
	      (t nil))))

(provide 'idlw-shell)

;;; Load the toolbar when wanted by the user.

(defun idlwave-shell-toggle-toolbar ()
  "Toggle the display of the debugging toolbar."
  (interactive)
  (if (featurep 'idlwave-toolbar)
      (idlwave-toolbar-toggle)
    (require 'idlwave-toolbar)
    (idlwave-toolbar-toggle)))


(when idlwave-shell-use-toolbar
  (or (load "idlw-toolbar" t)
      (message
       "Tried to load file `idlw-toolbar.el', but file does not exist")))

;;; idlw-shell.el ends here


