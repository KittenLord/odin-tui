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


Nav :: enum {
    N, E, S, W,
}

Pos_from_Nav :: proc (n : Nav) -> Pos {
    switch n {
    case .N: return { 0, -1 }
    case .E: return { 1, 0 }
    case .S: return { 0, 1 }
    case .W: return { -1, 0 }
    }

    panic("bad")
}

is_hjkl :: proc (r : rune) -> bool {
    return r == 'h' || r == 'j' || r == 'k' || r == 'l'
}

Nav_from_hjkl :: proc (r : rune) -> Nav {
    switch r {
    case 'h': return .W
    case 'j': return .S
    case 'k': return .N
    case 'l': return .E
    }

    panic("bad")
}

Pos_from_hjkl :: proc (r : rune) -> Pos {
    return Pos_from_Nav(Nav_from_hjkl(r))
}

Element :: struct {
    kind : string,

    children : []^Element,

    parent : ^Element,
    focused : bool,
    lastRenderedRect : Rect,

    render     : proc (self : ^Element, ctx : ^RenderingContext, rect : Rect),
    negotiate  : proc (self : ^Element, constraints : Constraints) -> (size : Pos),

    input      : proc (self : ^Element, input : rune),
    inputFocus : proc (self : ^Element, input : rune),

    focus      : proc (self : ^Element),
    navigate   : proc (self : ^Element, dir : Nav),


    // TODO: this might become a struct of style-related things
    stretch : [2]bool,
}

render_default :: proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
    return
}

negotiate_default :: proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
    return constraints.preferredSize
}

input_default :: proc (self : ^Element, input : rune) {
    return
}

inputFocus_default :: proc (self : ^Element, input : rune) {
    switch input {
    case 'h':
        self->navigate(.W)
    case 'j':
        self->navigate(.S)
    case 'k':
        self->navigate(.N)
    case 'l':
        self->navigate(.E)
    case:
        break
    }
}

focus_default :: proc (self : ^Element) {
    return
}

navigate_default :: proc (self : ^Element, dir : Nav) {
    if element_isRoot(self) { return }
    self.parent->navigate(dir)
    return
}






element_render :: proc (e : ^Element, ctx : ^RenderingContext, rect : Rect) {
    oldStyle := c_styleGet(ctx.commandBuffer)

    e->render(ctx, rect)
    e.lastRenderedRect = rect

    if c_styleGet(ctx.commandBuffer) != oldStyle {
        c_style(ctx.commandBuffer, oldStyle)
    }
}

element_negotiate :: proc (e : ^Element, constraints : Constraints) -> (size : Pos) {
    r := e->negotiate(constraints)
    r = { math.min(r.x, constraints.maxSize.x), math.min(r.y, constraints.maxSize.y) }

    return r
}

element_input :: proc (e : ^Element, input : rune) {
    // NOTE: prevents multiple elements from receiving the same inputs due to the focus changing mid-traversing
    element_inputSingleFocus(e, input)
    element_inputRawOnly(e, input)
}

element_inputSingleFocus :: proc (e : ^Element, input : rune) -> bool {
    if e.focused {
        e->inputFocus(input)
        return true
    }

    for c in e.children {
        if element_inputSingleFocus(c, input) { return true }
    }

    return false
}

element_inputRawOnly :: proc (e : ^Element, input : rune) {
    if !e.focused { e->input(input) }

    for c in e.children {
        element_inputRawOnly(c, input)
    }
}

element_focus :: proc (e : ^Element) {
    e.focused = true

    e->focus()
}

element_unfocus :: proc (e : ^Element) {
    e.focused = false
}





element_findFocus :: proc (e : ^Element, excludeSelf : bool = false) -> (focus : ^Element, found : bool = false) {
    if e.focused && excludeSelf  { return }
    if e.focused { return e, true }
    for c in e.children {
        focus, found = element_findFocus(c)
        if found { break }
    }

    return
}

