package tui

import str "core:strings"

substring :: proc (s : string, lo, hi : int) -> (sub : string, ok : bool) {
    if lo == hi && hi == len(s) { return "", true }
    sub, ok = str.substring(s, lo, hi)
    return
}

// substring_from :: proc (s : string, lo : int) -> (sub : string, ok : bool) {
//     return substring(s, lo, len(s))
// }

sign_i16 :: proc (v : i16) -> i16 {
    return i16(int(0 < v) - int(v < 0))
}




substring_to :: proc (s : string, hi : int) -> (sub : string, rest : string, ok : bool = false) {
    if hi > len(s) { return }
    if hi == 0 { return "", s, true }
    if hi == len(s) { return s, "", true }

    n := 0
    hib := 0
    for c, i in s {
        hib = i

        if n == hi { break }

        n += 1
    }

    return s[0:hib], s[hib:len((transmute([]u8)s))], true
}

substring_from :: proc (s : string, lo : int) -> (rest : string, sub : string, ok : bool = false) {
    if lo > len(s) { return }
    if lo == len(s) { return s, "", true }
    if lo == 0 { return "", s, true }

    n := 0
    lob := 0
    for c, i in s {
        if n == lo { break }

        n += 1
        lob = i
    }

    return s[0:lob], s[lob:len((transmute([]u8)s))], true
}
