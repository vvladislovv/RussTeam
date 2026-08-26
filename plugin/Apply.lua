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

local function resolveParent(parentSid, index)
	if type(parentSid) == "string" and parentSid:sub(1, 5) == "root:" then
		local ok, svc = pcall(function() return game:GetService(parentSid:sub(6)) end)
		return ok and svc or nil
	end
	return index[parentSid]
end

-- Готовые меши держим наготове: собрать один меш стоит запроса к Roblox,
-- а копия делается мгновенно. На модели из тысячи мешей разница огромная.
local meshCache = {}

-- Точность столкновений и отрисовки влияют на то, как Roblox собирает меш,
-- поэтому их надо задать при создании: присвоить потом не получится.
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
		return nil, tostring(made)
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
			logError("меш %s недоступен (%s) — поставил обычную деталь",
				meshId, tostring(err):sub(1, 60))
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

local function applyProps(inst, props)
	for name, encoded in pairs(props) do
		if READ_ONLY[name] then continue end
		if type(encoded) == "table" and encoded.__t == "ref" then
			table.insert(deferredRefs, { inst = inst, prop = name, sid = encoded.d })
		else
			local value = decodeValue(encoded)
			if value ~= nil then
				pcall(function() inst[name] = value end)
			end
		end
	end
end

local function flushRefs(index)
	local placed, lost = 0, 0
	for _, r in ipairs(deferredRefs) do
		local target = index[r.sid]
		if target and r.inst.Parent then
			local ok = pcall(function() r.inst[r.prop] = target end)
			if ok then placed += 1 else lost += 1 end
		else
			lost += 1
		end
	end
	deferredRefs = {}
	if placed > 0 or lost > 0 then
		logError("ссылки: поставлено %d, потеряно %d", placed, lost)
	end
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
	local built = 0
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
				local parent = resolveParent(rec.parent, index)
				if parent then
					local inst = createInstance(rec.cls, rec)
					breathe()
					if inst then
						inst.Name = rec.name
						applyProps(inst, rec.props)
						inst:SetAttribute(SID_ATTR, rec.sid)
						inst.Parent = parent
						index[rec.sid] = inst
					end
				else
					table.insert(stillWaiting, ev)
				end
			end
		end
		if #stillWaiting == #remaining then break end
		remaining = stillWaiting
	end
	for _, ev in ipairs(remaining) do
		logError("не нашёл родителя для %s — пропустил", ev.rec.name)
	end

	-- Изменения
	for _, ev in ipairs(sets) do
		local rec = ev.rec
		local inst = index[rec.sid]
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
				local parent = resolveParent(rec.parent, index)
				if parent and inst.Parent ~= parent then
					inst.Parent = parent
				end
			end
		end
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
	table.sort(dels, function(a, b) return depth(a.sid) > depth(b.sid) end)
	for _, ev in ipairs(dels) do
		local inst = index[ev.sid]
		if inst then
			pcall(function() inst.Parent = nil end)
			index[ev.sid] = nil
		end
	end

	return conflicts
end

--==============================================================
-- Транспорт: свой сервер
--==============================================================
Apply.applyProps  = applyProps
Apply.flushRefs   = flushRefs
Apply.applyEvents = applyEvents

return Apply
