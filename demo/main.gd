extends Control

## デモ用。スキャナが拾うべきものと、拾ってはいけないものを両方入れてある。

func _ready() -> void:
    # 拾うべき: tr() に渡したキー。
    # 画面に出す文字はシーン側の自動翻訳に任せて、ここでは代入しない——
    # 代入すると text が訳文で上書きされ、監査からはキーが見えなくなる。
    print(tr("MENU_TITLE"), " / ", tr(&"MENU_START"))
    print(tr("MSG_WELCOME"))

    # 拾うべき: tr() で包まれていないハードコード文字列
    $Footer.text = "Copyright 2026"

    # 拾ってはいけない: コメント行
    # $Footer.text = "これはコメントなので対象外"

    _apply_locale()


func _apply_locale() -> void:
    var n := 3
    print(tr_n("ITEM_COUNT", "ITEM_COUNT_PLURAL", n))
    print(atr("AUTO_KEY"))
