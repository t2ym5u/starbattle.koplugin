local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase            = require("screen_base")
local MenuHelper            = require("menu_helper")
local StarBattleBoard       = lrequire("board")
local StarBattleBoardWidget = lrequire("board_widget")

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
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Star Battle"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            { text = self:getSizeButtonText(), callback = function() self:openSizeMenu() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Controls first: the board is sized from whatever room they leave.
    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Undo"),   callback = function() self:onUndo() end },
        { text = _("Hint"), callback = function() self:onHint() end },
        { text = _("Reveal"), callback = function() self:onReveal() end },
    })
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick outer border, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = StarBattleBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c) self:onCellAction(r, c) end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function StarBattleScreen:onCellAction(r, c)
    self.board:cycleCell(r, c)
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState(self.board:serialize())
    self:refreshActionBar()
end

function StarBattleScreen:onUndo()
    if self.board:undoMove() then
        self.board_widget:refresh()
        self:updateStatus()
        self.plugin:saveState(self.board:serialize())
        self:refreshActionBar()
    end
end

function StarBattleScreen:onReveal()
    self.board:reveal()
    self.board_widget:refresh()
    self:updateStatus(_("Solution revealed."))
    self.plugin:saveState(self.board:serialize())
    self:refreshActionBar()
end

function StarBattleScreen:isRoundOver()
    return self.board.won
end

-- A hint can place the last cell, so the round may end here.
function StarBattleScreen:onHint()
    ScreenBase.onHint(self)
    self:refreshActionBar()
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
    for idx, s in ipairs(StarBattleBoard.SIZES) do
        sizes[#sizes + 1] = {
            id   = s.n,
            text = T(_("%1\xC3\x97%2 (%3\xE2\x98\x85)"), s.n, s.n, s.k),
        }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
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
        status = self:joinStatus(
            T("%1×%1", n), T(_("%1\xE2\x98\x85/row"), k), T(_("Stars: %1/%2"), placed, total))
    end
    ScreenBase.updateStatus(self, status)
end

function StarBattleScreen:getSizeButtonText()
    local n = self.board.n
    return T(_("Size: %1"), n .. "\xC3\x97" .. n)
end

return StarBattleScreen
