package tui

import "core:fmt"

import "core:slice"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:math"

import "core:log"


drawTextBetterer :: proc (ctx : ^RenderingContext, text : string, rect : Rect, align : Alignment, wrap : Wrapping, rendering : bool = true, ll_list : []i16 = nil) -> (actualRect : Rect, truncated : bool) {
    return _drawTextBetterer(ctx, text, rect, align, wrap, rendering)
}


// TODO: should we just render one line at a time and align it right away, so as to not
// calculate alignments beforehand (and not rendering twice)?
_drawTextBetter :: proc (ctx : ^RenderingContext, text : string, rect : Rect, align : Alignment, wrap : Wrapping, rendering : bool = true, ll_list : []i16 = nil) -> (actualRect : Rect, truncated : bool) {
    ll_list := ll_list

    if rect.z == 0 || rect.w == 0 {
        // TODO: text is all whitespace?
        return { 0, 0, 0, 0 }, (len(text) != 0)
    }

    if rendering {
        ll_list = make([]i16, rect.w)
        _drawTextBetter(ctx, text, rect, align, wrap, false, ll_list)
    }

    defer if rendering {
        delete(ll_list)
    }

    ll_new :: proc (writer : ^Writer, ll_list : []i16, ll_off : i16, ll_cur : ^i16, ll_spacebar : ^i16, minOffset : ^i16, align : Alignment) -> bool {
        if writer_remaining(writer^).y <= 1 { return false }

        precalculatedLength := ll_list != nil ? ll_list[writer.pos.y + ll_off + 1] : 0
        // TODO: calculate offset based off alignment
        offset := precalculatedLength == 0 ? 0 : (precalculatedLength * 0)
        if offset < minOffset^ { minOffset^ = offset }

        writer_newline(writer, offset)

        if ll_list != nil { ll_list[writer.pos.y + ll_off] = 0 }

        ll_cur^ = 0
        ll_spacebar^ = 0

        return true
    }

    ll_add :: proc (value : i16, writer : Writer, ll_list : []i16, ll_off : i16, ll_cur : ^i16, ll_max : ^i16) {
        if ll_list != nil {
            ll_list[writer.pos.y + ll_off] += value
        }

        ll_cur^ += value
        if ll_cur^ > ll_max^ { ll_max^ = ll_cur^ }
    }

    State :: enum {
        SkippingWhitespace,
        CollectingShortWord,
        DumpingLargeWord,
    }

    state : State = .SkippingWhitespace

    minOffset : i16 = 0

    sw_lo  := 0
    sw_hi  := 0
    sw_len : i16 = 0

    ll_max : i16 = 0
    ll_cur : i16 = 0
    ll_spacebar : i16 = 0
    ll_off := -rect.y

    // TODO: the first line should be aligned and minOffset assigned
    writer := Writer{ rect, rect.xy, rendering, ctx == nil ? nil : ctx.commandBuffer }
    writer_start(&writer)

    num := 0
    l := len(text)
    // NOTE: i is byte offset
    outerLoop: for c, i in text {
        cs := utf8.rune_size(c)
        eof := (num + 1 >= l)

        switchState := true
        mainLoop: for switchState {
            switchState = false

            switch state {
            case .SkippingWhitespace: {
                if !str.is_space(c) {
                    switchState = true
                    state = .CollectingShortWord
                    continue mainLoop
                }

                continue mainLoop
            }
            case .CollectingShortWord: {
                if sw_len == 0 {
                    sw_lo = i
                    sw_hi = i
                    sw_len = 0
                }

                if !str.is_space(c) {
                    sw_hi = i + cs
                    sw_len += 1
                }
                
                if sw_len > rect.z {
                    switchState = true
                    state = .DumpingLargeWord
                    continue mainLoop
                }

                if str.is_space(c) || eof {
                    if (ll_spacebar + sw_len) <= writer_remaining(writer).x {
                        if ll_spacebar == 1 {
                            writer_writeOnCurrentLine(&writer, " ")
                            ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                        }

                        writer_writeOnCurrentLine(&writer, text[sw_lo:sw_hi])
                        ll_add(sw_len, writer, ll_list, ll_off, &ll_cur, &ll_max)
                        ll_spacebar = 1
                        sw_len = 0

                        // NOTE: if !str.is_space then we are at eof and we should consume the last character
                        switchState = str.is_space(c)
                        state = .SkippingWhitespace
                        continue mainLoop
                    }

                    switch wrap {
                    case .NoWrapping: {
                        ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop

                        // NOTE: the word is guaranteed to fit into the newly opened line, we can reuse the short word code
                        switchState = true
                        state = .CollectingShortWord
                        continue mainLoop
                    }
                    case .Wrapping: {
                        switchState = true
                        state = .DumpingLargeWord
                        continue mainLoop
                    }
                    }
                }
            }
            case .DumpingLargeWord: {
                if ll_spacebar == 1 {
                    if writer_remaining(writer).x < 1 {
                        ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop
                    }
                    else {
                        writer_writeOnCurrentLine(&writer, " ")
                        ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                    }

                    ll_spacebar = 0
                }

                if sw_len > 0 {
                    sw_len = 0
                    remaining : string = text[sw_lo:sw_hi]

                    for len(remaining) > 0 {
                        written : i16
                        written, remaining, _ = writer_writeOnCurrentLine(&writer, remaining)
                        ll_add(written, writer, ll_list, ll_off, &ll_cur, &ll_max)

                        ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop
                    }
                }


                if str.is_space(c) {
                    switchState = true
                    state = .SkippingWhitespace
                    continue mainLoop
                }

                ok := writer_writeRuneOnCurrentLine(&writer, c)
                if ok {
                    ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                }
                else {
                    ll_new(&writer, ll_list, ll_off, &ll_cur, &ll_spacebar, &minOffset, align) or_break outerLoop
                    writer_writeRuneOnCurrentLine(&writer, c)
                    ll_add(1, writer, ll_list, ll_off, &ll_cur, &ll_max)
                }
            }
            }
        }

        // NOTE: if we break in the outerLoop this will be less than length (hence no defer)
        num += 1
    }

    if ll_cur != 0 { writer_newline(&writer) }

    truncated = (num < l)
    actualRect = Rect{ rect.x, rect.y, ll_max, writer.pos.y - rect.y }

    return
}



