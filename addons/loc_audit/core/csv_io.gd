@tool
class_name LocCsvIo
extends RefCounted

## CSV <-> PO conversion for Godot 4 localization files.
##
## CSV layout follows Godot's own translation CSV: the first column holds the
## message key, every following column holds one locale. The header row names
## the locales.
##
##     keys,en,ja
##     MENU_START,Start,はじめる

class Table extends RefCounted:
    var locales: PackedStringArray = PackedStringArray()
    var keys: PackedStringArray = PackedStringArray()
    ## key -> locale -> text
    var rows: Dictionary = {}
    ## key -> translator comment (survives a PO round trip)
    var comments: Dictionary = {}
    ## Entries a PO marked "#, fuzzy" and read_po therefore left out.
    var skipped_fuzzy: int = 0
    ## Header columns with no locale name. Their cells are not held here, so
    ## writing this table back would drop those columns from the file.
    var dropped_columns: int = 0
    ## Keys the file listed more than once. Only the last row of each survives
    ## in `rows`, so writing back would delete the others.
    var duplicate_keys: PackedStringArray = PackedStringArray()

    func text_for(key: String, locale: String) -> String:
        var row: Dictionary = rows.get(key, {})
        return String(row.get(locale, ""))

    func set_text(key: String, locale: String, value: String) -> void:
        if not rows.has(key):
            rows[key] = {}
            keys.append(key)
        rows[key][locale] = value


# --- CSV -------------------------------------------------------------------

static func read_csv(path: String, delimiter: String = ",") -> Table:
    var table := Table.new()
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        push_error("loc_audit: cannot open %s (%d)" % [path, FileAccess.get_open_error()])
        return table

    var header := f.get_csv_line(delimiter)
    if header.size() < 2:
        push_error("loc_audit: %s needs a key column and at least one locale column" % path)
        return table
    # Each locale remembers its own column. An empty header cell (Excel adds
    # those readily) must not shift every locale after it by one.
    var columns: Array[int] = []
    for i in range(1, header.size()):
        var loc: String = header[i].strip_edges()
        if loc != "":
            if table.locales.has(loc):
                # Two columns with the same name: whichever is read last
                # would silently win, and writing back would put that one
                # in both. Refuse the file rather than lose a column.
                push_error("loc_audit: %s names the locale column \"%s\" twice" % [path, loc])
                f.close()
                return Table.new()
            table.locales.append(loc)
            columns.append(i)
        else:
            # The cells under a nameless column are not read, so this table can
            # no longer stand for the whole file. Remembered, because writing it
            # back would take that column out of somebody's CSV.
            table.dropped_columns += 1

    while not f.eof_reached():
        var line := f.get_csv_line(delimiter)
        if line.size() == 0:
            continue
        # Godot's importer takes the key exactly as written, spaces and all.
        # Trimming here would make the audit see a key the game never asks
        # for, and a write-back would rename it.
        var key: String = line[0]
        if key == "":
            continue
        # A key listed twice keeps only its last row here (a Dictionary has one
        # slot per key), so writing the table back would delete the earlier
        # rows. Remembered rather than merged silently.
        if table.rows.has(key) and not table.duplicate_keys.has(key):
            table.duplicate_keys.append(key)
        for i in range(table.locales.size()):
            var col: int = columns[i]
            var value: String = line[col] if col < line.size() else ""
            # Godot's own CSV importer unescapes cell text by default
            # (unescape_translations = true): "\n" in a cell is a newline in
            # the game. Read the same way, or the audit measures strings the
            # player never sees.
            table.set_text(key, table.locales[i], _godot_unescape(value))
    f.close()
    return table


