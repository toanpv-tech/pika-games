-- libs/maze — pure maze generation and graph queries (no engine calls)
-- Resolve: require("libs/maze")
--
-- Ports input/word_maze.html genMaze / openDirs / bfsDist / bfsNextStep, including
-- the avoid-cell parameter that fixes the key-deadlock bug documented in GDD 6.2b.
--
-- Layout: the grid is a flat array of wall-mask bytes indexed (y-1)*cols + x, so a
-- whole map is one Lua table with an array part only. Cell tables would be up to
-- 91 small hash tables to pointer-chase through PSRAM.
--
-- Every buffer here is preallocated by M.new() and reused, so generating a map
-- allocates nothing after the first one.

local CFG = require("libs/config")

local M = {}
local Maze = {}
Maze.__index = Maze

local DIRS, OPP = CFG.DIRS, CFG.OPP
local WALL_ALL = CFG.WALL_T | CFG.WALL_R | CFG.WALL_B | CFG.WALL_L

-- Preallocate for the largest ladder grid so no map entry grows a table.
local MAX_CELLS = CFG.MAX_COLS * CFG.MAX_ROWS

function M.new()
  local self = setmetatable({
    cols = 0, rows = 0, n = 0,
    walls = {},     -- [i] = wall mask
    visited = {},   -- generation scratch
    stack = {},     -- explicit stack; no recursion (32 KB engine task stack)
    dist = {},      -- BFS distance scratch
    queue = {},     -- BFS queue scratch
    prev = {},      -- BFS parent scratch
    dir_buf = {},   -- reusable result buffer for open_dirs(); shared, copy if held
  }, Maze)
  for i = 1, MAX_CELLS do
    self.walls[i] = WALL_ALL
    self.visited[i] = false
    self.stack[i] = 0
    self.dist[i] = -1
    self.queue[i] = 0
    self.prev[i] = 0
  end
  for d = 1, 4 do self.dir_buf[d] = 0 end
  return self
end

function Maze:index(x, y) return (y - 1) * self.cols + x end

-- Bounds guard for any caller that derives a coordinate rather than walking one.
--
-- Deliberately kept with no call site today: generate() never opens a wall on the
-- outer edge, so every walk that steps only through open walls (start_move,
-- monster AI, BFS) is bounded by construction and does not need the check. It is
-- the entry point for code that computes a cell directly, which has no such
-- guarantee -- and where the failure is silent rather than loud: walls[] is
-- preallocated to MAX_COLS*MAX_ROWS, so on a small map an out-of-range x wraps
-- into a neighbouring row's cell instead of indexing nil.
function Maze:in_bounds(x, y)
  return x >= 1 and x <= self.cols and y >= 1 and y <= self.rows
end

-- True when the wall on side `dir` of (x,y) is closed.
function Maze:has_wall(x, y, dir)
  return (self.walls[(y - 1) * self.cols + x] & DIRS[dir].bit) ~= 0
end

-- Fill self.open_dirs / self.open_n with the passable directions from (x,y).
-- Iteration order is HTML's DIRS order (up, right, down, left), which the demo's
-- "first open direction" behaviours depend on.
function Maze:open_dirs(x, y)
  local mask = self.walls[(y - 1) * self.cols + x]
  local out, k = self.dir_buf, 0
  for d = 1, 4 do
    if (mask & DIRS[d].bit) == 0 then
      k = k + 1
      out[k] = d
    end
  end
  return out, k
end

function Maze:open_count(x, y)
  local mask = self.walls[(y - 1) * self.cols + x]
  local k = 0
  for d = 1, 4 do
    if (mask & DIRS[d].bit) == 0 then k = k + 1 end
  end
  return k
end

