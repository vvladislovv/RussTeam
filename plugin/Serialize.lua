--!nonstrict
-- Перевод свойств Roblox в JSON и обратно, снимок одного объекта
-- и его отпечаток для сравнения «изменилось / нет».

local HttpService = game:GetService("HttpService")
local Config = require(script.Parent.Config)

local SID_ATTR       = Config.SID_ATTR
local SYNCED_CLASSES = Config.SYNCED_CLASSES
local GROUP_PROPS    = Config.GROUP_PROPS
local PROPS          = Config.PROPS

local Serialize = {}


local function encodeValue(v)
	local t = typeof(v)
	if t == "Vector3" then
		return { __t = "v3", d = { v.X, v.Y, v.Z } }
	elseif t == "Color3" then
		return { __t = "c3", d = { v.R, v.G, v.B } }
	elseif t == "UDim" then
		return { __t = "ud", d = { v.Scale, v.Offset } }
	elseif t == "UDim2" then
		return { __t = "ud2", d = { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset } }
	elseif t == "Vector2" then
		return { __t = "v2", d = { v.X, v.Y } }
	elseif t == "NumberRange" then
		return { __t = "nr", d = { v.Min, v.Max } }
	elseif t == "BrickColor" then
		return { __t = "bc", d = v.Number }
	elseif t == "PhysicalProperties" then
		return { __t = "pp", d = { v.Density, v.Friction, v.Elasticity,
		                           v.FrictionWeight, v.ElasticityWeight } }
	elseif t == "EnumItem" then
		return { __t = "en", d = v.Value }
	elseif t == "Instance" then
		-- Ссылка на другой объект: несём идентификатор, а не сам объект.
		-- Если цель ещё не помечена, помечаем прямо сейчас — иначе ссылка потеряется.
		if not SYNCED_CLASSES[v.ClassName] then return nil end
		local sid = v:GetAttribute(SID_ATTR)
		if type(sid) ~= "string" or sid == "" then
			sid = HttpService:GenerateGUID(false)
			pcall(function() v:SetAttribute(SID_ATTR, sid) end)
		end
		return { __t = "ref", d = sid }
	elseif t == "number" or t == "string" or t == "boolean" then
		return v
	end
	return nil -- неизвестный тип не переносим
end

local function decodeValue(v)
	if type(v) ~= "table" then return v end
	local k, d = v.__t, v.d
	if k == "v3" then
		return Vector3.new(d[1], d[2], d[3])
	elseif k == "cf" then
		return CFrame.new(d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9], d[10], d[11], d[12])
	elseif k == "c3" then
		return Color3.new(d[1], d[2], d[3])
	elseif k == "ud" then
		return UDim.new(d[1], d[2])
	elseif k == "ud2" then
		return UDim2.new(d[1], d[2], d[3], d[4])
	elseif k == "v2" then
		return Vector2.new(d[1], d[2])
	elseif k == "nr" then
		return NumberRange.new(d[1], d[2])
	elseif k == "bc" then
		return BrickColor.new(d)
	elseif k == "pp" then
		return PhysicalProperties.new(d[1], d[2], d[3], d[4], d[5])
	elseif k == "en" then
		return d -- присваивание числа в Enum-свойство Roblox принимает
	elseif k == "ref" then
		return nil -- ссылки ставятся отдельным проходом, когда цель уже создана
	end
	return nil
end

-- CFrame:GetComponents возвращает 12 значений, а не таблицу — оборачиваем.
local function packCFrame(cf)
	local a, b, c, d, e, f, g, h, i, j, k, l = cf:GetComponents()
	return { __t = "cf", d = { a, b, c, d, e, f, g, h, i, j, k, l } }
end

--==============================================================
-- Идентификаторы и обход дерева
--==============================================================

local function newSid()
	return HttpService:GenerateGUID(false)
end

local function ensureSid(inst)
	local sid = inst:GetAttribute(SID_ATTR)
	if type(sid) ~= "string" or sid == "" then
		sid = newSid()
		inst:SetAttribute(SID_ATTR, sid)
	end
	return sid
end

local function rootSid(name)
	return "root:" .. name
end

local function propListFor(inst)
	local list, seen = {}, {}
	local function add(name)
		if not seen[name] then
			seen[name] = true
			table.insert(list, name)
		end
	end
	for _, entry in ipairs(GROUP_PROPS) do
		local ok, isType = pcall(function() return inst:IsA(entry[1]) end)
		if ok and isType then
			for _, name in ipairs(entry[2]) do add(name) end
		end
	end
	for _, name in ipairs(PROPS[inst.ClassName] or {}) do add(name) end
	return list
end

-- Родословная: цепочка от корня до самого объекта. Нужна, потому что проекты
-- у людей РАЗНЫЕ: идентификатор родителя из чужого проекта у меня ничего не
-- значит, а по именам и классам я могу достроить недостающих родителей сам.
-- Studio требует разрешение на изменение скриптов не только для записи,
-- но и для ЧТЕНИЯ исходников. Без него скрипты нельзя ни отправить, ни принять.
local sourceReadDenied = 0

function Serialize.takeSourceReadDenied()
	local n = sourceReadDenied
	sourceReadDenied = 0
	return n
end

local function capture(inst, parentSid, ancestry)
	local props = {}
	for _, name in ipairs(propListFor(inst)) do
		local ok, raw = pcall(function() return inst[name] end)
		if not ok and name == "Source" then
			sourceReadDenied += 1
		end
		if ok then
			local enc
			if typeof(raw) == "CFrame" then
				enc = packCFrame(raw)
			else
				enc = encodeValue(raw)
			end
			if enc ~= nil then props[name] = enc end
		end
	end
	return {
		sid    = ensureSid(inst),
		cls    = inst.ClassName,
		name   = inst.Name,
		parent = parentSid,
		anc    = ancestry,      -- где искать или что достроить
		props  = props,
	}
end

-- Простой хэш записи — чтобы дёшево сравнивать «изменилось / нет».
local function hashRecord(rec)
	local ok, s = pcall(HttpService.JSONEncode, HttpService, {
		rec.cls, rec.name, rec.parent, rec.props,
	})
	if not ok then return "?" end
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 4294967296
	end
	return tostring(h) .. ":" .. tostring(#s)
end

Serialize.encodeValue = encodeValue
Serialize.decodeValue = decodeValue
Serialize.packCFrame  = packCFrame
Serialize.newSid      = newSid
Serialize.ensureSid   = ensureSid
Serialize.rootSid     = rootSid
Serialize.propListFor = propListFor
Serialize.capture     = capture
Serialize.hashRecord  = hashRecord

return Serialize
