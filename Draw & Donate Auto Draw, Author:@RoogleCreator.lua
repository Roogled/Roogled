local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local LocalDrawingCanvas = nil

local BotConfig = {
    Enabled = false,
    ImageURL = "",
    InstantDraw = false
}

-- -----------------------------------------------------------------
-- 1. БИТОВЫЕ ОПЕРАЦИИ через bit32 (Roblox)
-- -----------------------------------------------------------------
local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- -----------------------------------------------------------------
-- 2. БИНАРНЫЙ РИДЕР (без внешних библиотек)
-- -----------------------------------------------------------------
local BinaryReader = {}
BinaryReader.__index = BinaryReader

function BinaryReader.new(data)
    local self = setmetatable({}, BinaryReader)
    self.Data = data
    self.Position = 1
    self.Length = #data
    return self
end

function BinaryReader:ReadString(length)
    if self.Position + length - 1 > self.Length then return "" end
    local str = string.sub(self.Data, self.Position, self.Position + length - 1)
    self.Position = self.Position + length
    return str
end

function BinaryReader:ReadByte()
    if self.Position > self.Length then return 0 end
    local byte = string.byte(self.Data, self.Position)
    self.Position = self.Position + 1
    return byte or 0
end

function BinaryReader:ReadBytes(n, asTable)
    if self.Position + n - 1 > self.Length then n = self.Length - self.Position + 1 end
    local bytes = string.sub(self.Data, self.Position, self.Position + n - 1)
    self.Position = self.Position + n
    if asTable then
        local t = {}
        for i = 1, #bytes do t[i] = string.byte(bytes, i) end
        return t
    end
    return bytes
end

function BinaryReader:ReadUInt32()
    local b1 = self:ReadByte()
    local b2 = self:ReadByte()
    local b3 = self:ReadByte()
    local b4 = self:ReadByte()
    return lshift(b1, 24) + lshift(b2, 16) + lshift(b3, 8) + b4
end

function BinaryReader:ReadInt32()
    local val = self:ReadUInt32()
    if val >= 2^31 then val = val - 2^32 end
    return val
end

function BinaryReader:ForkReader(length)
    if self.Position + length - 1 > self.Length then length = self.Length - self.Position + 1 end
    local sub = string.sub(self.Data, self.Position, self.Position + length - 1)
    self.Position = self.Position + length
    return BinaryReader.new(sub)
end

-- -----------------------------------------------------------------
-- 3. INFLATE (Zlib) – реализация на Lua с bit32
-- -----------------------------------------------------------------
local Inflate = {}

local function buildFixedTables()
    local bitlen = {}
    for i = 0, 143 do bitlen[i+1] = 8 end
    for i = 144, 255 do bitlen[i+1] = 9 end
    for i = 256, 279 do bitlen[i+1] = 7 end
    for i = 280, 287 do bitlen[i+1] = 8 end
    local codes, nextCode = {}, 0
    for i = 1, 288 do
        local len = bitlen[i]
        if len then
            codes[i-1] = { code = nextCode, len = len }
            nextCode = nextCode + 1
        end
    end
    local distCodes = {}
    for i = 1, 32 do distCodes[i-1] = { code = i-1, len = 5 } end
    return codes, distCodes
end

local fixedLitCodes, fixedDistCodes = buildFixedTables()

local function buildHuffmanTree(codes)
    local maxBits = 0
    for _, v in pairs(codes) do if v.len > maxBits then maxBits = v.len end end
    local blCount = {}
    for i = 1, maxBits do blCount[i] = 0 end
    for _, v in pairs(codes) do blCount[v.len] = (blCount[v.len] or 0) + 1 end
    local nextCode = {}
    local code = 0
    for bits = 1, maxBits do
        code = lshift((code + (blCount[bits-1] or 0)), 1)
        nextCode[bits] = code
    end
    local tree = {}
    for _, v in pairs(codes) do
        if v.len > 0 then
            local val = nextCode[v.len]
            tree[val] = v.symbol
            nextCode[v.len] = val + 1
        end
    end
    return tree, maxBits