TextTokenType :: enum {
    EOF,
    Invalid,

    Word,
    Whitespace,
    ParagraphBreak,
}


TextToken :: struct {
    type : TextTokenType,
    value : string,
    n : int, // TODO: ugly but also idk about using union here
}

Tokenizer :: struct {
    text : string,

    peek : Maybe(TextToken),
}

text_isWhitespace :: proc (r : rune) -> bool {
    return r == ' ' || r == '\n' || r == '\t'
}

text_pop :: proc (t : ^Tokenizer) -> TextToken {
    if peek, ok := t.peek.?; ok {
        t.peek = {}
        return peek
    }

    if len(t.text) == 0 { return TextToken{ type = .EOF } }
    pc, _ := str_index(t.text, 0)

    if false {}
    else if text_isWhitespace(pc) {
        left := 0
        newLines := 0
        for c in t.text {
            if !text_isWhitespace(c) { break }

            if c == '\n' {
                newLines += 1
            }

            cs := utf8.rune_size(c)
            left += cs
        }

        if newLines <= 1 {
            token := TextToken{ type = .Whitespace, value = t.text[:left] }
            t.text = t.text[left:]
            return token
        }
        else {
            token := TextToken{ type = .ParagraphBreak, value = t.text[:left], n = newLines }
            t.text = t.text[left:]
            return token
        }

    }
    else {
        left := 0
        for c in t.text {
            if text_isWhitespace(c) { break }

            cs := utf8.rune_size(c)
            left += cs
        }

        token := TextToken{ type = .Word, value = t.text[:left] }
        t.text = t.text[left:]
        return token
    }

    return TextToken{ type = .Invalid }
}

text_peek :: proc (t : ^Tokenizer) -> TextToken {
    if peek, ok := t.peek.?; ok {
        return peek
    }

    p := text_pop(t)
    t.peek = p
    return p
}