element_findChildWithFocus :: proc (e : ^Element, focus : ^Element = nil) -> (child : ^Element, found : bool = false) {
    focus := focus

    if focus == nil {
        focus = element_findFocus(e) or_return
    }

    if focus == e { return }

    for focus.parent != e {
        focus = focus.parent
    }

    child = focus
    return
}

// NOTE: this doesnt return an ok cuz its very inconvenient
element_retrieve :: proc ($ty : typeid, root : ^Element, path : []int, kind : string = "") -> (e : ^ty = nil) {
    root := root
    for next in path {
        if next >= len(root.children) { return }
        root = root.children[next]
    }

    if kind != "" && root.kind != kind { return }

    e = cast(^ty)root
    return
}


MAX_SIZE : Pos : { 1000, 1000 }

Constraints :: struct {
    maxSize : Pos,
    preferredSize : Pos,

    widthByHeightPriceRatio : f64,
}

Filling :: enum {
    MinimalPossible,
    MinimalNecessary,
    Expand,
}

Stretching :: struct {
    fill : Filling,
    priority : int,
}

LinearStretchingOverride :: struct {
    index : int,
    stretching : Stretching,
}

// The priority is the following:
// If stretching override is available, use it
// If not, but array element is available, use it
// If not, use stretching
LinearStretching :: struct {
    single : Stretching,
    array : []Maybe(Stretching),
    overrides : []LinearStretchingOverride,
}



Wrapping :: enum {
    Wrapping,       // word gets cut at the end of the line, gets continued immediately on the next one
    NoWrapping,     // if word doesn't fit on the current line move it to the second. If it doesn't fit there either fall back to Wrapping
    // Hyphenation,    // Wrapping, but with hyphens
}

AlignmentHorizontal :: enum {
    Left,
    Mid,
    Right,
}

AlignmentVertical :: enum {
    Top,
    Mid,
    Bot,
}

Alignment :: struct {
    horizontal : AlignmentHorizontal,
    vertical   : AlignmentVertical,
}





element_isRoot :: proc (e : ^Element) -> bool {
    return e.parent == nil || e.parent == e
}

element_root :: proc (e : ^Element) -> (root : ^Element) {
    if element_isRoot(e) { return e }
    return element_root(e.parent)
}

element_assignParentRecurse :: proc (root : ^Element) {
    for e in root.children {
        e.parent = root
        element_assignParentRecurse(e)
    }
}

element_getParentIndex :: proc (target : ^Element) -> int {
    if element_isRoot(target) { return 0 }

    // NOTE: should never return -1 if set up correctly
    i, s := slice.linear_search(target.parent.children, target)
    if !s {
        panic("element_assignParentRecurse")
    }
    return i
}

element_getParentIndexSameKind :: proc (target : ^Element) -> int {
    if element_isRoot(target) { return 0 }

    i := 0
    for e in target.parent.children {
        if e == target { return i }
        if e.kind == target.kind { i += 1 }
    }

    panic("element_assignParentRecurse")
}

element_getFullKindName :: proc (target : ^Element) -> string {
    b, _ := str.builder_make_none()
    l : [dynamic]^Element

    target := target
    append(&l, target)
    for target.parent != nil && target.parent != target {
        target = target.parent
        append(&l, target)
    }

    slice.reverse(l[:])

    for e, i in l {
        if i != 0 {
            fmt.sbprint(&b, " / ")
        }

        fmt.sbprintf(&b, "%v #%v", e.kind, element_getParentIndexSameKind(e))
    }

    return str.to_string(b)
}

Element_Table :: struct {
    using base : Element,

    configuration : Buffer(int),

    // NOTE: gap.x - between columns, gap.y - between rows
    gap : [2]Maybe(BoxType),

    stretchingCols : LinearStretching,
    stretchingRows : LinearStretching,
}

Element_Label :: struct {
    using base : Element,

    text : string,
}

Element_Linear_Orientation :: enum {
    Vertical,
    Horizontal,
}