end

local function readBits(reader, n)
    if not reader.bitBuffer then reader.bitBuffer = 0; reader.bitCount = 0 end
    while reader.bitCount < n do
        local byte = reader:ReadByte()
        if byte == nil then error("EOF") end
        reader.bitBuffer = bor(reader.bitBuffer, lshift(byte, reader.bitCount))
        reader.bitCount = reader.bitCount + 8
    end
    local mask = (1 << n) - 1   -- здесь << допустим только в математическом смысле, но в Lua 5.1 нет. Заменим:
    -- В Lua 5.1 нет оператора <<, но для маски можно вычислить через 2^n
    mask = 2^n - 1
    local val = band(reader.bitBuffer, mask)
    reader.bitBuffer = rshift(reader.bitBuffer, n)
    reader.bitCount = reader.bitCount - n
    return val
end

local function decodeSymbol(reader, tree, maxBits)
    local code = 0
    for len = 1, maxBits do
        local bit = readBits(reader, 1)
        code = bor(code, lshift(bit, len-1))
        local sym = tree[code]
        if sym ~= nil then return sym end
    end
    error("Bad Huffman code")
end

local function inflateBlock(reader, outputFunc)
    local last = readBits(reader, 1)
    local btype = readBits(reader, 2)
    if btype == 0 then
        -- uncompressed
        readBits(reader, (4 - reader.bitCount) % 4)
        local len = reader:ReadUInt32()
        local nlen = reader:ReadUInt32()
        for i = 1, len do
            local byte = reader:ReadByte()
            outputFunc(byte)
        end
    elseif btype == 1 or btype == 2 then
        local litTree, distTree, litMaxBits, distMaxBits
        if btype == 1 then
            litTree, litMaxBits = buildHuffmanTree(fixedLitCodes)
            distTree, distMaxBits = buildHuffmanTree(fixedDistCodes)
        else
            local hlit = readBits(reader, 5) + 257
            local hdist = readBits(reader, 5) + 1
            local hclen = readBits(reader, 4) + 4
            local codeLenOrder = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
            local codeLenTree = {}
            for i = 1, hclen do
                local bits = readBits(reader, 3)
                codeLenTree[codeLenOrder[i]] = { symbol = codeLenOrder[i], len = bits }
            end
            local _, maxBitsCL = buildHuffmanTree(codeLenTree)
            local litLenCodes = {}
            local i = 0
            while i < hlit + hdist do
                local sym = decodeSymbol(reader, codeLenTree, maxBitsCL)
                if sym < 16 then
                    litLenCodes[i+1] = sym
                    i = i + 1
                elseif sym == 16 then
                    local rep = 3 + readBits(reader, 2)
                    local val = litLenCodes[i]
                    for _ = 1, rep do litLenCodes[i+1] = val; i = i+1 end
                elseif sym == 17 then
                    local rep = 3 + readBits(reader, 3)
                    for _ = 1, rep do litLenCodes[i+1] = 0; i = i+1 end
                elseif sym == 18 then
                    local rep = 11 + readBits(reader, 7)
                    for _ = 1, rep do litLenCodes[i+1] = 0; i = i+1 end
                end
            end
            local litCodes, distCodes = {}, {}
            for idx=1, hlit do
                if litLenCodes[idx] then
                    litCodes[idx-1] = { symbol = idx-1, len = litLenCodes[idx] }
                end
            end
            for idx=1, hdist do
                if litLenCodes[hlit+idx] then
                    distCodes[idx-1] = { symbol = idx-1, len = litLenCodes[hlit+idx] }
                end
            end
            litTree, litMaxBits = buildHuffmanTree(litCodes)
            distTree, distMaxBits = buildHuffmanTree(distCodes)
        end

        local lengthExtra = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
        local lengthBase = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
        local distExtra = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
        local distBase = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,161,193,225,257,289,321,385,449,513,577,641,705,769,833,897,961,1025,1089,1153,1217,1281,1345,1409,1473,1537,1601,1665,1729,1793,1857,1921,1985,2049,2113,2177,2241,2305,2369,2433,2497,2561,2625,2689,2753,2817,2881,2945,3009,3073,3137,3201,3265,3329,3393,3457,3521,3585,3649,3713,3777,3841,3905,3969,4033,4097,4161,4225,4289,4353,4417,4481,4545,4609,4673,4737,4801,4865,4929,4993,5057,5121,5185,5249,5313,5377,5441,5505,5569,5633,5697,5761,5825,5889,5953,6017,6081,6145,6209,6273,6337,6401,6465,6529,6593,6657,6721,6785,6849,6913,6977,7041,7105,7169,7233,7297,7361,7425,7489,7553,7617,7681,7745,7809,7873,7937,8001,8065,8129,8193}

        while true do
            local sym = decodeSymbol(reader, litTree, litMaxBits)
            if sym < 256 then
                outputFunc(sym)
            elseif sym == 256 then
                break
            else
                local lenIdx = sym - 257
                local extraBits = lengthExtra[lenIdx+1]
                local length = lengthBase[lenIdx+1] + readBits(reader, extraBits)
                local distSym = decodeSymbol(reader, distTree, distMaxBits)
                local distExtraBits = distExtra[distSym+1]
                local distance = distBase[distSym+1] + readBits(reader, distExtraBits)
                local start = #outputFunc.buffer - distance + 1
                for i = 1, length do
                    outputFunc(outputFunc.buffer[start + i - 1])
                end
            end
        end
    else
        error("Invalid block type")
    end
    return last == 1
