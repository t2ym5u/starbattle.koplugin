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
-- Region generation via BFS flood-fill from N random seeds. Since 1.7.0
-- puzzles are built around a star placement instead (regionsAround); this
-- stays for the specs, which count the solutions of random layouts.
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
--
-- Since 1.7.0 the generator no longer uses it (logicSolve proves a puzzle
-- unique as it solves it); the specs keep it as an independent check.
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
-- (what the 1.6 generator did between region tweaks).
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

-- ---------------------------------------------------------------------------
-- Logic solver: the deductions a player makes, never "suppose this cell
-- holds a star and see what breaks". A puzzle is only kept once this solver
-- fills the whole grid from the regions alone; every step it takes is
-- forced, so that also proves the solution unique.
--
--   tier 1  a star empties its eight neighbours; a row, column or region
--           with its k stars has the rest empty; one with exactly as many
--           open cells as missing stars has a star in each.
--   tier 2  counting over a band of m consecutive rows (or columns): when
--           m regions lie entirely inside the band they take all its
--           stars, so the band's other cells are empty; when the band's
--           open cells belong to m regions only, those regions put all
--           their stars inside it, so their cells outside are empty.
--   tier 3  one row, column or region at a time, the ways its missing
--           stars can still sit (never touching, never more than another
--           row/column/region can take): a cell in every way gets a star, a
--           cell in none is empty, and a cell that every way rules out (a
--           neighbour of its stars, or the rest of a row/column/region they
--           fill up) is empty.
--
-- Each pass takes the first deduction of the lowest tier that has one.
-- Cells are numbered (r - 1) * n + c; s[i] is 0 (open), 1 (star) or -1.
-- Returns (solved, s, steps) where steps[t] counts the tier-t passes.
-- ---------------------------------------------------------------------------

