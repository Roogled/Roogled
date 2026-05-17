if not pcall(function() return bit32 end) and pcall(function() return bit end) then
    getfenv().bit32 = bit
end

local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local LocalPlayer = Players.LocalPlayer
local LocalDrawingCanvas = nil

local BotConfig = {
    Enabled = false,
    ImageURL = "",
    InstantDraw = false
}

local Unfilter, BinaryReader, Deflate
local chunks = {}
local PNG = {}
PNG.__index = PNG

---------------------------------------------------------------------------------------------
-- [1. GUI INTERFACE]
---------------------------------------------------------------------------------------------
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
Title.Text = "Draw & Donate Auto Draw (Ultra Opt)"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.BackgroundColor3 = Color3.fromRGB(34, 34, 40)
Title.Font = Enum.Font.SourceSans
Title.TextSize = 14
Title.Parent = MainFrame

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

local ToggleBtn = CreateButton("Please wait...", 50, function() end)
ToggleBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 75)
ToggleBtn.AutoButtonColor = false

local ModeBtn = CreateButton("Mode: Smooth (Stable but slow)", 87, function() end)
ModeBtn.MouseButton1Click:Connect(function()
    BotConfig.InstantDraw = not BotConfig.InstantDraw
    if BotConfig.InstantDraw then
        ModeBtn.Text = "Mode: Instant (Fast/Laggy)"
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
StatusLabel.Text = "Status: Connecting..."
StatusLabel.TextColor3 = Color3.fromRGB(255, 165, 0)
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
ProgressBarFill.Parent = ProgressBarBg

---------------------------------------------------------------------------------------------
-- [2. СВЕРХБЫСТРЫЙ ИСПРАВЛЕННЫЙ PNG-ПАРСЕР]
---------------------------------------------------------------------------------------------
function PNG.new(buffer)
    local reader = BinaryReader.new(buffer)
    local file = { Chunks = {}, Metadata = {}, Reading = true, ZlibStream = "" }
    reader:ReadString(8) -- Пропускаем хедер
    
    while file.Reading do
        local length = reader:ReadInt32()
        local chunkType = reader:ReadString(4)
        local data
        if length > 0 then
            data = reader:ForkReader(length)
            reader:ReadUInt32() -- Пропускаем CRC
        end
        local chunk = { Length = length, Type = chunkType, Data = data }
        local handler = chunks[chunkType]
        if handler then handler(file, chunk) end
        table.insert(file.Chunks, chunk)
    end
    
    local result = {}
    local idx = 0
    Deflate:InflateZlib({
        Input = BinaryReader.new(file.ZlibStream),
        Output = function(byte)
            idx = idx + 1
            result[idx] = string.char(byte)
        end
    })
    
    local width = file.Width
    local height = file.Height
    local colorType = file.ColorType
    local bpp = (colorType == 2 and 3) or (colorType == 6 and 4) or 4
    local bufferData = BinaryReader.new(table.concat(result))
    
    -- Сразу генерируем плоскую таблицу цветов вместо кучи функций
    local colorTable = table.create(height)
    local alphaTable = table.create(height)
    
    local fromRGB = Color3.fromRGB
    for row = 1, height do
        bufferData:ReadByte() -- Тип фильтра (упрощено, предполагает стандартные фильтры)
        local bytes = bufferData:ReadBytes(width * bpp, true)
        
        local rowColors = table.create(width)
        local rowAlphas = table.create(width)
        
        local bIdx = 1
        if colorType == 2 then -- RGB
            for col = 1, width do
                rowColors[col] = fromRGB(bytes[bIdx] or 255, bytes[bIdx+1] or 255, bytes[bIdx+2] or 255)
                rowAlphas[col] = 255
                bIdx = bIdx + 3
            end
        elseif colorType == 6 then -- RGBA
            for col = 1, width do
                rowColors[col] = fromRGB(bytes[bIdx] or 255, bytes[bIdx+1] or 255, bytes[bIdx+2] or 255)
                rowAlphas[col] = bytes[bIdx+3] or 255
                bIdx = bIdx + 4
            end
        else -- На случай других форматов, ставим заглушку белого
            for col = 1, width do
                rowColors[col] = fromRGB(255,255,255)
                rowAlphas[col] = 255
            end
        end
        colorTable[row] = rowColors
        alphaTable[row] = rowAlphas
    end
    
    file.ColorTable = colorTable
    file.AlphaTable = alphaTable
    return file
end

---------------------------------------------------------------------------------------------
-- [3. ASYNCHRONOUS MODULE DOWNLOADING]
---------------------------------------------------------------------------------------------
task.spawn(function()
    local function secureGet(url)
        local s, r = pcall(function() return game:HttpGet(url) end)
        if s then return loadstring(r)() end
        return nil
    end

    Unfilter = secureGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-PNG-Library/master/Modules/Unfilter.lua")
    BinaryReader = secureGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-PNG-Library/master/Modules/BinaryReader.lua")
    Deflate = secureGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-PNG-Library/master/Modules/Deflate.lua")
    chunks.IDAT = secureGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-PNG-Library/master/Chunks/IDAT.lua")
    chunks.IEND = secureGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-PNG-Library/master/Chunks/IEND.lua")
    chunks.IHDR = secureGet("https://raw.githubusercontent.com/CloneTrooper1019/Roblox-PNG-Library/master/Chunks/IHDR.lua")

    if Unfilter and BinaryReader and Deflate and chunks.IDAT then
        StatusLabel.Text = "Status: Ready to draw!"
        StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 100)
        ToggleBtn.Text = "START"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(40, 150, 80)
        ToggleBtn.AutoButtonColor = true
    else
        StatusLabel.Text = "Status: Connection error!"
        StatusLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
    end
end)

