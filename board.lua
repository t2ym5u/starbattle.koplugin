local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")

local emptyGrid = grid_utils.emptyGrid
local shuffle   = grid_utils.shuffle

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

local SIZES = {
    { n = 6,  k = 1 },
    { n = 8,  k = 2 },
    { n = 10, k = 2 },
}
local DEFAULT_N = 8
local DEFAULT_K = 2

-- Cell mark values
local MARK_EMPTY = 0
local MARK_STAR  = 1
local MARK_DOT   = 2

-- ---------------------------------------------------------------------------
-- Region generation via BFS flood-fill from N random seeds
-- ---------------------------------------------------------------------------

local DIR4 = { {-1,0},{1,0},{0,-1},{0,1} }

local function inBounds(r, c, n)
    return r >= 1 and r <= n and c >= 1 and c <= n
end

local function generateRegions(n)
    local region_id = emptyGrid(n, n, 0)
    local seeds = {}

    -- Place N seeds, each in a distinct cell
    local all_cells = {}
    for r = 1, n do
        for c = 1, n do all_cells[#all_cells + 1] = { r, c } end
    end
    shuffle(all_cells)
    for i = 1, n do
        local cell = all_cells[i]
        seeds[i] = { r = cell[1], c = cell[2] }
        region_id[cell[1]][cell[2]] = i
    end

    -- BFS expansion: frontier per region
    local frontiers = {}
    for i = 1, n do
        frontiers[i] = { seeds[i] }
    end

    local unassigned = n * n - n
    local iter = 0
    local max_iter = n * n * 4

    while unassigned > 0 and iter < max_iter do
        iter = iter + 1
        -- Pick a random region and try to expand one cell
        local order = {}
        for i = 1, n do order[i] = i end
        shuffle(order)
        for _, reg in ipairs(order) do
            local frontier = frontiers[reg]
            if #frontier > 0 then
                -- Pick random cell from frontier
                local fi = math.random(#frontier)
                local cell = frontier[fi]
                local expanded = false
                -- Try all 4 neighbours in random order
                local dirs = { {-1,0},{1,0},{0,-1},{0,1} }
                shuffle(dirs)
                for _, d in ipairs(dirs) do
                    local nr, nc = cell.r + d[1], cell.c + d[2]
                    if inBounds(nr, nc, n) and region_id[nr][nc] == 0 then
                        region_id[nr][nc] = reg
                        frontiers[reg][#frontiers[reg] + 1] = { r = nr, c = nc }
                        unassigned = unassigned - 1
                        expanded = true
                        break
                    end
                end
                if not expanded then
                    -- Remove this frontier cell (no unassigned neighbours)
                    table.remove(frontier, fi)
                end
            end
        end
    end

    -- Fallback: assign any remaining unassigned cells to nearest region
    if unassigned > 0 then
        for r = 1, n do
            for c = 1, n do
                if region_id[r][c] == 0 then
                    region_id[r][c] = ((r + c) % n) + 1
                end
            end
        end
    end

    return region_id
end

-- ---------------------------------------------------------------------------
-- Star placement solver (backtracking row-by-row)
-- ---------------------------------------------------------------------------

local function solveStar(n, k, region_id)
    local solution = emptyGrid(n, n, 0)
    local row_count = {}
    local col_count = {}
    local reg_count = {}
    for i = 1, n do row_count[i] = 0; col_count[i] = 0; reg_count[i] = 0 end

    local function isAdjacent(r, c)
        for dr = -1, 1 do
            for dc = -1, 1 do
                if not (dr == 0 and dc == 0) then
                    local nr, nc = r + dr, c + dc
                    if inBounds(nr, nc, n) and solution[nr][nc] == 1 then
                        return true
                    end
                end
            end
        end
        return false
    end

    -- Place exactly k stars in each row by choosing columns
    -- We go row by row, choosing k columns per row
    local iter_count = { 0 }
    local MAX_ITER = 200000

    local function pickCols(r, start_c, placed)
        if iter_count[1] > MAX_ITER then return false end
        iter_count[1] = iter_count[1] + 1
        if placed == k then
            if r == n then
                return true  -- all rows done
            end
            return pickCols(r + 1, 1, 0)
        end
        -- Need to place (k - placed) more stars in row r, columns start_c..n
        local remaining_cols = n - start_c + 1
        local needed = k - placed
        if remaining_cols < needed then return false end

        for c = start_c, n do
            local reg = region_id[r][c]
            if col_count[c] < k and reg_count[reg] < k and not isAdjacent(r, c) then
                solution[r][c] = 1
                row_count[r] = row_count[r] + 1
                col_count[c] = col_count[c] + 1
                reg_count[reg] = reg_count[reg] + 1

                if pickCols(r, c + 1, placed + 1) then return true end

                solution[r][c] = 0
                row_count[r] = row_count[r] - 1
                col_count[c] = col_count[c] - 1
                reg_count[reg] = reg_count[reg] - 1
            end
        end
        return false
    end

    if pickCols(1, 1, 0) then
        return solution
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- StarBattleBoard
-- ---------------------------------------------------------------------------

local StarBattleBoard = {}
StarBattleBoard.__index = StarBattleBoard

function StarBattleBoard:new(opts)
    opts = opts or {}
    local obj = setmetatable({
        n          = opts.n or DEFAULT_N,
        k          = opts.k or DEFAULT_K,
        region_id  = nil,
        solution   = nil,
        marks      = nil,
        won        = false,
        undo       = UndoStack:new{ max_size = 500 },
    }, self)
    obj:generate()
    return obj
end

function StarBattleBoard:generate()
    local n, k = self.n, self.k
    local max_attempts = 10
    for attempt = 1, max_attempts do
        local region_id = generateRegions(n)
        local sol = solveStar(n, k, region_id)
        if sol then
            self.region_id = region_id
            self.solution  = sol
            self.marks     = emptyGrid(n, n, MARK_EMPTY)
            self.won       = false
            self.undo:clear()
            return
        end
    end
    -- Fallback: trivial 6x6 k=1 layout
    self.n = 6; self.k = 1
    local n2 = 6
    local region_id = emptyGrid(n2, n2, 0)
    for r = 1, n2 do
        for c = 1, n2 do
            region_id[r][c] = r  -- each row is its own region
        end
    end
    local sol = emptyGrid(n2, n2, 0)
    for r = 1, n2 do sol[r][r] = 1 end
    self.region_id = region_id
    self.solution  = sol
    self.marks     = emptyGrid(n2, n2, MARK_EMPTY)
    self.won       = false
    self.undo:clear()
end

function StarBattleBoard:cycleCell(r, c)
    if self.won then return false end
    local cur = self.marks[r][c]
    local nxt
    if     cur == MARK_EMPTY then nxt = MARK_STAR
    elseif cur == MARK_STAR  then nxt = MARK_DOT
    else                          nxt = MARK_EMPTY
    end
    self.undo:push{ r = r, c = c, old = cur }
    self.marks[r][c] = nxt
    self:_checkWin()
    return true
end

function StarBattleBoard:undoMove()
    local entry = self.undo:pop()
    if not entry then return false end
    self.marks[entry.r][entry.c] = entry.old
    self.won = false
    return true
end

function StarBattleBoard:_checkWin()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local want = (self.solution[r][c] == 1) and MARK_STAR or MARK_EMPTY
            local got  = self.marks[r][c]
            -- Allow dot as "empty" for win check
            if got == MARK_DOT then got = MARK_EMPTY end
            if got ~= want then
                self.won = false
                return
            end
        end
    end
    self.won = true
end

function StarBattleBoard:getConflicts()
    local n, k = self.n, self.k
    local conflict = emptyGrid(n, n, false)

    -- Row/col/region counts
    local row_stars = {}
    local col_stars = {}
    local reg_stars = {}
    for i = 1, n do row_stars[i] = 0; col_stars[i] = 0; reg_stars[i] = 0 end

    for r = 1, n do
        for c = 1, n do
            if self.marks[r][c] == MARK_STAR then
                row_stars[r] = row_stars[r] + 1
                col_stars[c] = col_stars[c] + 1
                reg_stars[self.region_id[r][c]] = reg_stars[self.region_id[r][c]] + 1
            end
        end
    end

    for r = 1, n do
        for c = 1, n do
            if self.marks[r][c] == MARK_STAR then
                -- Check row overflow
                if row_stars[r] > k then conflict[r][c] = true end
                -- Check col overflow
                if col_stars[c] > k then conflict[r][c] = true end
                -- Check region overflow
                if reg_stars[self.region_id[r][c]] > k then conflict[r][c] = true end
                -- Check adjacency
                for dr = -1, 1 do
                    for dc = -1, 1 do
                        if not (dr == 0 and dc == 0) then
                            local nr, nc = r + dr, c + dc
                            if inBounds(nr, nc, n) and self.marks[nr][nc] == MARK_STAR then
                                conflict[r][c] = true
                            end
                        end
                    end
                end
            end
        end
    end
    return conflict
end

function StarBattleBoard:countStars()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self.marks[r][c] == MARK_STAR then count = count + 1 end
        end
    end
    return count
end

function StarBattleBoard:totalStars()
    return self.n * self.k
end

function StarBattleBoard:reveal()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            self.marks[r][c] = (self.solution[r][c] == 1) and MARK_STAR or MARK_EMPTY
        end
    end
    self.won = true
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

function StarBattleBoard:serialize()
    local n = self.n
    local region_flat, sol_flat, marks_flat = {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            region_flat[#region_flat + 1] = self.region_id[r][c]
            sol_flat[#sol_flat + 1]       = self.solution[r][c]
            marks_flat[#marks_flat + 1]   = self.marks[r][c]
        end
    end
    return { n = self.n, k = self.k, region_id = region_flat,
             solution = sol_flat, marks = marks_flat, won = self.won }
end

function StarBattleBoard:load(data)
    if type(data) ~= "table" or not data.region_id then return false end
    local n = data.n or DEFAULT_N
    local k = data.k or DEFAULT_K
    self.n  = n
    self.k  = k
    self.region_id = emptyGrid(n, n, 0)
    self.solution  = emptyGrid(n, n, 0)
    self.marks     = emptyGrid(n, n, MARK_EMPTY)
    local idx = 1
    for r = 1, n do
        for c = 1, n do
            self.region_id[r][c] = data.region_id[idx] or 1
            self.solution[r][c]  = data.solution[idx]  or 0
            self.marks[r][c]     = data.marks[idx]     or MARK_EMPTY
            idx = idx + 1
        end
    end
    self.won = data.won or false
    self.undo:clear()
    return true
end

StarBattleBoard.MARK_EMPTY = MARK_EMPTY
StarBattleBoard.MARK_STAR  = MARK_STAR
StarBattleBoard.MARK_DOT   = MARK_DOT
StarBattleBoard.SIZES      = SIZES
StarBattleBoard.DEFAULT_N  = DEFAULT_N
StarBattleBoard.DEFAULT_K  = DEFAULT_K

return StarBattleBoard
