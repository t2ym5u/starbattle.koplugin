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

-- compat[j]: the combos that may follow combo j in the next row (no star
-- touching one of j's, diagonals included); compat[0] = all of them.
local compat_cache = {}
local function rowCompat(n, k)
    local key = n * 100 + k
    if compat_cache[key] then return compat_cache[key] end
    local combos = rowCombos(n, k)
    local compat = { [0] = {} }
    for i = 1, #combos do compat[0][i] = i end
    for j, a in ipairs(combos) do
        local list = {}
        for i, b in ipairs(combos) do
            local ok = true
            for x = 1, k do
                for y = 1, k do
                    if math.abs(a[x] - b[y]) <= 1 then ok = false end
                end
            end
            if ok then list[#list + 1] = i end
        end
        compat[j] = list
    end
    compat_cache[key] = compat
    return compat
end

-- per-row scratch lists of countSolutions (never nested), per size
local scratch_cache = {}

-- dead (optional): the dead ends found so far, per row (see below), to
-- carry over to a recount of a layout changed only in rows up to some row
-- (tweakUntilUnique).
local function countSolutions(n, k, region_id, limit, node_budget, dead)
    local combos = rowCombos(n, k)
    local compat = rowCompat(n, k)

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

    -- Depth-first, a row at a time, combos in order, written as a loop
    -- with its own stack (LuaJIT runs that much faster than recursion).
    --
    -- Two lookaheads are worked out once per row before its combos are
    -- tried: needy (a region that rows r+1..n can't fill on their own, by
    -- suffix, needs stars in this row) and must (a column that one star
    -- every other row can't fill otherwise needs a star in this row; one
    -- that would be short even so rules out the row). Only combos clear of
    -- the previous row's stars are looked at (compat).
    --
    -- Dead ends already explored are skipped: what is left to place below
    -- row r only depends on r, the stars per column and per region so far,
    -- and row r's combo, so a state whose rows below held no solution
    -- holds none when the search reaches it again by another path.
    -- Solutions come in the same order, only sooner. The key packs it all
    -- into one integer (counts in base 3, as k <= 2), one table per row.
    -- Whether a state is a dead end only depends on the layout of the rows
    -- below it, so the tables of rows at or below the last changed row
    -- stay good for a changed layout.
    local scratch = scratch_cache[n]
    if not scratch then
        scratch = { {}, {}, {} }
        for r = 1, n do scratch[1][r], scratch[2][r], scratch[3][r] = {}, {}, {} end
        scratch_cache[n] = scratch
    end
    local needy_gs, needy_ds, must_cs = scratch[1], scratch[2], scratch[3]
    local nneedys, nmusts = {}, {}
    -- (without a dead table, none is kept: on the small boards the
    -- bookkeeping costs more than it saves)
    local pow3 = { [1] = 1 }
    for i = 2, n do pow3[i] = pow3[i - 1] * 3 end
    local col_key, reg_key = 0, 0
    local ncombo = #combos + 1
    local chosen = { [0] = 0 }   -- chosen[r]: row r's combo (0: none yet)
    local pos = {}               -- pos[r]: next index into row r's list
    local keys, before = {}, {} -- per row: its state key, solutions then

    -- Entering row r: count the node and work out its lookaheads.
    -- False when the row can't take any combo.
    local function enter(r)
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return false end
        local rows_left = n - r
        local half_dn, half_up = math.floor(rows_left / 2), math.ceil(rows_left / 2)
        local needy_g, needy_d, must_c = needy_gs[r], needy_ds[r], must_cs[r]
        local nneedy, nmust = 0, 0
        for g = 1, n do
            local d = k - reg_count[g] - suffix[g][r + 1]
            if d > 0 then
                if d > k then return false end
                nneedy = nneedy + 1
                needy_g[nneedy], needy_d[nneedy] = g, d
            end
        end
        for c = 1, n do
            local need = k - col_count[c]
            if need > half_up then
                if need - 1 > half_dn then return false end
                nmust = nmust + 1
                must_c[nmust] = c
            end
        end
        nneedys[r], nmusts[r] = nneedy, nmust
        pos[r] = 1
        return true
    end

    -- Takes row r's combo back off the board.
    local function lift(r)
        local cb, regs, row = combos[chosen[r]], region_id[r], star[r]
        for i = 1, k do
            local c = cb[i]
            reg_count[regs[c]] = reg_count[regs[c]] - 1
            col_count[c] = col_count[c] - 1
            row[c + 1] = false
            col_key = col_key - pow3[c]
            reg_key = reg_key - pow3[regs[c]]
        end
        chosen[r] = 0
    end

    local r = 1
    if not enter(1) then r = 0 end
    while r >= 1 do
        -- next combo of row r that passes every check
        local list = compat[chosen[r - 1]]
        local regs = region_id[r]
        local needy_g, needy_d, must_c = needy_gs[r], needy_ds[r], must_cs[r]
        local nneedy, nmust = nneedys[r], nmusts[r]
        local p, pick = pos[r], nil
        while p <= #list do
            local ci = list[p]
            p = p + 1
            local cb = combos[ci]
            local ok = true
            for i = 1, k do
                local c = cb[i]
                if col_count[c] >= k or reg_count[regs[c]] >= k then ok = false; break end
            end
            if ok and k == 2 and regs[cb[1]] == regs[cb[2]] and reg_count[regs[cb[1]]] > 0 then
                ok = false   -- both stars in one region that already has one
            end
            if ok then
                for j = 1, nmust do
                    local c, hit = must_c[j], false
                    for i = 1, k do
                        if cb[i] == c then hit = true; break end
                    end
                    if not hit then ok = false; break end
                end
            end
            if ok then
                for j = 1, nneedy do
                    local g, got = needy_g[j], 0
                    for i = 1, k do
                        if regs[cb[i]] == g then got = got + 1 end
                    end
                    if got < needy_d[j] then ok = false; break end
                end
            end
            if ok and dead then
                local ck, rk = col_key, reg_key
                for i = 1, k do
                    ck = ck + pow3[cb[i]]
                    rk = rk + pow3[regs[cb[i]]]
                end
                local key = (ck * pow3[n] * 3 + rk) * ncombo + ci
                if not dead[r][key] then pick = ci; keys[r] = key; break end
            elseif ok then
                pick = ci
                break
            end
        end
        pos[r] = p
        if pick then
            local cb, row = combos[pick], star[r]
            for i = 1, k do
                local c = cb[i]
                reg_count[regs[c]] = reg_count[regs[c]] + 1
                col_count[c] = col_count[c] + 1
                row[c + 1] = true
                col_key = col_key + pow3[c]
                reg_key = reg_key + pow3[regs[c]]
            end
            chosen[r] = pick
            before[r] = solutions
            if r == n then
                -- A full board. Every column and region has k stars: the
                -- lookaheads leave no room for less once the last row is
                -- placed.
                nodes = nodes + 1
                if nodes > node_budget then exhausted = true; break end
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
                if solutions >= limit then break end
                lift(r)
            elseif enter(r + 1) then
                r = r + 1
            else
                if exhausted then break end
                if dead then dead[r][keys[r]] = true end
                lift(r)
            end
        else
            -- row r is done: back to row r-1's next combo
            r = r - 1
            if r >= 1 then
                if dead and solutions == before[r] then dead[r][keys[r]] = true end
                lift(r)
            end
        end
    end
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

-- dead: countSolutions' dead ends for this layout, kept from count to count.
local function tweakUntilUnique(n, k, region_id, target, rival, node_budget, dead)
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
                local last = 0
                for _, cell in ipairs(cells) do
                    region_id[cell[1]][cell[2]] = to
                    if cell[1] > last then last = cell[1] end
                end
                -- dead ends above the last changed row may not be any more
                for r = 1, last - 1 do dead[r] = {} end
                moved = true
                break
            end
        end
        if not moved then return false, step - 1 end
        local solutions, exhausted, first, second = countSolutions(n, k, region_id, 2, node_budget, dead)
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
        local dead
        if tweak then
            dead = {}
            for r = 1, n do dead[r] = {} end
        end
        local solutions, exhausted, sol, rival = countSolutions(n, k, region_id, 2, node_budget, dead)
        counts = counts + 1
        local unique = not exhausted and solutions == 1
        if sol and tweak and not unique and not exhausted then
            -- Tweaking keeps sol a solution, so the layout stays a valid
            -- (if unproven) fallback whatever happens.
            local used
            unique, used = tweakUntilUnique(n, k, region_id, sol, rival, node_budget, dead)
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
