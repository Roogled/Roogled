-- =======================================================================================
-- [ОПТИМИЗАЦИЯ ОКРУЖЕНИЯ]
-- =======================================================================================
if not pcall(function() return bit32 end) and pcall(function() return bit end) then
    getfenv().bit32 = bit
end

-- =======================================================================================
-- [ПОЛНЫЕ ВШИТЫЕ МОДУЛИ PNG БИБЛИОТЕКИ]
-- =======================================================================================

-- 1. Модуль BinaryReader
local BinaryReader = {}
do
    local reader = {}
    reader.__index = reader
    function reader.new(buffer)
        return setmetatable({Buffer = buffer, Length = #buffer, Index = 1}, reader)
    end
    function reader:ReadString(len)
        local str = string.sub(self.Buffer, self.Index, self.Index + len - 1)
        self.Index = self.Index + len
        return str
    end
    function reader:ReadByte()
        local byte = string.byte(self.Buffer, self.Index)
        self.Index = self.Index + 1
        return byte
    end
    function reader:ReadBytes(len, asTable)
        if asTable then
            local bytes = {}
            for i = 1, len do bytes[i] = string.byte(self.Buffer, self.Index + i - 1) end
            self.Index = self.Index + len
            return bytes
        else
            return self:ReadString(len)
        end
    end
    function reader:ReadInt32()
        local b1, b2, b3, b4 = self:ReadByte(), self:ReadByte(), self:ReadByte(), self:ReadByte()
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end
    function reader:ReadUInt32()
        return self:ReadInt32() % 4294967296
    end
    function reader:ForkReader(len)
        return reader.new(self:ReadString(len))
    end
    BinaryReader = reader
end

-- 2. Модуль Unfilter
local Unfilter = {}
do
    function Unfilter:None(scanline, bitmap, bpp, row)
        for i = 1, #scanline do bitmap[row][i] = scanline[i] end
    end
    function Unfilter:Sub(scanline, bitmap, bpp, row)
        for i = 1, #scanline do
            local prior = (i > bpp) and bitmap[row][i - bpp] or 0
            bitmap[row][i] = (scanline[i] + prior) % 256
        end
    end
    function Unfilter:Up(scanline, bitmap, bpp, row)
        for i = 1, #scanline do
            local prior = (row > 1) and bitmap[row - 1][i] or 0
            bitmap[row][i] = (scanline[i] + prior) % 256
        end
    end
    function Unfilter:Average(scanline, bitmap, bpp, row)
        for i = 1, #scanline do
            local prior = (i > bpp) and bitmap[row][i - bpp] or 0
            local up = (row > 1) and bitmap[row - 1][i] or 0
            bitmap[row][i] = (scanline[i] + math.floor((prior + up) / 2)) % 256
        end
    end
    function Unfilter:Paeth(scanline, bitmap, bpp, row)
        for i = 1, #scanline do
            local a = (i > bpp) and bitmap[row][i - bpp] or 0
            local b = (row > 1) and bitmap[row - 1][i] or 0
            local c = (i > bpp and row > 1) and bitmap[row - 1][i - bpp] or 0
            local p = a + b - c
            local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
            local nearest = (pa <= pb and pa <= pc) and a or (pb <= pc and b or c)
            bitmap[row][i] = (scanline[i] + nearest) % 256
        end
    end
end

-- 3. ПОЛНЫЙ Модуль Deflate (Оригинальный алгоритм без урезания)
local Deflate = {}
do
    local bit32 = getfenv().bit32 or bit
    local bnot, band, rshift, lshift = bit32.bnot, bit32.band, bit32.rshift, bit32.lshift
    
    local function reverseBits(n, bits)
        local r = 0
        for i = 1, bits do
            r = lshift(r, 1) + band(n, 1)
            n = rshift(n, 1)
        end
        return r
    end

    local function makeHuffmanTable(lengths)
        local count = #lengths
        local maxLen = 0
        for i = 1, count do if lengths[i] > maxLen then maxLen = lengths[i] end end
        local bl_count = {}
        for i = 1, maxLen do bl_count[i] = 0 end
        for i = 1, count do if lengths[i] > 0 then bl_count[lengths[i]] = bl_count[lengths[i]] + 1 end end
        local code = 0
        local next_code = {}
        for bits = 1, maxLen do
            code = lshift(code + (bl_count[bits - 1] or 0), 1)
            next_code[bits] = code
        end
        local table = {}
        for i = 1, count do
            local l = lengths[i]
            if l > 0 then
                table[reverseBits(next_code[l], l)] = {l, i - 1}
                next_code[l] = next_code[l] + 1
            end
        end
        return table, maxLen
    end

    local function decodeSymbol(reader, bitBuffer, bitCount, huffTable, maxLen)
        while bitCount < maxLen do
            local byte = reader:ReadByte()
            if not byte then break end
            bitBuffer = bitBuffer + lshift(byte, bitCount)
            bitCount = bitCount + 8
        end
        for bits = 1, maxLen do
            local code = band(bitBuffer, lshift(1, bits) - 1)
            local res = huffTable[code]
            if res and res[1] == bits then
                return res[2], bitBuffer / lshift(1, bits), bitCount - bits
            end
        end
        return nil, bitBuffer, bitCount
    end

    function Deflate:InflateZlib(config)
        local reader = config.Input
        local output = config.Output
        
        local cmf = reader:ReadByte()
        local flg = reader:ReadByte()
        if (cmf * 256 + flg) % 31 ~= 0 then error("Zlib - Invalid checksum", 2) end
        if band(flg, 32) ~= 0 then error("Zlib - Preset dictionaries not supported", 2) end
        
        local bitBuffer, bitCount = 0, 0
        local isLast = 0
        
        local lengthBases = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
        local lengthExtra = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
        local distBases = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
        local distExtra = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
        local clOrder = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

        local fixedLitTable, fixedLitMax
        do
            local lens = {}
            for i = 1, 144 do lens[i] = 8 end
            for i = 145, 256 do lens[i] = 9 end
            for i = 257, 280 do lens[i] = 7 end
            for i = 281, 288 do lens[i] = 8 end
            fixedLitTable, fixedLitMax = makeHuffmanTable(lens)
        end
        local fixedDistTable, fixedDistMax = makeHuffmanTable({5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5})

        local history = {}
        local historyIndex = 1

        while isLast == 0 do
            while bitCount < 3 do
                local byte = reader:ReadByte()
                if not byte then break end
                bitBuffer = bitBuffer + lshift(byte, bitCount)
                bitCount = bitCount + 8
            end
            isLast = band(bitBuffer, 1)
            local blockType = band(rshift(bitBuffer, 1), 3)
            bitBuffer = rshift(bitBuffer, 3)
            bitCount = bitCount - 3
            
            if blockType == 0 then -- Uncompressed
                bitBuffer, bitCount = 0, 0
                local len = reader:ReadByte() + reader:ReadByte() * 256
                local nlen = reader:ReadByte() + reader:ReadByte() * 256
                for i = 1, len do
                    local byte = reader:ReadByte()
                    output(byte)
                    history[historyIndex] = byte
                    historyIndex = (historyIndex % 32768) + 1
                end
            elseif blockType == 1 or blockType == 2 then -- Huffman
                local litTable, litMax, distTable, distMax
                if blockType == 1 then
                    litTable, litMax, distTable, distMax = fixedLitTable, fixedLitMax, fixedDistTable, fixedDistMax
                else
                    while bitCount < 14 do
                        bitBuffer = bitBuffer + lshift(reader:ReadByte(), bitCount)
                        bitCount = bitCount + 8
                    end
                    local hlit = band(bitBuffer, 31) + 257
                    local hdist = band(rshift(bitBuffer, 5), 31) + 1
                    local hclen = band(rshift(bitBuffer, 10), 15) + 4
                    bitBuffer = rshift(bitBuffer, 14)
                    bitCount = bitCount - 14
                    
                    local clLens = {}
                    for i = 1, 19 do clLens[i] = 0 end
                    for i = 1, hclen do
                        while bitCount < 3 do bitBuffer = bitBuffer + lshift(reader:ReadByte(), bitCount) bitCount = bitCount + 8 end
                        clLens[clOrder[i] + 1] = band(bitBuffer, 7)
                        bitBuffer = rshift(bitBuffer, 3)
                        bitCount = bitCount - 3
                    end
                    local clTable, clMax = makeHuffmanTable(clLens)
                    
                    local allLens = {}
                    local target = hlit + hdist
                    while #allLens < target do
                        local sym
                        sym, bitBuffer, bitCount = decodeSymbol(reader, bitBuffer, bitCount, clTable, clMax)
                        if sym < 16 then
                            table.insert(allLens, sym)
                        local rep = 0, last = 0
                        elseif sym == 16 then
                            while bitCount < 2 do bitBuffer = bitBuffer + lshift(reader:ReadByte(), bitCount) bitCount = bitCount + 8 end
                            rep = band(bitBuffer, 3) + 3 bitBuffer = rshift(bitBuffer, 2) bitCount = bitCount - 2
                            last = allLens[#allLens]
                            for i = 1, rep do table.insert(allLens, last) end
                        elseif sym == 17 then
                            while bitCount < 3 do bitBuffer = bitBuffer + lshift(reader:ReadByte(), bitCount) bitCount = bitCount + 8 end
                            rep = band(bitBuffer, 7) + 3 bitBuffer = rshift(bitBuffer, 3) bitCount = bitCount - 3
                            for i = 1, rep do table.insert(allLens, 0) end
                        elseif sym == 18 then
                            while bitCount < 7 do bitBuffer = bitBuffer + lshift(reader:ReadByte(), bitCount) bitCount = bitCount + 8 end
                            rep = band(bitBuffer, 127) + 11 bitBuffer = rshift(bitBuffer, 7) bitCount = bitCount - 7
                            for i = 1, rep do table.insert(allLens, 0) end
                        end
                    end
                    local litLens = {}
                    for i = 1, hlit do litLens[i] = allLens[i] end
                    local distLens = {}
                    for i = hlit + 1, #allLens do table.insert(distLens, allLens[i]) end
                    litTable, litMax = makeHuffmanTable(litLens)
                    distTable, distMax = makeHuffmanTable(distLens)
                end
                
                while true do
                    local sym
                    sym, bitBuffer, bitCount = decodeSymbol(reader, bitBuffer, bitCount, litTable, litMax)
                    if sym < 256 then
                        output(sym)
                        history[historyIndex] = sym
                        historyIndex = (historyIndex % 32768) + 1
                    elseif sym == 256 then
                        break
                    else
                        local lenIdx = sym - 256
                        local len = lengthBases[lenIdx]
                        local extraL = lengthExtra[lenIdx]
                        if extraL > 0 then
                            while bitCount < extraL do bitBuffer = bitBuffer + lshift(reader:ReadByte(), bitCount) bitCount = bitCount + 8 end
                            len = len + band(bitBuffer, lshift(1, extraL) - 1)
                            bitBuffer = rshift(bitBuffer, extraL)
                            bitCount = bitCount - extraL
                        end
                        local distSym
                        distSym, bitBuffer, bitCount = decodeSymbol(reader, bitBuffer, bitCount, distTable, distMax)
                        local dist = distBases[distSym + 1]
                        local extraD = distExtra[distSym + 1]
                        if extraD > 0 then
                            while bitCount < extraD do bitBuffer = bitBuffer + lshift(reader:ReadByte(), bitCount) bitCount = bitCount + 8 end
                            dist = dist + band(bitBuffer, lshift(1, extraD) - 1)
                            bitBuffer = rshift(bitBuffer, extraD)
                            bitCount = bitCount - extraD
                        end
                        for i = 1, len do
                            local lookBack = (historyIndex - 1 - dist) % 32768 + 1
                            local byte = history[lookBack] or 0
                            output(byte)
                            history[historyIndex] = byte
                            historyIndex = (historyIndex % 32768) + 1
                        end
                    end
                end
            end
        end
    end
end

-- 4. Обработчики Чанков
local chunks = {}
chunks.IHDR = function(file, chunk)
    local reader = chunk.Data
    file.Width = reader:ReadInt32()
    file.Height = reader:ReadInt32()
    file.BitDepth = reader:ReadByte()
    file.ColorType = reader:ReadByte()
    file.Compression = reader:ReadByte()
    file.Filter = reader:ReadByte()
    file.Interlace = reader:ReadByte()
end
chunks.IDAT = function(file, chunk)
    file.ZlibStream = file.ZlibStream .. chunk.Data.Buffer
end
chunks.IEND = function(file, chunk) file.Reading = false end
chunks.PLTE = function(file, chunk)
    local reader = chunk.Data
    local palette = {}
    for i = 1, chunk.Length, 3 do
        table.insert(palette, Color3.fromRGB(reader:ReadByte(), reader:ReadByte(), reader:ReadByte()))
    end
    file.Palette = palette
end
chunks.tRNS = function(file, chunk)
    local reader = chunk.Data
    local alpha = {}
    for i = 1, chunk.Length do table.insert(alpha, reader:ReadByte()) end
    file.AlphaData = alpha
end
chunks.bKGD = function() end chunks.cHRM = function() end chunks.gAMA = function() end
chunks.sRGB = function() end chunks.tEXt = function() end chunks.tIME = function() end

-- =======================================================================================
-- [ОСНОВНАЯ PNG ЛОГИКА]
-- =======================================================================================
local PNG = {}
PNG.__index = PNG

local function getBytesPerPixel(colorType)
    if colorType == 0 or colorType == 3 then return 1
    elseif colorType == 4 then return 2
    elseif colorType == 2 then return 3
    elseif colorType == 6 then return 4
    else return 0 end
end

function PNG:GetPixel(x, y)
    x = math.clamp(math.floor(x), 1, self.Width)
    y = math.clamp(math.floor(y), 1, self.Height)
    local row = self.Bitmap[y]
    if not row then return Color3.new(1,1,1), 0 end
    
    local bpp = self.BytesPerPixel
    local i0 = ((x - 1) * bpp) + 1
    local colorType = self.ColorType
    
    if colorType == 2 then
        return Color3.fromRGB(row[i0] or 0, row[i0+1] or 0, row[i0+2] or 0), 255
    elseif colorType == 6 then
        return Color3.fromRGB(row[i0] or 0, row[i0+1] or 0, row[i0+2] or 0), row[i0+3] or 255
    elseif colorType == 3 then
        local idx = (row[i0] or 0) + 1
        local color = self.Palette and self.Palette[idx] or Color3.new(1,1,1)
        local alpha = self.AlphaData and self.AlphaData[idx] or 255
        return color, alpha
    elseif colorType == 0 then
        local g = (row[i0] or 0) / 255
        return Color3.new(g, g, g), 255
    elseif colorType == 4 then
        local g = (row[i0] or 0) / 255
        return Color3.new(g, g, g), row[i0+1] or 255
    end
    return Color3.new(1,1,1), 255
end

function PNG.new(buffer)
    local reader = BinaryReader.new(buffer)
    local file = { Chunks = {}, Metadata = {}, Reading = true, ZlibStream = "" }
    
    if reader:ReadString(8) ~= "\137PNG\r\n\26\n" then error("PNG - Invalid header", 2) end
    
    while file.Reading do
        local length = reader:ReadInt32()
        local chunkType = reader:ReadString(4)
        local data = reader:ForkReader(length)
        if length > 0 then reader:ReadUInt32() end
        local chunk = { Length = length, Type = chunkType, Data = data }
        local handler = chunks[chunkType]
        if handler then handler(file, chunk) end
    end
    
    local decompressed = {}
    Deflate:InflateZlib({
        Input = BinaryReader.new(file.ZlibStream),
        Output = function(byte) table.insert(decompressed, string.char(byte)) end
    })
    
    local response = table.concat(decompressed)
    local width, height = file.Width, file.Height
    local bBuffer = BinaryReader.new(response)
    file.ZlibStream = nil
    
    local bitmap = {}
    file.Bitmap = bitmap
    local bpp = math.max(1, getBytesPerPixel(file.ColorType) * (file.BitDepth / 8))
    file.BytesPerPixel = bpp
    
    for row = 1, height do
        local filterType = bBuffer:ReadByte()
        local scanline = bBuffer:ReadBytes(width * bpp, true)
        bitmap[row] = {}
        
        if filterType == 0 then Unfilter:None(scanline, bitmap, bpp, row)
        elseif filterType == 1 then Unfilter:Sub(scanline, bitmap, bpp, row)
        elseif filterType == 2 then Unfilter:Up(scanline, bitmap, bpp, row)
        elseif filterType == 3 then Unfilter:Average(scanline, bitmap, bpp, row)
        elseif filterType == 4 then Unfilter:Paeth(scanline, bitmap, bpp, row) end
    end
    return setmetatable(file, PNG)
end

-- =======================================================================================
-- [ИНТЕРФЕЙС И ЛОГИКА РИСОВАНИЯ]
-- =======================================================================================
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local LocalDrawingCanvas = nil

local BotConfig = { Enabled = false, ImageURL = "", InstantDraw = false }

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "DrawAndDonateAutoDraw"
ScreenGui.ResetOnSpawn = false
pcall(function() ScreenGui.Parent = CoreGui end)
if not ScreenGui.Parent then ScreenGui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

local MainFrame = Instance.new("Frame")
MainFrame.Size = UDim2.new(0, 250, 0, 260)
MainFrame.Position = UDim2.new(0.05, 0, 0.3, 0)
MainFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

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

local function CreateButton(text, yPos)
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
    return Btn
end

local ToggleBtn = CreateButton("START", 50)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)

local ModeBtn = CreateButton("Mode: Smooth (Stable but slow)", 87)
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
TextBox.Parent = MainFrame
TextBox.FocusLost:Connect(function(ep) if ep then BotConfig.ImageURL = TextBox.Text end end)

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Size = UDim2.new(1, -20, 0, 40)
StatusLabel.Position = UDim2.new(0, 10, 0, 160)
StatusLabel.Text = "Status: Ready to draw!"
StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 100)
StatusLabel.BackgroundTransparency = 1
StatusLabel.Font = Enum.Font.SourceSans
StatusLabel.TextSize = 13
StatusLabel.Parent = MainFrame

local ProgressBarBg = Instance.new("Frame")
ProgressBarBg.Size = UDim2.new(1, -20, 0, 6)
ProgressBarBg.Position = UDim2.new(0, 10, 0, 235)
ProgressBarBg.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
ProgressBarBg.Parent = MainFrame

local ProgressBarFill = Instance.new("Frame")
ProgressBarFill.Size = UDim2.new(0, 0, 1, 0)
ProgressBarFill.BackgroundColor3 = Color3.fromRGB(0, 255, 150)
ProgressBarFill.BorderSizePixel = 0
ProgressBarFill.Parent = ProgressBarBg

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
        if not LocalDrawingCanvas then StatusLabel.Text = "Status: Open the easel first!" return end
        if BotConfig.ImageURL == "" or not string.match(BotConfig.ImageURL, "http") then StatusLabel.Text = "Status: Invalid image URL!" return end

        BotConfig.Enabled = true
        ToggleBtn.Text = "STOP"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(170, 40, 40)
        
        drawingThread = task.spawn(function()
            StatusLabel.Text = "Status: Downloading..."
            local successFetch, resultBuffer = pcall(function() return game:HttpGet(BotConfig.ImageURL) end)
            if not successFetch then StatusLabel.Text = "Status: Download failed!" BotConfig.Enabled = false ToggleBtn.Text = "START" return end

            StatusLabel.Text = "Status: Processing..."
            task.wait()
            
            local successPng, pngImage = pcall(function() return PNG.new(resultBuffer) end)
            if not successPng or not pngImage then 
                StatusLabel.Text = "Status: Bad image file!" 
                BotConfig.Enabled = false ToggleBtn.Text = "START" return 
            end

            local resX = tonumber(LocalDrawingCanvas.CurrentResX or 150)
            local resY = tonumber(LocalDrawingCanvas.CurrentResY or 150)
            
            StatusLabel.Text = "Status: Drawing..."
            
            local canvas = LocalDrawingCanvas
            local drawLine = canvas.DrawLine
            local renderCanvas = canvas.Render
            local imgWidth = pngImage.Width
            local imgHeight = pngImage.Height
            local getPixel = pngImage.GetPixel
            local math_clamp = math.clamp
            local math_floor = math.floor
            local vec2_new = Vector2.new
            local task_wait = task.wait
            local config = BotConfig
            local isInstant = config.InstantDraw

            for y = 1, resY do
                if not config.Enabled then return end
                
                local ratioY = y / resY
                for x = 1, resX do
                    local srcX = math_clamp(math_floor((x / resX) * imgWidth), 1, imgWidth)
                    local srcY = math_clamp(math_floor(ratioY * imgHeight), 1, imgHeight)
                    
                    local color, alpha = getPixel(pngImage, srcX, srcY)
                    
                    if alpha > 15 then
                        local pPos = vec2_new(x, y)
                        drawLine(canvas, pPos, pPos, color, 1)
                    end
                end
                
                if not isInstant then
                    ProgressBarFill.Size = UDim2.new(ratioY, 0, 1, 0)
                    if y % 4 == 0 then
                        if renderCanvas then renderCanvas(canvas) end
                        task_wait()
                    end
                end
            end
            
            if renderCanvas then renderCanvas(canvas) end
            ProgressBarFill.Size = UDim2.new(1, 0, 1, 0)
            StatusLabel.Text = "Status: Done!"
            BotConfig.Enabled = false
            ToggleBtn.Text = "START"
            ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
        end)
    end
end)
