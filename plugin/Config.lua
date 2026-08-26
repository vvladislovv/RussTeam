--!nonstrict
-- Настройки RussTeam: пределы, списки классов и свойств.
-- Всё, что может понадобиться подкрутить, собрано здесь.

local Config = {}


Config.SID_ATTR       = "__vsid"
-- Обрезать проект нельзя: лучше долгая отправка, чем молча потерянная часть.
-- Предел оставлен только как защита от бесконечного обхода.
Config.MAX_INSTANCES  = 100000
Config.MAX_FEED_CHAR  = 24000000       -- предел на одну отправку, крупнее шлём порциями
Config.LOGO           = "rbxassetid://76862624121244"
Config.LOGO_ON        = "rbxassetid://81200107897024"   -- есть связь
Config.LOGO_OFF       = "rbxassetid://74248098555570"   -- связи нет
-- В консоль Studio по умолчанию идут только поломки. Поставь true,
-- если надо видеть каждый шаг при разборе.
Config.VERBOSE        = false
-- Автоматическая уборка ВЫКЛЮЧЕНА. Она оказалась слишком грубой: у моделей
-- и папок сравнить содержимое дёшево нельзя, и под нож попадало нужное.
-- Дубликаты предотвращаются при приёме (объект узнаётся, а не создаётся),
-- а разовая уборка осталась кнопкой в подробностях.
Config.AUTO_DEDUPE    = false
Config.VERSION        = "5.4"          -- видно на сервере: сразу ясно, у кого что запущено
-- Надёжность важнее скорости: за 12 секунд крупная пачка успевает применяться
-- целиком, и обмены не наступают друг другу на пятки.
Config.AUTO_TICK      = 12
Config.TICK_MAX       = 60             -- при сбоях отступаем до этого значения
-- Замер на живой Studio: 20 000 событий (3,5 МБ) уходят за 0,66 с, а 60 000
-- (10,6 МБ) Roblox уже не вывозит — обрывает по таймауту. Берём с запасом.
Config.CHUNK_EVENTS   = 8000
-- Приём идёт порциями: Studio успевает дышать, а человек видит ход работы.
-- Меньше порция — плавнее, но дольше; больше — быстрее, но рывками.
Config.APPLY_SLICE    = 200
Config.MAX_CONFLICTS  = 50             -- больше в списке держать бессмысленно
Config.BIG_CHANGE     = 400
-- Массовое удаление — почти всегда беда, а не намерение: сбой у напарника,
-- случайное выделение, откат. Больше этого числа удалений за раз требуют
-- подтверждения человеком, даже если остальное принимается само.
Config.MAX_AUTO_DELETE = 50            -- больше этого за раз не применяем без подтверждения
Config.IDLE_AFTER     = 300                             -- через сколько секунд считаем, что человек отошёл

-- Что не считаем изменениями проекта. Мусор от запуска игры и служебные
-- объекты чужих инструментов иначе затапливают напарника.
-- Только служебное. Camera и Terrain и так не переносятся по классу, а по
-- имени их отсекать нельзя: деталь можно назвать «Camera», и она настоящая.
Config.IGNORE_NAMES = {
	["__Rojo_SessionLock"] = true,
}

Config.IGNORE_PREFIX = { "__" }        -- служебное и временные папки

-- Персонажей раньше отсекали целиком — из-за манекенов, которые Studio
-- создаёт при запуске игры. Но обмен и так стоит на паузе во время Play,
-- значит в режиме редактирования всё с Humanoid — настоящее содержимое:
-- NPC, оснастки, заготовки. Их надо переносить.
Config.SKIP_CHARACTERS = false

