@tool
class_name LocReport
extends RefCounted

## The missing / unused / undefined / hardcoded pass.
##
## It lives here rather than in the dock so that it is a plain function of the
## CSV plus the project files, and can be checked without opening an editor.

const Scanner := preload("res://addons/loc_audit/core/scanner.gd")


class Result extends RefCounted:
    var locale: String = ""
    var key_count: int = 0
    var file_count: int = 0
    ## In the CSV, but this locale's column is empty.
    var untranslated: Array[String] = []
    ## In the CSV, but nothing in the project ever asks for it.
    var unused: Array[String] = []
    ## Asked for by the project, but missing from the CSV. Holds Scanner.Use.
    var undefined: Array = []
    ## Visible strings assigned in GDScript without tr(). Holds Scanner.Use.
    var hardcoded: Array = []

    func total() -> int:
        return untranslated.size() + unused.size() + undefined.size() + hardcoded.size()


## `table` is a LocCsvIo.Table.
static func run(table, locale: String, root: String = "res://") -> Result:
    var r := Result.new()
    r.locale = locale
    # Anything that is not a Table (null, a number, some other object) gets an
    # empty result rather than a script error halfway through.
    # `in` on a non-object (an int, a string) is itself a script error, so the
    # type check has to come first.
    if table == null or not (table is Object) or not ("keys" in table) or not ("locales" in table):
        return r
    # A locale the CSV does not have would make every key look untranslated.
    if not Array(table.locales).has(locale):
        push_error("loc_audit: \"%s\" is not a column in the CSV (columns: %s)" % [
            locale, ", ".join(table.locales)])
        return r

    var files := Scanner.collect_source_files(root, true)
    r.file_count = files.size()
    r.key_count = table.keys.size()

    # A key counts as used whether it goes through tr() in code or sits on a
    # translatable property in a scene.
    var used := {}
    for u in Scanner.find_uses(files):
        if not used.has(u.key):
            used[u.key] = u

    # A literal assigned to a visible property in GDScript goes through auto
    # translation at runtime exactly like a scene property does. If that
    # literal is a key in the CSV it is a use of the key, not a hardcoded
    # string - the same line must not land in two categories.
    for h in Scanner.find_hardcoded_gd(files):
        if table.rows.has(h.key):
            if not used.has(h.key):
                used[h.key] = h
        else:
            r.hardcoded.append(h)

    for key in table.keys:
        if String(table.text_for(key, locale)).strip_edges() == "":
            r.untranslated.append(key)
        if not used.has(key):
            r.unused.append(key)

    for key in used.keys():
        if not table.rows.has(key):
            r.undefined.append(used[key])

    return r