## The escapes Godot's CSV importer resolves when it builds a Translation.
## The importer calls String.c_unescape(), which is not a parser: it replaces
## \a \b \f \n \r \t \v \' \" one after the other and "\\" last of all, and
## knows nothing about \uXXXX. Doing the same thing in the same order is the
## only way to read what the game will show; a cleverer reader would be wrong
## exactly where it differs (measured against the importer on 4.4 and 4.7).
static func _godot_unescape(s: String) -> String:
    if s.find("\\") < 0:
        return s
    var out := s
    out = out.replace("\\a", "\a")
    out = out.replace("\\b", "\b")
    out = out.replace("\\f", "\f")
    out = out.replace("\\n", "\n")
    out = out.replace("\\r", "\r")
    out = out.replace("\\t", "\t")
    out = out.replace("\\v", "\v")
    out = out.replace("\\'", "'")
    out = out.replace("\\\"", "\"")
    out = out.replace("\\\\", "\\")
    return out


## Keys whose value for `locale` cannot be stored in a Godot translation CSV:
## a backslash followed by one of a b f n r t v ' " is read by the importer as
## an escape no matter how it is written (see _godot_unescape - "\\" is
## resolved last, so doubling does not protect the pair). The game would show
## something else for these, and the caller should say so.
static func unrepresentable_keys(table: Table, locale: String) -> PackedStringArray:
    var out := PackedStringArray()
    var re := RegEx.create_from_string(r'\\[abfnrtv' + "'" + r'"]')
    for key in table.keys:
        if re.search(table.text_for(key, locale)) != null:
            out.append(key)
    return out


static func write_csv(table: Table, path: String, delimiter: String = ",") -> Error:
    if delimiter.length() != 1:
        push_error("loc_audit: the CSV delimiter must be exactly one character")
        return ERR_INVALID_PARAMETER
    if table.locales.is_empty():
        # A table without a single locale column is not a translation file.
        # Writing it would replace somebody's CSV with a "keys" header.
        push_error("loc_audit: refusing to write a CSV with no locale column to %s" % path)
        return ERR_INVALID_DATA
    # Opening the real file for writing would truncate it before a single row
    # is written. This is somebody's translation work, so it is written beside
    # the original and only swapped in once it is complete.
    var tmp := _tmp_path(path)
    var f := FileAccess.open(tmp, FileAccess.WRITE)
    if f == null:
        return FileAccess.get_open_error()

    var header := PackedStringArray(["keys"])
    header.append_array(table.locales)
    f.store_csv_line(header, delimiter)

    for key in table.keys:
        var line := PackedStringArray([key])
        for locale in table.locales:
            line.append(_csv_cell(table.text_for(key, locale)))
        f.store_csv_line(line, delimiter)
    return _finish(f, tmp, path)


## What goes into a CSV cell so that Godot's importer (which unescapes) and
## read_csv give back the string that was put in:
##   - a backslash is doubled, or the importer would read it as the start of
##     an escape;
##   - a carriage return becomes a newline. Godot's CSV reader splits a cell
##     on a bare CR, and the two engine versions disagree about what is left,
##     so a CR cannot survive the file at all. A newline can - the cell is
##     quoted for it.
static func _csv_cell(v: String) -> String:
    var out := v.replace("\\", "\\\\")
    return out.replace("\r\n", "\n").replace("\r", "\n")


## The names of the working files are unlikely to be somebody else's. A plain
## ".bak" next to a translation CSV is exactly where a translator keeps a copy.
static func _tmp_path(path: String) -> String:
    return path + ".loc_audit.tmp"


# --- PO --------------------------------------------------------------------

static func write_po(table: Table, locale: String, path: String) -> Error:
    var tmp := _tmp_path(path)
    var f := FileAccess.open(tmp, FileAccess.WRITE)
    if f == null:
        return FileAccess.get_open_error()

    # The "\n" in these header strings must reach the file as two characters,
    # backslash and n. A real newline inside the quotes makes the PO
    # unreadable for every consumer (Godot's loader, msgfmt, Poedit).
    # The locale comes from a CSV header cell, so it is escaped like any
    # other value rather than pasted in.
    f.store_line("msgid \"\"")
    f.store_line("msgstr \"\"")
    f.store_line("\"Content-Type: text/plain; charset=UTF-8\\n\"")
    f.store_line("\"Language: %s\\n\"" % _escape_inner(locale))
    f.store_line("")

    for key in table.keys:
        var comment := String(table.comments.get(key, ""))
        if comment != "":
            for cl in comment.split("\n"):
                f.store_line("#. " + cl)
        f.store_line("msgid " + _quote(key))
        f.store_line("msgstr " + _quote(table.text_for(key, locale)))
        f.store_line("")
    return _finish(f, tmp, path)


