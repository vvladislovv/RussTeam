--!nonstrict
-- Применение чужих изменений к своему проекту: создание, правка,
-- ссылки между объектами и удаление в правильном порядке.

local AssetService = game:GetService("AssetService")

local Config    = require(script.Parent.Config)
local Serialize = require(script.Parent.Serialize)

local SID_ATTR    = Config.SID_ATTR
local decodeValue = Serialize.decodeValue

local Apply = {}

-- Точка отсчёта и сообщения о поломках приходят снаружи:
-- модуль не должен знать, откуда берётся состояние.
local baseline, onError = {}, function() end

function Apply.setBaseline(snap) baseline = snap or {} end
function Apply.setErrorSink(fn) onError = fn or function() end end

local function logError(fmt, ...) onError(string.format(fmt, ...)) end

-- Обычные сообщения наружу не выводим: их место в журнале панели.
local function log(_fmt, ...) end

local function serviceByName(name)
	local ok, svc = pcall(function() return game:GetService(name) end)
	return ok and svc or nil
end

-- Ищем ребёнка сначала по номеру, потом по имени и классу.
local function findChild(parent, entry, index)
	if entry.s and index[entry.s] then
		local cached = index[entry.s]
		if cached.Parent == parent then return cached end
	end
	for _, c in ipairs(parent:GetChildren()) do
		if c:GetAttribute(SID_ATTR) == entry.s then
			index[entry.s] = c
			return c
		end
	end
	for _, c in ipairs(parent:GetChildren()) do
		if c.Name == entry.n and c.ClassName == entry.c then
			return c
		end
	end
	return nil
end

-- Ищет уже существующий такой же объект: то же имя, тот же класс, тот же
-- родитель. Нужен, когда карты похожи, но номера у объектов разные.
local function findTwin(parent, rec, claimed)
	if not parent then return nil end
	for _, c in ipairs(parent:GetChildren()) do
		if c.Name == rec.name and c.ClassName == rec.cls and not claimed[c] then
			return c
		end
	end
	return nil
end

-- Родословная спасает, когда проекты разные: родителя с чужим номером у меня
-- нет, но по цепочке «Workspace → Hive → Hive4» я его найду или создам.
local function resolveByAncestry(ancestry, index)
	if type(ancestry) ~= "table" or #ancestry == 0 then return nil end

	local first = ancestry[1]
	local current = first and first.root and serviceByName(first.root) or nil
	if not current then return nil end

	for i = 2, #ancestry do
		local entry = ancestry[i]
		local found = findChild(current, entry, index)
		if not found then
			-- Достраиваем недостающего родителя. Класс берём из родословной,
			-- поэтому папка останется папкой, а модель моделью.
			local ok, made = pcall(Instance.new, entry.c or "Folder")
			if not ok or not made then
				local ok2, folder = pcall(Instance.new, "Folder")
				if not ok2 then return nil end
				made = folder
			end
			made.Name = entry.n or "Восстановлено"
			if entry.s then pcall(function() made:SetAttribute(SID_ATTR, entry.s) end) end
			made.Parent = current
			if entry.s then index[entry.s] = made end
			found = made
		end
		current = found
	end
	return current
end

-- Как resolveParent, но ничего не создаёт: для удалений достраивать
-- родителей бессмысленно и вредно.
local function resolveParentSoft(parentSid, index, ancestry)
	if type(parentSid) == "string" and parentSid:sub(1, 5) == "root:" then
		return serviceByName(parentSid:sub(6))
	end
	local direct = index[parentSid]
	if direct then return direct end
	if type(ancestry) ~= "table" or #ancestry == 0 then return nil end
	local current = ancestry[1] and ancestry[1].root and serviceByName(ancestry[1].root) or nil
	if not current then return nil end
	for i = 2, #ancestry do
		local found = findChild(current, ancestry[i], index)
		if not found then return nil end
		current = found
	end
	return current
end

local function resolveParent(parentSid, index, ancestry)
	if type(parentSid) == "string" and parentSid:sub(1, 5) == "root:" then
		return serviceByName(parentSid:sub(6))
	end
	local direct = index[parentSid]
	if direct then return direct end
	-- Номера не нашлось — идём по родословной.
	return resolveByAncestry(ancestry, index)
end

-- Готовые меши держим наготове: собрать один меш стоит запроса к Roblox,
-- а копия делается мгновенно. На модели из тысячи мешей разница огромная.
local meshCache = {}

