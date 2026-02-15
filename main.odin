package tui

import "core:fmt"
import px "core:sys/posix"
import lx "core:sys/linux"
import os "core:os/os2"
import os_old "core:os"
import "core:math"
import "core:slice"
import "core:time"

import str "core:strings"
import utf8 "core:unicode/utf8"

import "core:log"

import "core:prof/spall"
import "base:runtime"
import "core:sync"




when ODIN_DEBUG {
    spall_ctx: spall.Context
    @(thread_local) spall_buffer: spall.Buffer

    // Automatic profiling of every procedure:

    @(instrumentation_enter)
    spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
    	spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
    }

    @(instrumentation_exit)
    spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
    	spall._buffer_end(&spall_ctx, &spall_buffer)
    }
}








// TODO: Rect -> Pos, rect is kinda bad for buffers in retrospect

// NOTE: data is sequential rows
Buffer :: struct($Item : typeid) {
    rect : Rect,
    data : []Item,
}

buffer_create :: proc (r : Rect, $ty : typeid) -> (buffer : Buffer(ty), ok : bool = false) {
    size := r.z * r.w
    buffer = Buffer(ty){ rect = r, data = make([]ty, size) }
    ok = true
    return
}

buffer_get :: proc (buffer : Buffer($ty), pos : Pos, relative : bool = true) -> (cell : ty, ok : bool = false) {
    rpos := (!relative) ? (pos - buffer.rect.xy) : pos
    if rpos.x < 0 || rpos.y < 0 { return }
    if rpos.x >= buffer.rect.z || rpos.y >= buffer.rect.w { return }

    index := rpos.y * buffer.rect.z + rpos.x
    if index < 0 || cast(int)index >= len(buffer.data) { return }
    return buffer.data[index], true
}

buffer_set :: proc (buffer : Buffer($ty), pos : Pos, value : ty, relative : bool = true) -> (ok : bool = false) {
    rpos := (!relative) ? (pos - buffer.rect.xy) : pos
    if rpos.x < 0 || rpos.y < 0 { return }
    if rpos.x >= buffer.rect.z || rpos.y >= buffer.rect.w { return }
    index := rpos.y * buffer.rect.z + rpos.x
    if index < 0 || cast(int)index >= len(buffer.data) { return }
    buffer.data[index] = value
    ok = true
    return
}

buffer_reset :: proc (buffer : Buffer($ty), value : ty) {
    for i in 0..<(buffer.rect.z * buffer.rect.w) {
        buffer.data[i] = value
    }
}

buffer_copyToBuffer :: proc (dst : Buffer($ty), src : Buffer(ty), offset : Pos = { 0, 0 }) {
    for x in 0..<src.rect.z {
        for y in 0..<src.rect.w {
            buffer_set(dst, { x, y } + src.rect.xy + offset, buffer_get(src, { x, y }) or_continue)
        }
    }
}