// TODO: we probably need to remember the last child that was focused and return to it instead of the first one
Element_Linear :: struct {
    using base : Element,

    isHorizontal : bool,
    gap : Maybe(BoxType),
    stretching : LinearStretching,
}

Element_Scroll :: struct {
    using base : Element,

    scroll : [2]bool,

    // TODO: scrollbars on both sides? idk
    // TODO: should this just be a single boolean, or is the configurability here a good thing?
    scrollbar : [2]bool,

    // NOTE:
    // true  -> searches for the focused element, tries to fit it within the rendered rect
    // false -> just changes the offset
    targetFocus : bool,




    // NOTE: RUNTIME THINGS
    offset : Pos,
    remaining : Pos,
}

Element_Box :: struct {
    using base : Element,

    margin : Rect,
    padding : Rect,

    border : BoxType,
}


Element_default :: Element{
    kind = "Element",

    render = render_default,
    negotiate = negotiate_default,
    input = input_default,
    inputFocus = inputFocus_default,
    focus = focus_default,
    navigate = navigate_default,
}

Element_Box_default :: Element_Box{
    kind = "Box",

    render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
        self := cast(^Element_Box)self

        rect_m := rect_fix(rect + { self.margin.w, self.margin.x, -(self.margin.y + self.margin.w), -(self.margin.z + self.margin.x) })

        if self.border != .None {
            drawBox(ctx.bufferBoxes, rect_m, self.border)
            rect_m = rect_fix(rect + { 1, 1, -2, -2 })
        }

        rect_p := rect_fix(rect_m + { self.padding.w, self.padding.x, -(self.padding.y + self.padding.w), -(self.padding.z + self.padding.x) })

        if len(self.children) > 0 {
            element_render(self.children[0], ctx, rect_p)
        }
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        self := cast(^Element_Box)self

        border : i16 = self.border != .None ? 1 : 0
        delta := Pos{
            self.margin.w + self.margin.y + self.padding.w + self.padding.y + border,
            self.margin.x + self.margin.z + self.padding.x + self.padding.z + border,
        }

        if len(self.children) > 0 {
            return element_negotiate(self.children[0], Constraints{ maxSize = pos_fix(constraints.maxSize - delta), preferredSize = pos_fix(constraints.preferredSize - delta), widthByHeightPriceRatio = 1 }) + delta
        }
        else {
            return constraints.preferredSize
        }
    },

    input = input_default,
    inputFocus = inputFocus_default,

    focus = proc (self : ^Element) {
        if len(self.children) > 0 {
            element_unfocus(self)
            element_focus(self.children[0])
        }
    },

    navigate = navigate_default,
}

Element_Label_default :: Element_Label{
    kind = "Label",

    render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
        self := cast(^Element_Label)self

        if self.focused {
            c_style(ctx.commandBuffer, FontStyle{ fg = FontColor_Standard.Black, bg = FontColor_Standard.White })
            cc_fill(ctx.commandBuffer, rect)
        }

        drawTextBetter(ctx, self.text, rect, { .Left, .Top }, .NoWrapping)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        // TODO: this is still kinda scuffed and doesnt take the price into account (and furthermore is heavily biased into larger height, which is good actually, but not always)
        
        self := cast(^Element_Label)self

        if rect, truncated := drawTextBetter(nil, self.text, { 0, 0, constraints.preferredSize.x, constraints.maxSize.y }, { .Left, .Top }, .NoWrapping, rendering = false); !truncated {
            return rect.zw
        }

        rect, truncated := drawTextBetter(nil, self.text, { 0, 0, constraints.maxSize.x, constraints.maxSize.y }, { .Left, .Top }, .NoWrapping, rendering = false)
        if truncated { return constraints.maxSize }

        wlo : i16 = 0
        whi : i16 = rect.z
        wcc : i16 = 0
        wtmp : i16 = 0
        ry : i16 = 0

        found := false

        iteration := 0
        for wlo < whi || !found {
            iteration += 1

            wtmp = (wlo + whi) / 2
            wrect := Rect{ 0, 0, wtmp, constraints.maxSize.y }
            rect, truncated := drawTextBetter(nil, self.text, wrect, { .Left, .Top }, .NoWrapping, rendering = false)

            // NOTE: we try to find the smallest width possible, so if it is NOT truncated, we try to find smaller

            if truncated {
                // If truncated, we need to search larger
                wlo = wtmp + 1
            }
            else {
                found = true
                // If NOT truncated, search lower

                if wtmp <= constraints.preferredSize.x {
                    wtmp = constraints.preferredSize.x
                    wrect := Rect{ 0, 0, wtmp, constraints.maxSize.y }
                    rect, _ := drawTextBetter(nil, self.text, wrect, { .Left, .Top }, .NoWrapping, rendering = false)

                    whi = wtmp
                    wcc = wtmp
                    ry = rect.w

                    break
                }

                whi = wtmp
                wcc = wtmp
                ry = rect.w
            }
        }

        return { wcc, ry }
    },

    input = input_default,
    inputFocus = inputFocus_default,
    focus = focus_default,
    navigate = navigate_default,
}

