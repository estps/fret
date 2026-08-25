-- disktest.lua - fills a filesystem with 0.1MB chunks until full
-- usage: disktest [path]
--   no arg  -> computer's own root
--   disk    -> first floppy, disk2 -> another, etc.

local CHUNK = 100000          -- 0.1MB per file
local NAME = ".filltest"

local target = ...
if not target or #target == 0 then target = "" end

print("Mounted filesystems:")
for _, d in ipairs(fs.list("")) do
    if fs.isDir(d) and not fs.isReadOnly(d) then
        print(("  %s: %.2f MB free"):format(d, fs.getFreeSpace(d) / 1e6))
    end
end
print(("  %s (root): %.2f MB free")
    :format("", fs.getFreeSpace("") / 1e6))
print(("Filling '%s' (%.2f MB free at start)")
    :format(#target > 0 and target or "<root>", fs.getFreeSpace(target) / 1e6))

local function p(f) return fs.combine(target, f) end

-- clean up any previous aborted run
for _, f in ipairs(fs.list(target)) do
    if f:match("^" .. NAME .. "%.%d+$") then fs.delete(p(f)) end
end

local files = 0
local total = 0

while true do
    local f = p(NAME .. "." .. files)
    local fh = fs.open(f, "wb")
    if not fh then
        print("fs.open failed on file " .. files .. " (limit reached?)")
        break
    end
    local data = string.rep("x", 1024)
    local ok = true
    for i = 1, 100 do        -- 100 x 1KB = ~0.1MB per file
        if not fh.write(data) then
            print("write failed at file " .. files .. ", block " .. i)
            ok = false
            break
        end
    end
    fh.close()
    if not ok then break end
    files = files + 1
    total = total + CHUNK

    local free = fs.getFreeSpace(target)
    if files % 5 == 0 or free <= 0 then
        print(("filled %d files | %.1f MB written | %.2f MB free")
            :format(files, total / 1e6, free / 1e6))
    end
    if free <= 0 then
        print("\nDisk is FULL.")
        break
    end
end

print(("\nRESULT: '%s' accepted %.2f MB across %d files")
    :format(#target > 0 and target or "<root>", total / 1e6, files))
print(("fs.getFreeSpace now reports %.2f MB remaining")
    :format(fs.getFreeSpace(target) / 1e6))

io.write("Delete test files? [y/N] ")
local ans = read()
if ans:lower():sub(1, 1) == "y" then
    for i = 0, files - 1 do
        local f = p(NAME .. "." .. i)
        if fs.exists(f) then fs.delete(f) end
    end
    print(("Deleted. Free space: %.2f MB")
        :format(fs.getFreeSpace(target) / 1e6))
else
    print("Left in place. Remove later from '" .. (#target > 0 and target or "root") .. "'.")
end
