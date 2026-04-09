package tui

import "core:slice"
import "core:math"

// NOTE: allocator argument removed because even if you want to specify the allocator it's
// much more convenient to set the context allocator once instead of passing it to each
// procedure

// I'm not sure how to go about attaching data, really if we just allocate more space per element we don't need an additional
// data pointer stored at the element, but I might be missing something............ will return to it later

BuilderOptions :: struct {
    store : rawptr,
    size  : int,
}

instantiate :: proc (e : ^Element) -> ^Element {
    return element_clone(e)
}

element :: proc (value : $ty, children : []^Element = nil) -> ^Element {
    e := cast(^Element)new_clone(value)
    e.children = children == nil ? nil : slice.clone(children)
    return e
}

builder_prepare :: proc (default : $ty, opt : BuilderOptions) -> ^ty {
    size := max(size_of(ty), opt.size)
    bytes := make([]u8, size)
    e : ^ty = cast(^ty)raw_data(bytes)
    e^ = default
    e.size = size
    return e
}

builder_store :: proc (element : $ty, opt : BuilderOptions) -> ^Element {
    if opt.store != nil {
        (cast(^ty)opt.store)^ = element
    }

    return element
}

label :: proc (text : string, opt : BuilderOptions = {}) -> ^Element {
    e := builder_prepare(Element_Label_default, opt)

    e.text = text

    return builder_store(e, opt)
}

linear :: proc (orientation : Element_Linear_Orientation, gap : Maybe(BoxType), s : LinearStretching, children : []^Element, opt : BuilderOptions = {}) -> ^Element {
    e := builder_prepare(Element_Linear_default, opt)

    e.children = slice.clone(children)

    e.stretching = s
    e.gap = gap
    e.isHorizontal = (orientation == .Horizontal)

    return builder_store(e, opt)
}

scroll :: proc (scroll : [2]bool, scrollbar : [2]bool, targetFocus : bool, child : ^Element, opt : BuilderOptions = {}) -> ^Element {
    e := builder_prepare(Element_Scroll_default, opt)

    e.children = slice.clone([]^Element{ child })

    e.scroll = scroll
    e.scrollbar = scrollbar
    e.targetFocus = targetFocus

    return builder_store(e, opt)
}

box :: proc (border : BoxType, margin : Rect, padding : Rect, child : ^Element, opt : BuilderOptions = {}) -> ^Element {
    e := builder_prepare(Element_Box_default, opt)

    e.children = slice.clone([]^Element{ child })

    e.border = border
    e.margin = margin
    e.padding = padding

    return builder_store(e, opt)
}

table :: proc (size : Pos, gap : [2]Maybe(BoxType), stretching : [2]LinearStretching, children : []^Element, opt : BuilderOptions = {}) -> ^Element {
    e := builder_prepare(Element_Table_default, opt)

    e.children = slice.clone(children)

    buffer, _ := buffer_create(Rect{ 0, 0, size.x, size.y }, int)
    e.configuration = buffer

    index := 0
    for y in 0..<size.y {
        for x in 0..<size.x {
            buffer_set(buffer, { x, y }, index)
            index += 1
        }
    }

    // TODO: array and overrides need to be copied to current allocator
    e.stretchingCols = stretching[0]
    e.stretchingRows = stretching[1]
    e.gap = gap

    return builder_store(e, opt)
}