end

function Inflate.InflateZlib(reader, outputFunc)
    local cmf = reader:ReadByte()
    local flg = reader:ReadByte()
    if (cmf * 256 + flg) % 31 ~= 0 then error("Bad Zlib header") end
    if band(cmf, 0x0F) ~= 8 then error("Only deflate supported") end
    outputFunc.buffer = {}
    local function wrappedOut(byte)
        outputFunc.buffer[#outputFunc.buffer+1] = byte
        outputFunc(byte)
    end
    local done = false
    while not done do
        done = inflateBlock(reader, wrappedOut)
    end
    local adler = reader:ReadUInt32() -- skip
    local result = table.concat(outputFunc.buffer)
    outputFunc.buffer = nil
    return result
end

-- -----------------------------------------------------------------
-- 4. ФИЛЬТРЫ PNG
-- -----------------------------------------------------------------
local Unfilter = {}

function Unfilter:None(scanline, bitmap, bpp, row)
    for i = 1, #scanline do
        bitmap[row][i] = scanline[i]
    end
end

function Unfilter:Sub(scanline, bitmap, bpp, row)
    for i = 1, #scanline do
        local left = (i > bpp) and bitmap[row][i - bpp] or 0
        bitmap[row][i] = band(scanline[i] + left, 0xFF)
    end
end

function Unfilter:Up(scanline, bitmap, bpp, row)
    local prevRow = bitmap[row-1] or {}
    for i = 1, #scanline do
        local above = prevRow[i] or 0
        bitmap[row][i] = band(scanline[i] + above, 0xFF)
    end
end

function Unfilter:Average(scanline, bitmap, bpp, row)
    local prevRow = bitmap[row-1] or {}
    for i = 1, #scanline do
        local left = (i > bpp) and bitmap[row][i - bpp] or 0
        local above = prevRow[i] or 0
        bitmap[row][i] = band(scanline[i] + math.floor((left + above) / 2), 0xFF)
    end
end

function Unfilter:Paeth(scanline, bitmap, bpp, row)
    local prevRow = bitmap[row-1] or {}
    for i = 1, #scanline do
        local left = (i > bpp) and bitmap[row][i - bpp] or 0
        local above = prevRow[i] or 0
        local upperLeft = (i > bpp) and (prevRow[i - bpp] or 0) or 0
        local p = left + above - upperLeft
        local pa = math.abs(p - left)
        local pb = math.abs(p - above)
        local pc = math.abs(p - upperLeft)
        local predictor
        if pa <= pb and pa <= pc then predictor = left
        elseif pb <= pc then predictor = above
        else predictor = upperLeft end
        bitmap[row][i] = band(scanline[i] + predictor, 0xFF)
    end
end

-- -----------------------------------------------------------------
-- 5. ПАРСЕР PNG
-- -----------------------------------------------------------------
local function getBytesPerPixel(colorType)
    if colorType == 0 or colorType == 3 then return 1 end
    if colorType == 4 then return 2 end
    if colorType == 2 then return 3 end
    if colorType == 6 then return 4 end
    return 0
end

local PNG = {}
PNG.__index = PNG

function PNG.new(buffer)
    local reader = BinaryReader.new(buffer)
    local header = reader:ReadString(8)
    if header ~= "\137PNG\r\n\26\n" then error("Not a PNG") end

    local file = {
        Chunks = {}, Width = 0, Height = 0, BitDepth = 0,
        ColorType = 0, Palette = {}, AlphaData = {}, ZlibStream = {}
    }

    while true do
        local length = reader:ReadInt32()
        local chunkType = reader:ReadString(4)
        local data = nil
        if length > 0 then data = reader:ForkReader(length) end
        local crc = reader:ReadUInt32()

        if chunkType == "IHDR" then
            file.Width = data:ReadInt32()
            file.Height = data:ReadInt32()
            file.BitDepth = data:ReadByte()
            file.ColorType = data:ReadByte()
            data:ReadByte() -- compression
            data:ReadByte() -- filter
            data:ReadByte() -- interlace
        elseif chunkType == "IDAT" then
            local chunkData = data:ReadBytes(length, true)
            for _, byte in ipairs(chunkData) do
                file.ZlibStream[#file.ZlibStream+1] = string.char(byte)
            end
        elseif chunkType == "PLTE" then
            local bytes = data:ReadBytes(length, true)
            for i = 1, #bytes, 3 do
                local r, g, b = bytes[i], bytes[i+1], bytes[i+2]
                file.Palette[#file.Palette+1] = Color3.fromRGB(r, g, b)
            end
        elseif chunkType == "tRNS" then
            local bytes = data:ReadBytes(length, true)
            if file.ColorType == 3 then
                for i = 1, #bytes do
                    file.AlphaData[i] = bytes[i]
                end
            elseif file.ColorType == 0 then
                file.TransparentGray = bytes[1] or 0
            elseif file.ColorType == 2 then
                file.TransparentRGB = {r=bytes[1], g=bytes[2], b=bytes[3]}
            end
        elseif chunkType == "IEND" then
            break
        end
    end

    local zlibStr = table.concat(file.ZlibStream)
    local inflateReader = BinaryReader.new(zlibStr)
    local decompressed = ""
    Inflate.InflateZlib(inflateReader, function(byte)
        decompressed = decompressed .. string.char(byte)
        if not BotConfig.InstantDraw and #decompressed % 40000 == 0 then task.wait() end
    end)

    local imgReader = BinaryReader.new(decompressed)
    local width = file.Width
    local height = file.Height
    local bpp = getBytesPerPixel(file.ColorType) * (file.BitDepth / 8)
    file.BytesPerPixel = bpp
    file.Bitmap = {}

    for row = 1, height do
        if not BotConfig.InstantDraw and row % 2 == 0 then task.wait() end
        local filterType = imgReader:ReadByte()
        local scanline = imgReader:ReadBytes(width * bpp, true)
        file.Bitmap[row] = {}
        if filterType == 0 then Unfilter:None(scanline, file.Bitmap, bpp, row)
        elseif filterType == 1 then Unfilter:Sub(scanline, file.Bitmap, bpp, row)
        elseif filterType == 2 then Unfilter:Up(scanline, file.Bitmap, bpp, row)
        elseif filterType == 3 then Unfilter:Average(scanline, file.Bitmap, bpp, row)
        elseif filterType == 4 then Unfilter:Paeth(scanline, file.Bitmap, bpp, row)
        end
    end

    return setmetatable(file, PNG)
end

function PNG:GetPixel(x, y)
    x = math.clamp(math.floor(x+0.5), 1, self.Width)
    y = math.clamp(math.floor(y+0.5), 1, self.Height)
    local row = self.Bitmap[y]
    if not row then return Color3.new(1,1,1), 255 end
    local bpp = self.BytesPerPixel
    local i0 = (x-1) * bpp + 1
    local colorType = self.ColorType

    if colorType == 0 then
        local gray = row[i0] or 0
        return Color3.fromRGB(gray, gray, gray), 255
    elseif colorType == 2 then
        local r, g, b = row[i0] or 0, row[i0+1] or 0, row[i0+2] or 0
        return Color3.fromRGB(r, g, b), 255
    elseif colorType == 3 then
        local idx = (row[i0] or 0) + 1
        local color = self.Palette[idx] or Color3.new(1,1,1)
        local alpha = self.AlphaData and self.AlphaData[idx] or 255
        return color, alpha
    elseif colorType == 4 then
        local gray, a = row[i0] or 0, row[i0+1] or 255
        return Color3.fromRGB(gray, gray, gray), a
    elseif colorType == 6 then
        local r, g, b, a = row[i0] or 0, row[i0+1] or 0, row[i0+2] or 0, row[i0+3] or 255
        return Color3.fromRGB(r, g, b), a
    end
    return Color3.new(1,1,1), 255
end

-- -----------------------------------------------------------------
-- 6. GUI (с надежным ожиданием PlayerGui)
-- -----------------------------------------------------------------
local function CreateGUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "DrawAndDonateAutoDraw"
    screenGui.ResetOnSpawn = false

    -- Пытаемся вставить в CoreGui, если не получается – в PlayerGui
    local success, err = pcall(function()
        screenGui.Parent = CoreGui
    end)
    if not success then
        local playerGui = LocalPlayer:WaitForChild("PlayerGui")
        screenGui.Parent = playerGui
    end

    local MainFrame = Instance.new("Frame")
    MainFrame.Size = UDim2.new(0, 250, 0, 260)
    MainFrame.Position = UDim2.new(0.05, 0, 0.3, 0)
    MainFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
    MainFrame.BorderSizePixel = 0
    MainFrame.Active = true
    MainFrame.Draggable = true
    MainFrame.Parent = screenGui

    local UICorner = Instance.new("UICorner")
    UICorner.CornerRadius = UDim.new(0, 2)
    UICorner.Parent = MainFrame

    local Title = Instance.new("TextLabel")
    Title.Size = UDim2.new(1, 0, 0, 40)
    Title.Text = "Draw & Donate Auto Draw"
    Title.TextColor3 = Color3.fromRGB(255, 255, 255)
    Title.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
    Title.Font = Enum.Font.SourceSans
    Title.TextSize = 14
    Title.Parent = MainFrame

    local UTCorner = Instance.new("UICorner")
    UTCorner.CornerRadius = UDim.new(0, 2)
    UTCorner.Parent = Title

    local function CreateButton(text, yPos, callback)
        local Btn = Instance.new("TextButton")
        Btn.Size = UDim2.new(1, -20, 0, 32)
        Btn.Position = UDim2.new(0, 10, 0, yPos)
        Btn.Text = text
        Btn.TextColor3 = Color3.fromRGB(240, 240, 240)
        Btn.BackgroundColor3 = Color3.fromRGB(44, 44, 52)
        Btn.Font = Enum.Font.SourceSans
        Btn.TextSize = 14
        Btn.Parent = MainFrame
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 2)
        c.Parent = Btn
        Btn.MouseButton1Click:Connect(callback)
        return Btn
    end

    local ToggleBtn = CreateButton("START", 50, function() end)
    ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
    ToggleBtn.AutoButtonColor = true

    local ModeBtn = CreateButton("Mode: Smooth (Stable but slow)", 87, function() end)
    ModeBtn.MouseButton1Click:Connect(function()
        BotConfig.InstantDraw = not BotConfig.InstantDraw
        if BotConfig.InstantDraw then
            ModeBtn.Text = "Mode: Instant (Might lag a bit)"
            ModeBtn.TextColor3 = Color3.fromRGB(255, 215, 0)
        else
            ModeBtn.Text = "Mode: Smooth (Stable but slow)"
            ModeBtn.TextColor3 = Color3.fromRGB(240, 240, 240)
        end
    end)

    local TextBox = Instance.new("TextBox")
    TextBox.Size = UDim2.new(1, -20, 0, 30)
    TextBox.Position = UDim2.new(0, 10, 0, 125)
    TextBox.Text = "Insert direct .png URL link"
    TextBox.TextColor3 = Color3.fromRGB(200, 200, 200)
    TextBox.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
    TextBox.Font = Enum.Font.SourceSans
    TextBox.TextSize = 12
    TextBox.TextWrapped = true
    TextBox.ClearTextOnFocus = false
    TextBox.Parent = MainFrame
    local BoxCorner = Instance.new("UICorner")
    BoxCorner.CornerRadius = UDim.new(0, 2)
    BoxCorner.Parent = TextBox
    TextBox.FocusLost:Connect(function(ep) if ep then BotConfig.ImageURL = TextBox.Text end end)

    local StatusLabel = Instance.new("TextLabel")
    StatusLabel.Size = UDim2.new(1, -20, 0, 40)
    StatusLabel.Position = UDim2.new(0, 10, 0, 160)
    StatusLabel.Text = "Status: Ready (No external libs)"
    StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 100)
    StatusLabel.BackgroundTransparency = 1
    StatusLabel.Font = Enum.Font.SourceSans
    StatusLabel.TextSize = 13
    StatusLabel.TextWrapped = true
    StatusLabel.Parent = MainFrame

    local AuthorLabel = Instance.new("TextLabel")
    AuthorLabel.Size = UDim2.new(1, -20, 0, 20)
    AuthorLabel.Position = UDim2.new(0, 10, 0, 205)
    AuthorLabel.Text = "Author: @RoogleCreator"
    AuthorLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
    AuthorLabel.BackgroundTransparency = 1
    AuthorLabel.Font = Enum.Font.SourceSans
    AuthorLabel.TextSize = 12
    AuthorLabel.Parent = MainFrame

    local ProgressBarBg = Instance.new("Frame")
    ProgressBarBg.Size = UDim2.new(1, -20, 0, 6)
    ProgressBarBg.Position = UDim2.new(0, 10, 0, 235)
    ProgressBarBg.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    ProgressBarBg.BorderSizePixel = 0
    ProgressBarBg.Parent = MainFrame
    local ProgressBarFill = Instance.new("Frame")
    ProgressBarFill.Size = UDim2.new(0, 0, 1, 0)
    ProgressBarFill.BackgroundColor3 = Color3.fromRGB(0, 255, 150)
    ProgressBarFill.BorderSizePixel = 0
    ProgressBarFill.Parent = ProgressBarBg

    return ToggleBtn, ModeBtn, StatusLabel, ProgressBarFill
end

-- Создаём GUI и получаем ссылки на элементы управления
local ToggleBtn, ModeBtn, StatusLabel, ProgressBarFill = CreateGUI()

-- -----------------------------------------------------------------
-- 7. ПОИСК CANVAS И ОСНОВНОЙ ЦИКЛ
-- -----------------------------------------------------------------
local function FindLocalDrawingCanvas()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    if not playerGui then return nil end
    local canvasFrame = nil
    for _, v in ipairs(playerGui:GetDescendants()) do
        if v:IsA("Frame") and v:FindFirstChild("FastCanvas") then canvasFrame = v break end
    end
    if not canvasFrame then return nil end
    local successGC, registry = pcall(getgc, true)
    if successGC then
        for i = 1, #registry do
            local obj = registry[i]
            if type(obj) == "table" and rawget(obj, "DrawLine") then
                if rawget(obj, "CurrentCanvasFrame") == canvasFrame or tostring(rawget(obj, "CurrentCanvasFrame")) == tostring(canvasFrame) then
                    return obj
                end
            end
        end
    end
    return nil
end

local drawingThread = nil

ToggleBtn.MouseButton1Click:Connect(function()
    if BotConfig.Enabled then
        BotConfig.Enabled = false
        ToggleBtn.Text = "START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
        if drawingThread then task.cancel(drawingThread) end
        StatusLabel.Text = "Status: Stopped."
        ProgressBarFill.Size = UDim2.new(0, 0, 1, 0)
    else
        LocalDrawingCanvas = FindLocalDrawingCanvas()
        if not LocalDrawingCanvas then
            StatusLabel.Text = "Status: Open the easel first!"
            return
        end
        if BotConfig.ImageURL == "" or not string.match(BotConfig.ImageURL, "http") then
            StatusLabel.Text = "Status: Invalid image URL!"
            return
        end

        BotConfig.Enabled = true
        ToggleBtn.Text = "STOP"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(170, 40, 40)

        drawingThread = task.spawn(function()
            StatusLabel.Text = "Status: Downloading..."
            local successFetch, resultBuffer = pcall(function() return game:HttpGet(BotConfig.ImageURL) end)
            if not successFetch then
                StatusLabel.Text = "Status: Download failed!"
                BotConfig.Enabled = false
                ToggleBtn.Text = "START"
                return
            end

            StatusLabel.Text = "Status: Processing..."
            if not BotConfig.InstantDraw then task.wait() end

            local successPng, pngImage = pcall(function() return PNG.new(resultBuffer) end)
            if not successPng or not pngImage then
                StatusLabel.Text = "Status: Bad image file!"
                BotConfig.Enabled = false
                ToggleBtn.Text = "START"
                return
            end

            local resX = tonumber(LocalDrawingCanvas.CurrentResX or 150)
            local resY = tonumber(LocalDrawingCanvas.CurrentResY or 150)

            StatusLabel.Text = "Status: Drawing..."
            for y = 1, resY do
                if not BotConfig.Enabled then break end
                for x = 1, resX do
                    local srcX = (x / resX) * pngImage.Width
                    local srcY = (y / resY) * pngImage.Height
                    local color, alpha = pngImage:GetPixel(srcX, srcY)
                    if alpha > 15 then
                        LocalDrawingCanvas:DrawLine(Vector2.new(x, y), Vector2.new(x, y), color, 1)
                    end
                end
                if not BotConfig.InstantDraw then
                    ProgressBarFill.Size = UDim2.new(y / resY, 0, 1, 0)
                    if y % 3 == 0 then
                        if LocalDrawingCanvas.Render then LocalDrawingCanvas:Render() end
                        task.wait()
                    end
                end
            end

            if LocalDrawingCanvas.Render then LocalDrawingCanvas:Render() end
            ProgressBarFill.Size = UDim2.new(1, 0, 1, 0)
            StatusLabel.Text = "Status: Done!"
            BotConfig.Enabled = false
            ToggleBtn.Text = "START"
            ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
        end)
    end
end)