// NOTE: man i fucking hate how odin handles strings, why even add it as a type if it's so fucked
str_index :: proc (s : string, i : int) -> (r : rune, ok : bool = false) {
    for c in s {
        return c, true
    }

    return
}

str_length :: proc (s : string) -> int {
    i := 0
    for _ in s {
        i += 1
    }

    return i
}

_drawTextBetterer :: proc (ctx : ^RenderingContext, text : string, rect : Rect, align : Alignment, wrap : Wrapping, rendering : bool = true) -> (actualRect : Rect, truncated : bool) {
    t := Tokenizer{
        text = text
    }

    line := str.builder_make_none()

    line_index : i16 = 0
    line_index_actual : i16 = -1

    len_actual := i16(0)
    len_max := rect.z

    truncated = true

    nextEnsureWhitespace := false
    ensureWhitespace := false

    // TODO: this won't be able to support making stuff bold/changing colors mid-line. We probably need a
    // dynamic array storing styles and indexes they're changed at, and dump line accordingly by segments
    // We could just dump tokens immediately instead of accumulating, but then we wouldn't be able to align
    // reliably. I am perplexed

    // NOTE: for some reason append(&line.buf) is faster than sbprint(&line) (without aggressive optimizations)

    for true {
        token := text_pop(&t)
        if token.type == .EOF { truncated = false }

        if line_index >= rect.w { break }



        ensureWhitespace = nextEnsureWhitespace
        nextEnsureWhitespace = false


        if token.type == .Word {
            len_current := cast(i16)len(line.buf)
            len_ws      := ensureWhitespace ? i16(1) : 0
            len_word    := cast(i16)str_length(token.value)

            if len_current + len_ws + len_word <= len_max {
                if ensureWhitespace {
                    append(&line.buf, " ")
                }

                append(&line.buf, token.value)

                len_actual = math.max(len_actual, cast(i16)len(line.buf))
                line_index_actual = line_index
            }
            else {
                if len_word <= len_max {
                    t.peek = token
                }
                else {
                    remaining := len_max - (len_current + len_ws)

                    fit, rest, _ := substring_to(token.value, cast(int)remaining)
                    t.peek = TextToken{ type = .Word, value = rest }

                    if fit != "" && ensureWhitespace {
                        append(&line.buf, " ")
                    }

                    append(&line.buf, fit)

                    len_actual = math.max(len_actual, cast(i16)len(line.buf))
                    line_index_actual = line_index
                }


                lhs := rect.x // TODO: potential for aligning
                if rendering {
                    c_goto(ctx.commandBuffer, { lhs, rect.y + line_index })
                    c_appendString(ctx.commandBuffer, str.to_string(line))
                }
                str.builder_reset(&line)

                line_index += 1
            }
        }
        else if token.type == .Whitespace {
            nextEnsureWhitespace = true
        }
        else if token.type == .ParagraphBreak {
            // It makes me think, in some sense having closures is a
            // convenient way to sugarize a state machine conveniently
            // contained in a single for loop, instead of being forced to
            // explicitly define the state and pass it to functions

            // NOTE: verbatim copypaste from .Word branch

            lhs := rect.x
            if rendering {
                c_goto(ctx.commandBuffer, { lhs, rect.y + line_index })
                c_appendString(ctx.commandBuffer, str.to_string(line))
            }
            str.builder_reset(&line)

            line_index += 1



            // We are currently on the line below last text, if we have 2 new
            // lines it should translate into a single line gap
            line_index += i16(token.n - 1)
        }
        else if token.type == .EOF {
            // NOTE: verbatim copypaste from .Word branch
            lhs := rect.x
            if rendering {
                c_goto(ctx.commandBuffer, { lhs, rect.y + line_index })
                c_appendString(ctx.commandBuffer, str.to_string(line))
            }
            str.builder_reset(&line)

            line_index += 1

            break
        }
        else {
            panic("bad")
        }
    }

    actualRect = { rect.x, rect.y, len_actual, line_index_actual + 1 }
    return
}
