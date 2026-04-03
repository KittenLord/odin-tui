package tui

import "core:slice"

// NOTE: allocator argument removed because even if you want to specify the allocator it's
// much more convenient to set the context allocator once instead of passing it to each
// procedure

// I'm not sure how to go about attaching data, really if we just allocate more space per element we don't need an additional
// data pointer stored at the element, but I might be missing something............ will return to it later

Store :: struct($tyDefault, $tyData : typeid) {
    store   : ^^Element,        // Where to store the created element
    default : tyDefault,        // Essentially how much space to allocate instead of the default type, i.e. if you have expanded it
    data    : tyData,           // 
}

instantiate :: proc (e : ^Element) -> ^Element {
    return element_clone(e)
}

element :: proc (value : $ty, children : []^Element = nil) -> ^Element {
    e := cast(^Element)new_clone(value)
    e.children = children == nil ? nil : slice.clone(children)
    return e
}

label :: proc (text : string) -> ^Element {
    e := new_clone(Element_Label_default)
    e.text = text
    return e
}

linear :: proc (orientation : Element_Linear_Orientation, gap : Maybe(BoxType), s : LinearStretching, children : []^Element) -> ^Element {
    e := new_clone(Element_Linear_default)
    e.children = slice.clone(children)

    e.stretching = s
    e.gap = gap
    e.isHorizontal = (orientation == .Horizontal)

    return e
}

scroll :: proc (scroll : [2]bool, scrollbar : [2]bool, targetFocus : bool, child : ^Element) -> ^Element {
    e := new_clone(Element_Scroll_default)
    e.children = slice.clone([]^Element{ child })

    e.scroll = scroll
    e.scrollbar = scrollbar
    e.targetFocus = targetFocus

    return e
}

box :: proc (border : BoxType, margin : Rect, padding : Rect, child : ^Element) -> ^Element {
    e := new_clone(Element_Box_default)
    e.children = slice.clone([]^Element{ child })

    e.border = border
    e.margin = margin
    e.padding = padding

    return e
}

table :: proc (size : Pos, gap : [2]Maybe(BoxType), stretching : [2]LinearStretching, children : []^Element) -> ^Element {
    e := new_clone(Element_Table_default)
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

    return e
}