Element_Linear_default :: Element_Linear{
    kind = "Linear",

    render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
        Element_Linear_internalRender(self, ctx, rect, rect.zw, true)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        return Element_Linear_internalRender(self, nil, Rect{ 0, 0, constraints.maxSize.x, constraints.maxSize.y }, constraints.preferredSize, false)
    },

    input = input_default,
    inputFocus = inputFocus_default,

    focus = proc (self : ^Element) {
        self := cast(^Element_Linear)self

        element_unfocus(self)
        element_focus(self.children[0])
    },

    navigate = proc (self : ^Element, dir : Nav) {
        self := cast(^Element_Linear)self

        focus, found := element_findFocus(self)
        if !found || focus == self { return }
        pfocus := focus

        focus, _ = element_findChildWithFocus(self, focus)

        i, f := slice.linear_search(self.children, focus)

        m := Pos{ i16(self.isHorizontal), i16(!self.isHorizontal) }
        ss := (m * Pos_from_Nav(dir))
        s := ss.x + ss.y

        if s == 0 {
            navigate_default(self, dir)
            return
        }

        // TODO: optional wrapping?
        if i == 0 && s < 0 {
            navigate_default(self, dir)
            return
        }
        if i == len(self.children) - 1 && s > 0 {
            navigate_default(self, dir)
            return
        }

        element_unfocus(pfocus)
        element_focus(self.children[i + int(s)])
    },
}