## Close a finished temporary file and put it in place - but only if every
## write actually reached the disk. A full disk, a quota, a network drive that
## went away: the store_* calls report nothing by themselves, and without this
## check a file that stops halfway through would be swapped over somebody's
## translations and the original deleted.
static func _finish(f: FileAccess, tmp: String, path: String) -> Error:
    f.flush()
    var werr := f.get_error()
    f.close()
    if werr != OK:
        push_error("loc_audit: writing %s failed (error %d); %s was left untouched" % [tmp, werr, path])
        DirAccess.remove_absolute(tmp)
        return werr
    if FileAccess.get_file_as_bytes(tmp).size() == 0:
        # Nothing reached the disk. Never swap an empty file in.
        DirAccess.remove_absolute(tmp)
        return ERR_FILE_CANT_WRITE
    return _swap_in(tmp, path)


## Put a finished temporary file in place of the real one. The original is
## moved aside first, so a failure at any step leaves either the old file or
## the new one — never a half-written file where the translations used to be.
static func _swap_in(tmp: String, path: String) -> Error:
    var dir := DirAccess.open(path.get_base_dir())
    if dir == null:
        DirAccess.remove_absolute(tmp)
        return ERR_CANT_OPEN

    var final_name := path.get_file()
    var tmp_name := tmp.get_file()
    var backup_name := final_name + ".loc_audit.bak"
    var had_original := FileAccess.file_exists(path)

    if had_original:
        if dir.file_exists(backup_name):
            dir.remove(backup_name)
        var moved_aside := dir.rename(final_name, backup_name)
        if moved_aside != OK:
            dir.remove(tmp_name)
            return moved_aside

    var swapped := dir.rename(tmp_name, final_name)
    if swapped != OK:
        # Put the original back and take the half-finished file away, rather
        # than leaving a stray .tmp next to somebody's translations.
        dir.remove(tmp_name)
        if had_original:
            # If even that fails the translations still exist, but under a name
            # nobody is looking for. Say where they are instead of reporting
            # only the first failure and leaving the file apparently gone.
            var restored := dir.rename(backup_name, final_name)
            if restored != OK:
                push_error(("loc_audit: could not write %s and could not put the original back "
                    + "(error %d). Your file is safe at %s - rename it back by hand.") % [
                    path, restored, path.get_base_dir().path_join(backup_name)])
        return swapped

    if had_original:
        # The new file is in place, so this is not a failure worth undoing -
        # but a copy of the old translations is now sitting next to them under
        # a name nobody expects (a read-only original does this). Say so rather
        # than leave it to be found later.
        var swept := dir.remove(backup_name)
        if swept != OK:
            push_warning("loc_audit: %s was written, but the copy of the old file at %s could not be removed (error %d). Delete it by hand." % [
                path, path.get_base_dir().path_join(backup_name), swept])
    return OK


