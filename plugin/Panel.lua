--!nonstrict
-- Панель RussTeam. Ничего не решает: показывает состояние S
-- и сообщает о нажатиях через обработчики H.

local Selection  = game:GetService("Selection")
local RunService = game:GetService("RunService")
local Config = require(script.Parent.Config)

local LOGO     = Config.LOGO
local LOGO_ON  = Config.LOGO_ON
local LOGO_OFF = Config.LOGO_OFF
local VERSION    = Config.VERSION
local IDLE_AFTER = Config.IDLE_AFTER

local Panel = {}

-- Состояние и обработчики подставляет главный скрипт
local S = {
	connected = false, statusText = "не подключен", meName = "?", meId = 0,
	roster = {}, history = {}, conflicts = {}, bigPending = nil,
	autoOn = true, myPending = 0, presenceNote = nil, devShown = false,
}
local H = {}
local oldVersions = 0   -- у скольких участников версия не наша

local function agoText(ts)
	if not ts then return "давно" end
	local d = os.time() - ts
	if d < 90 then return "сейчас" end
	if d < 3600 then return string.format("%d мин назад", math.floor(d / 60)) end
	if d < 86400 then return string.format("%d ч назад", math.floor(d / 3600)) end
	return string.format("%d дн назад", math.floor(d / 86400))
end

function Panel.create(plugin, state, handlers)
	S = state
	H = handlers

-- Интерфейс
--==============================================================

local toolbar = plugin:CreateToolbar("RussTeam")

-- Кнопку делаем первой. Если что-то ниже сломается на другой версии Studio,
-- она всё равно будет на месте — иначе плагин пропадает молча.
local openBtn = toolbar:CreateButton("RussTeam", "Перенос изменений между проектами", LOGO_OFF)
openBtn.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"RussTeamPanel",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 340, 560, 300, 380)
)
widget.Title = "RussTeam"

local BG     = Color3.fromRGB(28, 33, 44)
local PANEL  = Color3.fromRGB(41, 47, 60)
local FIELD  = Color3.fromRGB(35, 40, 52)
local TEXT   = Color3.fromRGB(238, 241, 246)
local MUTED  = Color3.fromRGB(140, 149, 166)
local BLUE   = Color3.fromRGB(58, 122, 224)
local GREEN  = Color3.fromRGB(66, 160, 96)
local WARN   = Color3.fromRGB(220, 160, 60)
local RED    = Color3.fromRGB(214, 92, 92)

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.fromScale(1, 1)
scroll.BackgroundColor3 = BG
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 5
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = widget

local root = Instance.new("Frame")
root.Size = UDim2.new(1, 0, 0, 0)
root.AutomaticSize = Enum.AutomaticSize.Y
root.BackgroundTransparency = 1
root.Parent = scroll

do
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 6)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = root
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, 10)
	p.PaddingLeft = UDim.new(0, 10)
	p.PaddingRight = UDim.new(0, 10)
	p.PaddingBottom = UDim.new(0, 12)
	p.Parent = root
end

local order = 0
local function nextOrder()
	order += 1
	return order
end

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 6)
	c.Parent = inst
end

local function label(text, color, size, bold)
	local l = Instance.new("TextLabel")
	l.Size = UDim2.new(1, 0, 0, size or 18)
	l.BackgroundTransparency = 1
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = bold and 13 or 12
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = color or TEXT
	l.Text = text
	l.TextWrapped = true
	l.LayoutOrder = nextOrder()
	l.Parent = root
	return l
end

local function button(text, color, height)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, height or 32)
	b.BackgroundColor3 = color or PANEL
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 13
	b.TextColor3 = TEXT
	b.Text = text
	b.LayoutOrder = nextOrder()
	b.Parent = root
	corner(b)
	return b
end

local function field(placeholder, settingKey)
	local box = Instance.new("TextBox")
	box.Size = UDim2.new(1, 0, 0, 28)
	box.BackgroundColor3 = FIELD
	box.BorderSizePixel = 0
	box.Font = Enum.Font.Code
	box.TextSize = 12
	box.TextColor3 = TEXT
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = MUTED
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = plugin:GetSetting(settingKey) or ""
	box.LayoutOrder = nextOrder()
	box.Parent = root
	corner(box, 4)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.Parent = box
	-- Сохраняем на каждое изменение текста, а не только при потере фокуса:
	-- иначе вписал, сразу нажал «Подключиться» — и значение не запомнилось.
	local function remember()
		local value = box.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if value ~= (plugin:GetSetting(settingKey) or "") then
			plugin:SetSetting(settingKey, value)
		end
	end
	box:GetPropertyChangedSignal("Text"):Connect(remember)
	box.FocusLost:Connect(remember)
	return box
