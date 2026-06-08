local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local gwb            = require("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

local StarBattleBoard = require("board")

-- ---------------------------------------------------------------------------
-- Colours
-- ---------------------------------------------------------------------------

local C_BG         = Blitbuffer.COLOR_WHITE
local C_LINE       = Blitbuffer.COLOR_BLACK
local C_GRID       = Blitbuffer.COLOR_GRAY_9
local C_SELECTED   = Blitbuffer.COLOR_GRAY_D
local C_CONFLICT   = Blitbuffer.COLOR_GRAY_A
local C_DOT        = Blitbuffer.COLOR_GRAY_4
local C_STAR       = Blitbuffer.COLOR_BLACK

-- ---------------------------------------------------------------------------
-- StarBattleBoardWidget
-- ---------------------------------------------------------------------------

local StarBattleBoardWidget = GridWidgetBase:extend{
    board    = nil,
    selected = nil,  -- {r, c} or nil
}

function StarBattleBoardWidget:init()
    local n   = self.board and self.board.n or 8
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)
end

function StarBattleBoardWidget:onCellTap(row, col)
    if self.onCellAction then
        self.onCellAction(row, col)
    end
end

-- ---------------------------------------------------------------------------
-- paintTo
-- ---------------------------------------------------------------------------

function StarBattleBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }

    local board = self.board
    local n     = board.n
    local cell  = self.dimen.w / n

    -- Background
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    local conflicts = board:getConflicts()

    -- Cell backgrounds
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)
            local bg
            if self.selected and self.selected[1] == r and self.selected[2] == c then
                bg = C_SELECTED
            elseif conflicts[r][c] then
                bg = C_CONFLICT
            end
            if bg then bb:paintRect(cx, cy, cw, ch, bg) end
        end
    end

    -- Grid lines (thin)
    local thin  = Size.line.thin  or 1
    local thick = math.max(2, math.floor(cell * 0.08))

    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i * cell), y, lw, self.dimen.h, C_LINE)
        drawLine(bb, x, y + math.floor(i * cell), self.dimen.w, lw, C_LINE)
    end

    -- Thick region borders
    local reg_thick = math.max(3, math.floor(cell * 0.12))
    for r = 1, n do
        for c = 1, n do
            -- Right border: between (r,c) and (r,c+1)
            if c < n and board.region_id[r][c] ~= board.region_id[r][c + 1] then
                local bx = x + math.floor(c * cell) - math.floor(reg_thick / 2)
                local by = y + math.floor((r - 1) * cell)
                drawLine(bb, bx, by, reg_thick, math.ceil(cell), C_LINE)
            end
            -- Bottom border: between (r,c) and (r+1,c)
            if r < n and board.region_id[r][c] ~= board.region_id[r + 1][c] then
                local bx = x + math.floor((c - 1) * cell)
                local by = y + math.floor(r * cell) - math.floor(reg_thick / 2)
                drawLine(bb, bx, by, math.ceil(cell), reg_thick, C_LINE)
            end
        end
    end

    -- Cell content
    local pad    = self.number_padding or 2
    local inner  = math.max(1, math.floor(cell - 2 * pad))
    local star_face = self.number_face
    local dot_face  = self.note_face

    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c - 1) * cell)
            local cy = y + math.floor((r - 1) * cell)
            local mark = board.marks[r][c]

            if mark == StarBattleBoard.MARK_STAR then
                -- Draw star as "*" centered in cell
                local text = "*"
                local m    = RenderText:sizeUtf8Text(0, inner, star_face, text, true, false)
                local bx   = cx + pad + math.floor((inner - m.x) / 2)
                local by   = cy + pad + math.floor((inner + m.y_top - m.y_bottom) / 2)
                RenderText:renderUtf8Text(bb, bx, by, star_face, text, true, false, C_STAR)
            elseif mark == StarBattleBoard.MARK_DOT then
                -- Draw dot as "." centered in cell
                local text = "."
                local m    = RenderText:sizeUtf8Text(0, inner, dot_face, text, true, false)
                local bx   = cx + pad + math.floor((inner - m.x) / 2)
                local by   = cy + pad + math.floor((inner + m.y_top - m.y_bottom) / 2)
                RenderText:renderUtf8Text(bb, bx, by, dot_face, text, true, false, C_DOT)
            end
        end
    end
end

return StarBattleBoardWidget
