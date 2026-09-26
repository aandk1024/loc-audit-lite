@tool
class_name LocScanner
extends RefCounted

## Walks the project for translation keys that are actually used, and for
## user-visible strings that were never wrapped in tr().
##
## What the scanner reads is source text, and two things follow from that:
##
##   - A key is written in source with escapes ("\"", "\\", "\n"); the key the
##     game actually asks for is the unescaped string. Every key is unescaped
##     here, so what comes out matches what the CSV holds.
##   - A tr() inside a comment or a string literal is not a use. GDScript is
##     read one string literal at a time, and what stands right before the
##     literal ('tr(', '.text =') decides what it is. Single, double, triple
##     and raw (r"...") quotes all count.

const SKIP_DIRS := ["addons", ".godot", ".git", ".import"]

## A directory link that points back at one of its own ancestors would be walked
## for ever, with the editor frozen for as long as it took. Neither limit is
## within reach of a project laid out by hand.
const MAX_DEPTH := 40
const MAX_DIRS := 20000

## Control properties whose value ends up on screen.
const TEXT_PROPS := [
    "text",
    "title",
    "tooltip_text",
    "placeholder_text",
    "dialog_text",
    "ok_button_text",
    "cancel_button_text",
    "hint_tooltip",
]

## Node types whose "text" is document content rather than a UI label.
const CONTENT_NODES := ["TextEdit", "CodeEdit"]


class Use extends RefCounted:
    var key: String = ""
    var file: String = ""
    var line: int = 0
    ## "tr" when the string goes through the translation server,
    ## "raw" when it is printed as written.
    var kind: String = "tr"

    func _init(p_key: String, p_file: String, p_line: int, p_kind: String) -> void:
        key = p_key
        file = p_file
        line = p_line
        kind = p_kind


static func collect_source_files(root: String = "res://", skip_addons: bool = true) -> PackedStringArray:
    var out := PackedStringArray()
    # An empty root would silently walk the current directory instead.
    if root.strip_edges() == "":
        return out
    var root_depth := root.get_slice_count("/")
    var walked := 0
    # Two different links can lead to one folder. Walking it twice would list
    # every file under it twice, and the report would count each fault twice.
    var seen := {}
    var stack := PackedStringArray([root])
    while stack.size() > 0:
        var dir_path: String = stack[stack.size() - 1]
        stack.remove_at(stack.size() - 1)
        var mark := dir_path.simplify_path()
        if seen.has(mark):
            continue
        seen[mark] = true
        walked += 1
        if walked > MAX_DIRS:
            push_error("loc_audit: stopped after %d folders under %s; the scan is not complete. A directory link pointing back into the project will do this." % [MAX_DIRS, root])
            break
        var dir := DirAccess.open(dir_path)
        if dir == null:
            continue
        dir.list_dir_begin()
        var name := dir.get_next()
        while name != "":
            if name.begins_with("."):
                name = dir.get_next()
                continue
            var full := dir_path.path_join(name)
            if dir.current_is_dir():
                var skip := false
                for s in SKIP_DIRS:
                    if name == s and (s != "addons" or skip_addons):
                        skip = true
                # Godot itself ignores a folder holding a .gdignore; the walk
                # follows suit, so retired copies never leak into a report.
                if not skip and FileAccess.file_exists(full.path_join(".gdignore")):
                    skip = true
                if not skip and full.get_slice_count("/") - root_depth > MAX_DEPTH:
                    push_error("loc_audit: %s is more than %d folders deep; it was not scanned." % [full, MAX_DEPTH])
                    skip = true
                if not skip:
                    stack.append(full)
            else:
                var ext := name.get_extension().to_lower()
                if ext == "gd" or ext == "tscn":
                    out.append(full)
            name = dir.get_next()
        dir.list_dir_end()
    return out


