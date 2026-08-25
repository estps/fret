-- disktest.lua - fills the disk with 0.1MB chunks until full
-- reports the total space usable, then cleans up after itself

local CHUNK = 100000          -- 0.1MB per write
local NAME = ".filltest"

print("Disk space at start: " .. fs.getFreeSpace("") / 1000000 .. " MB free")

local files = 0
local total = 0

while true do
    local f = NAME .. "." .. files
    local fh = fs.open(f, "wb")
    if not fh then
        print("fs.open failed on file " .. files)
        break
    end
    local data = string.rep("x", 1024)
    local ok = true
    for i = 1, 100 do        -- 100 x 1KB = ~0.1MB per file
        local w = fh.write(data)
        if not w then
            print("write failed at file " .. files .. ", block " .. i)
            ok = false
            break
        end
    end
    fh.close()
    if not ok then break end
    files = files + 1
    total = total + CHUNK

    local free = fs.getFreeSpace("")
    print(("filled %d files | %.1f MB written | %.2f MB free")
        :format(files, total / 1000000, free / 1000000))

    if free <= 0 then
        print("\nDisk is FULL.")
        break
    end
end

print(("\nRESULT: disk accepted %.2f MB across %d files (0.1 MB each)")
    :format(total / 1000000, files))
print(("fs.getFreeSpace reported %.2f MB remaining")
    :format(fs.getFreeSpace("") / 1000000))

io.write("Delete test files? [y/N] ")
local ans = read()
if ans:lower():sub(1, 1) == "y" then
    for i = 0, files - 1 do
        local f = NAME .. "." .. i
        if fs.exists(f) then fs.delete(f) end
    end
    print("Deleted. Free space: " .. fs.getFreeSpace("") / 1000000 .. " MB")
else
    print("Left in place. Remove later with: rm .filltest.*")
end