end

-- шапка с логотипом и лампочкой состояния
local dot, whoLbl
do
	local head = Instance.new("Frame")
	head.Size = UDim2.new(1, 0, 0, 42)
	head.BackgroundTransparency = 1
	head.LayoutOrder = nextOrder()
	head.Parent = root

	local logo = Instance.new("ImageLabel")
	logo.Size = UDim2.fromOffset(34, 34)
	logo.BackgroundTransparency = 1
	logo.Image = LOGO
	logo.Parent = head

	local n = Instance.new("TextLabel")
	n.Size = UDim2.new(1, -60, 0, 20)
	n.Position = UDim2.fromOffset(44, 2)
	n.BackgroundTransparency = 1
	n.Font = Enum.Font.GothamBold
	n.TextSize = 16
	n.TextXAlignment = Enum.TextXAlignment.Left
	n.TextColor3 = TEXT
	n.Text = "RussTeam"
	n.Parent = head

	whoLbl = Instance.new("TextLabel")
	whoLbl.Size = UDim2.new(1, -60, 0, 14)
	whoLbl.Position = UDim2.fromOffset(44, 22)
	whoLbl.BackgroundTransparency = 1
	whoLbl.Font = Enum.Font.Gotham
	whoLbl.TextSize = 11
	whoLbl.TextXAlignment = Enum.TextXAlignment.Left
	whoLbl.TextColor3 = MUTED
	whoLbl.Text = "не подключен"
	whoLbl.Parent = head

	dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(10, 10)
	dot.Position = UDim2.new(1, -12, 0, 12)
	dot.BackgroundColor3 = MUTED
	dot.BorderSizePixel = 0
	dot.Parent = head
	corner(dot, 5)
end

-- Крупная полоса состояния: видно с одного взгляда, не читая текст
local banner, bannerMain, bannerSub
do
	banner = Instance.new("Frame")
	banner.Size = UDim2.new(1, 0, 0, 46)
	banner.BackgroundColor3 = PANEL
	banner.BorderSizePixel = 0
	banner.LayoutOrder = nextOrder()
	banner.Parent = root
	corner(banner)

	local stripe = Instance.new("Frame")
	stripe.Name = "Stripe"
	stripe.Size = UDim2.new(0, 4, 1, -12)
	stripe.Position = UDim2.fromOffset(0, 6)
	stripe.BackgroundColor3 = MUTED
	stripe.BorderSizePixel = 0
	stripe.Parent = banner
	corner(stripe, 2)

	bannerMain = Instance.new("TextLabel")
	bannerMain.Size = UDim2.new(1, -22, 0, 20)
	bannerMain.Position = UDim2.fromOffset(14, 5)
	bannerMain.BackgroundTransparency = 1
	bannerMain.Font = Enum.Font.GothamBold
	bannerMain.TextSize = 14
	bannerMain.TextXAlignment = Enum.TextXAlignment.Left
	bannerMain.TextColor3 = MUTED
	bannerMain.Text = "НЕ ПОДКЛЮЧЕН"
	bannerMain.Parent = banner

	bannerSub = Instance.new("TextLabel")
	bannerSub.Size = UDim2.new(1, -22, 0, 16)
	bannerSub.Position = UDim2.fromOffset(14, 24)
	bannerSub.BackgroundTransparency = 1
	bannerSub.Font = Enum.Font.Gotham
	bannerSub.TextSize = 11
	bannerSub.TextXAlignment = Enum.TextXAlignment.Left
	bannerSub.TextTruncate = Enum.TextTruncate.AtEnd
	bannerSub.TextColor3 = MUTED
	bannerSub.Text = "введи ключ и канал"
	bannerSub.Parent = banner
end