Element_Scroll_default :: Element_Scroll{
    kind = "Scroll",

    render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
        self := cast(^Element_Scroll)self

        oldRect := rect
        rect := rect

        if self.scrollbar.x { rect.w -= 1 }
        if self.scrollbar.y { rect.z -= 1 }

        maxSize := Pos{ self.scroll.x ? max(i16) : rect.z, self.scroll.y ? max(i16) : rect.w }

        c := self.children[0]
        size := element_negotiate(c, Constraints{ maxSize = maxSize, preferredSize = rect.zw, widthByHeightPriceRatio = 1 })
        // if size.x < rect.z { size.x = rect.z }
        // if size.y < rect.w { size.y = rect.w }

        srect := Rect{ 0, 0, size.x, size.y }

        self.remaining = (srect.zw - self.offset) - rect.zw

        // NOTE: thank GOD we don't have or_do!!!!!
        for _ in 0..<1 {
            // TODO: free resources lol
            buffer := buffer_create(srect, CellData) or_break
            screen := buffer_create(srect, rune) or_break
            box := buffer_create(srect, BoxType) or_break

            cb : CommandBuffer = CommandBuffer_Buffer{
                buffer = buffer,

                pos = { 0, 0 },
                style = FontStyle_default,
            }

            sctx := RenderingContext{
                bufferBoxes = box,
                screenRect = srect,
                commandBuffer = &cb,
            }


            element_render(c, &sctx, sctx.screenRect)

            resolveBoxBuffer(box, screen)
            cc_bufferPresent(&cb, screen)



            // TODO: tf do we do if element is bigger than rect? I guess we have to reemploy the !targetFocus scrolling in that situation
            if focus, ok := element_findFocus(self, excludeSelf = true); self.targetFocus && ok {
                fcrect := focus.lastRenderedRect
                srect := Rect{ self.offset.x, self.offset.y, rect.z, rect.w }

                if !is_rect_within_rect(fcrect, srect) {
                    if fcrect.x < srect.x { srect.x = fcrect.x }
                    if fcrect.y < srect.y { srect.y = fcrect.y }

                    if fcrect.x + fcrect.z > srect.x + srect.z { srect.x += (fcrect.x + fcrect.z) - (srect.x + srect.z) }
                    if fcrect.y + fcrect.w > srect.y + srect.w { srect.y += (fcrect.y + fcrect.w) - (srect.y + srect.w) }
                }

                self.offset = srect.xy
            }




            oldStyle := c_styleGet(ctx.commandBuffer)
            cc_bufferPresentCool(ctx.commandBuffer, cb.(CommandBuffer_Buffer).buffer, rect.xy, { self.offset.x, self.offset.y, rect.z, rect.w })
            c_style(ctx.commandBuffer, oldStyle)


            calculateScrollbar :: proc (visible : i16, total : i16, scroll : i16, offset : i16) -> (start_size : Pos) {
                v := cast(f64)visible
                t := cast(f64)total
                s := cast(f64)scroll
                o := cast(f64)offset

                start_size.x = cast(i16)math.round((o / t) * s)
                start_size.y = cast(i16)math.round((v / t) * s)

                if offset == 0 { start_size.x = 0 }
                if offset > 0 && start_size.x == 0 && start_size.y < scroll { start_size.x += 1 }
                if offset + visible >= total && start_size.x + start_size.y < scroll { start_size.x += 1 }
                if offset + visible < total && start_size.x + start_size.y == scroll && start_size.x > 0 { start_size.x -= 1 }

                return
            }

            if self.scrollbar.y {
                start_size := calculateScrollbar(rect.w, srect.w, oldRect.w - 2, self.offset.y)

                screct := Rect{ oldRect.x + oldRect.z - 1, oldRect.y + 1 + start_size.x, 1, start_size.y }
                cc_fill(ctx.commandBuffer, screct, '𜸩')

                c_goto(ctx.commandBuffer, { oldRect.x + oldRect.z - 1, oldRect.y })
                c_appendRune(ctx.commandBuffer, '█')

                c_goto(ctx.commandBuffer, { oldRect.x + oldRect.z - 1, oldRect.y + oldRect.w - 1 })
                c_appendRune(ctx.commandBuffer, '█')
            }


        }
    },

    // TODO: we probably want as much space as possible on the non-scrollable axis (if any)
    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        return constraints.preferredSize
    },

    input = input_default,
    inputFocus = proc (self : ^Element, input : rune) {
        self := cast(^Element_Scroll)self
        if self.targetFocus { return } // NOTE: should never happen

        if !is_hjkl(input) { return }

        dir := Nav_from_hjkl(input)
        step := Pos_from_Nav(dir)

        if !self.scroll.x && step.x != 0 {
            self->navigate(dir)
            return
        }

        if !self.scroll.y && step.y != 0 {
            self->navigate(dir)
            return
        }

        if step.x >= 1 && self.remaining.x <= 0 {
            self->navigate(dir)
            return
        }

        if step.y >= 1 && self.remaining.y <= 0 {
            self->navigate(dir)
            return
        }

        newOffset := self.offset + step

        if newOffset.x < 0 || newOffset.y < 0 {
            self->navigate(dir)
            return
        }

        self.offset = newOffset
    },

    focus = proc (self : ^Element) {
        self := cast(^Element_Scroll)self

        if self.targetFocus {
            element_unfocus(self)
            element_focus(self.children[0])
        }
        else {
            return
        }
    },

    navigate = navigate_default,
}

