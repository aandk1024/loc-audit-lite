@tool
extends VBoxContainer

## The editor dock. Every button is a thin wrapper around core/, so the logic
## itself stays testable without an editor.

const CsvIo := preload("res://addons/loc_audit/core/csv_io.gd")
const Scanner := preload("res://addons/loc_audit/core/scanner.gd")
const Report := preload("res://addons/loc_audit/core/report.gd")

const C_OK := "#7ec87e"
const C_ERR := "#e06c6c"
const C_WARN := "#e0b070"
const C_DIM := "#9a9a9a"

## Long reports are truncated; the dock is not a log viewer.
const MAX_LINES := 40
## And the log itself starts over past this many characters.
const LOG_LIMIT := 200000
## Overflow findings shown per run; past this the rest is counted, not
## printed, so one run can never scroll its own heading out of the log.
const MAX_OVERFLOW_LINES := 400

var _log_chars := 0

@onready var _csv_path: LineEdit = $CsvRow/CsvPath
@onready var _po_path: LineEdit = $PoRow/PoPath
@onready var _locales: LineEdit = $LocaleRow/Locales
@onready var _log: RichTextLabel = $Log

var _busy := false


func _ready() -> void:
    $Report.pressed.connect(_on_report)
    _log.clear()
    _info("Paths are res:// paths. Locales may be comma separated (en,ja,de).")
    _prefill()
    _lite_note()
    $CsvToPo.queue_free()
    $PoToCsv.queue_free()
    $CheckOverflow.queue_free()
    $PoRow.queue_free()


## The fields start empty rather than holding an example path: a made-up
## default means the first button press anybody tries answers "not found",
## which reads as a broken plugin. Instead the translations the project has
## registered (Project Settings > Localization) are turned back into the CSV
## they were imported from, so the first press works.
func _prefill() -> void:
    if _csv_path.text.strip_edges() != "" or _locales.text.strip_edges() != "":
        return
    var csv := _registered_csv()
    if csv == "":
        _info("No translation CSV was found from Project Settings > Localization; type the paths in.")
        return
    var locales := _csv_locales(csv)
    if locales.is_empty():
        # The file is there but is not a translation table (no locale columns).
        # Saying so beats leaving three empty fields with no explanation.
        _info(_esc("%s has no locale column, so the fields were left empty." % csv))
        return
    _csv_path.text = csv
    _locales.text = ",".join(locales)
    # CSV -> PO writes the first locale, so that is the file it would write.
    if _po_path.text.strip_edges() == "":
        _po_path.text = csv.get_base_dir().path_join(locales[0] + ".po")
    _info("Filled in from Project Settings > Localization. The first locale (%s) is the reference; change the order if your screens were laid out in another one." % locales[0])


## The CSV a registered .translation came from: Godot's importer writes
## "<name>.<locale>.translation" next to "<name>.csv".
static func _registered_csv() -> String:
    return _registered_csv_from(ProjectSettings.get_setting(
        "internationalization/locale/translations", PackedStringArray()))


## Split out so the list can be handed in: what the buyer's project registers
## is exactly what has to be tried against, and there is no other way to write
## those cases down.
static func _registered_csv_from(registered) -> String:
    # The setting is a PackedStringArray, but a project file edited by hand can
    # hold anything. Whatever it is, only strings are looked at.
    if not (registered is PackedStringArray or registered is Array):
        return ""
    for entry in registered:
        if not (entry is String or entry is StringName):
            continue
        var path := String(entry)
        var ext := path.get_extension().to_lower()
        if ext == "csv":
            if FileAccess.file_exists(path):
                return path
            continue
        # Only a .translation names a CSV. A .po registered directly is the
        # translator's file, not the table this dock edits - and guessing a
        # ".csv" next to it would hand back a file nobody asked for.
        if ext != "translation":
            continue
        # Strip ".translation", then the ".<locale>" the importer added.
        var without_ext := path.get_basename()
        for candidate in [without_ext.get_basename() + ".csv", without_ext + ".csv"]:
            if FileAccess.file_exists(candidate):
                return candidate
    return ""


## The locale columns of a translation CSV, read from its header row alone -
## the dock opens with the editor, so it must not read a whole file to do it.
static func _csv_locales(path: String) -> PackedStringArray:
    var out := PackedStringArray()
    var f := FileAccess.open(path, FileAccess.READ)
    if f == null:
        return out
    var header := f.get_csv_line()
    f.close()
    for i in range(1, header.size()):
        var locale: String = header[i].strip_edges()
        if locale != "" and not out.has(locale):
            out.append(locale)
    return out


# --- CSV -> PO ---------------------------------------------------------------


# --- PO -> CSV ---------------------------------------------------------------


# --- missing / unused / hardcoded --------------------------------------------

