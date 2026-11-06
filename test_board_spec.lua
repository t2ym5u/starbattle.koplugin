local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("StarBattleBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    -- Regression guard for the 2026-07-21 bug: 91% of attempts at n=8/k=2
    -- fell back to a hardcoded 6×6/k=1 layout that silently overrides the
    -- requested n/k (`self.n = 6; self.k = 1` in the fallback branch). The
    -- fix raised max_attempts 10->500. These tests assert the board actually
    -- honors the requested size/k instead of silently downgrading.
    local function newBoard(n, k)
        math.randomseed(42)
        return Board:new{ n = n or 8, k = k or 2 }
    end

    describe("construction", function()
        it("creates an 8×8/k=2 board by default", function()
            local b = Board:new()
            assert.are.equal(8, b.n)
            assert.are.equal(2, b.k)
        end)
    end)

    describe("generate", function()
        it("honors the requested n/k instead of falling back", function()
            for _, size in ipairs(Board.SIZES) do
                math.randomseed(size.n * 1000 + size.k)
                local b = Board:new{ n = size.n, k = size.k }
                assert.are.equal(size.n, b.n, ("n silently downgraded for requested n=%d k=%d"):format(size.n, size.k))
                assert.are.equal(size.k, b.k, ("k silently downgraded for requested n=%d k=%d"):format(size.n, size.k))
            end
        end)

        it("solution has exactly k stars per row, column and region, no two adjacent", function()
            local b = newBoard(8, 2)
            local n, k = b.n, b.k
            local row_stars, col_stars, reg_stars = {}, {}, {}
            for i = 1, n do row_stars[i] = 0; col_stars[i] = 0 end
            for r = 1, n do
                for c = 1, n do
                    if b.solution[r][c] == 1 then
                        row_stars[r] = row_stars[r] + 1
                        col_stars[c] = col_stars[c] + 1
                        local rid = b.region_id[r][c]
                        reg_stars[rid] = (reg_stars[rid] or 0) + 1
                        for dr = -1, 1 do
                            for dc = -1, 1 do
                                if not (dr == 0 and dc == 0) then
                                    local nr, nc = r + dr, c + dc
                                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                                        assert.are_not.equal(1, b.solution[nr] and b.solution[nr][nc],
                                            ("adjacent stars at [%d][%d] and [%d][%d]"):format(r, c, nr, nc))
                                    end
                                end
                            end
                        end
                    end
                end
            end
            for i = 1, n do
                assert.are.equal(k, row_stars[i], ("row %d has %d stars, want %d"):format(i, row_stars[i], k))
                assert.are.equal(k, col_stars[i], ("col %d has %d stars, want %d"):format(i, col_stars[i], k))
            end
            for _, count in pairs(reg_stars) do
                assert.are.equal(k, count)
            end
        end)
    end)

    -- 1.5.0: a row-at-a-time solver with column/region lookahead replaced
    -- the cell-by-cell one, and 10x10 layouts with rivals get their regions
    -- tweaked (10x10 took 3-7 s on a desktop). Keep the old solver here and
    -- check the new one agrees with it, solutions included, and that every
    -- size still yields uniquely solvable puzzles, quickly.
    describe("solver and generator", function()
        local function emptyGrid(n, m, v)
            local g = {}
            for r = 1, n do
                g[r] = {}
                for c = 1, m do g[r][c] = v end
            end
            return g
        end
        local function inBounds(r, c, n)
            return r >= 1 and r <= n and c >= 1 and c <= n
        end

        -- The pre-1.5.0 solver, verbatim.
        local function oldCountSolutions(n, k, region_id, limit, node_budget)
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

            local solutions, nodes, exhausted = 0, 0, false
            local first_solution = nil

            local function pickCols(r, start_c, placed)
                if solutions >= limit or exhausted then return end
                nodes = nodes + 1
                if nodes > node_budget then exhausted = true; return end

                if placed == k then
                    if r == n then
                        solutions = solutions + 1
                        if not first_solution then
                            first_solution = emptyGrid(n, n, 0)
                            for rr = 1, n do
                                for cc = 1, n do first_solution[rr][cc] = solution[rr][cc] end
                            end
                        end
                        return
                    end
                    pickCols(r + 1, 1, 0)
                    return
                end
                local remaining_cols = n - start_c + 1
                local needed = k - placed
                if remaining_cols < needed then return end

                for c = start_c, n do
                    local reg = region_id[r][c]
                    if col_count[c] < k and reg_count[reg] < k and not isAdjacent(r, c) then
                        solution[r][c] = 1
                        row_count[r] = row_count[r] + 1
                        col_count[c] = col_count[c] + 1
                        reg_count[reg] = reg_count[reg] + 1

                        pickCols(r, c + 1, placed + 1)

                        solution[r][c] = 0
                        row_count[r] = row_count[r] - 1
                        col_count[c] = col_count[c] - 1
                        reg_count[reg] = reg_count[reg] - 1
                        if solutions >= limit or exhausted then return end
                    end
                end
            end

            pickCols(1, 1, 0)
            return solutions, exhausted, first_solution
        end
        it("counts the same solutions as the old solver on random layouts", function()
            for _, size in ipairs({ {6, 1}, {8, 2}, {10, 2} }) do
                local n, k = size[1], size[2]
                for seed = 1, (n == 10 and 12 or 40) do
                    math.randomseed(seed * 104729 + n)
                    local reg = Board._generateRegions(n)
                    local so, eo, fo = oldCountSolutions(n, k, reg, 2, 3000000)
                    local sn, en, fn = Board._countSolutions(n, k, reg, 2, 3000000)
                    assert.is_false(eo)
                    assert.is_false(en)
                    assert.are.equal(so, sn)
                    if so > 0 then assert.are.same(fo, fn) end
                end
            end
        end)

        -- 1.6.0: the dead ends a count finds are kept for the next count
        -- of a layout changed only in rows up to some row (the tweaks), for
        -- the rows at or below it. Same counts and solutions as counting
        -- from nothing (also checked against 1.5.0 on 12,000 counts).
        it("keeps dead ends across recounts of a tweaked layout", function()
            local function same(a, b)
                if a == nil or b == nil then return a == b end
                for r = 1, #a do
                    for c = 1, #a do
                        if a[r][c] ~= b[r][c] then return false end
                    end
                end
                return true
            end
            for _, size in ipairs({ {6, 1}, {8, 2}, {10, 2} }) do
                local n, k = size[1], size[2]
                for seed = 1, (n == 10 and 4 or 10) do
                    math.randomseed(seed * 7177 + n)
                    local reg = Board._generateRegions(n)
                    local dead = {}
                    for r = 1, n do dead[r] = {} end
                    for _ = 1, 5 do
                        local s1, e1, f1, g1 = Board._countSolutions(n, k, reg, 2, 3000000)
                        local s2, e2, f2, g2 = Board._countSolutions(n, k, reg, 2, 3000000, dead)
                        assert.are.equal(s1, s2)
                        assert.are.equal(e1, e2)
                        assert.is_true(same(f1, f2) and same(g1, g2))
                        local r, c = math.random(n), math.random(n)
                        local nr = math.max(1, math.min(n, r + math.random(-1, 1)))
                        reg[r][c] = reg[nr][c]
                        for rr = 1, r - 1 do dead[rr] = {} end
                    end
                end
            end
        end)

        it("builds uniquely solvable puzzles quickly at every size", function()
            for _, size in ipairs(Board.SIZES) do
                local worst = 0
                for seed = 1, 12 do
                    math.randomseed(seed * 7919 + size.n)
                    local t0 = os.clock()
                    local b = Board:new{ n = size.n, k = size.k }
                    worst = math.max(worst, os.clock() - t0)
                    local count, exhausted, sol = Board._countSolutions(size.n, size.k, b.region_id, 2, 3000000)
                    assert.is_false(exhausted)
                    assert.are.equal(1, count, ("n=%d seed %d not unique"):format(size.n, seed))
                    assert.are.same(b.solution, sol)
                    -- regions stay connected, n of them
                    local seen_regions = {}
                    for r = 1, size.n do
                        for c = 1, size.n do seen_regions[b.region_id[r][c]] = true end
                    end
                    local count_regions = 0
                    for g in pairs(seen_regions) do
                        count_regions = count_regions + 1
                        local start
                        local cells = 0
                        for r = 1, size.n do
                            for c = 1, size.n do
                                if b.region_id[r][c] == g then
                                    cells = cells + 1
                                    start = start or { r, c }
                                end
                            end
                        end
                        local seen, stack, reached = { [start[1] * 100 + start[2]] = true }, { start }, 1
                        while #stack > 0 do
                            local cur = table.remove(stack)
                            for _, d in ipairs({ {-1,0},{1,0},{0,-1},{0,1} }) do
                                local nr, nc = cur[1] + d[1], cur[2] + d[2]
                                if inBounds(nr, nc, size.n) and b.region_id[nr][nc] == g
                                        and not seen[nr * 100 + nc] then
                                    seen[nr * 100 + nc] = true
                                    reached = reached + 1
                                    stack[#stack + 1] = { nr, nc }
                                end
                            end
                        end
                        assert.are.equal(cells, reached, ("region %d split"):format(g))
                    end
                    assert.are.equal(size.n, count_regions)
                end
                -- generous: well under 0.5 s on a desktop
                assert.is_true(worst < 3.0, ("n=%d took %.2f s"):format(size.n, worst))
            end
        end)
    end)

    -- 1.7.0: a puzzle is kept only once a logic solver that never guesses
    -- (no "suppose a star here and see what breaks") fills the grid from
    -- the regions alone. Before, 10x10 puzzles needed trial and error 29
    -- times out of 30, and the fallbacks could hand out an unproven layout
    -- or silently switch to 6x6.
    describe("logic solver and generator (1.7.0)", function()
        local SEEDS = 30

        local function regionSizes(b)
            local sizes = {}
            for r = 1, b.n do
                for c = 1, b.n do
                    local g = b.region_id[r][c]
                    sizes[g] = (sizes[g] or 0) + 1
                end
            end
            return sizes
        end

        local function toGrid(n, s)
            local g = {}
            for r = 1, n do
                g[r] = {}
                for c = 1, n do g[r][c] = s[(r - 1) * n + c] == 1 and 1 or 0 end
            end
            return g
        end

        it("solves every puzzle without guessing, and it is the only solution", function()
            for _, size in ipairs(Board.SIZES) do
                local n, k = size.n, size.k
                for seed = 1, SEEDS do
                    math.randomseed(seed * 1009 + n)
                    local b = Board:new{ n = n, k = k }
                    assert.are.equal(n, b.n)
                    assert.are.equal(k, b.k)
                    local solved, s, steps = Board._logicSolve(n, k, b.region_id)
                    assert.is_true(solved, ("n=%d seed %d needs guessing"):format(n, seed))
                    assert.are.same(b.solution, toGrid(n, s))
                    -- more than the basic rules
                    assert.is_true(steps[2] + steps[3] > 0, ("n=%d seed %d trivial"):format(n, seed))
                    local count, exhausted, sol = Board._countSolutions(n, k, b.region_id, 2, 3000000)
                    assert.is_false(exhausted)
                    assert.are.equal(1, count, ("n=%d seed %d not unique"):format(n, seed))
                    assert.are.same(b.solution, sol)
                    -- n regions, none that just gives its stars away
                    local sizes, regions = regionSizes(b), 0
                    for _, cells in pairs(sizes) do
                        regions = regions + 1
                        assert.is_true(cells >= (k == 1 and 2 or 3))
                    end
                    assert.are.equal(n, regions)
                end
            end
        end)

        it("builds the same puzzle from the same seed", function()
            for _, size in ipairs(Board.SIZES) do
                math.randomseed(777)
                local a = Board:new{ n = size.n, k = size.k }
                math.randomseed(777)
                local b = Board:new{ n = size.n, k = size.k }
                assert.are.same(a.region_id, b.region_id)
                assert.are.same(a.solution, b.solution)
            end
        end)

        it("keeps a stored puzzle per size, solved without guessing", function()
            for _, size in ipairs(Board.SIZES) do
                local n, k = size.n, size.k
                local region_id, sol = Board._storedPuzzle(n, k)
                assert.is_not_nil(region_id, ("no stored %dx%d puzzle"):format(n, n))
                local count, exhausted, only = Board._countSolutions(n, k, region_id, 2, 3000000)
                assert.is_false(exhausted)
                assert.are.equal(1, count)
                assert.are.same(only, sol)
            end
        end)

        -- Every deduction is forced: whenever the solver fills a random
        -- layout, that layout has exactly that one solution, and it never
        -- fills one that has none. (Checked on 5,962 layouts while writing
        -- it, 883 of them filled: 0 mismatches.)
        it("never claims a layout the backtracking count disagrees with", function()
            for _, size in ipairs(Board.SIZES) do
                local n, k = size.n, size.k
                for seed = 1, (n == 10 and 15 or 60) do
                    math.randomseed(seed * 4099 + n)
                    local reg = Board._generateRegions(n)
                    local solved, s = Board._logicSolve(n, k, reg)
                    local count, exhausted, sol = Board._countSolutions(n, k, reg, 2, 3000000)
                    assert.is_false(exhausted)
                    if solved then
                        assert.are.equal(1, count)
                        assert.are.same(sol, toGrid(n, s))
                    end
                end
            end
        end)

        -- generous bound for busted's plain Lua; LuaJIT on a desktop takes
        -- under 40 ms per puzzle at worst (about 1 s on a Kobo Aura)
        it("builds a puzzle quickly at every size", function()
            for _, size in ipairs(Board.SIZES) do
                local worst = 0
                for seed = 1, 10 do
                    math.randomseed(seed * 31 + size.n)
                    local t0 = os.clock()
                    Board:new{ n = size.n, k = size.k }
                    worst = math.max(worst, os.clock() - t0)
                end
                assert.is_true(worst < 1.0, ("n=%d took %.2f s"):format(size.n, worst))
            end
        end)

        it("loads a 1.6 save", function()
            -- a 6x6 game saved by 1.6.1, one star placed
            local data = {
                n = 6, k = 1, won = false,
                region_id = { 3,3,3,3,6,2, 3,3,4,6,6,2, 3,3,4,4,6,2,
                              1,1,1,4,2,2, 1,5,5,4,2,2, 5,5,4,4,2,2 },
                solution  = { 0,0,0,0,1,0, 0,1,0,0,0,0, 0,0,0,1,0,0,
                              1,0,0,0,0,0, 0,0,1,0,0,0, 0,0,0,0,0,1 },
                marks     = { 0,0,0,0,1,0, 0,0,0,0,0,0, 0,0,0,0,0,0,
                              0,0,0,0,0,0, 0,0,0,0,0,0, 0,0,0,0,0,0 },
            }
            local b = Board:new{ empty = true }
            assert.is_true(b:load(data))
            assert.are.equal(6, b.n)
            assert.are.equal(1, b.k)
            assert.are.equal(Board.MARK_STAR, b.marks[1][5])
            assert.are.equal(1, b:countStars())
            b:reveal()
            assert.is_true(b.won)
        end)
    end)

    describe("cycleCell / getConflicts / reveal", function()
        it("cycles a cell EMPTY→STAR→DOT→EMPTY", function()
            local b = newBoard(8, 2)
            assert.are.equal(Board.MARK_EMPTY, b.marks[1][1])
            b:cycleCell(1, 1)
            assert.are.equal(Board.MARK_STAR, b.marks[1][1])
            b:cycleCell(1, 1)
            assert.are.equal(Board.MARK_DOT, b.marks[1][1])
            b:cycleCell(1, 1)
            assert.are.equal(Board.MARK_EMPTY, b.marks[1][1])
        end)

        it("reveal matches the solution and wins", function()
            local b = newBoard(8, 2)
            b:reveal()
            assert.is_true(b.won)
            assert.are.equal(b:totalStars(), b:countStars())
        end)

        it("getConflicts flags row overflow", function()
            local b = newBoard(6, 1)
            -- place k+1 stars in row 1 far enough apart to avoid adjacency conflicts
            b.marks[1][1] = Board.MARK_STAR
            b.marks[1][4] = Board.MARK_STAR
            local conflicts = b:getConflicts()
            assert.is_true(conflicts[1][1])
            assert.is_true(conflicts[1][4])
        end)
    end)

    describe("undoMove", function()
        it("restores the previous mark", function()
            local b = newBoard(8, 2)
            b:cycleCell(1, 1)
            assert.are.equal(Board.MARK_STAR, b.marks[1][1])
            local ok = b:undoMove()
            assert.is_true(ok)
            assert.are.equal(Board.MARK_EMPTY, b.marks[1][1])
        end)
    end)

    describe("serialize / load", function()
        it("round-trips region, solution and marks", function()
            local b = newBoard(8, 2)
            b:cycleCell(1, 1)
            local data = b:serialize()
            local b2   = Board:new{ n = b.n, k = b.k }
            local ok   = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            assert.are.equal(b.k, b2.k)
            assert.are.equal(b.marks[1][1], b2.marks[1][1])
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
end)