linearStretching_get :: proc (l : LinearStretching, i : int) -> (s : Stretching) {
    s = l.single

    if l.array != nil && i < len(l.array) {
        s = l.array[i].? or_else s
    }

    if l.overrides != nil {
        for o in l.overrides {
            if o.index == i {
                s = o.stretching
            }
        }
    }

    return
}


Element_Linear_internalRender :: proc (self : ^Element, ctx : ^RenderingContext, rect : Rect, preferred : Pos, rendering : bool) -> (size : Pos) {
    self := cast(^Element_Linear)self

    sizes := make([]i16, len(self.children))
    defer delete(sizes)

    caps := make([]u64, len(self.children))
    defer delete(caps)

    deltas := make([]i64, len(self.children))
    defer delete(deltas)

    priorities := make([]u64, len(self.children))
    defer delete(priorities)

    stretchings := make([]Stretching, len(self.children))
    defer delete(stretchings)

    sl: for _, i in self.children {
        s := linearStretching_get(self.stretching, i)

        stretchings[i] = s
        priorities[i] = calculatePriority(s)
    }

    // NOTE: vertical is default, therefore
    // x => single
    // y => linear

    h := self.isHorizontal
    mflip :: proc (p : Pos, h : bool) -> Pos {
        if !h { return p.xy }
        else  { return p.yx }
    }

    singleMax : i16 = 0
    singlePreferred := mflip(preferred, h).x

    rect := rect
    oldRect := rect

    border, useGap := self.gap.?
    lg := i16(len(self.children) - 1)
    g := mflip({ 0, useGap ? lg : 0 }, h)
    rect -= { 0, 0, g.x, g.y }

    singleLimit := mflip(rect.zw, h).x
    linearLimit := mflip(rect.zw, h).y
    linearLimits := make([]i16, len(self.children))
    defer delete(linearLimits)

    for &l in linearLimits {
        l = linearLimit
    }

    linearTotal : i16 = 0


    lastIteration :: 1
    for iteration in 0 ..= lastIteration {
        linearTotal = 0
        singleMax = 0

        for c, i in self.children {
            maxSize := Pos{ singleLimit, linearLimits[i] }

            preferredSize := Pos{ singlePreferred, math.min(linearLimits[i], linearLimit / cast(i16)len(self.children)) }
            if stretchings[i].fill == .MinimalPossible { preferredSize.y = 1 }

            wbhRatio : f64 = 1

            size := element_negotiate(c, Constraints{ maxSize = mflip(maxSize, h), preferredSize = mflip(preferredSize, h), widthByHeightPriceRatio = wbhRatio })

            size = mflip(size, h)

            singleMax = math.max(singleMax, size.x)
            linearTotal += size.y
            sizes[i] = size.y
        }

        delta := mflip(rect.zw, h).y - linearTotal

        // NOTE: unintentionally this made stretching not work within a scroll, which is good
        if iteration == lastIteration && delta > 0 && (!rendering || (!self.stretch.y && !self.stretch.x)) { delta = 0 }

        limit := delta < 0 ? caps : nil

        for &c, i in caps { c = cast(u64)math.abs(sizes[i]) }

        divideBetween(cast(u64)math.abs(delta), priorities, transmute([]u64)deltas, maxValues = limit)

        for d, i in deltas {
            linearLimits[i] = sizes[i] + (sign_i16(delta) * cast(i16)d)
        }
    }

    linearTotal = math.sum(linearLimits)

    if !rendering {
        size = mflip(Pos{ singleMax, linearTotal + lg }, h)
        return
    }

    offset := rect.xy
    for c, i in self.children {
        size := Pos{ singleLimit, linearLimits[i] }
        size = mflip(size, h)

        element_render(c, ctx, { offset.x, offset.y, size.x, size.y })

        offset += mflip(Pos{ 0, linearLimits[i] }, h)

        if useGap && i != len(self.children) - 1 {
            gsize := mflip(Pos{ singleLimit, 1 }, h)
            drawBlock(ctx.bufferBoxes, { offset.x, offset.y, gsize.x, gsize.y }, border)

            offset += mflip(Pos{ 0, 1 }, h)
        }
    }

    return
}


