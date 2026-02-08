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

// TODO: we will need to be able to execute commands not only on stdout, but also on arbitrary 2d buffer (e.g. scrolling)

CommandBuffer :: struct {
    builder : str.Builder,
}

c_appendRune :: proc (cb : ^CommandBuffer, r : rune) {
    str.write_rune(&cb.builder, r)
}

c_appendString :: proc (cb : ^CommandBuffer, s : string) {
    str.write_string(&cb.builder, s)
}

c_clear :: proc (cb : ^CommandBuffer) {
    c_appendString(cb, "\e[2J")
}

c_goto :: proc (cb : ^CommandBuffer, p : Pos) {
    buffer : [32]u8
    s := fmt.bprintf(buffer[:], "\e[%v;%vH", p.y + 1, p.x + 1)
    c_appendString(cb, s)
}

c_drawBox :: proc (buffer : Buffer(BoxType), rect : Rect, type : BoxType) {
    br := br_from_rect(rect)

    for x in rect.x..<br.x {
        buffer_set(buffer, Pos{ x,   rect.y }, type)
        buffer_set(buffer, Pos{ x, br.y - 1 }, type)
    }

    for y in (rect.y + 1)..<(br.y - 1) {
        buffer_set(buffer, Pos{ rect.x,   y }, type)
        buffer_set(buffer, Pos{ br.x - 1, y }, type)
    }
}

// NOTE: mostly for drawing lines
c_drawBlock :: proc (buffer : Buffer(BoxType), rect : Rect, type : BoxType) {
    br := br_from_rect(rect)

    for x in rect.x..<br.x {
        for y in rect.y..<br.y {
            buffer_set(buffer, Pos{ x, y }, type)
        }
    }
}

c_resolveBoxBuffer :: proc (buffer : Buffer(BoxType), out : Buffer(rune)) {
    for x in 0..<buffer.rect.z {
        for y in 0..<buffer.rect.w {
            type := buffer_get(buffer, { x, y }) or_continue
            if type == .None { continue }

            n := buffer_get(buffer, { x, y - 1 }) or_else .None
            e := buffer_get(buffer, { x + 1, y }) or_else .None
            s := buffer_get(buffer, { x, y + 1 }) or_else .None
            w := buffer_get(buffer, { x - 1, y }) or_else .None

            candidate : BoxCharacter
            for c in BoxCharacters {
                if n not_in c.masks[0] ||
                   e not_in c.masks[1] ||
                   s not_in c.masks[2] ||
                   w not_in c.masks[3] { continue }

                candidate = c
                if type in c.type { break }
            }

            buffer_set(out, { x, y }, candidate.character)
        }
    }
}

c_fill :: proc (cb : ^CommandBuffer, rect : Rect, char : rune = ' ') {
    for y in rect.y ..= (rect.y + rect.w - 1) {
        c_goto(cb, { rect.x, y })
        for x in rect.x ..= (rect.x + rect.z - 1) {
            c_appendRune(cb, char)
        }
    }
}



Recorder :: struct {
    rect : Rect,
    pos  : Pos,

    render : bool,
    commandBuffer : ^CommandBuffer,
}

recorder_start :: proc (r : ^Recorder) {
    if r.render { c_goto(r.commandBuffer, r.pos) }
}

recorder_done :: proc (r : Recorder) -> bool {
    return recorder_remaining(r).y <= 0
}

recorder_newline :: proc (r : ^Recorder, offset : i16 = 0) -> (ok : bool = false) {
    if recorder_done(r^) { return }
    if offset >= r.rect.z { return }

    r.pos.y += 1
    r.pos.x = r.rect.x + offset

    if r.render { c_goto(r.commandBuffer, r.pos) }

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

    if r.render {
        c_appendString(r.commandBuffer, taken)
    }

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

    if r.render {
        c_appendRune(r.commandBuffer, c)
    }

    r.pos.x += 1
    ok = true
    return
}