## Every key handed to tr()/atr()/tr_n() in GDScript, plus every literal set on
## a translatable Control property inside a .tscn.
static func find_uses(files: PackedStringArray) -> Array:
    var uses: Array = []
    # The code right before a literal decides what the literal is. These run
    # on that short stretch only, never on the whole line.
    #   tr("KEY")            -> the code before the literal ends in 'tr('
    #   tr_n("ONE", "MANY")  -> before the second literal there is just ', '
    # atr_n must come before atr in the alternation, or "atr_n(" is read as
    # "atr" followed by an underscore and never matches.
    var re_before_tr := RegEx.create_from_string(r'\b(atr_n|atr|tr_n|tr)\s*\(\s*&?$')
    var re_before_second := RegEx.create_from_string(r'^\s*,\s*&?$')
    var re_node := RegEx.create_from_string(r'^\s*\[node\b[^\]]*\btype="([A-Za-z0-9_]+)"')
    var re_open := RegEx.create_from_string(r'^\s*([a-z_]+)\s*=\s*"(.*)$')

    for file in files:
        var f := FileAccess.open(file, FileAccess.READ)
        if f == null:
            continue
        if file.get_extension().to_lower() == "tscn":
            _scene_uses(f, file, re_node, re_open, uses)
        else:
            var plural_open := false
            for lit in _gd_literals(f):
                var m := re_before_tr.search(lit.before)
                if m != null:
                    plural_open = m.get_string(1).ends_with("_n")
                    if lit.text != "":
                        uses.append(Use.new(lit.text, file, lit.line, "tr"))
                    continue
                if plural_open and re_before_second.search(lit.before) != null:
                    if lit.text != "":
                        uses.append(Use.new(lit.text, file, lit.line, "tr"))
                plural_open = false
        f.close()
    return uses


## Translatable properties set in a .tscn. Only a [node] section holds them:
## a [sub_resource] with a "text" of its own is a resource field that nobody
## hands to the translation server.
static func _scene_uses(f: FileAccess, file: String, re_node: RegEx, re_open: RegEx, uses: Array) -> void:
    var re_section := RegEx.create_from_string(r'^\[(?:gd_scene|gd_resource|ext_resource|sub_resource|node|connection|editable)\b')
    var line_no := 0
    var node_type := ""
    var in_node := false
    while not f.eof_reached():
        var line := f.get_line()
        line_no += 1
        if line.begins_with("["):
            var nm := re_node.search(line)
            in_node = line.begins_with("[node")
            node_type = nm.get_string(1) if nm != null else ""
            continue
        if not in_node:
            continue
        var m := re_open.search(line)
        if m == null or not TEXT_PROPS.has(m.get_string(1)):
            continue
        # Only the body of a text editor is content; its placeholder and
        # tooltip are labels like anybody else's.
        if CONTENT_NODES.has(node_type) and m.get_string(1) == "text":
            continue
        # Godot writes a real newline into the .tscn when the text has one,
        # so the value may run over several lines. Read until the closing
        # quote. A line inside the value that starts with "[" is normally
        # BBCode ("[center]"); only a real section header means the quote was
        # never closed.
        var start_line := line_no
        var rest := m.get_string(2)
        var body := ""
        var closing := _closing_quote(rest)
        var gave_up := false
        while closing < 0 and not f.eof_reached():
            body += rest + "\n"
            rest = f.get_line()
            line_no += 1
            if re_section.search(rest) != null:
                gave_up = true
                break
            closing = _closing_quote(rest)
        if gave_up:
            var nm2 := re_node.search(rest)
            in_node = rest.begins_with("[node")
            node_type = nm2.get_string(1) if nm2 != null else ""
            continue
        if closing < 0:
            continue
        body += rest.substr(0, closing)
        var value := _unescape(body)
        if value.strip_edges() != "":
            uses.append(Use.new(value, file, start_line, "raw"))


## GDScript literals assigned straight to a visible property. These are the
## strings that will never be translated no matter how complete the CSV is.
static func find_hardcoded_gd(files: PackedStringArray) -> Array:
    var out: Array = []
    var props := "|".join(TEXT_PROPS)
    # "=" and "+=" both put the literal on screen. The literal has to follow
    # the assignment directly: in `.text = tr("K")` the code before the
    # literal ends in 'tr(', and that one belongs to find_uses.
    var re_before := RegEx.create_from_string(r'\.(%s)\s*\+?=\s*$' % props)
    for file in files:
        if file.get_extension().to_lower() != "gd":
            continue
        var f := FileAccess.open(file, FileAccess.READ)
        if f == null:
            continue
        for lit in _gd_literals(f):
            if lit.text.strip_edges() == "":
                continue
            if re_before.search(lit.before) != null:
                out.append(Use.new(lit.text, file, lit.line, "raw"))
        f.close()
    return out


## Index of the first unescaped double quote in `s`, or -1 if there is none.
static func _closing_quote(s: String) -> int:
    var i := 0
    while i < s.length():
        var c := s[i]
        if c == "\\":
            i += 2
            continue
        if c == "\"":
            return i
        i += 1
    return -1