drawBox :: proc (buffer : Buffer(BoxType), rect : Rect, type : BoxType) {
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
drawBlock :: proc (buffer : Buffer(BoxType), rect : Rect, type : BoxType) {
    br := br_from_rect(rect)

    for x in rect.x..<br.x {
        for y in rect.y..<br.y {
            buffer_set(buffer, Pos{ x, y }, type)
        }
    }
}

resolveBoxBuffer :: proc (buffer : Buffer(BoxType), out : Buffer(rune)) {
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

drawTextBetter :: proc (ctx : ^RenderingContext, text : string, rect : Rect, align : Alignment, wrap : Wrapping, rendering : bool = true, ll_list : []i16 = nil) -> (actualRect : Rect, truncated : bool) {
    ll_list := ll_list

    if rendering {
        ll_list = make([]i16, rect.w)
        drawTextBetter(ctx, text, rect, align, wrap, false, ll_list)
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





divideBetween :: proc (value : u64, coefficients : []u64, values : []u64, gap : u64 = 0, maxValues : []u64 = nil) {
    gaps := (cast(u64)len(coefficients) - 1) * gap
    if gaps >= value { return }

    value := value - gaps

    one : f64 = 0
    for c in coefficients { one += f64(c) }
    if one == 0 { return }

    total : u64 = 0
    for c, i in coefficients {
        v  := u64(f64(value) * (f64(c) / one))
        mv := maxValues != nil ? maxValues[i] : v
        v = math.min(v, mv)

        values[i] = v
        total += v
    }

    if total >= value { return }

    // TODO: I'm not sure if this is adequate, we need to prioritize larger coefficients and probably do it without a loop
    rest := value - total
    prest := rest + 1
    for rest > 0 && prest != rest {
        prest = rest

        for c, i in coefficients {
            if rest == 0 { break }
            if c == 0 { continue }
            if maxValues != nil && values[i] >= maxValues[i] { continue }

            values[i] += 1
            rest -= 1
        }
    }
}





// TODO: THIS IS INCORRECT, JUST TEMPORARY
buyIncrement :: proc (base : Pos, old : Pos, max : Pos, widthByHeightPriceRatio : f64) -> (new : Pos) {
    new = old
    if base + old == max { return }

    heightByHeightPriceRatio : f64 = 1

    costH := cast(f64)old.y * heightByHeightPriceRatio
    costW := cast(f64)old.x * widthByHeightPriceRatio

    ncostH := cast(f64)(old.y + 1) * heightByHeightPriceRatio
    ncostW := cast(f64)(old.x + 1) * widthByHeightPriceRatio

    if base.y + old.y + 1 > max.y { ncostH = 99999999999 }
    if base.x + old.x + 1 > max.x { ncostW = 99999999999 }

    if (ncostH + costW) < (costH + ncostW) {
        new.y += 1
    }
    else {
        new.x += 1
    }

    return
}




RenderingContext :: struct {
    bufferBoxes : Buffer(BoxType),
    screenRect : Rect,
    commandBuffer : ^CommandBuffer,
}

run :: proc () -> bool {
    // when ODIN_DEBUG
    logFile, _ := os_old.open("./log.txt", os_old.O_CREATE | os_old.O_TRUNC | os_old.O_RDWR)
    context.logger = log.create_file_logger(logFile, .Debug, { .Level, .Short_File_Path, .Line })

    p20table_magic := Element_Label_default
    p20table_magic.text = "Magic:"

    p20table_type := Element_Label_default
    p20table_type.text = "Type:"

    p20table_magicValue := Element_Label_default
    p20table_magicValue.text = "7f 45 4c 46"

    p20table_typeValue := Element_Label_default
    p20table_typeValue.text = "Shared Object"

    p20table := Element_Table_default
    p20table.children = { &p20table_magic, &p20table_type, &p20table_magicValue, &p20table_typeValue }
    p20table.stretch = { true, false }
    p20table.configuration = Buffer(int){ rect = { 0, 0, 2, 2 }, data = { 0, 2, 1, 3 } }
    p20table.stretchingCols = { Stretching{ priority = 0, fill = .MinimalNecessary }, Stretching{ priority = 5, fill = .Expand } }
    p20table.stretchingRows = { Stretching{ priority = 0, fill = .MinimalPossible }, Stretching{ priority = 0, fill = .MinimalPossible } }

    p20linear := Element_Linear_default
    p20linear.children = { &p20table_magic, &p20table_type, &p20table_magicValue, &p20table_typeValue }
    p20linear.stretch = { false, true }
    p20linear.isHorizontal = false
    p20linear.stretching = {
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
    }

    p20text00 := Element_Label_default
    p20text00.text = "[1:1] In the beginning when God created the heavens and the earth,"

    p20text01 := Element_Label_default
    p20text01.text = "[1:2] the earth was a formless void and darkness covered the face of the deep, while a wind from God swept over the face of the waters."

    p20text02 := Element_Label_default
    p20text02.text = "[1:3] Then God said, \"Let there be light\"; and there was light."

    p20text03 := Element_Label_default
    p20text03.text = "[1:4] And God saw that the light was good; and God separated the light from the darkness."

    p20text04 := Element_Label_default
    p20text04.text = "[1:5] God called the light Day, and the darkness he called Night. And there was evening and there was morning, the first day."

    p20text05 := Element_Label_default
    p20text05.text = "[1:6] And God said, \"Let there be a dome in the midst of the waters, and let it separate the waters from the waters.\""

    p20text06 := Element_Label_default
    p20text06.text = "[1:7] So God made the dome and separated the waters that were under the dome from the waters that were above the dome. And it was so."

    p20text07 := Element_Label_default
    p20text07.text = "[1:8] God called the dome Sky. And there was evening and there was morning, the second day."

    p20text08 := Element_Label_default
    p20text08.text = "[1:9] And God said, \"Let the waters under the sky be gathered together into one place, and let the dry land appear.\" And it was so."

    p20text09 := Element_Label_default
    p20text09.text = "[1:10] God called the dry land Earth, and the waters that were gathered together he called Seas. And God saw that it was good."

    p20text10 := Element_Label_default
    p20text10.text = "[1:11] Then God said, \"Let the earth put forth vegetation: plants yielding seed, and fruit trees of every kind on earth that bear fruit with the seed in it.\" And it was so."

    p20text11 := Element_Label_default
    p20text11.text = "[1:12] The earth brought forth vegetation: plants yielding seed of every kind, and trees of every kind bearing fruit with the seed in it. And God saw that it was good."

    p20text12 := Element_Label_default
    p20text12.text = "[1:13] And there was evening and there was morning, the third day."

    p20text13 := Element_Label_default
    p20text13.text = "[1:14] And God said, \"Let there be lights in the dome of the sky to separate the day from the night; and let them be for signs and for seasons and for days and years,"

    p20text14 := Element_Label_default
    p20text14.text = "[1:15] and let them be lights in the dome of the sky to give light upon the earth.\" And it was so."

    p20text15 := Element_Label_default
    p20text15.text = "[1:16] God made the two great lights - the greater light to rule the day and the lesser light to rule the night - and the stars."

    p20text16 := Element_Label_default
    p20text16.text = "[1:17] God set them in the dome of the sky to give light upon the earth,"

    p20text17 := Element_Label_default
    p20text17.text = "[1:18] to rule over the day and over the night, and to separate the light from the darkness. And God saw that it was good."

    p20text18 := Element_Label_default
    p20text18.text = "[1:19] And there was evening and there was morning, the fourth day."

    p20text19 := Element_Label_default
    p20text19.text = "[1:20] And God said, \"Let the waters bring forth swarms of living creatures, and let birds fly above the earth across the dome of the sky.\""

    p20text20 := Element_Label_default
    p20text20.text = "[1:21] So God created the great sea monsters and every living creature that moves, of every kind, with which the waters swarm, and every winged bird of every kind. And God saw that it was good."

    p20text21 := Element_Label_default
    p20text21.text = "[1:22] God blessed them, saying, \"Be fruitful and multiply and fill the waters in the seas, and let birds multiply on the earth.\""

    p20text22 := Element_Label_default
    p20text22.text = "[1:23] And there was evening and there was morning, the fifth day."

    p20text23 := Element_Label_default
    p20text23.text = "[1:24] And God said, \"Let the earth bring forth living creatures of every kind: cattle and creeping things and wild animals of the earth of every kind.\" And it was so."

    p20text24 := Element_Label_default
    p20text24.text = "[1:25] God made the wild animals of the earth of every kind, and the cattle of every kind, and everything that creeps upon the ground of every kind. And God saw that it was good."

    p20text25 := Element_Label_default
    p20text25.text = "[1:26] Then God said, \"Let us make humankind in our image, according to our likeness; and let them have dominion over the fish of the sea, and over the birds of the air, and over the cattle, and over all the wild animals of the earth, and over every creeping thing that creeps upon the earth.\""

    p20text26 := Element_Label_default
    p20text26.text = "[1:27] So God created humankind in his image, in the image of God he created them; male and female he created them."

    p20text27 := Element_Label_default
    p20text27.text = "[1:28] God blessed them, and God said to them, \"Be fruitful and multiply, and fill the earth and subdue it; and have dominion over the fish of the sea and over the birds of the air and over every living thing that moves upon the earth.\""

    p20text28 := Element_Label_default
    p20text28.text = "[1:29] God said, \"See, I have given you every plant yielding seed that is upon the face of all the earth, and every tree with seed in its fruit; you shall have them for food."

    p20text29 := Element_Label_default
    p20text29.text = "[1:30] And to every beast of the earth, and to every bird of the air, and to everything that creeps on the earth, everything that has the breath of life, I have given every green plant for food.\" And it was so."

    p20text30 := Element_Label_default
    p20text30.text = "[1:31] God saw everything that he had made, and indeed, it was very good. And there was evening and there was morning, the sixth day. "

    p20lineart := Element_Linear_default
    p20lineart.children = {
        &p20text00, &p20text01, &p20text02, &p20text03, &p20text04,
        &p20text05, &p20text06, &p20text07, &p20text08, &p20text09,
        &p20text10, &p20text11, &p20text12, &p20text13, &p20text14,
        &p20text15, &p20text16, &p20text17, &p20text18, &p20text19,
        &p20text20, &p20text21, &p20text22, &p20text23, &p20text24,
        &p20text25, &p20text26, &p20text27, &p20text28, &p20text29,
        &p20text30,
    }
    p20lineart.stretch = { false, false }
    p20lineart.isHorizontal = false
    // TODO: okay this is dumb this has to be made more convenient (for tables as well i guess)
    p20lineart.stretching = {
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
        Stretching{ priority = 1, fill = .MinimalNecessary },
    }

    p20scroll := Element_Scroll_default
    p20scroll.children = { &p20lineart }
    p20scroll.scroll = { false, true }
    p20scroll.scrollbar = { false, true }
    p20scroll.targetFocus = true
    
    p20 := Element{
        kind = "P20",

        children = { &p20scroll },

        render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
            rectTitle, rectLine, rest := rect_splitHorizontalLineGap(rect, 1, 1)

            label := Element_Label_default
            label.text = "ELF Header"
            element_render(&label, ctx, rectTitle)

            drawBlock(ctx.bufferBoxes, rectLine, .SingleCurve)

            element_render(self.children[0], ctx, rest)
        },

        input = input_default,
        inputFocus = inputFocus_default,
        focus = proc (self : ^Element) {
            element_unfocus(self)
            element_focus(self.children[0])
        },
        navigate = navigate_default,
    }

    p30 := Element{
        kind = "P30",

        render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
            label := Element_Label_default
            label.text = "Program header"
            element_render(&label, ctx, { rect.x, rect.y, rect.z, 1 })

            drawBlock(ctx.bufferBoxes, { rect.x, rect.y + 1, rect.z, 1 }, .SingleCurve)
        },

        input = input_default,
        inputFocus = inputFocus_default,
        focus = proc (self : ^Element) {
            element_unfocus(self)
            element_focus(self.children[0])
        },
        navigate = navigate_default,
    }

    p50 := Element{
        kind = "P50",

        render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
            label := Element_Label_default
            label.text = "Segment content"
            element_render(&label, ctx, { rect.x, rect.y, rect.z, 1 })

            drawBlock(ctx.bufferBoxes, { rect.x, rect.y + 1, rect.z, 1 }, .SingleCurve)
        },

        input = input_default,
        inputFocus = inputFocus_default,
        focus = proc (self : ^Element) {
            element_unfocus(self)
            element_focus(self.children[0])
        },
        navigate = navigate_default,
    }

    root := Element{
        kind = "Root",

        children = { &p20, &p30, &p50 },
        render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
            drawBox(ctx.bufferBoxes, ctx.screenRect, .SingleCurve)
            content := rect_inner(ctx.screenRect)

            width := content.z

            c : []u64 = { 2, 3, 5 }
            r : [3]u64
            divideBetween(cast(u64)width, c, r[:], 1)

            rectA, lineAB, rectBC := rect_splitVerticalLineGap(content, cast(i16)r[0], 1)
            rectB, lineBC, rectC := rect_splitVerticalLineGap(rectBC, cast(i16)r[1], 1)

            drawBlock(ctx.bufferBoxes, lineAB, .SingleCurve)
            drawBlock(ctx.bufferBoxes, lineBC, .SingleCurve)

            element_render(self.children[0], ctx, rectA)
            element_render(self.children[1], ctx, rectB)
            element_render(self.children[2], ctx, rectC)
        },

        input = input_default,
        inputFocus = inputFocus_default,
        focus = proc (self : ^Element) {
            element_unfocus(self)
            element_focus(self.children[0])
        },
        navigate = navigate_default,
    }



    term : px.termios
    _ = px.tcgetattr(px.STDIN_FILENO, &term)
    termRestore := term
    defer px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &termRestore)

    term.c_lflag -= { .ECHO, .ICANON }
    px.tcsetattr(px.STDIN_FILENO, .TCSANOW, &term)



    os.write_string(os.stdout, "\e[?25l")
    os.write_string(os.stdout, "\e[?1049h")

    defer {
        os.write_string(os.stdout, "\e[?25h")
        os.write_string(os.stdout, "\e[?1049l")
    }



    screen := buffer_create(getScreenRect() or_return, rune) or_return
    box := buffer_create(getScreenRect() or_return, BoxType) or_return
    cb : CommandBuffer = CommandBuffer_Stdout{
        builder = str.builder_make_none(),
        style = FontStyle_default,
    }


    root->focus()

    sw : time.Stopwatch

    for _ in 0..<1000 {
        buffer : [32]u8
        n, err := os.read_at_least(os.stdin, buffer[:], 1)


        time.stopwatch_reset(&sw)
        time.stopwatch_start(&sw)

        element_input(&root, utf8.rune_at_pos(transmute(string)buffer[:], 0))




        buffer_reset(box, BoxType.None)
        buffer_reset(screen, '\x00')
        c_reset(&cb)



        c_styleClear(&cb)
        c_clear(&cb)

        ctx := RenderingContext{
            bufferBoxes = box,
            screenRect = getScreenRect() or_break,
            commandBuffer = &cb,
        }

        element_assignParentRecurse(&root)
        element_render(&root, &ctx, ctx.screenRect)

        resolveBoxBuffer(box, screen)
        cc_bufferPresent(&cb, screen)

        os.write_string(os.stdout, str.to_string(cb.(CommandBuffer_Stdout).builder))


        time.stopwatch_stop(&sw)
        log.debugf("DRAW TIME: %v", time.stopwatch_duration(sw))
    }


    return true
}

main :: proc () {
    when ODIN_DEBUG {
        spall_ctx = spall.context_create("trace_test.spall")
        defer spall.context_destroy(&spall_ctx)

        buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
        defer delete(buffer_backing)

        spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
        defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

        spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    }





    run()
}
