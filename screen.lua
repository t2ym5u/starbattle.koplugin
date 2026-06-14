local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonTable     = require("ui/widget/buttontable")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local T               = require("ffi/util").template

local ScreenBase            = require("screen_base")
local MenuHelper            = require("menu_helper")
local StarBattleBoard       = lrequire("board")
local StarBattleBoardWidget = lrequire("board_widget")

local DeviceScreen = Device.screen

local GAME_RULES_EN = _([[
Star Battle — Rules

Place exactly N stars in the grid so that each row, each column, and each bold outlined region contains exactly N stars.

Non-adjacency rule:
• No two stars may be placed in adjacent cells — including diagonally adjacent cells.

Tap a cell to cycle through: star → empty marker (·) → blank.
The empty marker helps you note cells that cannot contain a star.
]])

local GAME_RULES_FR = [[
Star Battle — Règles

Placez exactement N étoiles dans la grille de sorte que chaque ligne, chaque colonne et chaque région en gras contienne exactement N étoiles.

Règle de non-adjacence :
• Deux étoiles ne peuvent pas être placées dans des cases adjacentes — y compris en diagonale.

Appuyez sur une case pour faire défiler : étoile → marqueur vide (·) → vide.
Le marqueur vide vous aide à noter les cases qui ne peuvent pas contenir d'étoile.
]]

local StarBattleScreen = ScreenBase:extend{}

function StarBattleScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", StarBattleBoard.DEFAULT_N)
    local k     = self:_kForN(n)
    self.board  = StarBattleBoard:new{ n = n, k = k }
    if not self.board:load(state) then
        -- fresh game already generated in new()
    end
    ScreenBase.init(self)
end

function StarBattleScreen:serializeState()
    return self.board:serialize()
end

function StarBattleScreen:_kForN(n)
    for _, s in ipairs(StarBattleBoard.SIZES) do
        if s.n == n then return s.k end
    end
    return 1
end

function StarBattleScreen:buildLayout()
    local sw           = DeviceScreen:getWidth()
    local is_landscape = self:isLandscape()

    self.board_widget = StarBattleBoardWidget:new{
        board        = self.board,
        onCellAction = function(r, c) self:onCellAction(r, c) end,
    }

    local board_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin  = Size.margin.default,
        self.board_widget,
    }

    local board_frame_size  = self.board_widget.size + (Size.padding.large + Size.margin.default) * 2
    local right_panel_width = sw - board_frame_size - Size.span.horizontal_default
    local button_width = is_landscape
        and math.max(right_panel_width - Size.span.horizontal_default, 100)
        or  math.floor(sw * 0.9)

    local top_buttons = ButtonTable:new{
        shrink_unneeded_width = true,
        width   = button_width,
        buttons = {{
            { text = _("New"),      callback = function() self:onNewGame() end },
            { id = "size_button",   text = self:getSizeButtonText(),
              callback = function() self:openSizeMenu() end },
            { text = _("Undo"),     callback = function() self:onUndo() end },
            { text = _("Reveal"),   callback = function() self:onReveal() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
            self:makeCloseButtonConfig(),
        }},
    }
    self.size_button = top_buttons:getButtonById("size_button")

    if is_landscape then
        local right_panel = VerticalGroup:new{
            align = "center",
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
        }
        self.layout = HorizontalGroup:new{
            align  = "center",
            board_frame,
            HorizontalSpan:new{ width = Size.span.horizontal_default },
            right_panel,
        }
    else
        self.layout = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Size.span.vertical_large },
            top_buttons,
            VerticalSpan:new{ width = Size.span.vertical_large },
            board_frame,
            VerticalSpan:new{ width = Size.span.vertical_large },
            self.status_text,
            VerticalSpan:new{ width = Size.span.vertical_large },
        }
    end
    self[1] = self.layout
    self:updateStatus()
end

function StarBattleScreen:onCellAction(r, c)
    self.board:cycleCell(r, c)
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState(self.board:serialize())
end

function StarBattleScreen:onUndo()
    if self.board:undoMove() then
        self.board_widget:refresh()
        self:updateStatus()
        self.plugin:saveState(self.board:serialize())
    end
end

function StarBattleScreen:onReveal()
    self.board:reveal()
    self.board_widget:refresh()
    self:updateStatus(_("Solution revealed."))
    self.plugin:saveState(self.board:serialize())
end

function StarBattleScreen:onNewGame()
    local n = self.plugin:getSetting("grid_n", StarBattleBoard.DEFAULT_N)
    local k = self:_kForN(n)
    self.board = StarBattleBoard:new{ n = n, k = k }
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function StarBattleScreen:openSizeMenu()
    local sizes = {}
    for _, s in ipairs(StarBattleBoard.SIZES) do
        sizes[#sizes + 1] = {
            id   = s.n,
            text = T(_("%1\xC3\x97%2 (%3\xE2\x98\x85)"), s.n, s.n, s.k),
        }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select grid size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", StarBattleBoard.DEFAULT_N),
        parent    = self,
        on_select = function(n)
            if n ~= self.board.n then
                self.plugin:saveSetting("grid_n", n)
                self:onNewGame()
            end
        end,
    }
end

function StarBattleScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.won then
        status = _("Congratulations! Puzzle solved!")
    else
        local placed = self.board:countStars()
        local total  = self.board:totalStars()
        local n, k   = self.board.n, self.board.k
        status = T(_("%1\xC3\x97%2 \xC2\xB7 %3\xE2\x98\x85/row \xC2\xB7 Stars: %4/%5"),
            n, n, k, placed, total)
    end
    ScreenBase.updateStatus(self, status)
end

function StarBattleScreen:getSizeButtonText()
    local n = self.board.n
    return T(_("Size: %1"), n .. "\xC3\x97" .. n)
end

return StarBattleScreen