## Turns the escapes GDScript and .tscn use back into the characters they
## stand for, so a key compares equal to the same key read from the CSV.
static func _unescape(s: String) -> String:
    if s.find("\\") < 0:
        return s
    var out := ""
    var i := 0
    while i < s.length():
        var c := s[i]
        if c == "\\" and i + 1 < s.length():
            var n := s[i + 1]
            if n == "u" or n == "U":
                # \uXXXX and \UXXXXXX name a character by its code point.
                var width := 4 if n == "u" else 6
                var hex := s.substr(i + 2, width)
                if hex.length() == width and hex.is_valid_hex_number(false):
                    out += char(hex.hex_to_int())
                    i += 2 + width
                    continue
            match n:
                "n": out += "\n"
                "t": out += "\t"
                "r": out += "\r"
                "\\": out += "\\"
                "\"": out += "\""
                "'": out += "'"
                _: out += "\\" + n
            i += 2
        else:
            out += c
            i += 1
    return out


## One string literal in a GDScript file: its text with escapes resolved, and
## the code that stood between it and the previous literal on its line.
class Literal extends RefCounted:
    var text: String = ""
    var before: String = ""
    var line: int = 0


## Every string literal in a GDScript file, in order. A comment marker outside
## a string ends the line. Single, double and triple quotes all count; a
## triple-quoted string may run over several lines; r"..." is read raw. One
## pass over the characters, so a very long line costs what it weighs and a
## stray quote character inside a comment cannot swallow the rest of the file.
static func _gd_literals(f: FileAccess) -> Array:
    var out: Array = []
    var line_no := 0
    # A triple-quoted string left open by an earlier line.
    var open_q := ""
    var open_raw := false
    var open_text := ""
    var open_before := ""
    var open_line := 0
    while not f.eof_reached():
        var line := f.get_line()
        line_no += 1
        var n := line.length()
        var i := 0
        var before := ""
        if open_q != "":
            var r := _read_string(line, 0, open_q, true, open_raw)
            if int(r[1]) < 0:
                open_text += line + "\n"
                continue
            open_text += String(r[0])
            out.append(_literal(open_text, open_before, open_line, open_raw))
            open_q = ""
            i = int(r[1])
        # Characters are compared as code points and the text is cut out in
        # one piece at the end; building it one character at a time made a
        # 100,000-character line cost over a second.
        var seg_start := i
        while i < n:
            var code := line.unicode_at(i)
            if code == 35:  # '#'
                break
            if code == 34 or code == 39:  # '"' or "'"
                var c := line.substr(i, 1)
                before = line.substr(seg_start, i - seg_start)
                # r"..." - the r belongs to the string, not to the code before it.
                var raw := before.ends_with("r") and not (before.length() >= 2 and _is_ident(before.unicode_at(before.length() - 2)))
                if raw:
                    before = before.substr(0, before.length() - 1)
                var triple := line.substr(i, 3) == c.repeat(3)
                var start := i + (3 if triple else 1)
                var r := _read_string(line, start, c, triple, raw)
                if int(r[1]) < 0:
                    if triple:
                        open_q = c
                        open_raw = raw
                        open_text = String(r[0]) + "\n"
                        open_before = before
                        open_line = line_no
                    # Otherwise the string never closed: the rest of the line is not code.
                    break
                out.append(_literal(String(r[0]), before, line_no, raw))
                before = ""
                i = int(r[1])
                seg_start = i
                continue
            i += 1
    return out


## Reads a string body from `start` up to its closing quote (one quote, or
## three for a triple-quoted string). Returns [body, index_after_the_quote],
## or [body_so_far, -1] when the line ends first. Escapes stay in the body
## as written; _literal resolves them.
static func _read_string(line: String, start: int, q: String, triple: bool, raw: bool) -> Array:
    var i := start
    var n := line.length()
    var qcode := q.unicode_at(0)
    var close := q.repeat(3) if triple else q
    while i < n:
        var code := line.unicode_at(i)
        if code == 92 and i + 1 < n:  # backslash
            # In a raw string a backslash only keeps a quote from closing it.
            if raw and line.unicode_at(i + 1) != qcode:
                i += 1
                continue
            i += 2
            continue
        if code == qcode and (not triple or line.substr(i, 3) == close):
            return [line.substr(start, i - start), i + close.length()]
        i += 1
    return [line.substr(start), -1]


static func _literal(text: String, before: String, line: int, raw: bool) -> Literal:
    var lit := Literal.new()
    lit.text = text if raw else _unescape(text)
    lit.before = before
    lit.line = line
    return lit


static func _is_ident(code: int) -> bool:
    return (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
        or (code >= 97 and code <= 122) or code == 95 or code > 127