func _on_report() -> void:
    if _refuse_while_busy():
        return
    var csv := _csv_path.text.strip_edges()
    var locale := _single_locale()
    if csv == "" or locale == "":
        _err("Fill in the CSV path and at least one locale.")
        return
    if not FileAccess.file_exists(csv):
        _err("not found: " + csv)
        return

    var table = CsvIo.read_csv(csv)
    if not Array(table.locales).has(locale):
        _err("\"%s\" is not a column in the CSV (columns: %s)." % [locale, ", ".join(table.locales)])
        return

    var r = Report.run(table, locale)

    _head("Report: %s (%d keys, %d source files)" % [r.locale, r.key_count, r.file_count])
    if r.file_count == 0:
        _line(C_WARN, "No .gd or .tscn was found outside addons/ and .gdignore folders, so every key looks unused. Check where the project's scenes live before deleting anything.")

    if r.untranslated.is_empty():
        _line(C_OK, "Untranslated: none")
    else:
        _line(C_ERR, "Untranslated (%d): in the CSV but the %s column is empty" % [r.untranslated.size(), _esc(locale)])
        _dump_keys(r.untranslated)

    if r.unused.is_empty():
        _line(C_OK, "Unused: none")
    else:
        _line(C_WARN, "Unused (%d): in the CSV but never reached by tr() or a scene property" % r.unused.size())
        _dump_keys(r.unused)

    if r.undefined.is_empty():
        _line(C_OK, "Undefined: none")
    else:
        _line(C_ERR, "Undefined (%d): used in the project but missing from the CSV" % r.undefined.size())
        _dump_uses(r.undefined)

    if r.hardcoded.is_empty():
        _line(C_OK, "Hardcoded: none")
    else:
        _line(C_ERR, "Hardcoded (%d): assigned to a visible property without tr()" % r.hardcoded.size())
        _dump_uses(r.hardcoded)

    if r.total() == 0:
        _ok("Nothing to fix for %s." % locale)


# --- overflow ----------------------------------------------------------------


# --- helpers -----------------------------------------------------------------

func _locale_list() -> PackedStringArray:
    var out := PackedStringArray()
    for part in _locales.text.split(",", false):
        var s: String = part.strip_edges()
        if s != "" and not out.has(s):
            out.append(s)
    return out


## While the overflow check awaits frames every other button is still live;
## its output would land in the middle of the overflow report.
func _refuse_while_busy() -> bool:
    if _busy:
        _err("A check is already running; wait for it to finish.")
    return _busy


static func _locale_loaded(locale: String, loaded: PackedStringArray) -> bool:
    var want := TranslationServer.standardize_locale(locale)
    for l in loaded:
        if TranslationServer.standardize_locale(String(l)) == want:
            return true
    return false


func _single_locale() -> String:
    var list := _locale_list()
    if list.is_empty():
        return ""
    if list.size() > 1:
        _info("Several locales given; using the first one (%s)." % list[0])
    return list[0]


## The fields take res:// paths, and both buttons replace the file they are
## pointed at. A typed-in absolute path would send that replacement anywhere on
## the disk - and _ensure_dir would build the folders to get there - so a path
## that is not inside the project or its user data is refused instead.
## Returns "" when the path may be written, or the reason it may not.
static func _refuse_write_outside_project(path: String) -> String:
    var p := path.strip_edges()
    if not (p.begins_with("res://") or p.begins_with("user://")):
        return "%s is not a res:// path. This writes to the file you name, so only paths inside the project (res://) or its user data (user://) are accepted. Nothing was written." % p
    # A ".." segment climbs back out again; a name that merely contains dots
    # ("a..b.csv") does not, so the segments are looked at rather than the text.
    for part in p.replace("\\", "/").split("/"):
        if part == "..":
            return "%s steps back out of the project with \"..\". Nothing was written." % p
    return ""


func _ensure_dir(path: String) -> void:
    var dir := path.get_base_dir()
    if dir != "" and not DirAccess.dir_exists_absolute(dir):
        DirAccess.make_dir_recursive_absolute(dir)


## Make a file written from here show up in the FileSystem panel right away.
func _rescan(path: String) -> void:
    if Engine.is_editor_hint() and path.begins_with("res://"):
        EditorInterface.get_resource_filesystem().scan()


func _dump_keys(keys: Array) -> void:
    var n: int = mini(keys.size(), MAX_LINES)
    for i in range(n):
        _line(C_DIM, "    " + _esc(String(keys[i])))
    if keys.size() > n:
        _line(C_DIM, "    ... and %d more" % (keys.size() - n))


func _dump_uses(items: Array) -> void:
    var n: int = mini(items.size(), MAX_LINES)
    for i in range(n):
        var u = items[i]
        _line(C_DIM, "    %s  (%s:%d)" % [_esc(String(u.key)), _esc(String(u.file)), u.line])
    if items.size() > n:
        _line(C_DIM, "    ... and %d more" % (items.size() - n))


## Keys and translations are arbitrary text, so a stray bracket must not be
## read as BBCode.
static func _esc(s: String) -> String:
    return s.replace("[", "[lb]")


## Two paths that spell the same file differently ("./", "//", "..", letter
## case on Windows) must still count as the same file.
static func _same_file(a: String, b: String) -> bool:
    var ga := ProjectSettings.globalize_path(a).simplify_path().to_lower()
    var gb := ProjectSettings.globalize_path(b).simplify_path().to_lower()
    return ga == gb


func _line(color: String, text: String) -> void:
    # The log is not a history. Past a few hundred kilobytes it starts over
    # rather than grow for the whole editor session.
    _log_chars += text.length()
    if _log_chars > LOG_LIMIT:
        _log.clear()
        _log_chars = text.length()
        _log.append_text("[color=%s](older output cleared)[/color]\n" % C_DIM)
    _log.append_text("[color=%s]%s[/color]\n" % [color, text])


func _head(text: String) -> void:
    _log.append_text("\n[b]%s[/b]\n" % _esc(text))


func _info(text: String) -> void:
    _line(C_DIM, _esc(text))


func _ok(text: String) -> void:
    _line(C_OK, _esc(text))


func _err(text: String) -> void:
    _line(C_ERR, _esc(text))

## Lite: say once, in the dock itself, what the full version adds and where it is.
func _lite_note() -> void:
    _info("Loc Audit Lite. The full version adds: Check overflow; CSV to PO and PO to CSV for handing work to translators and merging it back. https://theidlehands.itch.io/loc-audit")