-- Per size: king-move neighbours, row and column of each cell.
local geo_cache = {}
local function geometry(n)
    local geo = geo_cache[n]
    if geo then return geo end
    local nb, rowOf, colOf = {}, {}, {}
    for r = 1, n do
        for c = 1, n do
            local i = (r - 1) * n + c
            rowOf[i], colOf[i] = r, c
            local list = {}
            for dr = -1, 1 do
                for dc = -1, 1 do
                    local a, b = r + dr, c + dc
                    if (dr ~= 0 or dc ~= 0) and a >= 1 and a <= n and b >= 1 and b <= n then
                        list[#list + 1] = (a - 1) * n + b
                    end
                end
            end
            nb[i] = list
        end
    end
    geo = { nb = nb, rowOf = rowOf, colOf = colOf }
    geo_cache[n] = geo
    return geo
end

local function logicSolve(n, k, region_id)
    local N = n * n
    local geo = geometry(n)
    local nb, rowOf, colOf = geo.nb, geo.rowOf, geo.colOf
    -- units 1..n: rows, n+1..2n: columns, 2n+1..3n: regions; a cell is in
    -- units rowOf[i], n + colOf[i] and gu[i]
    local nunits = 3 * n
    local units, gu, reg = {}, {}, {}
    for u = 1, nunits do units[u] = {} end
    local s = {}
    for i = 1, N do
        local r, c = rowOf[i], colOf[i]
        s[i] = 0
        local g = region_id[r][c]
        reg[i] = g
        gu[i] = 2 * n + g
        local ur, uc, ug = units[r], units[n + c], units[2 * n + g]
        ur[#ur + 1] = i
        uc[#uc + 1] = i
        ug[#ug + 1] = i
    end
    local open, bad = N, false
    local steps = { 0, 0, 0 }
    -- dirty[u]: unit u may give tier 3 something new. A new empty cell
    -- only changes the placements of its own units (it can't make a
    -- placement rule more out); a new star changes what every unit needs.
    local dirty = {}
    for u = 1, nunits do dirty[u] = true end

    local function setEmpty(i)
        local v = s[i]
        if v == -1 then return end
        if v == 1 then bad = true; return end
        s[i] = -1
        open = open - 1
        dirty[rowOf[i]], dirty[n + colOf[i]], dirty[gu[i]] = true, true, true
    end
    local function setStar(i)
        local v = s[i]
        if v == 1 then return end
        if v == -1 then bad = true; return end
        s[i] = 1
        open = open - 1
        for u = 1, nunits do dirty[u] = true end
        local l = nb[i]
        for x = 1, #l do
            local j = l[x]
            if s[j] == 1 then bad = true elseif s[j] == 0 then s[j] = -1; open = open - 1 end
        end
    end

    local function tier1()
        local progress = false
        for u = 1, nunits do
            local l, t, un = units[u], 0, 0
            for x = 1, #l do
                local v = s[l[x]]
                if v == 1 then t = t + 1 elseif v == 0 then un = un + 1 end
            end
            if t > k or t + un < k then bad = true; return progress end
            if un > 0 and t == k then
                for x = 1, #l do if s[l[x]] == 0 then setEmpty(l[x]) end end
                progress = true
            elseif un > 0 and t + un == k then
                for x = 1, #l do if s[l[x]] == 0 then setStar(l[x]) end end
                progress = true
                if bad then return progress end
            end
        end
        return progress
    end

    -- tier 2: pre[(g - 1) * (n + 1) + x + 1] = region g's open-or-star
    -- cells in lines 1..x of the axis
    local pre, stride = {}, n + 1
    local function tier2()
        for axis = 0, 1 do
            local line = axis == 0 and rowOf or colOf
            for x = 1, n * stride do pre[x] = 0 end
            for i = 1, N do
                if s[i] ~= -1 then
                    local p = (reg[i] - 1) * stride + line[i] + 1
                    pre[p] = pre[p] + 1
                end
            end
            for g = 1, n do
                local base = (g - 1) * stride
                for x = 2, stride do pre[base + x] = pre[base + x] + pre[base + x - 1] end
            end
            for a = 1, n do
                for b = a, n - 1 do
                    local m = b - a + 1
                    local inside, touching = 0, 0
                    for g = 1, n do
                        local base = (g - 1) * stride
                        local here = pre[base + b + 1] - pre[base + a]
                        if here > 0 then
                            touching = touching + 1
                            if here == pre[base + stride] then inside = inside + 1 end
                        end
                    end
                    if inside > m or touching < m then bad = true; return false end
                    if inside == m or touching == m then
                        local progress = false
                        for i = 1, N do
                            if s[i] == 0 then
                                local base = (reg[i] - 1) * stride
                                local here = pre[base + b + 1] - pre[base + a]
                                local inband = line[i] >= a and line[i] <= b
                                if inband then
                                    if inside == m and here ~= pre[base + stride] then
                                        setEmpty(i); progress = true
                                    end
                                elseif touching == m and here > 0 then
                                    setEmpty(i); progress = true
                                end
                            end
                        end
                        if progress then return true end
                    end
                end
            end
        end
        return false
    end

    -- tier 3. A placement pl[1..sz] puts a unit's missing stars; it fits
    -- when no two touch and no unit gets more than it needs (tally: the
    -- placement's stars per unit while it is looked at).
    local need, tally = {}, {}
    for u = 1, nunits do tally[u] = 0 end
    local unk, held, cand, mark = {}, {}, {}, {}
    local pl1, pl2
    local function tallyAdd(i, d)
        local a, b, c = rowOf[i], n + colOf[i], gu[i]
        tally[a] = tally[a] + d
        tally[b] = tally[b] + d
        tally[c] = tally[c] + d
        return tally[a] <= need[a] and tally[b] <= need[b] and tally[c] <= need[c]
    end
    local function full(w)
        local t = tally[w]
        return t > 0 and t == need[w]
    end
    -- open cell j outside the unit is ruled out by the placement looked at
    local function ruledOut(j)
        local rj, cj = rowOf[j], colOf[j]
        if math.abs(rowOf[pl1] - rj) <= 1 and math.abs(colOf[pl1] - cj) <= 1 then return true end
        if pl2 and math.abs(rowOf[pl2] - rj) <= 1 and math.abs(colOf[pl2] - cj) <= 1 then return true end
        return full(rj) or full(n + cj) or full(gu[j])
    end
    -- what the placement looked at rules out, as the first candidates
    local nc, cur_u = 0, 0
    local function add(j)
        if s[j] == 0 and mark[j] ~= cur_u and rowOf[j] ~= cur_u
                and n + colOf[j] ~= cur_u and gu[j] ~= cur_u then
            mark[j] = cur_u
            nc = nc + 1
            cand[nc] = j
        end
    end
    local function addStar(a)
        local l = nb[a]
        for y = 1, #l do add(l[y]) end
        local w = rowOf[a]
        for y = 1, 3 do
            if w ~= cur_u and full(w) then
                local lw = units[w]
                for z = 1, #lw do add(lw[z]) end
            end
            w = y == 1 and n + colOf[a] or gu[a]
        end
    end
    local function collect(u)
        nc, cur_u = 0, u
        addStar(pl1)
        if pl2 then addStar(pl2) end
        return nc
    end

    local function tier3()
        for u = 1, nunits do
            local l, t, un = units[u], 0, 0
            for x = 1, #l do
                local v = s[l[x]]
                if v == 1 then t = t + 1 elseif v == 0 then un = un + 1 end
            end
            need[u] = k - t
        end
        for i = 1, N do mark[i] = 0 end
        -- smallest units first: the fewest ways to look at
        local order, size = {}, {}
        for u = 1, nunits do
            if need[u] > 0 and dirty[u] then
                local l, nu = units[u], 0
                for x = 1, #l do if s[l[x]] == 0 then nu = nu + 1 end end
                order[#order + 1] = u
                size[u] = nu * 64 + u
            end
        end
        table.sort(order, function(a, b) return size[a] < size[b] end)
        for oi = 1, #order do
            local u = order[oi]
            local want = need[u]
            do
                dirty[u] = false
                local l, nu = units[u], 0
                for x = 1, #l do
                    local j = l[x]
                    if s[j] == 0 then nu = nu + 1; unk[nu] = j; held[j] = 0 end
                end
                if nu > want then
                    -- pass 1: how many placements, and which cells they hold
                    local count = 0
                    for a = 1, nu do
                        local ca = unk[a]
                        if want == 1 then
                            if tallyAdd(ca, 1) then
                                count = count + 1
                                held[ca] = held[ca] + 1
                            end
                            tallyAdd(ca, -1)
                        else
                            local oka = tallyAdd(ca, 1)
                            for b = a + 1, nu do
                                local cb = unk[b]
                                if math.abs(rowOf[ca] - rowOf[cb]) > 1 or math.abs(colOf[ca] - colOf[cb]) > 1 then
                                    if tallyAdd(cb, 1) and oka then
                                        count = count + 1
                                        held[ca] = held[ca] + 1
                                        held[cb] = held[cb] + 1
                                    end
                                    tallyAdd(cb, -1)
                                end
                            end
                            tallyAdd(ca, -1)
                        end
                    end
                    if count == 0 then bad = true; return false end
                    local progress = false
                    for x = 1, nu do
                        local j = unk[x]
                        if held[j] == count then setStar(j); progress = true
                        elseif held[j] == 0 then setEmpty(j); progress = true end
                    end
                    if progress or bad then return progress end
                    -- pass 2: the cells outside u every placement rules out
                    local first = true
                    nc = 0
                    for a = 1, nu do
                        if not first and nc == 0 then break end
                        local ca = unk[a]
                        if want == 1 then
                            if tallyAdd(ca, 1) then
                                pl1, pl2 = ca, nil
                                if first then
                                    nc, first = collect(u), false
                                else
                                    local m = 0
                                    for x = 1, nc do
                                        if ruledOut(cand[x]) then m = m + 1; cand[m] = cand[x] end
                                    end
                                    nc = m
                                end
                            end
                            tallyAdd(ca, -1)
                        else
                            local oka = tallyAdd(ca, 1)
                            for b = a + 1, nu do
                                if not first and nc == 0 then break end
                                local cb = unk[b]
                                if math.abs(rowOf[ca] - rowOf[cb]) > 1 or math.abs(colOf[ca] - colOf[cb]) > 1 then
                                    if tallyAdd(cb, 1) and oka then
                                        pl1, pl2 = ca, cb
                                        if first then
                                            nc, first = collect(u), false
                                        else
                                            local m = 0
                                            for x = 1, nc do
                                                if ruledOut(cand[x]) then m = m + 1; cand[m] = cand[x] end
                                            end
                                            nc = m
                                        end
                                    end
                                    tallyAdd(cb, -1)
                                end
                            end
                            tallyAdd(ca, -1)
                        end
                    end
                    for x = 1, nc do setEmpty(cand[x]); progress = true end
                    if progress or bad then return progress end
                end
            end
        end
        return false
    end

    while true do
        if bad then return false, s, steps end
        if open == 0 then
            tier1()
            return not bad, s, steps
        end
        if tier1() then
            steps[1] = steps[1] + 1
        elseif tier2() then
            steps[2] = steps[2] + 1
        elseif not bad and tier3() then
            steps[3] = steps[3] + 1
        else
            return false, s, steps
        end
    end
end

-- A random star placement: k stars per row and column, none touching.
-- Rows are filled in order with their k-column combos shuffled; a column
-- that can no longer reach k stars in the rows left (one every other row)
-- turns the row down. Nil after `budget` rows tried.
local function randomStars(n, k, budget)
    local combos, compat = rowCombos(n, k), rowCompat(n, k)
    local col_count = {}
    for c = 1, n do col_count[c] = 0 end
    local chosen, lists, pos = { [0] = 0 }, {}, {}
    local nodes = 0
    local function enter(r)
        local src = compat[chosen[r - 1]]
        local l = {}
        for i = 1, #src do l[i] = src[i] end
        shuffle(l)
        lists[r], pos[r] = l, 1
    end
    enter(1)
    local r = 1
    while r >= 1 do
        nodes = nodes + 1
        if nodes > budget then return nil end
        local l, pick = lists[r], nil
        while pos[r] <= #l do
            local ci = l[pos[r]]
            pos[r] = pos[r] + 1
            local cb, ok = combos[ci], true
            for i = 1, k do
                if col_count[cb[i]] >= k then ok = false; break end
            end
            if ok then
                for i = 1, k do col_count[cb[i]] = col_count[cb[i]] + 1 end
                local left = n - r
                for c = 1, n do
                    if k - col_count[c] > math.ceil(left / 2) then ok = false; break end
                end
                if ok then
                    pick = ci
                    break
                end
                for i = 1, k do col_count[cb[i]] = col_count[cb[i]] - 1 end
            end
        end
        if pick then
            chosen[r] = pick
            if r == n then
                local sol = emptyGrid(n, n, 0)
                for rr = 1, n do
                    local cb = combos[chosen[rr]]
                    for i = 1, k do sol[rr][cb[i]] = 1 end
                end
                return sol
            end
            r = r + 1
            enter(r)
        else
            r = r - 1
            if r >= 1 then
                local cb = combos[chosen[r]]
                for i = 1, k do col_count[cb[i]] = col_count[cb[i]] - 1 end
            end
        end
    end
    return nil
end

-- n regions around a star placement, k stars each. With k = 2, each star
-- (in random order) is paired with the nearest star still free and the two
-- are joined by a shortest path of free cells; that pair, or the lone star
-- when k = 1, starts a region. Then regions take a random free neighbouring
-- cell in turn until the grid is full (every star is placed by then, so
-- each region keeps exactly k). Nil when a pair can't be joined.
local function joinPath(n, sol, region_id, a, b)
    local parent = { [a[1] * 100 + a[2]] = false }
    local queue, head = { a }, 1
    local dirs = {}
    while head <= #queue do
        local cur = queue[head]
        head = head + 1
        if cur[1] == b[1] and cur[2] == b[2] then
            local path, cell = {}, cur
            while cell do
                path[#path + 1] = cell
                cell = parent[cell[1] * 100 + cell[2]]
            end
            return path
        end
        for i = 1, 4 do dirs[i] = DIR4[i] end
        shuffle(dirs)
        for _, d in ipairs(dirs) do
            local nr, nc = cur[1] + d[1], cur[2] + d[2]
            local key = nr * 100 + nc
            if inBounds(nr, nc, n) and region_id[nr][nc] == 0 and parent[key] == nil
                    and (sol[nr][nc] == 0 or (nr == b[1] and nc == b[2])) then
                parent[key] = cur
                queue[#queue + 1] = { nr, nc }
            end
        end
    end
    return nil
end

local function regionsAround(n, k, sol, small, extra_lo, extra_hi)
    local region_id = emptyGrid(n, n, 0)
    local stars = {}
    for r = 1, n do
        for c = 1, n do
            if sol[r][c] == 1 then stars[#stars + 1] = { r, c } end
        end
    end
    shuffle(stars)
    local frontier, paired, g = {}, {}, 0
    local left = n * n
    for si, a in ipairs(stars) do
        if not paired[si] then
            paired[si] = true
            g = g + 1
            local cells = { a }
            if k == 2 then
                local bj, bd
                for sj = si + 1, #stars do
                    if not paired[sj] then
                        local b = stars[sj]
                        local d = math.abs(a[1] - b[1]) + math.abs(a[2] - b[2])
                        if not bd or d < bd then bj, bd = sj, d end
                    end
                end
                paired[bj] = true
                cells = joinPath(n, sol, region_id, a, stars[bj])
                if not cells then return nil end
            end
            for _, cell in ipairs(cells) do
                region_id[cell[1]][cell[2]] = g
                left = left - 1
            end
            frontier[g] = cells
        end
    end
    -- The first floor(n * small) regions (random ones: the stars were
    -- shuffled) stop at extra_lo to extra_hi cells more than they start with,
    -- unless nothing else can grow.
    local order, dirs = {}, {}
    local cap, size = {}, {}
    for g = 1, n do
        size[g] = #frontier[g]
        cap[g] = g <= math.floor(n * small) and size[g] + math.random(extra_lo, extra_hi) or n * n
    end
    local all = false
    while left > 0 do
        local grew = false
        for g = 1, n do order[g] = g end
        shuffle(order)
        for _, g in ipairs(order) do
            local fr = frontier[g]
            while #fr > 0 and (all or size[g] < cap[g]) do
                local fi = math.random(#fr)
                local cell = fr[fi]
                for i = 1, 4 do dirs[i] = DIR4[i] end
                shuffle(dirs)
                local took = false
                for _, d in ipairs(dirs) do
                    local nr, nc = cell[1] + d[1], cell[2] + d[2]
                    if inBounds(nr, nc, n) and region_id[nr][nc] == 0 then
                        region_id[nr][nc] = g
                        size[g] = size[g] + 1
                        fr[#fr + 1] = { nr, nc }
                        left = left - 1
                        took = true
                        break
                    end
                end
                if took then grew = true; break end
                table.remove(fr, fi)
            end
        end
        if not grew then
            if all then return nil end
            all = true
        else
            all = false
        end
    end
    return region_id
end

-- Whether the region of cell (r, c) stays in one piece, and keeps at least
-- min_size cells, without that cell.
local function regionStaysWhole(region_id, n, r, c, min_size)
    local g = region_id[r][c]
    local start, total = nil, 0
    for rr = 1, n do
        for cc = 1, n do
            if region_id[rr][cc] == g and (rr ~= r or cc ~= c) then
                total = total + 1
                start = start or { rr, cc }
            end
        end
    end
    if total < min_size then return false end
    local seen = { [start[1] * 100 + start[2]] = true }
    local stack, reached = { start }, 1
    while #stack > 0 do
        local cur = table.remove(stack)
        for _, d in ipairs(DIR4) do
            local nr, nc = cur[1] + d[1], cur[2] + d[2]
            local key = nr * 100 + nc
            if inBounds(nr, nc, n) and region_id[nr][nc] == g and not seen[key]
                    and (nr ~= r or nc ~= c) then
                seen[key] = true
                reached = reached + 1
                stack[#stack + 1] = { nr, nc }
            end
        end
    end
    return reached == total
end

local function copyRegions(region_id, n)
    local out = {}
    for r = 1, n do
        out[r] = {}
        for c = 1, n do out[r][c] = region_id[r][c] end
    end
    return out
end

local function openCount(s)
    local o = 0
    for i = 1, #s do if s[i] == 0 then o = o + 1 end end
    return o
end

-- Per size (tuned on 100 seeds each):
--   small   share of the regions that stay small: their stars, the cells
--           joining them, and extra[1] to extra[2] cells more. Small
--           regions give the solver its first steps; with none, a 10x10
--           layout leaves it nothing to start from.
--   max_open  a first solve leaving this many open cells or more starts
--           over at once (those rarely come right with a few tweaks)
--   tweaks  region tweaks per star placement before starting over
local GEN = {
    [6]  = { small = 0.5, extra = { 1, 2 }, max_open = nil, tweaks = 10 },
    [8]  = { small = 0,   extra = { 0, 0 }, max_open = 20,  tweaks = 10 },
    [10] = { small = 0.6, extra = { 0, 1 }, max_open = 20,  tweaks = 10 },
}
local GEN_DEFAULT = GEN[10]
local MAX_ATTEMPTS = 100

-- One puzzle the logic solver fully solves, or nil after MAX_ATTEMPTS star
-- placements. Counts, never the clock, so a seed gives the same puzzle on
-- every device (the Daily Challenge relies on that).
local function buildPuzzle(n, k, on_progress)
    local gen = GEN[n] or GEN_DEFAULT
    local min_size = k == 1 and 2 or 3   -- no region that just gives its stars away
    for attempt = 1, MAX_ATTEMPTS do
        if on_progress then on_progress(attempt / (attempt + 4)) end
        local sol = randomStars(n, k, 20 * n * n)
        local region_id = sol and regionsAround(n, k, sol, gen.small, gen.extra[1], gen.extra[2])
        if region_id then
            local solved, s, steps = logicSolve(n, k, region_id)
            local tweak = 0
            if gen.max_open and openCount(s) >= gen.max_open then tweak = gen.tweaks end
            -- Where the solver gets stuck, an open cell without a star
            -- next to a region whose stars it has all found moves into that
            -- region: there it is empty at once, and its old region has one
            -- place fewer for its stars. The solution keeps k stars per
            -- region, so it stays a solution; the solver then starts over
            -- on the new layout.
            while not solved and tweak < gen.tweaks do
                tweak = tweak + 1
                local done = {}
                for g = 1, n do done[g] = 0 end
                for i = 1, n * n do
                    if s[i] == 1 then
                        local g = region_id[math.floor((i - 1) / n) + 1][(i - 1) % n + 1]
                        done[g] = done[g] + 1
                    end
                end
                local moves = {}
                for i = 1, n * n do
                    local r, c = math.floor((i - 1) / n) + 1, (i - 1) % n + 1
                    if s[i] == 0 and sol[r][c] == 0 then
                        local g = region_id[r][c]
                        for _, d in ipairs(DIR4) do
                            local nr, nc = r + d[1], c + d[2]
                            if inBounds(nr, nc, n) then
                                local h = region_id[nr][nc]
                                if h ~= g and done[h] == k then
                                    moves[#moves + 1] = { r, c, h }
                                end
                            end
                        end
                    end
                end
                shuffle(moves)
                local cand
                for _, mv in ipairs(moves) do
                    if regionStaysWhole(region_id, n, mv[1], mv[2], min_size) then
                        cand = copyRegions(region_id, n)
                        cand[mv[1]][mv[2]] = mv[3]
                        break
                    end
                end
                if not cand then
                    -- none: some open cell without a star moves to a
                    -- neighbouring region, with what it takes to keep
                    -- both whole (regionMove)
                    local xs = {}
                    for i = 1, n * n do
                        local r, c = math.floor((i - 1) / n) + 1, (i - 1) % n + 1
                        if s[i] == 0 and sol[r][c] == 0 then xs[#xs + 1] = { r, c } end
                    end
                    shuffle(xs)
                    for xi = 1, math.min(#xs, 3) do
                        local x = xs[xi]
                        local cells, to = regionMove(region_id, n, x, sol)
                        if cells then
                            local g = region_id[x[1]][x[2]]
                            local left = -#cells
                            for r = 1, n do
                                for c = 1, n do
                                    if region_id[r][c] == g then left = left + 1 end
                                end
                            end
                            if left >= min_size then
                                cand = copyRegions(region_id, n)
                                for _, cell in ipairs(cells) do cand[cell[1]][cell[2]] = to end
                                break
                            end
                        end
                    end
                end
                if not cand then break end
                region_id = cand
                solved, s, steps = logicSolve(n, k, region_id)
            end
            -- a grid the basic rules alone fill is no puzzle: start over
            if solved and steps[2] + steps[3] > 0 then return region_id, sol end
        end
    end
    return nil
end

-- One stored puzzle per size, the fallback should buildPuzzle ever come
-- back empty (never seen in testing): letters are regions, the comment is
-- the solution. Built by buildPuzzle; the specs check that logicSolve
-- solves each one and that it has exactly one solution.
local STORED = {
    [6] = { k = 1, regions = {
            "CCCCFB", -- ....*.
            "CCDFFB", -- .*....
            "CCDDFB", -- ...*..
            "AAADBB", -- *.....
            "AEEDBB", -- ..*...
            "EEDDBB", -- .....*
    } },
    [8] = { k = 2, regions = {
            "AAAAEECC", -- .*.*....
            "AFAFEECC", -- .....*.*
            "AFFFEECC", -- .*.*....
            "BFFHEECC", -- .....*.*
            "BHHHEGGD", -- *.*.....
            "BBHGGGGD", -- ....*.*.
            "BBHHGGGD", -- *.*.....
            "BBHDDDDD", -- ....*.*.
    } },
    [10] = { k = 2, regions = {
            "JJJJAAGGEE", -- .....*..*.
            "HJJAAAGGEE", -- .*.*......
            "HHJJJJGGGE", -- ......*..*
            "HHIJIJGGGG", -- .*..*.....
            "HHIIIJGJJJ", -- ......*.*.
            "HIIIJJJJBJ", -- *..*......
            "HHIIJJJBBB", -- .......*.*
            "HHCCCFFFFF", -- ..*.*.....
            "DDFFCFFFFF", -- *......*..
            "DDDFFFFFFF", -- ..*..*....
    } },
}

-- The stored puzzle for size n with k stars (nil if there is none), with
-- its solution worked out by logicSolve.
local function storedPuzzle(n, k)
    local p = STORED[n]
    if not p or p.k ~= k then return nil end
    local region_id = emptyGrid(n, n, 0)
    for r = 1, n do
        for c = 1, n do region_id[r][c] = p.regions[r]:byte(c) - 64 end
    end
    local solved, s = logicSolve(n, k, region_id)
    if not solved then return nil end
    local sol = emptyGrid(n, n, 0)
    for i = 1, n * n do
        if s[i] == 1 then sol[math.floor((i - 1) / n) + 1][(i - 1) % n + 1] = 1 end
    end
    return region_id, sol
end

-- on_progress (optional): called with a 0..1 fraction as it goes.
function StarBattleBoard:generate(on_progress)
    local n, k = self.n, self.k
    local region_id, sol = buildPuzzle(n, k, on_progress)
    if not region_id then
        -- never seen in testing: a stored puzzle of the same size, also
        -- solved by logicSolve, rather than an unproven one
        region_id, sol = storedPuzzle(n, k)
    end
    if not region_id then
        -- a size the menu doesn't offer (SIZES): the default size's
        n, k = DEFAULT_N, DEFAULT_K
        self.n, self.k = n, k
        region_id, sol = storedPuzzle(n, k)
    end
    self.region_id = region_id
    self.solution  = sol
    self.marks     = emptyGrid(n, n, MARK_EMPTY)
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
StarBattleBoard._logicSolve      = logicSolve
StarBattleBoard._buildPuzzle     = buildPuzzle
StarBattleBoard._storedPuzzle    = storedPuzzle
StarBattleBoard._generateRegions = generateRegions

return StarBattleBoard
