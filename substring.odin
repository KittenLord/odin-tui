package tui

import str "core:strings"

substring :: proc (s : string, lo, hi : int) -> (sub : string, ok : bool) {
    if lo == hi && hi == len(s) { return "", true }
    sub, ok = str.substring(s, lo, hi)
    return
}

substring_from :: proc (s : string, lo : int) -> (sub : string, ok : bool) {
    return substring(s, lo, len(s))
}