-- Точность столкновений и отрисовки влияют на то, как Roblox собирает меш,
-- поэтому их надо задать при создании: присвоить потом не получится.
-- Учёт неудач со сборкой мешей: без него «часть мешей не переносится»
-- превращается в гадание.
local meshFails = {}

function Apply.takeMeshFails()
	local list = meshFails
	meshFails = {}
	return list
end

local function makeMeshPart(meshId, collision, render)
	local key = string.format("%s|%s|%s", meshId, tostring(collision), tostring(render))
	if meshCache[key] then
		return meshCache[key]:Clone()
	end
	local ok, made = pcall(function()
		return AssetService:CreateMeshPartAsync(meshId, {
			CollisionFidelity = collision or Enum.CollisionFidelity.Default,
			RenderFidelity = render or Enum.RenderFidelity.Automatic,
		})
	end)
	if not ok or not made then
		local reason = tostring(made)
		meshFails[meshId] = (meshFails[meshId] or reason)
		return nil, reason
	end
	meshCache[key] = made
	return made:Clone()
end

-- rec нужен, чтобы понять, как именно создавать объект.
-- MeshPart нельзя создать пустым и потом присвоить MeshId: Roblox запрещает
-- запись этого свойства. Меш собирается только через AssetService.
local function createInstance(cls, rec)
	if cls == "MeshPart" then
		local props = rec and rec.props or {}
		local encoded = props.MeshId
		local meshId = (type(encoded) == "string") and encoded or nil
		if meshId and meshId ~= "" then
			-- значения приходят числами: у Enum-свойств мы храним .Value
			local collision, render
			local cv, rv = props.CollisionFidelity, props.RenderFidelity
			if type(cv) == "table" and cv.d then
				collision = Enum.CollisionFidelity:FromValue(cv.d)
			end
			if type(rv) == "table" and rv.d then
				render = Enum.RenderFidelity:FromValue(rv.d)
			end
			local made, err = makeMeshPart(meshId, collision, render)
			if made then return made end
			-- Заготовка помечается, чтобы при следующем приёме попробовать снова:
			-- сбой мог быть временным, ассет ещё не догрузился.
			logError("меш не собрался: %s — %s", meshId, tostring(err):sub(1, 70))
		end
	end

	local ok, inst = pcall(Instance.new, cls)
	if ok and inst then return inst end

	local ok2, fallback = pcall(Instance.new, "Part")
	if ok2 then
		logError("класс %s создать не вышло, поставил Part", cls)
		return fallback
	end
	return nil
end

-- Ссылки нельзя ставить сразу: цель может приехать позже в том же пакете.
-- Копим их здесь и раскладываем последним проходом.
local deferredRefs = {}

-- Эти свойства Roblox запрещает записывать: их учитывают при создании.
local READ_ONLY = { MeshId = true, CollisionFidelity = true }

-- Сколько раз Studio отказала в записи исходников. Без разрешения на
-- изменение скриптов плагин не сможет переносить код, и человек должен
-- об этом узнать, а не гадать.
local sourceDenied = 0

function Apply.takeSourceDenied()
	local n = sourceDenied
	sourceDenied = 0
	return n
end

-- Что уже занято присланными записями. Сбрасывается один раз на приём.
local sessionClaimed = {}

function Apply.beginSession()
	sessionClaimed = {}
end

local function applyProps(inst, props)
	for name, encoded in pairs(props) do
		if READ_ONLY[name] then continue end
		if type(encoded) == "table" and encoded.__t == "ref" then
			table.insert(deferredRefs, { inst = inst, prop = name, sid = encoded.d })
		else
			local value = decodeValue(encoded)
			if value ~= nil then
				local ok, err = pcall(function() inst[name] = value end)
				if not ok and name == "Source" then
					sourceDenied += 1
					if sourceDenied == 1 then
						logError("Studio не даёт менять скрипты: %s", tostring(err):sub(1, 80))
					end
				end
			end
		end
	end
end

-- Ссылки, чья цель ещё не приехала. Раньше они просто терялись: сварка,
-- у которой вторая деталь придёт следующей пачкой, оставалась ни к чему
-- не привязанной. Теперь ждут до трёх приёмов.
local pendingRefs = {}
local REF_ATTEMPTS = 3

