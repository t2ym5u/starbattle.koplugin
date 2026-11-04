local grid_utils = require("grid_utils")
local UndoStack  = require("undo_stack")
local Hint       = require("hint")

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

    -- order/dirs are refilled in place before each shuffle (same random
    -- draws as fresh tables, without the garbage: this loop is most of the
    -- time spent on an 8x8 board, which tries hundreds of layouts).
    local order, dirs = {}, {}
    while unassigned > 0 and iter < max_iter do
        iter = iter + 1
        -- Pick a random region and try to expand one cell
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
                for i = 1, 4 do dirs[i] = DIR4[i] end
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
-- Star placement solver (backtracking row-by-row). Counts up to `limit`
-- valid placements (not just the first) so callers can verify uniqueness --
-- the region partition itself is the entire puzzle (visible from the
-- start, nothing hidden to dig), so like hitori/nurikabe this needs a
-- generate-and-verify-whole-candidate approach rather than a digging
-- retrofit. Returns (count, exhausted, first_solution, second_solution).
--
-- Each row takes one of its k-column combinations at once (columns at least
-- two apart), and a placement is dropped as soon as some column or region
-- can no longer reach k stars in the rows left: a column gets at most one
-- star every other row, a region at most ceil(run/2) per row for each run
-- of its cells. The old solver placed one cell at a time with no lookahead
-- and ran out of its node budget on more than half of the 10x10 layouts
-- (3-7 s per puzzle on a desktop, minutes on a Kobo); this one enumerates
-- solutions in the same order, with the same counts.
-- ---------------------------------------------------------------------------

local combo_cache = {}

