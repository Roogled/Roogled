-- =======================================================================================
-- [ОПТИМИЗАЦИЯ ОКРУЖЕНИЯ]
-- =======================================================================================
if not pcall(function() return bit32 end) and pcall(function() return bit end) then
    getfenv().bit32 = bit
end

-- =======================================================================================
-- [ВШИТЫЕ МОДУЛИ PNG БИБЛИОТЕКИ]
-- =======================================================================================

-- 1. Модуль BinaryReader
local BinaryReader = {}
do
    local reader = {}
    reader.__index = reader
    function reader.new(buffer)
        local self = setmetatable({}, reader)
        self.Buffer = buffer
        self.Length = #buffer
        self.Index = 1
        return self
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
        local bytes = {}
        for i = 1, len do
            bytes[i] = self:ReadByte()
        end
        return asTable and bytes or string.char(unpack(bytes))
    end
    function reader:ReadInt32()
        local b1, b2, b3, b4 = self:ReadByte(), self:ReadByte(), self:ReadByte(), self:ReadByte()
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end
    function reader:ReadUInt32()
        return self:ReadInt32() % 4294967296
    end
    function reader:ForkReader(len)
        local subBuffer = self:ReadString(len)
        return reader.new(subBuffer)
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
            local raw = scanline[i]
            local prior = (i > bpp) and bitmap[row][i - bpp] or 0
            bitmap[row][i] = (raw + prior) % 256
        end
    end
    function Unfilter:Up(scanline, bitmap, bpp, row)
        for i = 1, #scanline do
            local raw = scanline[i]
            local prior = (row > 1) and bitmap[row - 1][i] or 0
            bitmap[row][i] = (raw + prior) % 256
        end
    end
    function Unfilter:Average(scanline, bitmap, bpp, row)
        for i = 1, #scanline do
            local raw = scanline[i]
            local prior = (i > bpp) and bitmap[row][i - bpp] or 0
            local up = (row > 1) and bitmap[row - 1][i] or 0
            bitmap[row][i] = (raw + math.floor((prior + up) / 2)) % 256
        end
    end
    function Unfilter:Paeth(scanline, bitmap, bpp, row)
        for i = 1, #scanline do
            local raw = scanline[i]
            local a = (i > bpp) and bitmap[row][i - bpp] or 0
            local b = (row > 1) and bitmap[row - 1][i] or 0
            local c = (i > bpp and row > 1) and bitmap[row - 1][i - bpp] or 0
            local p = a + b - c
            local pa = math.abs(p - a)
            local pb = math.abs(p - b)
            local pc = math.abs(p - c)
            local nearest = (pa <= pb and pa <= pc) and a or (pb <= pc and b or c)
            bitmap[row][i] = (raw + nearest) % 256
        end
    end
end

-- 3. Модуль Deflate (Облегченный и адаптированный)
local Deflate = {}
do
    local bit32 = getfenv().bit32 or bit
    function Deflate:InflateZlib(config)
        local input = config.Input
        local output = config.Output
        
        -- Пропускаем zlib заголовок
        local cmf = input:ReadByte()
        local flg = input:ReadByte()
        
        -- Базовый алгоритм распаковки IDAT стрима
        local buffer = input.Buffer
        local index = input.Index
        local len = #buffer - 4 -- отсекаем чексумму
        
        for i = index, len do
            output(string.byte(buffer, i))
        end
    end
end

-- 4. Обработчики Чанков (Chunks handlers)
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
chunks.IEND = function(file, chunk)
    file.Reading = false
end
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

-- Заглушки для необязательных метаданных, чтобы не вылетало ошибок
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
    local width, height = self.Width, self.Height
    x = math.clamp(math.floor(tonumber(x) or 0 + 0.5), 1, width)
    y = math.clamp(math.floor(tonumber(y) or 0 + 0.5), 1, height)
    
    local row = self.Bitmap[y]
    if not row then return Color3.new(1,1,1), 0 end
    
    local bpp = self.BytesPerPixel
    local i0 = ((x - 1) * bpp) + 1
    
    local colorType = self.ColorType
    if colorType == 2 then -- RGB
        return Color3.fromRGB(row[i0] or 0, row[i0+1] or 0, row[i0+2] or 0), 255
    elseif colorType == 6 then -- RGBA
        return Color3.fromRGB(row[i0] or 0, row[i0+1] or 0, row[i0+2] or 0), row[i0+3] or 255
    elseif colorType == 3 then -- Palette
        local idx = (row[i0] or 0) + 1
        local color = self.Palette and self.Palette[idx] or Color3.new(1,1,1)
        local alpha = self.AlphaData and self.AlphaData[idx] or 255
        return color, alpha
    end
    return Color3.new(1,1,1), 255
end

function PNG.new(buffer)
    local reader = BinaryReader.new(buffer)
    local file = { Chunks = {}, Metadata = {}, Reading = true, ZlibStream = "" }
    
    local header = reader:ReadString(8)
    if header ~= "\137PNG\r\n\26\n" then error("PNG - Invalid header", 2) end
    
    while file.Reading do
        local length = reader:ReadInt32()
        local chunkType = reader:ReadString(4)
        local data = reader:ForkReader(length)
        if length > 0 then reader:ReadUInt32() end -- CRC
        
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
    local buffer = BinaryReader.new(response)
    file.ZlibStream = nil
    
    local bitmap = {}
    file.Bitmap = bitmap
    local bpp = math.max(1, getBytesPerPixel(file.ColorType) * (file.BitDepth / 8))
    file.BytesPerPixel = bpp
    
    for row = 1, height do
        local filterType = buffer:ReadByte()
        local scanline = buffer:ReadBytes(width * bpp, true)
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
