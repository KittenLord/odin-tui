package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"
import os_old "core:os"
import "core:math"
import "core:slice"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:log"


// TODO: recording commands will be moved here in the future


Recorder :: struct {
    rect : Rect,
    pos  : Pos,

    render : bool,
}

recorder_start :: proc (r : ^Recorder) {
    if r.render { c_goto(r.pos) }
}

recorder_done :: proc (r : Recorder) -> bool {
    return recorder_remaining(r).y <= 0
}

recorder_newline :: proc (r : ^Recorder, offset : i16 = 0) -> (ok : bool = false) {
    if recorder_done(r^) { return }
    if offset >= r.rect.z { return }

    r.pos.y += 1
    r.pos.x = r.rect.x + offset

    if r.render { c_goto(r.pos) }

    ok = true
    return
}

recorder_remaining :: proc (r : Recorder) -> Pos {
    return r.rect.xy + r.rect.zw - r.pos
}

// NOTE: Does NOT add a newline on the end

// 0, text, false
// n, rem, true
recorder_writeOnCurrentLine :: proc (r : ^Recorder, text : string) -> (written : i16 = 0, remaining : string, ok : bool = false) {
    remaining = text
    if recorder_done(r^) { return }

    rm := recorder_remaining(r^)
    l := math.min(cast(int)rm.x, len(text))

    taken, _ := str.substring_to(text, l)
    written = cast(i16)len(taken)
    remaining, _ = substring_from(text, l)

    if r.render { os.write_string(os.stdout, taken) }

    r.pos.x += cast(i16)l

    ok = true
    return
}

recorder_write :: proc (r : ^Recorder, text : string) -> (written : i16 = 0, remaining : string) {
    remaining = text

    for !recorder_done(r^) && len(remaining) > 0 {
        w : i16
        w, remaining, _ = recorder_writeOnCurrentLine(r, remaining)
        written += w
        recorder_newline(r, 0)
    }

    return
}

recorder_writeRuneOnCurrentLine :: proc (r : ^Recorder, c : rune) -> (ok : bool = false) {
    if recorder_done(r^) { return }
    if recorder_remaining(r^).x <= 0 { return }

    if r.render { os.write_rune(os.stdout, c) }

    r.pos.x += 1
    ok = true
    return
}