-- All sets of k columns out of 1..n, increasing, at least two apart.
local function rowCombos(n, k)
    local key = n * 100 + k
    if combo_cache[key] then return combo_cache[key] end
    local out, cur = {}, {}
    local function rec(start, left)
        if left == 0 then
            local t = {}
            for i = 1, #cur do t[i] = cur[i] end
            out[#out + 1] = t
            return
        end
        for c = start, n do
            cur[#cur + 1] = c
            rec(c + 2, left - 1)
            cur[#cur] = nil
        end
    end
    rec(1, k)
    combo_cache[key] = out
    return out
end

local function countSolutions(n, k, region_id, limit, node_budget)
    local combos = rowCombos(n, k)

    -- suffix[g][r]: most stars region g can still get in rows r..n.
    local suffix = {}
    for g = 1, n do suffix[g] = { [n + 1] = 0 } end
    for r = n, 1, -1 do
        local cap = {}
        for g = 1, n do cap[g] = 0 end
        local c = 1
        while c <= n do
            local g, run = region_id[r][c], 0
            while c <= n and region_id[r][c] == g do run = run + 1; c = c + 1 end
            cap[g] = cap[g] + math.ceil(run / 2)
        end
        for g = 1, n do suffix[g][r] = suffix[g][r + 1] + math.min(k, cap[g]) end
    end

    local col_count, reg_count = {}, {}
    for i = 1, n do col_count[i] = 0; reg_count[i] = 0 end
    -- star[r][c + 1]: padded by one column each side; row 0 stays empty.
    local star = {}
    for r = 0, n do
        star[r] = {}
        for c = 1, n + 2 do star[r][c] = false end
    end

    local solutions, nodes, exhausted = 0, 0, false
    local found = {}

    local function search(r)
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if r > n then
            -- Every column and region has k stars: the lookahead below
            -- leaves no room for less once the last row is placed.
            solutions = solutions + 1
            if solutions <= 2 then
                local sol = emptyGrid(n, n, 0)
                for rr = 1, n do
                    for cc = 1, n do
                        if star[rr][cc + 1] then sol[rr][cc] = 1 end
                    end
                end
                found[solutions] = sol
            end
            return
        end
        local prev, row, regs = star[r - 1], star[r], region_id[r]
        local rows_left = n - r
        for _, cb in ipairs(combos) do
            local ok = true
            for i = 1, k do
                local c = cb[i]
                if col_count[c] >= k or prev[c] or prev[c + 1] or prev[c + 2] then
                    ok = false
                    break
                end
            end
            if ok then
                for i = 1, k do
                    local c = cb[i]
                    reg_count[regs[c]] = reg_count[regs[c]] + 1
                    col_count[c] = col_count[c] + 1
                    row[c + 1] = true
                end
                for i = 1, k do
                    if reg_count[regs[cb[i]]] > k then ok = false; break end
                end
                if ok then
                    for g = 1, n do
                        if k - reg_count[g] > suffix[g][r + 1] then ok = false; break end
                    end
                end
                if ok then
                    for c = 1, n do
                        local need = k - col_count[c]
                        if need > 0 then
                            -- one star every other row; not right below one
                            local avail = row[c + 1] and math.floor(rows_left / 2)
                                or math.ceil(rows_left / 2)
                            if need > avail then ok = false; break end
                        end
                    end
                end
                if ok then search(r + 1) end
                for i = 1, k do
                    local c = cb[i]
                    reg_count[regs[c]] = reg_count[regs[c]] - 1
                    col_count[c] = col_count[c] - 1
                    row[c + 1] = false
                end
                if solutions >= limit or exhausted then return end
            end
        end
    end

    search(1)
    return solutions, exhausted, found[1], found[2]
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
    -- opts.empty: the caller loads a save or generates right after (with
    -- the progress bar), so skip the throwaway puzzle.
    if not opts.empty then obj:generate() end
    return obj
end

-- Cells to hand from x's region A to a neighbouring region B so that x
-- changes region while `target` keeps k stars in each: a shortest path of
-- target-free cells from x (in A) to a cell touching B, plus any piece of A
-- cut off by removing that path, provided no target star sits in such a
-- piece. Returns (cells, B) or nil.
local function regionMove(region_id, n, x, target)
    local g = region_id[x[1]][x[2]]
    -- Breadth-first from x over A's target-free cells.
    local parent = { [x[1] * 100 + x[2]] = false }
    local queue, head = { x }, 1
    local reach, to
    while head <= #queue and not reach do
        local cur = queue[head]
        head = head + 1
        local dirs = { 1, 2, 3, 4 }
        shuffle(dirs)
        for _, di in ipairs(dirs) do
            local d = DIR4[di]
            local nr, nc = cur[1] + d[1], cur[2] + d[2]
            if inBounds(nr, nc, n) then
                local h = region_id[nr][nc]
                if h ~= g then
                    reach, to = cur, h
                    break
                end
                local key = nr * 100 + nc
                if parent[key] == nil and target[nr][nc] == 0 then
                    parent[key] = cur
                    queue[#queue + 1] = { nr, nc }
                end
            end
        end
    end
    if not reach then return nil end

    local moving, out = {}, {}
    local cell = reach
    while cell do
        moving[cell[1] * 100 + cell[2]] = true
        out[#out + 1] = cell
        cell = parent[cell[1] * 100 + cell[2]]
    end

    -- The rest of A falls into pieces; only the one holding the target's
    -- stars may stay.
    local seen, kept = {}, 0
    for rr = 1, n do
        for cc = 1, n do
            local key = rr * 100 + cc
            if region_id[rr][cc] == g and not moving[key] and not seen[key] then
                seen[key] = true
                local piece, stars, stack = {}, 0, { { rr, cc } }
                while #stack > 0 do
                    local cur = table.remove(stack)
                    piece[#piece + 1] = cur
                    if target[cur[1]][cur[2]] == 1 then stars = stars + 1 end
                    for _, d in ipairs(DIR4) do
                        local nr, nc = cur[1] + d[1], cur[2] + d[2]
                        local nkey = nr * 100 + nc
                        if inBounds(nr, nc, n) and region_id[nr][nc] == g
                                and not moving[nkey] and not seen[nkey] then
                            seen[nkey] = true
                            stack[#stack + 1] = { nr, nc }
                        end
                    end
                end
                if stars > 0 then
                    kept = kept + 1
                else
                    for _, c2 in ipairs(piece) do out[#out + 1] = c2 end
                end
            end
        end
    end
    if kept ~= 1 then return nil end
    return out, to
end

-- A layout with several solutions is kept, and its first solution S taken
-- as the answer: a cell that holds a star in another solution but not in S
-- moves to a neighbouring region (see regionMove). S keeps exactly k stars
-- per region (the moved cells had none), the other solution now has too
-- few in the cell's old region, and the next count either proves S unique
-- or shows the next rival. Returns true once S is the only solution.
local MAX_REGION_TWEAKS = 40

local function tweakUntilUnique(n, k, region_id, target, rival, node_budget)
    for step = 1, MAX_REGION_TWEAKS do
        local xs = {}
        for r = 1, n do
            for c = 1, n do
                if rival[r][c] == 1 and target[r][c] == 0 then xs[#xs + 1] = { r, c } end
            end
        end
        shuffle(xs)
        local moved = false
        for _, x in ipairs(xs) do
            local cells, to = regionMove(region_id, n, x, target)
            if cells then
                for _, cell in ipairs(cells) do region_id[cell[1]][cell[2]] = to end
                moved = true
                break
            end
        end
        if not moved then return false, step - 1 end
        local solutions, exhausted, first, second = countSolutions(n, k, region_id, 2, node_budget)
        if exhausted or solutions == 0 then return false, step end
        if solutions == 1 then return true, step end
        rival = second
        for r = 1, n do
            for c = 1, n do
                if first[r][c] ~= target[r][c] then rival = first; break end
            end
            if rival == first then break end
        end
    end
    return false, MAX_REGION_TWEAKS
end

-- on_progress (optional): called with a 0..1 fraction as it goes.
function StarBattleBoard:generate(on_progress)
    local n, k = self.n, self.k
    -- Random-region layouts are often infeasible for a given k (measured
    -- ~91% single-attempt failure at n=8/k=2), and among the feasible ones
    -- only a few are unique: ~7% at n=6/k=1, under 1% at n=10/k=2. 6x6 and
    -- 8x8 find a unique one by plain retries within milliseconds. At 10x10
    -- that took ~1000 layouts (3-7 s on a desktop, minutes on a Kobo, and
    -- ~10% of games still fell back to an unproven layout), so there a
    -- feasible layout with rivals is tweaked until its first solution is
    -- the only one (tweakUntilUnique). Falls back to the best
    -- structurally-valid-but-unproven layout found if the budget runs out,
    -- same as nurikabe/hitori's approach.
    local max_attempts = 2000
    -- Node and count caps, not time, so a seed gives the same puzzle on any
    -- device. The solver needs well under node_budget on every layout
    -- measured; at 10x10 a puzzle took at most 116 counts over 300 seeds
    -- (median 16), so MAX_COUNTS is a safety net.
    local node_budget = 200000
    local tweak = n >= 10
    local MAX_COUNTS = 600
    local counts = 0
    local best_region_id, best_solution

    for attempt = 1, max_attempts do
        if tweak and counts >= MAX_COUNTS then break end
        if on_progress then on_progress(counts / (counts + 30)) end
        local region_id = generateRegions(n)
        local solutions, exhausted, sol, rival = countSolutions(n, k, region_id, 2, node_budget)
        counts = counts + 1
        local unique = not exhausted and solutions == 1
        if sol and tweak and not unique and not exhausted then
            -- Tweaking keeps sol a solution, so the layout stays a valid
            -- (if unproven) fallback whatever happens.
            local used
            unique, used = tweakUntilUnique(n, k, region_id, sol, rival, node_budget)
            counts = counts + used
        end
        if sol then
            if not best_region_id then
                best_region_id, best_solution = region_id, sol
            end
            if unique then
                self.region_id = region_id
                self.solution  = sol
                self.marks     = emptyGrid(n, n, MARK_EMPTY)
                self.won       = false
                self.undo:clear()
                return
            end
        end
    end
    if best_region_id then
        self.region_id = best_region_id
        self.solution  = best_solution
        self.marks     = emptyGrid(n, n, MARK_EMPTY)
        self.won       = false
        self.undo:clear()
        return
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

-- Like cycleCell(), but goes straight to a mark. Used by the Hint button,
-- and undoable through the same stack as a hand-made move.
function StarBattleBoard:setMark(r, c, mark)
    if self.won then return false end
    local cur = self.marks[r][c]
    if cur == mark then return true end
    self.undo:push{ r = r, c = c, old = cur }
    self.marks[r][c] = mark
    self:_checkWin()
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

-- A dot counts as empty for the win check, so only stars decide the puzzle:
-- cells without one read as empty and equals() compares star-ness.
Hint.install(StarBattleBoard, {
    getUser     = function(b, r, c) return b.marks[r][c] end,
    getSolution = function(b, r, c) return b.solution[r][c] == 1 and MARK_STAR or MARK_EMPTY end,
    isEmpty     = function(v) return v == MARK_EMPTY end,
    equals      = function(u, s) return (u == MARK_STAR) == (s == MARK_STAR) end,
    setCell     = function(b, r, c, v) return b:setMark(r, c, v) end,
    blank       = MARK_EMPTY,
})

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
-- for the specs
StarBattleBoard._countSolutions  = countSolutions
StarBattleBoard._generateRegions = generateRegions

return StarBattleBoard