-- Ход приёма: видно, сколько осталось, и что трогать проект нельзя
local progFrame, progFill, progText
do
	progFrame = Instance.new("Frame")
	progFrame.Size = UDim2.new(1, 0, 0, 34)
	progFrame.BackgroundColor3 = PANEL
	progFrame.BorderSizePixel = 0
	progFrame.Visible = false
	progFrame.LayoutOrder = nextOrder()
	progFrame.Parent = root
	corner(progFrame)

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, -16, 0, 6)
	track.Position = UDim2.fromOffset(8, 22)
	track.BackgroundColor3 = FIELD
	track.BorderSizePixel = 0
	track.Parent = progFrame
	corner(track, 3)

	progFill = Instance.new("Frame")
	progFill.Size = UDim2.new(0, 0, 1, 0)
	progFill.BackgroundColor3 = GREEN
	progFill.BorderSizePixel = 0
	progFill.Parent = track
	corner(progFill, 3)

	progText = Instance.new("TextLabel")
	progText.Size = UDim2.new(1, -16, 0, 18)
	progText.Position = UDim2.fromOffset(8, 3)
	progText.BackgroundTransparency = 1
	progText.Font = Enum.Font.GothamMedium
	progText.TextSize = 12
	progText.TextXAlignment = Enum.TextXAlignment.Left
	progText.TextColor3 = WARN
	progText.Text = ""
	progText.Parent = progFrame
end

label("Канал — общий код у обоих", MUTED)
local chanBox = field("RUSSTEAM-7K4M-92XQ", "channel")

local hintLbl = label("", WARN, 46)
hintLbl.Text = "Плагину нужен свой сервер-посредник: файл server.py из комплекта, "
	.. "поднимается на любой машине за пару минут. Адрес и ключ впиши ниже."

local advBtn = button("Показать: сервер и ключ")
local uniLbl = label("адрес сервера, например http://12.34.56.78:8770", MUTED)
local srvBox = field("http://адрес:8770", "server")
local keyLbl = label("ключ доступа к серверу", MUTED)
local keyBox = field("rt_...", "key")

local connectBtn = button("Подключиться", BLUE, 38)
local statusLbl = label("не подключен", MUTED, 32)

local peopleLbl = label("Кто в канале", MUTED, 18, true)
local peopleFrame = Instance.new("Frame")
peopleFrame.Size = UDim2.new(1, 0, 0, 0)
peopleFrame.AutomaticSize = Enum.AutomaticSize.Y
peopleFrame.BackgroundColor3 = PANEL
peopleFrame.BorderSizePixel = 0
peopleFrame.LayoutOrder = nextOrder()
peopleFrame.Parent = root
corner(peopleFrame)
do
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 2)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = peopleFrame
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, 6)
	p.PaddingBottom = UDim.new(0, 6)
	p.PaddingLeft = UDim.new(0, 8)
	p.PaddingRight = UDim.new(0, 8)
	p.Parent = peopleFrame
end

local devBtn = button("Показать подробности")
local histLbl = label("Что происходит", MUTED, 18, true)
local histFrame = Instance.new("Frame")
histFrame.Size = UDim2.new(1, 0, 0, 0)
histFrame.AutomaticSize = Enum.AutomaticSize.Y
histFrame.BackgroundColor3 = PANEL
histFrame.BorderSizePixel = 0
histFrame.LayoutOrder = nextOrder()
histFrame.Parent = root
corner(histFrame)
do
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 2)
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = histFrame
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, 6)
	p.PaddingBottom = UDim.new(0, 6)
	p.PaddingLeft = UDim.new(0, 8)
	p.PaddingRight = UDim.new(0, 8)
	p.Parent = histFrame
end

local bigBtn = button("Принять большую пачку", WARN)
local fullAcceptBtn = button("Принять весь проект", WARN, 38)
local sendDelBtn = button("Отправить удаления", RED, 38)
local rejectFullBtn = button("Отклонить весь проект")
local rejectBigBtn = button("Отклонить")
local rejectSendBtn = button("Не отправлять")

local conflictLbl = label("Конфликты", MUTED, 18, true)
local conflictFrame = Instance.new("Frame")
conflictFrame.Size = UDim2.new(1, 0, 0, 0)
conflictFrame.AutomaticSize = Enum.AutomaticSize.Y
conflictFrame.BackgroundColor3 = PANEL
conflictFrame.BorderSizePixel = 0
conflictFrame.LayoutOrder = nextOrder()
conflictFrame.Parent = root
corner(conflictFrame)
do
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, 2)
	l.Parent = conflictFrame
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, 6)
	p.PaddingBottom = UDim.new(0, 6)
	p.PaddingLeft = UDim.new(0, 8)
	p.PaddingRight = UDim.new(0, 8)
	p.Parent = conflictFrame