Element_Table_default :: Element_Table{
    kind = "Table",

    render = proc (self : ^Element, ctx : ^RenderingContext, rect : Rect) {
        Element_Table_internalRender(self, rect, ctx, true)
    },

    negotiate = proc (self : ^Element, constraints : Constraints) -> (size : Pos) {
        return Element_Table_internalRender(self, Rect{ 0, 0, constraints.maxSize.x, constraints.maxSize.y }, nil, false)
    },

    input = input_default,
    inputFocus = inputFocus_default,
    focus = proc (self : ^Element) {
        self := cast(^Element_Table)self

        n, _ := buffer_get(self.configuration, { 0, 0 })
        e := self.children[n]

        element_unfocus(self)
        element_focus(e)
    },
    navigate = proc (self : ^Element, dir : Nav) {
        self := cast(^Element_Table)self

        focus, found := element_findFocus(self)
        if !found || focus == self { return }
        pfocus := focus

        focus, _ = element_findChildWithFocus(self, focus)

        for x in 0..<self.configuration.rect.z {
            for y in 0..<self.configuration.rect.w {
                n := buffer_get(self.configuration, { x, y }) or_continue
                e := self.children[n]
                if e != focus { continue }

                if e == focus {
                    pos := Pos{ x, y } + Pos_from_Nav(dir)
                    n := buffer_get(self.configuration, pos) or_continue
                    e := self.children[n]

                    element_unfocus(pfocus)
                    element_focus(e)

                    return
                }
            }
        }

        navigate_default(self, dir)
    },
}

calculatePriority :: proc (s : Stretching, subtract : bool = false) -> u64 {
    m : u64 = math.max(cast(u64)s.priority, 1)
    switch s.fill {
    case .MinimalPossible:
        m = 1
    case .MinimalNecessary:
        m *= 10
    case .Expand:
        m *= 50
    }

    return m
}