---------------------------------------------------------------------------------------------
-- [4. CANVAS SEARCH AND DRAW]
---------------------------------------------------------------------------------------------
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
    if not Deflate then return end 

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
        if BotConfig.ImageURL == "" or not string.match(BotConfig.ImageURL, "http") then StatusLabel.Text = "Status: Invalid URL!" return end

        BotConfig.Enabled = true
        ToggleBtn.Text = "STOP"
        ToggleBtn.BackgroundColor3 = Color3.fromRGB(170, 40, 40)
        
        drawingThread = task.spawn(function()
            StatusLabel.Text = "Status: Downloading..."
            local successFetch, resultBuffer = pcall(function() return game:HttpGet(BotConfig.ImageURL) end)
            if not successFetch then StatusLabel.Text = "Status: Download failed!" BotConfig.Enabled = false return end

            StatusLabel.Text = "Status: Parsing PNG..."
            local successPng, pngImage = pcall(function() return PNG.new(resultBuffer) end)
            if not successPng or not pngImage then StatusLabel.Text = "Status: Bad PNG file!" BotConfig.Enabled = false return end

            local resX = tonumber(LocalDrawingCanvas.CurrentResX or 150)
            local resY = tonumber(LocalDrawingCanvas.CurrentResY or 150)
            
            StatusLabel.Text = "Status: Drawing..."
            
            -- КЭШ ПРЯМОЙ ТАБЛИЦЫ (БЕЗ ФУНКЦИЙ)
            local canvas = LocalDrawingCanvas
            local drawLine = canvas.DrawLine
            local renderCanvas = canvas.Render
            local imgWidth = pngImage.Width
            local imgHeight = pngImage.Height
            local cTable = pngImage.ColorTable
            local aTable = pngImage.AlphaTable
            
            local math_clamp = math.clamp
            local math_floor = math.floor
            local vec2_new = Vector2.new
            local task_wait = task.wait
            local config = BotConfig
            local isInstant = config.InstantDraw

            for y = 1, resY do
                if not config.Enabled then return end
                
                local ratioY = y / resY
                local srcY = math_clamp(math_floor(ratioY * imgHeight), 1, imgHeight)
                local targetColorRow = cTable[srcY]
                local targetAlphaRow = aTable[srcY]
                
                for x = 1, resX do
                    local srcX = math_clamp(math_floor((x / resX) * imgWidth), 1, imgWidth)
                    
                    -- Читаем напрямую из плоского массива, процессор отдыхает:
                    local alpha = targetAlphaRow[srcX] or 0
                    if alpha > 15 then
                        local color = targetColorRow[srcX]
                        local pPos = vec2_new(x, y)
                        drawLine(canvas, pPos, pPos, color, 1)
                    end
                end
                
                if not isInstant then
                    ProgressBarFill.Size = UDim2.new(ratioY, 0, 1, 0)
                    -- Оптимальный шаг отрисовки для плавности
                    if y % 5 == 0 then
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