-- DFS backtracker + braiding, matching HTML genMaze(). `rng_u32` is injected so
-- the caller owns the seed and runs stay reproducible.
function Maze:generate(cols, rows, braid, rng_u32)
  self.cols, self.rows = cols, rows
  local n = cols * rows
  self.n = n
  local walls, visited = self.walls, self.visited
  for i = 1, n do
    walls[i] = WALL_ALL
    visited[i] = false
  end

  local stack = self.stack
  local top = 1
  stack[1] = 1              -- start at (1,1), HTML's (0,0)
  visited[1] = true

  local cand = self.queue    -- reuse the BFS queue buffer as the neighbour list
  while top > 0 do
    local i = stack[top]
    local x = ((i - 1) % cols) + 1
    local y = ((i - 1) // cols) + 1
    local k = 0
    for d = 1, 4 do
      local nx, ny = x + DIRS[d].dx, y + DIRS[d].dy
      if nx >= 1 and nx <= cols and ny >= 1 and ny <= rows
         and not visited[(ny - 1) * cols + nx] then
        k = k + 1
        cand[k] = d
      end
    end
    if k == 0 then
      top = top - 1
    else
      local d = cand[(rng_u32() % k) + 1]
      local nx, ny = x + DIRS[d].dx, y + DIRS[d].dy
      local ni = (ny - 1) * cols + nx
      walls[i] = walls[i] & ~DIRS[d].bit
      walls[ni] = walls[ni] & ~DIRS[OPP[d]].bit
      visited[ni] = true
      top = top + 1
      stack[top] = ni
    end
  end

  -- Braiding: punch extra openings to create loops. braid is a probability per
  -- cell, so it is compared against a 0..99 draw exactly like the demo.
  local pct = braid * 100
  for y = 1, rows do
    for x = 1, cols do
      if (rng_u32() % 100) < pct then
        local i = (y - 1) * cols + x
        local k = 0
        for d = 1, 4 do
          local nx, ny = x + DIRS[d].dx, y + DIRS[d].dy
          if nx >= 1 and nx <= cols and ny >= 1 and ny <= rows
             and (walls[i] & DIRS[d].bit) ~= 0 then
            k = k + 1
            cand[k] = d
          end
        end
        if k > 0 then
          local d = cand[(rng_u32() % k) + 1]
          local nx, ny = x + DIRS[d].dx, y + DIRS[d].dy
          local ni = (ny - 1) * cols + nx
          walls[i] = walls[i] & ~DIRS[d].bit
          walls[ni] = walls[ni] & ~DIRS[OPP[d]].bit
        end
      end
    end
  end
end

-- BFS distances from (sx,sy) into self.dist (-1 = unreachable).
-- `avoid_i` (optional) is treated as impassable, never entered. This is the fix
-- from GDD 6.2b: the key must be reachable without passing through the cage cell,
-- otherwise a locked cage can make the key unobtainable.
function Maze:bfs_dist(sx, sy, avoid_i)
  local cols, n = self.cols, self.n
  local dist, queue, walls = self.dist, self.queue, self.walls
  for i = 1, n do dist[i] = -1 end
  local si = (sy - 1) * cols + sx
  dist[si] = 0
  queue[1] = si
  local head, tail = 1, 1
  while head <= tail do
    local i = queue[head]
    head = head + 1
    local x = ((i - 1) % cols) + 1
    local y = ((i - 1) // cols) + 1
    local dc = dist[i]
    local mask = walls[i]
    for d = 1, 4 do
      if (mask & DIRS[d].bit) == 0 then
        local nx, ny = x + DIRS[d].dx, y + DIRS[d].dy
        local ni = (ny - 1) * cols + nx
        if ni ~= avoid_i and dist[ni] < 0 then
          dist[ni] = dc + 1
          tail = tail + 1
          queue[tail] = ni
        end
      end
    end
  end
  return dist
end

-- First step of a shortest path from (sx,sy) to (tx,ty); nil when unreachable.
-- Used by the chaser (HTML bfsNextStep).
function Maze:next_step(sx, sy, tx, ty)
  local cols, n = self.cols, self.n
  local prev, queue, walls = self.prev, self.queue, self.walls
  for i = 1, n do prev[i] = 0 end
  local si = (sy - 1) * cols + sx
  local ti = (ty - 1) * cols + tx
  if si == ti then return nil end
  prev[si] = si
  queue[1] = si
  local head, tail = 1, 1
  local found = false
  while head <= tail do
    local i = queue[head]
    head = head + 1
    if i == ti then
      found = true
      break
    end
    local x = ((i - 1) % cols) + 1
    local y = ((i - 1) // cols) + 1
    local mask = walls[i]
    for d = 1, 4 do
      if (mask & DIRS[d].bit) == 0 then
        local nx, ny = x + DIRS[d].dx, y + DIRS[d].dy
        local ni = (ny - 1) * cols + nx
        if prev[ni] == 0 then
          prev[ni] = i
          tail = tail + 1
          queue[tail] = ni
        end
      end
    end
  end
  if not found then return nil end
  -- Walk back to the cell whose parent is the start.
  local cur = ti
  while prev[cur] ~= si do
    cur = prev[cur]
    if cur == 0 then return nil end
  end
  return ((cur - 1) % cols) + 1, ((cur - 1) // cols) + 1
end

return M
