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

sign_i16 :: proc (v : i16) -> i16 {
    return i16(int(0 < v) - int(v < 0))
}