end

-- внизу: ручной обмен и переключатель живого режима
local syncBtn = button("Обменяться сейчас")
local fullBtn = button("Отправить весь проект")
local askFullBtn = button("Запросить весь проект")
local pruneBtn = button("Убрать то, чего нет у напарника")
local dedupeBtn = button("Убрать дубликаты")
local repairBtn = button("Починить пустые меши")
local autoBtn = button("Живой режим: включён", GREEN)

-- Служебное показываем только по просьбе: в обычной работе панель должна
-- отвечать на один вопрос — идёт обмен или нет.
local function setDev(on)
	S.devShown = on
	histLbl.Visible = on
	histFrame.Visible = on
	peopleLbl.Visible = on
	peopleFrame.Visible = on
	pruneBtn.Visible = on and S.connected
	dedupeBtn.Visible = on and S.connected
	repairBtn.Visible = on and S.connected
	conflictLbl.Visible = on or (#S.conflicts > 0)
	conflictFrame.Visible = on or (#S.conflicts > 0)
	syncBtn.Visible = on and S.connected
	devBtn.Text = on and "Скрыть подробности" or "Показать подробности"
end
devBtn.MouseButton1Click:Connect(function() setDev(not S.devShown) end)

-- Адрес сервера прячем: он нужен раз в жизни
local advShown = false
local function setAdvanced(on)
	advShown = on
	uniLbl.Visible = on
	srvBox.Visible = on
	keyLbl.Visible = on
	keyBox.Visible = on
	hintLbl.Visible = (srvBox.Text == "" or keyBox.Text == "")
	advBtn.Text = on and "Скрыть: сервер и ключ" or "Показать: сервер и ключ"
end
advBtn.MouseButton1Click:Connect(function() setAdvanced(not advShown) end)
setAdvanced(srvBox.Text == "" or keyBox.Text == "")
setDev(false)

--==============================================================
-- Перерисовка
--==============================================================

local function emptyRow(parent, text)
	local f = Instance.new("Frame")
	f.Size = UDim2.new(1, 0, 0, 22)
	f.BackgroundTransparency = 1
	f.Parent = parent
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.Gotham
	t.TextSize = 12
	t.TextColor3 = MUTED
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.Text = text
	t.Parent = f
end

-- Кто из напарников сейчас за работой: недавно отмечался и у него есть неотправленное.
local function activePeers()
	local list, now = {}, os.time()
	for id, rec in pairs(S.roster) do
		if type(rec) == "table" and id ~= tostring(S.meId) then
			local fresh = rec.at and (now - rec.at) < IDLE_AFTER
			if fresh and (rec.pending or 0) > 0 then
				table.insert(list, rec.name or id)
			end
		end
	end
	return list
end

local function onlinePeers()
	local n, now = 0, os.time()
	for id, rec in pairs(S.roster) do
		if type(rec) == "table" and id ~= tostring(S.meId)
			and rec.at and (now - rec.at) < IDLE_AFTER then
			n += 1
		end
	end
	return n
end

local function refreshProgress()
	local p = S.progress
	if not p or not p.total or p.total == 0 then
		progFrame.Visible = false
		return
	end
	progFrame.Visible = true
	local share = math.clamp((p.done or 0) / p.total, 0, 1)
	progFill.Size = UDim2.new(share, 0, 1, 0)
	progText.Text = string.format("принимаю %d из %d — НЕ ТРОГАЙ ПРОЕКТ (%d%%)",
		p.done or 0, p.total, math.floor(share * 100))
end

local function refreshStatus()
	refreshProgress()
	statusLbl.Text = S.statusText
	hintLbl.Visible = not S.connected and (srvBox.Text == "" or keyBox.Text == "")
	statusLbl.TextColor3 = S.connected and TEXT or MUTED
	dot.BackgroundColor3 = S.connected and GREEN or MUTED
	whoLbl.Text = S.connected and ("подключен как " .. S.meName) or "не подключен"
	connectBtn.Text = S.connected and "Отключиться" or "Подключиться"
	connectBtn.BackgroundColor3 = S.connected and PANEL or BLUE
	-- В обычном виде панель отвечает на один вопрос: идёт обмен или нет.
	-- Всё остальное — под «Показать подробности».
	syncBtn.Visible    = S.connected and S.devShown
	fullBtn.Visible    = S.connected and S.devShown
	askFullBtn.Visible = S.connected and S.devShown
	pruneBtn.Visible   = S.connected and S.devShown
	dedupeBtn.Visible  = S.connected and S.devShown
	repairBtn.Visible  = S.connected and S.devShown
	autoBtn.Visible = S.connected
	conflictLbl.Visible = S.devShown or (#S.conflicts > 0)
	conflictFrame.Visible = S.devShown or (#S.conflicts > 0)
	bigBtn.Visible = S.bigPending ~= nil
	if S.bigPending then
		local d = S.bigPending.deletions
		bigBtn.Text = d and string.format("Принять УДАЛЕНИЕ %d объектов", d)
			or string.format("Принять %d изменений", S.bigPending.count or 0)
		bigBtn.BackgroundColor3 = d and RED or WARN
	end
	fullAcceptBtn.Visible = S.fullPending ~= nil
	sendDelBtn.Visible = S.sendPending ~= nil
	rejectFullBtn.Visible = S.fullPending ~= nil
	rejectBigBtn.Visible = S.bigPending ~= nil
	rejectSendBtn.Visible = S.sendPending ~= nil
	if S.sendPending then
		sendDelBtn.Text = string.format("Да, я удалил %d объектов — отправить",
			S.sendPending.count or 0)
	end
	if S.fullPending then
		fullAcceptBtn.Text = string.format("Принять весь проект: %d объектов",
			S.fullPending.count or 0)
	end
	if S.bigPending then
		bigBtn.Text = string.format("Принять %d изменений", S.bigPending.count)
	end
	autoBtn.Text = S.autoOn and "Живой режим: включён" or "Живой режим: выключен"
	autoBtn.BackgroundColor3 = S.autoOn and GREEN or PANEL

	local stripe = banner:FindFirstChild("Stripe")
	if not S.connected then
		bannerMain.Text = "НЕ ПОДКЛЮЧЕН"
		bannerMain.TextColor3 = MUTED
		bannerSub.Text = "изменения никуда не уходят"
		bannerSub.TextColor3 = MUTED
		if stripe then stripe.BackgroundColor3 = MUTED end
		banner.BackgroundColor3 = PANEL
		if openBtn then openBtn.Icon = LOGO_OFF end
		return
	end

	local busyList = activePeers()
	local online = onlinePeers()

	if #busyList > 0 then
		bannerMain.Text = "СЕЙЧАС РАБОТАЮТ"
		bannerMain.TextColor3 = WARN
		bannerSub.Text = table.concat(busyList, ", ") .. " правит проект прямо сейчас"
		bannerSub.TextColor3 = WARN
		if stripe then stripe.BackgroundColor3 = WARN end
		banner.BackgroundColor3 = Color3.fromRGB(56, 48, 34)
	else
		bannerMain.Text = "ПОДКЛЮЧЕН"
		bannerMain.TextColor3 = GREEN
		bannerSub.TextColor3 = MUTED
		if online > 0 then
			bannerSub.Text = string.format("в канале ещё %d, сейчас никто не правит", online)
		else
			bannerSub.Text = "в канале только ты"
		end
		if stripe then stripe.BackgroundColor3 = GREEN end
		banner.BackgroundColor3 = Color3.fromRGB(30, 46, 38)
	end

	if S.myPending > 0 then
		bannerSub.Text = bannerSub.Text .. string.format("  ·  у тебя %d неотправленных", S.myPending)
	end
	bannerSub.Text = bannerSub.Text .. (S.autoOn and "  ·  живой режим" or "  ·  вручную")
	if S.scriptsBlocked then
		bannerSub.Text = "нет разрешения менять скрипты — код не переносится"
		bannerSub.TextColor3 = RED
	elseif oldVersions > 0 then
		bannerSub.Text = string.format("у %d участник%s версия старее %s — обмен не дойдёт",
			oldVersions, oldVersions == 1 and "а" or "ов", VERSION)
		bannerSub.TextColor3 = RED
	end

	if not RunService:IsEdit() then
		bannerMain.Text = "ИДЁТ ЗАПУСК ИГРЫ"
		bannerMain.TextColor3 = MUTED
		bannerSub.Text = "обмен приостановлен, останови игру"
		local st = banner:FindFirstChild("Stripe")
		if st then st.BackgroundColor3 = MUTED end
	end
	if openBtn then openBtn.Icon = LOGO_ON end
end

local function refreshPeople()
	for _, ch in ipairs(peopleFrame:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end

	-- Короткое сообщение о том, кто только что пришёл или ушёл.
	if S.presenceNote then
		local f = Instance.new("Frame")
		f.Size = UDim2.new(1, 0, 0, 20)
		f.BackgroundTransparency = 1
		f.LayoutOrder = 0
		f.Parent = peopleFrame
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.Gotham
		t.TextSize = 11
		t.TextColor3 = MUTED
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.Text = S.presenceNote
		t.Parent = f
	end

	-- В списке только те, кто сейчас на месте. Ушедших не показываем:
	-- иначе через неделю тут кладбище из старых имён.
	local now = os.time()
	local n = 0
	oldVersions = 0
	for id, rec in pairs(S.roster) do
		if type(rec) == "table" and rec.at and (now - rec.at) < IDLE_AFTER then
			n += 1
			local isMe = (id == tostring(S.meId))
			local working = (rec.pending or 0) > 0
			local colour = working and WARN or GREEN
			local state = working and "правит проект" or "на месте"

			local f = Instance.new("Frame")
			f.Size = UDim2.new(1, 0, 0, 22)
			f.BackgroundTransparency = 1
			f.LayoutOrder = n
			f.Parent = peopleFrame

			local d = Instance.new("Frame")
			d.Size = UDim2.fromOffset(8, 8)
			d.Position = UDim2.fromOffset(0, 7)
			d.BackgroundColor3 = colour
			d.BorderSizePixel = 0
			d.Parent = f
			corner(d, 4)

			-- Версия у каждого на виду: разные версии — самая частая причина
			-- того, что изменения не доходят.
			local ver = tostring(rec.ver or "?")
			local outdated = (ver ~= VERSION) and ver ~= "?"

			local t = Instance.new("TextLabel")
			t.Size = UDim2.new(1, -96, 1, 0)
			t.Position = UDim2.fromOffset(14, 0)
			t.BackgroundTransparency = 1
			t.Font = working and Enum.Font.GothamMedium or Enum.Font.Gotham
			t.TextSize = 12
			t.TextXAlignment = Enum.TextXAlignment.Left
			t.TextTruncate = Enum.TextTruncate.AtEnd
			t.TextColor3 = isMe and MUTED or (working and WARN or TEXT)
			t.Text = string.format("%s%s — %s", rec.name or id, isMe and " (ты)" or "", state)
			t.Parent = f

			if not isMe then
				local kick = Instance.new("TextButton")
				kick.Size = UDim2.fromOffset(18, 18)
				kick.Position = UDim2.new(1, -18, 0, 2)
				kick.BackgroundColor3 = FIELD
				kick.BorderSizePixel = 0
				kick.Font = Enum.Font.GothamBold
				kick.TextSize = 12
				kick.TextColor3 = RED
				kick.Text = "×"
				kick.Parent = f
				corner(kick, 4)
				kick.MouseButton1Click:Connect(function()
					if H.onKick then H.onKick(id, rec.name) end
				end)
			end

			local v = Instance.new("TextLabel")
			v.Size = UDim2.fromOffset(52, 22)
			v.Position = UDim2.new(1, isMe and -52 or -74, 0, 0)
			v.BackgroundTransparency = 1
			v.Font = outdated and Enum.Font.GothamBold or Enum.Font.Gotham
			v.TextSize = 11
			v.TextXAlignment = Enum.TextXAlignment.Right
			v.TextColor3 = outdated and RED or MUTED
			v.Text = outdated and (ver .. " ⚠") or ver
			v.Parent = f
			if outdated then oldVersions += 1 end
		end
	end
	if n == 0 then emptyRow(peopleFrame, "никого") end
end

local function refreshHistory()
	for _, ch in ipairs(histFrame:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end
	if #S.history == 0 then
		emptyRow(histFrame, "пока ничего")
		return
	end
	for i, item in ipairs(S.history) do
		if i > 12 then break end
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 20)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		row.Parent = histFrame

		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.Gotham
		t.TextSize = 12
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.TextColor3 = (i == 1) and TEXT or MUTED
		t.Text = string.format("%s  ·  %s", os.date("%H:%M", item.at), item.text)
		t.Parent = row
	end
end

local function refreshConflicts()
	for _, ch in ipairs(conflictFrame:GetChildren()) do
		if ch:IsA("Frame") then ch:Destroy() end
	end
	if #S.conflicts == 0 then
		emptyRow(conflictFrame, "нет")
		return
	end
	for i, entry in ipairs(S.conflicts) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 50)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		row.Parent = conflictFrame

		local t = Instance.new("TextLabel")
		t.Size = UDim2.new(1, 0, 0, 20)
		t.BackgroundTransparency = 1
		t.Font = Enum.Font.GothamMedium
		t.TextSize = 12
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextColor3 = WARN
		t.TextTruncate = Enum.TextTruncate.AtEnd
		t.Text = entry.name .. " (" .. entry.cls .. ")"
		t.Parent = row

		local function small(text, x, w, cb)
			local b = Instance.new("TextButton")
			b.Size = UDim2.fromOffset(w, 22)
			b.Position = UDim2.fromOffset(x, 22)
			b.BackgroundColor3 = FIELD
			b.BorderSizePixel = 0
			b.Font = Enum.Font.Gotham
			b.TextSize = 11
			b.TextColor3 = TEXT
			b.Text = text
			b.Parent = row
			corner(b, 4)
			b.MouseButton1Click:Connect(cb)
		end
		small("Взять чужое", 0, 88, function()
			local _, index = H.scan()
			local inst = index[entry.sid]
			if inst then
				inst.Name = entry.theirs.name
				H.applyProps(inst, entry.theirs.props)
				H.flushRefs(index)
			end
			table.remove(S.conflicts, i)
			refreshConflicts()
		end)
		small("Оставить своё", 92, 94, function()
			table.remove(S.conflicts, i)
			refreshConflicts()
		end)
		small("Найти", 190, 54, function()
			local _, index = H.scan()
			local inst = index[entry.sid]
			if inst then Selection:Set({ inst }) end
		end)
	end
end

local function refreshAll()
	refreshPeople()   -- первым: здесь считаются устаревшие версии
	refreshStatus()
	refreshHistory()
	refreshConflicts()
end

	--==============================================================
	-- Нажатия: панель только сообщает о них наружу
	--==============================================================

	connectBtn.MouseButton1Click:Connect(function()
		if H.onConnect then H.onConnect() end
	end)
	syncBtn.MouseButton1Click:Connect(function()
		if H.onSync then H.onSync() end
	end)
	fullBtn.MouseButton1Click:Connect(function()
		if H.onFullPush then H.onFullPush() end
	end)
	dedupeBtn.MouseButton1Click:Connect(function()
		if H.onDedupe then H.onDedupe() end
	end)
	repairBtn.MouseButton1Click:Connect(function()
		if H.onRepairMeshes then H.onRepairMeshes() end
	end)
	autoBtn.MouseButton1Click:Connect(function()
		if H.onToggleAuto then H.onToggleAuto() end
	end)
	bigBtn.MouseButton1Click:Connect(function()
		if H.onAcceptBig then H.onAcceptBig() end
	end)
	fullAcceptBtn.MouseButton1Click:Connect(function()
		if H.onAcceptFull then H.onAcceptFull() end
	end)
	sendDelBtn.MouseButton1Click:Connect(function()
		if H.onAcceptSend then H.onAcceptSend() end
	end)
	rejectFullBtn.MouseButton1Click:Connect(function()
		if H.onRejectFull then H.onRejectFull() end
	end)
	rejectBigBtn.MouseButton1Click:Connect(function()
		if H.onRejectBig then H.onRejectBig() end
	end)
	rejectSendBtn.MouseButton1Click:Connect(function()
		if H.onRejectSend then H.onRejectSend() end
	end)
	askFullBtn.MouseButton1Click:Connect(function()
		if H.onRequestFull then H.onRequestFull() end
	end)
	pruneBtn.MouseButton1Click:Connect(function()
		if H.onPrune then H.onPrune() end
	end)
	openBtn.Click:Connect(function()
		widget.Enabled = not widget.Enabled
		openBtn:SetActive(widget.Enabled)
	end)
	openBtn:SetActive(widget.Enabled)

	-- отдаём наружу то, что нужно главному скрипту
	Panel.refresh = refreshAll
	Panel.fields = function()
		return chanBox.Text, srvBox.Text, keyBox.Text
	end
	Panel.setFields = function(chan, srv, key)
		if chan then chanBox.Text = chan end
		if srv then srvBox.Text = srv end
		if key then keyBox.Text = key end
	end
	Panel.widget = widget
	Panel.showSetup = setAdvanced

	refreshAll()
	return Panel
end

return Panel