Config.ROOTS = {
	"Workspace",
	"ServerScriptService",
	"ServerStorage",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"StarterGui",
	"StarterPack",
	"StarterPlayer",
	"Lighting",
	"SoundService",
}
-- Классы, которые переносим.
Config.SYNCED_CLASSES = {
	-- контейнеры
	Folder = true, Model = true, Configuration = true,
	-- геометрия
	Part = true, WedgePart = true, CornerWedgePart = true, TrussPart = true,
	SpawnLocation = true, MeshPart = true, Seat = true, VehicleSeat = true,
	-- крепления и сварки
	Attachment = true, Weld = true, Motor6D = true, WeldConstraint = true,
	Motor = true, Snap = true, HingeConstraint = true, SpringConstraint = true,
	RopeConstraint = true, RodConstraint = true, AlignPosition = true,
	AlignOrientation = true, BallSocketConstraint = true, PrismaticConstraint = true,
	-- поверхности и оформление
	Decal = true, Texture = true, SurfaceAppearance = true,
	ParticleEmitter = true, Trail = true, Beam = true, Smoke = true,
	Fire = true, Sparkles = true, Highlight = true,
	PointLight = true, SpotLight = true, SurfaceLight = true,
	-- интерфейсы
	ScreenGui = true, SurfaceGui = true, BillboardGui = true,
	Frame = true, TextLabel = true, TextButton = true, TextBox = true,
	ImageLabel = true, ImageButton = true, ScrollingFrame = true,
	ViewportFrame = true, VideoFrame = true,
	UIListLayout = true, UIGridLayout = true, UIPadding = true,
	UICorner = true, UIStroke = true, UIGradient = true, UIAspectRatioConstraint = true,
	UISizeConstraint = true, UITextSizeConstraint = true, UIScale = true,
	-- персонажи
	Humanoid = true, Accessory = true, HumanoidDescription = true,
	-- звук
	Sound = true, SoundGroup = true,
	-- код
	Script = true, LocalScript = true, ModuleScript = true,
	-- значения
	StringValue = true, NumberValue = true, BoolValue = true, IntValue = true,
	Vector3Value = true, CFrameValue = true, Color3Value = true, ObjectValue = true,
	-- освещение и атмосфера
	Sky = true, Atmosphere = true, BlurEffect = true, BloomEffect = true,
	DepthOfFieldEffect = true, SunRaysEffect = true, ColorCorrectionEffect = true,
	-- контейнеры Starter*: без них молча пропадают все скрипты внутри
	StarterPlayerScripts = true, StarterCharacterScripts = true, StarterGear = true,
	-- связь между кодом: без них игра у напарника не заработает
	RemoteEvent = true, RemoteFunction = true,
	BindableEvent = true, BindableFunction = true,
	-- одежда, внешность и оснастка персонажа
	NoCollisionConstraint = true, AnimationConstraint = true,
	WrapTarget = true, WrapLayer = true,
	BodyColors = true, BodyPartDescription = true, FaceControls = true,
	CharacterMesh = true, Shirt = true, Pants = true, ShirtGraphic = true,
	-- оснастка персонажей
	Bone = true, Motor = true, AnimationController = true, Animator = false,
	-- прочее
	Animation = true, Tool = true, ClickDetector = true, ProximityPrompt = true,
	SpecialMesh = true, UIFlexItem = true,
}

-- Свойства по группам: берутся, если объект проходит IsA.
Config.GROUP_PROPS = {
	{ "BasePart", {
		"Size", "CFrame", "Anchored", "CanCollide", "CanTouch", "CanQuery",
		"Color", "Material", "MaterialVariant", "Transparency", "Reflectance",
		"CastShadow", "Massless", "CollisionGroup", "TopSurface", "BottomSurface",
		"Locked", "PivotOffset", "CustomPhysicalProperties",
	} },
	{ "JointInstance",  { "Part0", "Part1", "C0", "C1", "Enabled" } },
	{ "Constraint",     { "Attachment0", "Attachment1", "Enabled", "Visible" } },
	{ "GuiObject", {
		"Size", "Position", "AnchorPoint", "BackgroundColor3", "BackgroundTransparency",
		"BorderSizePixel", "BorderColor3", "Visible", "ZIndex", "Rotation",
		"ClipsDescendants", "LayoutOrder",
	} },
	{ "TextLabel",      { "Text", "TextColor3", "TextSize", "Font", "TextWrapped",
	                      "TextXAlignment", "TextYAlignment", "TextScaled", "RichText",
	                      "TextTransparency", "TextStrokeTransparency", "TextStrokeColor3" } },
	{ "ImageLabel",     { "Image", "ImageColor3", "ImageTransparency", "ScaleType" } },
	{ "LayerCollector", { "Enabled", "ResetOnSpawn", "DisplayOrder", "ZIndexBehavior" } },
	{ "LuaSourceContainer", { "Source" } },
	{ "Light",          { "Brightness", "Color", "Enabled", "Range", "Shadows" } },
	{ "ValueBase",      { "Value" } },
}