local function flushRefs(index)
	local placed, waiting = 0, {}

	-- сначала те, что ждали с прошлого раза
	local queue = {}
	for _, r in ipairs(pendingRefs) do table.insert(queue, r) end
	for _, r in ipairs(deferredRefs) do table.insert(queue, r) end
	deferredRefs = {}

	for _, r in ipairs(queue) do
		local target = index[r.sid]
		if target and r.inst and r.inst.Parent then
			local ok = pcall(function() r.inst[r.prop] = target end)
			if ok then
				placed += 1
			else
				r.tries = (r.tries or 0) + 1
				if r.tries < REF_ATTEMPTS then table.insert(waiting, r) end
			end
		elseif r.inst and r.inst.Parent then
			-- цель ещё не приехала: подождём следующего приёма
			r.tries = (r.tries or 0) + 1
			if r.tries < REF_ATTEMPTS then table.insert(waiting, r) end
		end
		-- объект-владелец исчез — ссылку выбрасываем молча
	end

	pendingRefs = waiting
	if #waiting > 0 then
		logError("ссылок ждут цели: %d (доставлю, когда цель приедет)", #waiting)
	end
	return placed, #waiting
end

function Apply.pendingRefCount()
	return #pendingRefs
end

-- Применяет один пакет. Возвращает список конфликтов.
local function applyEvents(events, localSnap, index, authorOfBatch)
	local conflicts = {}

	local adds, sets, dels = {}, {}, {}
	for _, ev in ipairs(events) do
		if ev.op == "add" then table.insert(adds, ev)
		elseif ev.op == "set" then table.insert(sets, ev)
		else table.insert(dels, ev) end
	end

	-- Сборка меша — обращение к Roblox, оно не мгновенное. На большой модели
	-- их сотни, поэтому каждые 20 объектов отдаём управление Studio,
	-- иначе она подвиснет на минуту и покажется, что всё сломалось.
	local built, addedCount, adopted = 0, 0, 0
	-- Закреплённые объекты живут на ВЕСЬ приём, а не на одну порцию.
	-- Иначе записи из разных порций хватают один и тот же местный объект:
	-- на проекте с сотнями одноимённых соседей так терялась половина.
	local claimed = sessionClaimed
	local function breathe()
		built += 1
		if built % 20 == 0 then task.wait() end
	end

	-- Создание: несколько проходов, потому что родитель может приехать
	-- в том же пакете и ещё не существовать.
	local remaining = adds
	for _ = 1, 8 do
		if #remaining == 0 then break end
		local stillWaiting = {}
		for _, ev in ipairs(remaining) do
			local rec = ev.rec
			if index[rec.sid] then
				table.insert(sets, { op = "set", rec = rec, base = ev.base })
			else
				local parent = resolveParent(rec.parent, index, rec.anc)
				if parent then
					-- Карты у людей часто похожи: одна копия другой. Тогда объект
					-- уже есть, но с ДРУГИМ номером — каждая Studio присвоила свой.
					-- Прежде чем создавать, ищем такой же по имени и классу
					-- и принимаем его за свой, иначе получим дубликат.
					-- Занятыми считаем только те объекты, что уже приняли в ЭТОМ
					-- проходе. Раньше я проверял наличие в местном указателе —
					-- а там есть ВСЕ местные объекты, поэтому пара никогда не
					-- находилась и плодились дубликаты.
					local twin = findTwin(parent, rec, claimed)
					if twin then
						pcall(function() twin:SetAttribute(SID_ATTR, rec.sid) end)
						twin.Name = rec.name
						applyProps(twin, rec.props)
						index[rec.sid] = twin
						claimed[twin] = true
						adopted += 1
						continue
					end

					local inst = createInstance(rec.cls, rec)
					breathe()
					if inst then
						inst.Name = rec.name
						applyProps(inst, rec.props)
						inst:SetAttribute(SID_ATTR, rec.sid)
						inst.Parent = parent
						index[rec.sid] = inst
						claimed[inst] = true
						addedCount += 1
					end
				else
					table.insert(stillWaiting, ev)
				end
			end
		end
		if #stillWaiting == #remaining then break end
		remaining = stillWaiting
	end
	local skippedCount = #remaining
	if #remaining > 0 then
		-- Итогом, а не по строке на объект: иначе консоль заливает сотнями
		-- одинаковых сообщений и в них не видно ничего полезного.
		local names = {}
		for i = 1, math.min(#remaining, 5) do
			table.insert(names, remaining[i].rec.name)
		end
		logError("не нашлось места для %d объектов (%s%s) — пропущены",
			#remaining, table.concat(names, ", "), #remaining > 5 and ", …" or "")
	end

	-- Изменения
	local created, changed = 0, 0
	for _, ev in ipairs(sets) do
		local rec = ev.rec
		local inst = index[rec.sid]

		-- Проекты разные: правку могли прислать для объекта, которого у меня
		-- никогда не было. Тогда изменение — это на самом деле создание.
		if not inst then
			local parent = resolveParent(rec.parent, index, rec.anc)
			if parent then
				-- может, он уже есть под тем же именем — тогда берём его
				local twin = findTwin(parent, rec, claimed)
				if twin then
					inst = twin
					pcall(function() twin:SetAttribute(SID_ATTR, rec.sid) end)
					index[rec.sid] = twin
					claimed[twin] = true
				end
				if not inst then
					local made = createInstance(rec.cls, rec)
					breathe()
					if made then
						made.Name = rec.name
						applyProps(made, rec.props)
						pcall(function() made:SetAttribute(SID_ATTR, rec.sid) end)
						made.Parent = parent
						index[rec.sid] = made
						created += 1
					end
				end
			end
		end

		if inst then
			local mine = localSnap[rec.sid]
			local base = baseline[rec.sid]
			-- Конфликт: и мы, и они правили одно и то же с общей точки.
			local iChanged = mine and base and mine.hash ~= base.hash
			local theyMoved = ev.base and base and ev.base ~= base.hash
			if iChanged and (theyMoved or (mine and mine.hash ~= rec.hash)) then
				table.insert(conflicts, {
					sid = rec.sid, name = rec.name, cls = rec.cls,
					theirs = rec, author = authorOfBatch,
				})
			else
				inst.Name = rec.name
				applyProps(inst, rec.props)
				local parent = resolveParent(rec.parent, index, rec.anc)
				if parent and inst.Parent ~= parent then
					inst.Parent = parent
				end
				changed += 1
			end
		end
	end

	if created > 0 then
		log("достроено объектов, которых не было: %d", created)
	end

	-- Ссылки между объектами — когда все цели уже созданы.
	flushRefs(index)

	-- Удаления: сначала самые глубокие. Сортировка по номеру бессмысленна —
	-- считаем настоящую глубину в дереве, иначе родителя сносим раньше детей
	-- и до них уже не дотянуться.
	local function depth(sid)
		local inst = index[sid]
		local d, guard_ = 0, 0
		while inst and inst.Parent and guard_ < 100 do
			d += 1
			guard_ += 1
			inst = inst.Parent
		end
		return d
	end
	-- Ищем, что удалять: сначала по номеру, потом по родословной и имени.
	-- Без этого удаления в чужом проекте не срабатывают вовсе — номер там свой.
	local function findVictim(ev)
		local direct = index[ev.sid]
		if direct then return direct end
		if not ev.name or not ev.cls then return nil end
		local parent = resolveParentSoft(ev.parent, index, ev.anc)
		if not parent then return nil end
		for _, c in ipairs(parent:GetChildren()) do
			if c.Name == ev.name and c.ClassName == ev.cls then return c end
		end
		return nil
	end

	table.sort(dels, function(a, b) return depth(a.sid) > depth(b.sid) end)
	local removed = 0
	for _, ev in ipairs(dels) do
		local inst = findVictim(ev)
		if inst then
			pcall(function() inst.Parent = nil end)
			index[ev.sid] = nil
			removed += 1
		end
	end

	return conflicts, {
		removed = removed,
		added   = addedCount,
		adopted = adopted,     -- нашлись такие же объекты, дубликаты не создавались
		changed = changed,
		created = created,     -- достроено по правкам объектов, которых не было
		skipped = skippedCount,
	}
end

--==============================================================
-- Транспорт: свой сервер
--==============================================================
--==============================================================
-- Уборка дубликатов
--==============================================================

-- Одинаковыми считаем только те, что совпадают полностью: имя, класс и место
-- в пространстве. Просто одинаковые имена — обычное дело и трогать их нельзя,
-- а вот две детали в одной точке это всегда след неудачной синхронизации.
-- Отпечаток объекта: что он такое, где стоит, какого размера и что внутри.
-- Два объекта считаем одним и тем же, только если отпечатки совпали целиком.
-- Так модель с тремя деталями не спутается с моделью из трёх других деталей.
local function fingerprint(inst, depth)
	depth = depth or 0
	if depth > 6 then return "…" end

	local parts = { inst.ClassName, inst.Name }

	if inst:IsA("BasePart") then
		local c = { inst.CFrame:GetComponents() }
		for i = 1, 12 do
			table.insert(parts, string.format("%.3f", c[i]))
		end
		table.insert(parts, string.format("%.3f/%.3f/%.3f", inst.Size.X, inst.Size.Y, inst.Size.Z))
		table.insert(parts, tostring(inst.Color))
		table.insert(parts, inst.Material.Name)
		table.insert(parts, string.format("%.3f", inst.Transparency))
		if inst:IsA("MeshPart") then
			table.insert(parts, inst.MeshId)
			table.insert(parts, inst.TextureID)
		end
	elseif inst:IsA("Model") then
		-- у модели тоже есть место и габариты
		local okP, pivot = pcall(function() return inst:GetPivot() end)
		if okP then
			local c = { pivot:GetComponents() }
			for i = 1, 12 do
				table.insert(parts, string.format("%.3f", c[i]))
			end
		end
		local okS, size = pcall(function() return inst:GetExtentsSize() end)
		if okS then
			table.insert(parts, string.format("%.3f/%.3f/%.3f", size.X, size.Y, size.Z))
		end
	elseif inst:IsA("LuaSourceContainer") then
		local okSrc, src = pcall(function() return inst.Source end)
		table.insert(parts, okSrc and tostring(#src) or "?")
	end

	-- содержимое: сортируем, чтобы порядок детей не влиял
	local kids = {}
	for _, c in ipairs(inst:GetChildren()) do
		table.insert(kids, fingerprint(c, depth + 1))
	end
	table.sort(kids)
	table.insert(parts, "[" .. table.concat(kids, ";") .. "]")

	return table.concat(parts, "|")
end

--==============================================================
-- Приведение к присланному состоянию
--==============================================================

-- Убирает всё, чего нет в присланном полном снимке. Нужно, когда напарник
-- отправляет проект целиком: у него объект удалён, а у нас остался.
-- Трогаем только то, что вообще синхронизируем: чужое и служебное не наше дело.
-- Только ищет, ничего не удаляет. Возвращает список того, чего нет
-- в присланном снимке.
function Apply.findMissing(roots, keepSids, keepPaths)
	local doomed = {}
	local SYNCED = Config.SYNCED_CLASSES
	local IGNORE_NAMES = Config.IGNORE_NAMES
	local IGNORE_PREFIX = Config.IGNORE_PREFIX

	local function ignored(inst)
		if IGNORE_NAMES[inst.Name] then return true end
		for _, pref in ipairs(IGNORE_PREFIX) do
			if inst.Name:sub(1, #pref) == pref then return true end
		end
		return false
	end

	local function walk(inst, path, depth)
		if depth > 40 then return end
		for _, c in ipairs(inst:GetChildren()) do
			if not ignored(c) and SYNCED[c.ClassName] then
				local childPath = path .. "/" .. c.Name .. ":" .. c.ClassName
				local sid = c:GetAttribute(SID_ATTR)
				if (sid and keepSids[sid]) or keepPaths[childPath] then
					walk(c, childPath, depth + 1)
				else
					table.insert(doomed, { inst = c, path = c:GetFullName(),
						inside = #c:GetDescendants() })
				end
			end
		end
	end

	for _, root in ipairs(roots) do
		local ok, svc = pcall(function() return game:GetService(root) end)
		if ok and svc then walk(svc, root, 0) end
	end
	return doomed
end

function Apply.pruneMissing(roots, keepSids, keepPaths)
	local removed, kept = 0, 0
	local doomed = {}

	local SYNCED = Config.SYNCED_CLASSES
	local IGNORE_NAMES = Config.IGNORE_NAMES
	local IGNORE_PREFIX = Config.IGNORE_PREFIX

	local function ignored(inst)
		if IGNORE_NAMES[inst.Name] then return true end
		for _, pref in ipairs(IGNORE_PREFIX) do
			if inst.Name:sub(1, #pref) == pref then return true end
		end
		if Config.SKIP_CHARACTERS and inst:FindFirstChildOfClass("Humanoid") then return true end
		return false
	end

	local function walk(inst, path, depth)
		if depth > 40 then return end
		for _, c in ipairs(inst:GetChildren()) do
			if not ignored(c) and SYNCED[c.ClassName] then
				local childPath = path .. "/" .. c.Name .. ":" .. c.ClassName
				local sid = c:GetAttribute(SID_ATTR)
				local survives = (sid and keepSids[sid]) or keepPaths[childPath]
				if survives then
					kept += 1
					walk(c, childPath, depth + 1)
				else
					-- целиком, вместе с содержимым
					table.insert(doomed, c)
				end
			end
		end
	end

	for _, root in ipairs(roots) do
		local ok, svc = pcall(function() return game:GetService(root) end)
		if ok and svc then walk(svc, root, 0) end
	end

	for _, inst in ipairs(doomed) do
		if inst.Parent then
			pcall(function() inst.Parent = nil end)
			removed += 1
		end
	end
	return removed, kept
end

--==============================================================
-- Починка пустых мешей
--==============================================================

-- Меш, приехавший от старой версии плагина, остался белой заготовкой:
-- MeshId пустой. Сам объект не знает, чем он должен быть — но такой же
-- по имени обычно есть рядом в проекте. По нему и восстанавливаем.
function Apply.repairMeshes(roots)
	-- 1. собираем образцы: имя -> целый меш
	local samples = {}
	local broken = {}

	local function walk(inst, depth)
		if depth > 40 then return end
		for _, c in ipairs(inst:GetChildren()) do
			if c:IsA("MeshPart") then
				if c.MeshId ~= "" then
					samples[c.Name] = samples[c.Name] or c
				else
					table.insert(broken, c)
				end
			end
			walk(c, depth + 1)
		end
	end
	for _, root in ipairs(roots) do
		local ok, svc = pcall(function() return game:GetService(root) end)
		if ok and svc then walk(svc, 0) end
	end

	-- 2. чиним
	local fixed, hopeless = 0, {}
	for _, bad in ipairs(broken) do
		local sample = samples[bad.Name]
		if sample then
			local made = makeMeshPart(sample.MeshId, sample.CollisionFidelity, sample.RenderFidelity)
			if made then
				-- переносим на новый объект всё, что было у сломанного
				made.Name = bad.Name
				made.CFrame = bad.CFrame
				made.Size = (bad.Size.Magnitude > 0.01) and bad.Size or sample.Size
				made.Anchored = bad.Anchored
				made.CanCollide = bad.CanCollide
				made.Transparency = bad.Transparency
				made.Color = bad.Color
				made.Material = bad.Material
				if sample.TextureID ~= "" then
					pcall(function() made.TextureID = sample.TextureID end)
				end
				local sid = bad:GetAttribute(SID_ATTR)
				if sid then pcall(function() made:SetAttribute(SID_ATTR, sid) end) end
				-- переносим детей
				for _, kid in ipairs(bad:GetChildren()) do
					kid.Parent = made
				end
				made.Parent = bad.Parent
				bad:Destroy()
				fixed += 1
			end
		else
			table.insert(hopeless, bad:GetFullName())
		end
	end
	return fixed, hopeless, #broken
end

--==============================================================
-- Поиск и уборка дубликатов
--==============================================================

-- Ничего не удаляет: только находит и возвращает список пар.
function Apply.findDuplicates(roots)
	local found = {}

	-- Смотрим только на то, что вообще синхронизируем. Служебное вроде
	-- TouchTransmitter и Animator движок создаёт сам — это не наши дубликаты.
	local SYNCED = Config.SYNCED_CLASSES

	local function walk(inst, depth)
		if depth > 40 then return end
		local seen = {}
		for _, c in ipairs(inst:GetChildren()) do
			if not SYNCED[c.ClassName] then continue end
			local key = fingerprint(c, 0)
			if seen[key] then
				table.insert(found, { keep = seen[key], drop = c, path = c:GetFullName() })
			else
				seen[key] = c
			end
		end
		for _, c in ipairs(inst:GetChildren()) do
			walk(c, depth + 1)
		end
	end

	for _, root in ipairs(roots) do
		local ok, svc = pcall(function() return game:GetService(root) end)
		if ok and svc then walk(svc, 0) end
	end
	return found
end

function Apply.dedupe(roots)
	local found = Apply.findDuplicates(roots)
	local removed = 0
	for _, pair in ipairs(found) do
		if pair.drop and pair.drop.Parent then
			pcall(function() pair.drop.Parent = nil end)
			removed += 1
		end
	end
	return removed, found
end

Apply.applyProps  = applyProps
Apply.flushRefs   = flushRefs
Apply.applyEvents = applyEvents

return Apply
