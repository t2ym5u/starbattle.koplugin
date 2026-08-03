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