-- Свойства конкретных классов, поверх групповых.
Config.PROPS = {
	Part            = { "Shape" },
	-- MeshId сам не записывается: по нему меш собирается через AssetService.
	MeshPart        = { "MeshId", "TextureID", "DoubleSided",
	                    "RenderFidelity", "CollisionFidelity" },
	SpawnLocation   = { "Enabled", "Neutral", "Duration", "TeamColor" },
	TrussPart       = { "Style" },
	Seat            = { "Disabled" },
	VehicleSeat     = { "MaxSpeed", "Torque", "TurnSpeed" },
	Attachment      = { "CFrame", "Visible" },
	WeldConstraint  = { "Part0", "Part1", "Enabled" },
	Script          = { "Disabled", "RunContext" },
	LocalScript     = { "Disabled" },
	Decal           = { "Texture", "Face", "Color3", "Transparency", "ZIndex" },
	Texture         = { "Texture", "Face", "StudsPerTileU", "StudsPerTileV", "Transparency" },
	SurfaceAppearance = { "ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap", "AlphaMode" },
	SurfaceGui      = { "Face", "SizingMode", "PixelsPerStud", "AlwaysOnTop", "LightInfluence", "Adornee" },
	BillboardGui    = { "Size", "StudsOffset", "AlwaysOnTop", "MaxDistance", "LightInfluence", "Adornee" },
	ParticleEmitter = { "Texture", "Rate", "Speed", "SpreadAngle", "Enabled",
	                    "LightEmission", "LightInfluence", "Drag", "Acceleration", "EmissionDirection" },
	Trail           = { "Texture", "Enabled", "Attachment0", "Attachment1",
	                    "MinLength", "FaceCamera", "LightEmission" },
	Beam            = { "Texture", "Attachment0", "Attachment1", "Enabled", "Width0", "Width1",
	                    "CurveSize0", "CurveSize1", "Segments", "FaceCamera" },
	Highlight       = { "Adornee", "FillColor", "OutlineColor", "FillTransparency",
	                    "OutlineTransparency", "DepthMode", "Enabled" },
	Humanoid        = { "MaxHealth", "Health", "WalkSpeed", "JumpPower", "HipHeight",
	                    "DisplayName", "RigType", "AutoRotate", "BreakJointsOnDeath" },
	Bone            = { "CFrame", "Transform" },
	NoCollisionConstraint = { "Part0", "Part1", "Enabled" },
	WrapTarget      = { "CageMeshId", "CageOrigin", "Color", "ImportOrigin", "Stiffness" },
	WrapLayer       = { "CageMeshId", "ReferenceMeshId", "Color", "Order", "Puffiness" },
	BodyColors      = { "HeadColor3", "LeftArmColor3", "LeftLegColor3", "RightArmColor3",
	                    "RightLegColor3", "TorsoColor3" },
	Shirt           = { "ShirtTemplate", "Color3" },
	Pants           = { "PantsTemplate", "Color3" },
	ShirtGraphic    = { "Graphic", "Color3" },
	CharacterMesh   = { "BaseTextureId", "BodyPart", "MeshId", "OverlayTextureId" },
	Accessory       = { "AccessoryType" },
	Sound           = { "SoundId", "Volume", "Playing", "Looped", "PlaybackSpeed",
	                    "RollOffMaxDistance", "RollOffMinDistance", "SoundGroup" },
	Animation       = { "AnimationId" },
	Tool            = { "GripPos", "CanBeDropped", "RequiresHandle", "ToolTip" },
	ClickDetector   = { "MaxActivationDistance", "CursorIcon" },
	ProximityPrompt = { "ActionText", "ObjectText", "HoldDuration", "MaxActivationDistance",
	                    "Enabled", "RequiresLineOfSight", "KeyboardKeyCode" },
	UICorner        = { "CornerRadius" },
	UIStroke        = { "Color", "Thickness", "Transparency", "ApplyStrokeMode" },
	UIGradient      = { "Rotation", "Offset", "Enabled" },
	UIPadding       = { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" },
	UIListLayout    = { "FillDirection", "Padding", "SortOrder",
	                    "HorizontalAlignment", "VerticalAlignment" },
	UIScale         = { "Scale" },
	UIAspectRatioConstraint = { "AspectRatio", "AspectType", "DominantAxis" },
	ObjectValue     = { "Value" },
	CFrameValue     = { "Value" },
	ScrollingFrame  = { "CanvasSize", "ScrollBarThickness", "AutomaticCanvasSize",
	                    "ScrollingDirection", "ElasticBehavior" },
	SpecialMesh     = { "MeshType", "MeshId", "TextureId", "Scale", "Offset", "VertexColor" },
	Sky             = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp",
	                    "StarCount", "SunAngularSize", "MoonAngularSize", "CelestialBodiesShown" },
	Atmosphere      = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" },
	BlurEffect      = { "Size", "Enabled" },
	BloomEffect     = { "Intensity", "Size", "Threshold", "Enabled" },
	DepthOfFieldEffect = { "FarIntensity", "FocusDistance", "InFocusRadius", "NearIntensity", "Enabled" },
	SunRaysEffect   = { "Intensity", "Spread", "Enabled" },
	ColorCorrectionEffect = { "Brightness", "Contrast", "Saturation", "TintColor", "Enabled" },
	UIFlexItem      = { "FlexMode", "GrowRatio", "ShrinkRatio" },
	Model           = {},
	Folder          = {},
	Configuration   = {},
}


return Config