Element_Table_internalRender :: proc (self : ^Element, rect : Rect, ctx : ^RenderingContext, render : bool) -> (size : Pos) {
    self := cast(^Element_Table)self

    maxCols := make([]i16, self.configuration.rect.z)
    maxRows := make([]i16, self.configuration.rect.w)
    limCols := make([]i16, self.configuration.rect.z)
    limRows := make([]i16, self.configuration.rect.w)
    defer delete(maxCols)
    defer delete(maxRows)
    defer delete(limCols)
    defer delete(limRows)

    capCols := make([]u64, self.configuration.rect.z)
    capRows := make([]u64, self.configuration.rect.w)
    defer delete(capCols)
    defer delete(capRows)


    deltaCols := make([]i64, self.configuration.rect.z)
    deltaRows := make([]i64, self.configuration.rect.w)
    defer delete(deltaCols)
    defer delete(deltaRows)



    priorityCols := make([]u64, self.configuration.rect.z)
    priorityRows := make([]u64, self.configuration.rect.w)
    defer delete(priorityCols)
    defer delete(priorityRows)


    stretchingCols := make([]Stretching, self.configuration.rect.z)
    defer delete(stretchingCols)
    stretchingRows := make([]Stretching, self.configuration.rect.w)
    defer delete(stretchingRows)

    for i in 0..<self.configuration.rect.z {
        s := linearStretching_get(self.stretchingCols, cast(int)i)

        stretchingCols[i] = s
        priorityCols[i] = calculatePriority(s)
    }

    for i in 0..<self.configuration.rect.w {
        s := linearStretching_get(self.stretchingRows, cast(int)i)

        stretchingRows[i] = s
        priorityCols[i] = calculatePriority(s)
    }


    rect := rect
    oldRect := rect

    
    gapX, useGapX := self.gap.x.?
    gapY, useGapY := self.gap.y.?
    gap := [2]BoxType{ gapX, gapY }
    useGap := [2]bool{ useGapX, useGapY }

    gapSize := [2]i16{ useGap.x ? (self.configuration.rect.z - 1) : 0, useGap.y ? (self.configuration.rect.w - 1) : 0 }

    rect -= { 0, 0, gapSize.x, gapSize.y }



    for &l in limCols { l = rect.z }
    for &l in limRows { l = rect.w }


    lastIteration :: 1
    for iteration in 0 ..= lastIteration {

        for &m, i in maxCols { m = 0 }
        for &m, i in maxRows { m = 0 }



        // TODO: loop in order of multiplicative preference
        for x in 0..<self.configuration.rect.z {
            for y in 0..<self.configuration.rect.w {
                n := buffer_get(self.configuration, { x, y }) or_continue
                e := self.children[n]

                maxSize := Pos{ limCols[x], limRows[y] }

                preferredSize := Pos{ math.min(maxSize.x, rect.z / self.configuration.rect.z), math.min(maxSize.y, rect.w / self.configuration.rect.w) }
                if stretchingCols[x].fill == .MinimalPossible { preferredSize.x = 1 }
                if stretchingRows[y].fill == .MinimalPossible { preferredSize.y = 1 }

                // TODO: still not sure about this
                wbhRatio := (f64(rect.z)) / (f64(rect.w))

                size := element_negotiate(e, Constraints{ maxSize = maxSize, preferredSize = preferredSize, widthByHeightPriceRatio = wbhRatio })
                maxCols[x] = math.max(maxCols[x], size.x)
                maxRows[y] = math.max(maxRows[y], size.y)
            }
        }

        totalCols := math.sum(maxCols)
        totalRows := math.sum(maxRows)

        // NOTE: unless this is the last iteration, elements should get as much space as possible
        dc := rect.z - totalCols
        if iteration == lastIteration && dc > 0 && (!render || !self.stretch.x) { dc = 0 }

        dr := rect.w - totalRows
        if iteration == lastIteration && dr > 0 && (!render || !self.stretch.y) { dr = 0 }

        lc := dc < 0 ? capCols : nil
        lr := dr < 0 ? capRows : nil

        for &c, i in capCols { c = cast(u64)math.abs(maxCols[i]) }
        for &c, i in capRows { c = cast(u64)math.abs(maxRows[i]) }

        divideBetween(cast(u64)math.abs(dc), priorityCols, transmute([]u64)deltaCols, maxValues = lc)
        divideBetween(cast(u64)math.abs(dr), priorityRows, transmute([]u64)deltaRows, maxValues = lr)

        for d, i in deltaCols {
            limCols[i] = maxCols[i] + (sign_i16(dc) * cast(i16)d)
        }

        for d, i in deltaRows {
            limRows[i] = maxRows[i] + (sign_i16(dr) * cast(i16)d)
        }
    }

    totalCols := math.sum(limCols)
    totalRows := math.sum(limRows)

    size = { totalCols, totalRows } + gapSize

    if !render { return }




    offset := rect.xy
    for x in 0..<self.configuration.rect.z {
        for y in 0..<self.configuration.rect.w {
            n := buffer_get(self.configuration, { x, y }) or_continue
            e := self.children[n]

            msize := Pos{ limCols[x], limRows[y] }
            element_render(e, ctx, { offset.x, offset.y, msize.x, msize.y })

            offset.y += msize.y

            if useGap.y && y < self.configuration.rect.w - 1 {
                if x == 0 {
                    drawBlock(ctx.bufferBoxes, { offset.x, offset.y, oldRect.z, 1 }, gap.y)
                }

                offset.y += 1
            }
        }

        offset.y = rect.y
        offset.x += (limCols[x])

        if useGap.x && x < self.configuration.rect.z - 1 {
            drawBlock(ctx.bufferBoxes, { offset.x, offset.y, 1, oldRect.w }, gap.x)
            offset.x += 1
        }
    }

    return
}