static func read_po(path: String, locale: String) -> Table:
    var table := Table.new()
    table.locales = PackedStringArray([locale])
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        push_error("loc_audit: cannot open %s (%d)" % [path, FileAccess.get_open_error()])
        return table

    var pending_comment := PackedStringArray()
    var current_key := ""
    var current_value := ""
    var state := ""  # "" | "msgid" | "msgstr" | "skip"
    # "#, fuzzy" sits above the msgid it belongs to. It is held in
    # fuzzy_pending until that msgid arrives, then moves to fuzzy for the
    # entry being read.
    var fuzzy := false
    var fuzzy_pending := false

    while not f.eof_reached():
        var raw := f.get_line()
        var line := raw.strip_edges()
        if line == "":
            _commit_po_entry(table, locale, state, current_key, current_value, fuzzy, pending_comment)
            state = ""
            current_key = ""
            current_value = ""
            pending_comment = PackedStringArray()
            fuzzy = false
            # A flag line with nothing after it belongs to no entry. Letting
            # it wait would make it swallow the next real one.
            fuzzy_pending = false
            continue
        if line.begins_with("#."):
            pending_comment.append(line.substr(2).strip_edges())
            continue
        if line.begins_with("#,") and line.find("fuzzy") >= 0:
            # gettext's "needs review" flag. msgfmt leaves such entries out of
            # the compiled catalogue, and so does this: a fuzzy translation
            # must not land in the CSV looking like a finished one.
            fuzzy_pending = true
            continue
        if line.begins_with("#~"):
            # An obsolete entry. Whatever flag sat above it was its own.
            fuzzy_pending = false
            continue
        if line.begins_with("#"):
            continue
        if line.begins_with("msgid "):
            # Comments collected so far belong to the entry just closed, if
            # one was; otherwise they are this entry's and must stay.
            if _commit_po_entry(table, locale, state, current_key, current_value, fuzzy, pending_comment):
                pending_comment = PackedStringArray()
            fuzzy = fuzzy_pending
            fuzzy_pending = false
            state = "msgid"
            current_key = _unquote(line.substr(6))
            current_value = ""
            continue
        if line.begins_with("msgid_plural"):
            # The plural form of the key. A CSV has one cell per key, so it is
            # not carried over. "skip" keeps the entry open (so the blank line
            # still commits it) while ignoring this line's continuations.
            state = "skip"
            continue
        if line.begins_with("msgstr["):
            # gettext plurals. A CSV cannot hold more than one string per key,
            # so the singular is taken and the other forms are dropped - but
            # the entry must stay open, or msgstr[1] would throw away msgstr[0].
            if line.begins_with("msgstr[0]"):
                state = "msgstr"
                current_value = _unquote(line.substr(9))
            else:
                state = "skip"
            continue
        if line.begins_with("msgstr "):
            state = "msgstr"
            current_value = _unquote(line.substr(7))
            continue
        if line.begins_with("\""):
            var chunk := _unquote(line)
            if state == "msgid":
                current_key += chunk
            elif state == "msgstr":
                current_value += chunk
    _commit_po_entry(table, locale, state, current_key, current_value, fuzzy, pending_comment)
    f.close()

    # The PO header carries an empty msgid; it is metadata, not a message.
    table.rows.erase("")
    var cleaned := PackedStringArray()
    for k in table.keys:
        if k != "":
            cleaned.append(k)
    table.keys = cleaned
    return table


## A finished PO entry goes into the table - unless it is fuzzy, in which case
## it is counted and left out. The header (empty msgid) is neither. Returns
## true when an entry was closed here.
static func _commit_po_entry(table: Table, locale: String, state: String, key: String,
        value: String, fuzzy: bool, comment: PackedStringArray) -> bool:
    if not (state == "msgstr" or state == "skip") or key == "":
        return false
    if fuzzy:
        table.skipped_fuzzy += 1
        return true
    table.set_text(key, locale, value)
    if comment.size() > 0:
        table.comments[key] = "\n".join(comment)
    return true


static func _escape_inner(s: String) -> String:
    var out := s.replace("\\", "\\\\")
    out = out.replace("\"", "\\\"")
    out = out.replace("\n", "\\n")
    out = out.replace("\r", "\\r")
    out = out.replace("\t", "\\t")
    return out


static func _quote(s: String) -> String:
    return "\"" + _escape_inner(s) + "\""


static func _unquote(s: String) -> String:
    var t := s.strip_edges()
    if t.begins_with("\""):
        t = t.substr(1)
    if t.ends_with("\""):
        t = t.substr(0, t.length() - 1)
    var out := ""
    var i := 0
    while i < t.length():
        var c := t[i]
        if c == "\\" and i + 1 < t.length():
            var n := t[i + 1]
            match n:
                "n": out += "\n"
                "t": out += "\t"
                "r": out += "\r"
                "\\": out += "\\"
                "\"": out += "\""
                _: out += n
            i += 2
        else:
            out += c
            i += 1
    return out
