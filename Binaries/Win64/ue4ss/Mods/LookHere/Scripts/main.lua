local UEHelpers = require("UEHelpers")
local Config = require("config")

local MOD_NAME = "LookHere"
local MOD_VERSION = "1.0.1"
local ACTOR_CLASS = "/Script/Engine.Actor"
local STATIC_MESH_ACTOR_CLASS = "/Script/Engine.StaticMeshActor"
local STATIC_MESH_COMPONENT_CLASS = "/Script/Engine.StaticMeshComponent"
local TEXT_RENDER_COMPONENT_CLASS = "/Script/Engine.TextRenderComponent"
local PAWN_CLASS = "/Script/Engine.Pawn"
local SKELETAL_MESH_COMPONENT_CLASS = "/Script/Engine.SkeletalMeshComponent"
local MESH_COMPONENT_CLASS = "/Script/Engine.MeshComponent"
local PRIMITIVE_COMPONENT_CLASS = "/Script/Engine.PrimitiveComponent"
local WAYPOINT_WIDGET_ASSET = "/Game/Blueprints/Widgets/HUD/W_Waypoint_Generic"
local WAYPOINT_WIDGET_CLASS = "/Game/Blueprints/Widgets/HUD/W_Waypoint_Generic.W_Waypoint_Generic_C"
local WAYPOINT_UPDATE_POSITION_PATH = "/Game/Blueprints/Widgets/HUD/W_Waypoint_ParentBP.W_Waypoint_ParentBP_C:UpdatePosition"
local WIDGET_BLUEPRINT_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local SPHERE_MESH_PATH = "/Engine/BasicShapes/Sphere.Sphere"
local OUTLINE_COMPONENT_ASSET = "/Game/Blueprints/Items/OutlineComponent"
local OUTLINE_COMPONENT_CLASS = "/Game/Blueprints/Items/OutlineComponent.OutlineComponent_C"
local INTERACTABLE_INTERFACE_ASSET = "/Game/Blueprints/Interfaces/I_Interactable"
local INTERACTABLE_INTERFACE_CLASS = "/Game/Blueprints/Interfaces/I_Interactable.I_Interactable_C"
local SERVER_PAGER_PATH = "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:Server_TriggerPager"
local BROADCAST_PAGER_PATH = "/Game/Blueprints/Characters/Abiotic_PlayerCharacter.Abiotic_PlayerCharacter_C:Broadcast_TriggerPager"
local CLIENT_RESTART_PATH = "/Script/Engine.PlayerController:ClientRestart"
local PLAYER_CONTROLLER_TICK_PATH = "/Game/Blueprints/Meta/Abiotic_PlayerController.Abiotic_PlayerController_C:ReceiveTick"
local HUD_DRAW_PATH = "/Script/Engine.HUD:ReceiveDrawHUD"
local HUD_FONT_ASSET = "/Engine/EngineFonts/Roboto"
local HUD_FONT_PATH = "/Engine/EngineFonts/Roboto.Roboto"

local GetKismetMathLibrary = UEHelpers.GetKismetMathLibrary
local GetKismetSystemLibrary = UEHelpers.GetKismetSystemLibrary
local GetGameplayStatics = UEHelpers.GetGameplayStatics
local RawGetPlayerController = UEHelpers.GetPlayerController
local GetPlayerController = nil

local state = {
    lastClientRequestTime = -1000.0,
    lastClientRequestWorldKey = nil,
    serverRequestTimes = {},
    hookRegistered = false,
    broadcastHookRegistered = false,
    labelTickHookRegistered = false,
    labelUpdateAccumulator = 0.0,
    labelComponents = {},
    labelComponentKeys = {},
    markerWidgets = {},
    markerWidgetSlots = {},
    directEntityOutlines = {},
    serverMarkerSlots = {},
    nextServerMarkerSlot = 1,
    widgetUpdateStarted = false,
    widgetDiagnostics = {},
    waypointPositionHookRegistered = false,
    waypointPositionHookActive = false,
    waypointPositionHookRunning = false,
    hudDrawHookRegistered = false,
    hudDrawHookActive = false,
    hudDrawDiagnostics = {},
    hudFont = nil,
    hudLabelSerial = 0,
    primaryHudCanvasDiagnosed = false,
    primaryHudCanvas = nil,
    markerDebugInfo = {},
    debugDisplayTargetInfo = Config.DebugDisplayTargetInfo == true,
    screenToWidgetLocalSupported = nil,
    pendingBroadcasts = {},
    processedBroadcastAnchors = {},
    pendingVisualizations = {},
    packetReceivers = {},
    packetCarrierCache = {},
    packetLocalSlots = {},
    packetSerial = 0,
    lastCooldownWarningTime = -1000.0,
    localSuccessSoundAnchors = {},
    activeMarkerTargets = {},
    serverAnchorTargetKeys = {},
    localPlayerController = nil,
    localPlayerPawn = nil,
    localPlayerContextLogKey = nil,
}

local function Log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

local function Debug(message)
    if Config.DebugLogging then
        Log(message)
    end
end

local function IsObjectValid(object)
    if object == nil then
        return false
    end

    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid == true
end

local function IsActorObject(object)
    if not IsObjectValid(object) then
        return false
    end

    local actorClass = StaticFindObject(ACTOR_CLASS)
    if not IsObjectValid(actorClass) then
        return false
    end

    local ok, isActor = pcall(function()
        return object:IsA(actorClass)
    end)
    return ok and isActor == true
end

local function ParamValue(param)
    if param == nil then
        return nil
    end

    local ok, value = pcall(function()
        return param:get()
    end)
    if ok then
        return value
    end

    return param
end

local function ObjectKey(object)
    if not IsObjectValid(object) then
        return nil
    end

    local ok, name = pcall(function()
        return object:GetFullName()
    end)
    if ok and name then
        return tostring(name)
    end

    return tostring(object)
end

local function GetControllerPawn(controller)
    if not IsObjectValid(controller) then
        return nil
    end

    local pawn = nil
    pcall(function() pawn = controller.Pawn end)
    if not IsObjectValid(pawn) then
        pcall(function() pawn = controller:K2_GetPawn() end)
    end
    if not IsObjectValid(pawn) then
        pcall(function() pawn = controller:GetPawn() end)
    end
    return IsObjectValid(pawn) and pawn or nil
end

local function IsStrictlyLocalController(controller)
    if not IsObjectValid(controller) then
        return false
    end

    local isLocalPlayerController = false
    pcall(function()
        isLocalPlayerController = controller:IsLocalPlayerController() == true
    end)
    if isLocalPlayerController then
        return true
    end

    local isLocalController = false
    pcall(function()
        isLocalController = controller:IsLocalController() == true
    end)
    return isLocalController
end

local function ValidateLocalPlayerContext(controller)
    if not IsStrictlyLocalController(controller) then
        return false, nil, "controller_not_local"
    end

    local pawn = GetControllerPawn(controller)
    if not IsObjectValid(pawn) then
        return false, nil, "pawn_invalid"
    end

    local pawnIsLocal = false
    pcall(function()
        pawnIsLocal = pawn:IsLocallyControlled() == true
    end)
    if not pawnIsLocal then
        return false, pawn, "pawn_not_local"
    end

    local pawnController = nil
    pcall(function() pawnController = pawn:GetController() end)
    if not IsObjectValid(pawnController)
        or ObjectKey(pawnController) ~= ObjectKey(controller)
    then
        return false, pawn, "pawn_controller_mismatch"
    end

    return true, pawn, "verified"
end

local function LogLocalPlayerContext(status, controller, pawn, detail)
    local logKey = table.concat({
        tostring(status),
        tostring(ObjectKey(controller) or "NoController"),
        tostring(ObjectKey(pawn) or "NoPawn"),
        tostring(detail or ""),
    }, "|")
    if state.localPlayerContextLogKey == logKey then
        return
    end

    state.localPlayerContextLogKey = logKey
    Log(string.format(
        "Local player context %s: controller=%s pawn=%s detail=%s",
        tostring(status),
        tostring(ObjectKey(controller) or "None"),
        tostring(ObjectKey(pawn) or "None"),
        tostring(detail or "None")
    ))
end

local function ClearLocalPlayerContext(reason)
    state.localPlayerController = nil
    state.localPlayerPawn = nil
    state.localPlayerContextLogKey = nil
    Debug("Local player context cleared: " .. tostring(reason or "Unknown"))
end

local function GetVerifiedLocalPlayerContext()
    local cachedOk, cachedPawn = ValidateLocalPlayerContext(state.localPlayerController)
    if cachedOk then
        state.localPlayerPawn = cachedPawn
        return state.localPlayerController, cachedPawn
    end

    state.localPlayerController = nil
    state.localPlayerPawn = nil

    local candidates = {}
    local candidateKeys = {}
    local function AddCandidate(candidate)
        if not IsObjectValid(candidate) then
            return
        end
        local key = ObjectKey(candidate) or tostring(candidate)
        if not candidateKeys[key] then
            candidateKeys[key] = true
            table.insert(candidates, candidate)
        end
    end

    -- UEHelpers v3 accepts any PlayerController because its predicate is
    -- IsPlayerController() OR IsLocalPlayerController(). Keep it only as a
    -- candidate and apply strict local-controller and local-pawn checks.
    local rawController = nil
    pcall(function() rawController = RawGetPlayerController() end)
    AddCandidate(rawController)

    for _, className in ipairs({ "Abiotic_PlayerController_C", "PlayerController", "Controller" }) do
        local found = nil
        pcall(function() found = FindAllOf(className) end)
        if found then
            for _, candidate in ipairs(found) do
                AddCandidate(candidate)
            end
        end
    end

    local rejected = {}
    for _, candidate in ipairs(candidates) do
        local valid, pawn, reason = ValidateLocalPlayerContext(candidate)
        if valid then
            state.localPlayerController = candidate
            state.localPlayerPawn = pawn
            LogLocalPlayerContext("selected", candidate, pawn, "strict_local_controller_and_pawn")
            return candidate, pawn
        end
        table.insert(rejected, string.format(
            "%s:%s",
            tostring(ObjectKey(candidate) or "UnknownController"),
            tostring(reason)
        ))
    end

    LogLocalPlayerContext("unavailable", nil, nil, table.concat(rejected, ";"))
    return nil, nil
end

GetPlayerController = function()
    local controller = GetVerifiedLocalPlayerContext()
    return controller
end

local function Now(worldContext)
    local gameplayStatics = GetGameplayStatics()
    if IsObjectValid(gameplayStatics) and IsObjectValid(worldContext) then
        local ok, value = pcall(function()
            return gameplayStatics:GetTimeSeconds(worldContext)
        end)
        if ok and type(value) == "number" then
            return value
        end
    end

    return os.clock()
end

local function GetCurrentWorldKey(worldContext)
    local world = nil
    if IsObjectValid(worldContext) then
        pcall(function() world = worldContext:GetWorld() end)
    end
    if not IsObjectValid(world) then
        local localController = GetPlayerController()
        if IsObjectValid(localController) then
            pcall(function() world = localController:GetWorld() end)
        end
    end
    if not IsObjectValid(world) then
        pcall(function() world = UEHelpers.GetWorld() end)
    end
    return ObjectKey(world)
end

local function ResetLocalCooldownState(reason)
    state.lastClientRequestTime = -1000.0
    state.lastClientRequestWorldKey = nil
    state.lastCooldownWarningTime = -1000.0
    Debug("Local cooldown state reset: " .. tostring(reason or "Unknown"))
end

local function HasAuthority(actor)
    if not IsObjectValid(actor) then
        return false
    end

    local ok, result = pcall(function()
        return actor:HasAuthority()
    end)
    return ok and result == true
end

local function ResolveActorFromObject(object)
    local current = object
    local visited = {}

    for _ = 1, 6 do
        if not IsObjectValid(current) then
            return nil
        end
        if IsActorObject(current) then
            return current
        end

        local currentKey = tostring(current)
        if visited[currentKey] then
            return nil
        end
        visited[currentKey] = true

        local owner = nil
        pcall(function() owner = current:GetOwner() end)
        if not IsActorObject(owner) then
            pcall(function() owner = current.Owner end)
        end
        if IsActorObject(owner) then
            return owner
        end

        local outer = nil
        pcall(function() outer = current:GetOuter() end)
        if not IsObjectValid(outer) or outer == current then
            return nil
        end
        current = outer
    end

    return nil
end

local function GetActorFromHitResult(hitResult)
    local candidates = {}
    local function AddCandidate(reader)
        local ok, candidate = pcall(reader)
        if ok and candidate ~= nil then
            table.insert(candidates, candidate)
        end
    end

    AddCandidate(function() return hitResult.Actor:Get() end)
    AddCandidate(function() return hitResult.HitObjectHandle.Actor:Get() end)
    AddCandidate(function() return hitResult.HitObjectHandle.ReferenceObject:Get() end)
    AddCandidate(function() return hitResult.Component:Get() end)

    for _, candidate in ipairs(candidates) do
        local actor = ResolveActorFromObject(candidate)
        if IsActorObject(actor) then
            return actor
        end
    end

    return nil
end

local function GetComponentFromHitResult(hitResult)
    local component = nil
    local ok = pcall(function() component = hitResult.Component:Get() end)
    if ok and IsObjectValid(component) then
        return component
    end

    pcall(function() component = hitResult.Component end)
    if IsObjectValid(component) then
        return component
    end

    return nil
end

local function ToCleanString(value, fallback)
    if value == nil then
        return fallback
    end

    local converted = nil
    pcall(function() converted = value:ToString() end)
    if converted == nil then
        converted = tostring(value)
    end
    converted = tostring(converted):gsub("[%z\1-\31\127]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if converted == "" then
        return fallback
    end
    return converted
end

local function GetObjectName(object, fallback)
    if not IsObjectValid(object) then
        return fallback or "None"
    end

    local value = nil
    pcall(function() value = object:GetName() end)
    if value ~= nil then
        return ToCleanString(value, fallback or "Unknown")
    end

    local fullName = nil
    pcall(function() fullName = object:GetFullName() end)
    return ToCleanString(fullName, fallback or "Unknown")
end

local function GetObjectClassName(object, fallback)
    if not IsObjectValid(object) then
        return fallback or "None"
    end

    local classObject = nil
    pcall(function() classObject = object:GetClass() end)
    return GetObjectName(classObject, fallback or "UnknownClass")
end

local function GetMarkerClassSignature(object)
    local className = GetObjectClassName(object, "")
    if className == "" then
        return 0
    end
    local hash = 0
    for index = 1, #className do
        hash = (hash * 131 + string.byte(className, index)) % 127
    end
    return hash + 1
end

local function EncodeMarkerClassSignatureYaw(object)
    return GetMarkerClassSignature(object) * (360.0 / 128.0)
end

local function DecodeMarkerClassSignature(anchor)
    local rotation = nil
    pcall(function() rotation = anchor:K2_GetActorRotation() end)
    if not rotation or rotation.Yaw == nil then
        return 0
    end
    local normalizedYaw = ((tonumber(rotation.Yaw) or 0.0) % 360.0 + 360.0) % 360.0
    return math.floor(normalizedYaw / (360.0 / 128.0) + 0.5) % 128
end

local function ReadHitVector(hitResult, primaryName, fallbackName)
    local ok, value = pcall(function()
        return hitResult[primaryName]
    end)
    if ok and value and value.X ~= nil then
        return value
    end

    if fallbackName then
        local fallbackOk, fallback = pcall(function()
            return hitResult[fallbackName]
        end)
        if fallbackOk and fallback and fallback.X ~= nil then
            return fallback
        end
    end

    return nil
end

local function MakeVector(x, y, z)
    local ok, value = pcall(function()
        return FVector(x, y, z)
    end)
    if ok and value then
        return value
    end

    return { X = x, Y = y, Z = z }
end

local function MakeRotator(pitch, yaw, roll)
    local ok, value = pcall(function()
        return FRotator(pitch, yaw, roll)
    end)
    if ok and value then
        return value
    end

    return { Pitch = pitch, Yaw = yaw, Roll = roll }
end

local function AddScaledVector(origin, direction, scale)
    return MakeVector(
        origin.X + direction.X * scale,
        origin.Y + direction.Y * scale,
        origin.Z + direction.Z * scale
    )
end

local function GetLocalCrosshairRay(preferredPlayerController)
    local playerController = preferredPlayerController or GetPlayerController()
    if not IsObjectValid(playerController) then
        return nil
    end

    local widgetLayout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if IsObjectValid(widgetLayout) then
        local ok, location, direction = pcall(function()
            local viewportSize = widgetLayout:GetViewportSize(playerController)
            local outLocation = {}
            local outDirection = {}
            playerController:DeprojectScreenPositionToWorld(
                viewportSize.X * 0.5,
                viewportSize.Y * 0.5,
                outLocation,
                outDirection
            )
            return outLocation, outDirection
        end)

        if ok and location and location.X ~= nil and direction and direction.X ~= nil then
            return location, direction
        end
    end

    local cameraManager = playerController.PlayerCameraManager
    if IsObjectValid(cameraManager) then
        local mathLibrary = GetKismetMathLibrary()
        return cameraManager:GetCameraLocation(), mathLibrary:GetForwardVector(cameraManager:GetCameraRotation())
    end

    return nil
end

local function GetServerViewRay(character)
    local eyeLocation = {}
    local eyeRotation = {}
    local eyesOk = pcall(function()
        character:GetActorEyesViewPoint(eyeLocation, eyeRotation)
    end)

    if eyesOk and eyeLocation.X ~= nil and eyeRotation.Yaw ~= nil then
        return eyeLocation, GetKismetMathLibrary():GetForwardVector(eyeRotation)
    end

    local location = nil
    local rotation = nil

    pcall(function()
        location = character:GetPawnViewLocation()
    end)

    local controller = nil
    pcall(function()
        controller = character:GetController()
    end)

    if IsObjectValid(controller) then
        pcall(function()
            rotation = controller:GetControlRotation()
        end)
    end

    if location == nil or location.X == nil then
        pcall(function()
            location = character:K2_GetActorLocation()
            location.Z = location.Z + 60.0
        end)
    end

    if rotation == nil or rotation.Yaw == nil then
        pcall(function()
            rotation = character:K2_GetActorRotation()
        end)
    end

    if location and location.X ~= nil and rotation and rotation.Yaw ~= nil then
        return location, GetKismetMathLibrary():GetForwardVector(rotation)
    end

    return nil
end

local function TraceDistanceSquared(startLocation, point)
    if not startLocation or not point then
        return math.huge
    end

    local dx = (point.X or 0.0) - (startLocation.X or 0.0)
    local dy = (point.Y or 0.0) - (startLocation.Y or 0.0)
    local dz = (point.Z or 0.0) - (startLocation.Z or 0.0)
    return dx * dx + dy * dy + dz * dz
end

local function BuildTraceHit(hitResult, startLocation, source)
    local point = ReadHitVector(hitResult, "ImpactPoint", "Location")
    if not point then
        return nil
    end

    local component = GetComponentFromHitResult(hitResult)
    local actor = GetActorFromHitResult(hitResult)
    if not IsActorObject(actor) and IsObjectValid(component) then
        actor = ResolveActorFromObject(component)
    end

    return {
        Actor = IsActorObject(actor) and actor or nil,
        Component = component,
        Point = point,
        Normal = ReadHitVector(hitResult, "ImpactNormal", "Normal"),
        Source = source,
        DistanceSquared = TraceDistanceSquared(startLocation, point),
    }
end

local function TraceByChannel(systemLibrary, worldContext, startLocation, endLocation, actorsToIgnore, transparent, traceChannel, source)
    local hitResult = {}
    local ok, wasHit = pcall(function()
        return systemLibrary:LineTraceSingle(
            worldContext,
            startLocation,
            endLocation,
            traceChannel,
            false,
            actorsToIgnore,
            0,
            hitResult,
            true,
            transparent,
            transparent,
            0.0
        )
    end)

    if not ok or not wasHit then
        return nil
    end
    return BuildTraceHit(hitResult, startLocation, source)
end

local function TraceByObjectTypes(systemLibrary, worldContext, startLocation, endLocation, actorsToIgnore, transparent)
    local objectTypes = Config.ObjectTraceTypes or { 1, 2 }
    if type(objectTypes) ~= "table" or next(objectTypes) == nil then
        return nil
    end

    local hitResult = {}
    local ok, wasHit = pcall(function()
        return systemLibrary:LineTraceSingleForObjects(
            worldContext,
            startLocation,
            endLocation,
            objectTypes,
            false,
            actorsToIgnore,
            0,
            hitResult,
            true,
            transparent,
            transparent,
            0.0
        )
    end)

    if not ok then
        Log("LineTraceSingleForObjects failed: " .. tostring(wasHit))
        return nil
    end
    if not wasHit then
        return nil
    end
    return BuildTraceHit(hitResult, startLocation, "DefaultObjectTypes")
end

local function TraceInteractionProbe(systemLibrary, worldContext, startLocation, endLocation, actorsToIgnore, transparent)
    local radius = Config.InteractionProbeRadius or 0.0
    local objectTypes = Config.ObjectTraceTypes or { 0, 1, 2, 3, 4, 5 }
    if radius <= 0.0 or type(objectTypes) ~= "table" or next(objectTypes) == nil then
        return nil
    end

    local hitResult = {}
    local ok, wasHit = pcall(function()
        return systemLibrary:SphereTraceSingleForObjects(
            worldContext,
            startLocation,
            endLocation,
            radius,
            objectTypes,
            false,
            actorsToIgnore,
            0,
            hitResult,
            true,
            transparent,
            transparent,
            0.0
        )
    end)
    if not ok then
        Log("SphereTraceSingleForObjects failed: " .. tostring(wasHit))
        return nil
    end
    if not wasHit then
        return nil
    end
    return BuildTraceHit(hitResult, startLocation, "InteractionSphere")
end

local IsEntityTarget
local DoesImplementInteractable
local GetDirectParentActor

local function IsInteractionProbeEligible(hit)
    if not hit or type(DoesImplementInteractable) ~= "function" then
        return false
    end
    return (IsObjectValid(hit.Component) and DoesImplementInteractable(hit.Component))
        or (IsActorObject(hit.Actor) and DoesImplementInteractable(hit.Actor))
end

local function TraceOnce(startLocation, direction, worldContext, actorsToIgnore)
    local systemLibrary = GetKismetSystemLibrary()
    if not IsObjectValid(systemLibrary) or not IsObjectValid(worldContext) then
        return nil
    end

    local endLocation = AddScaledVector(startLocation, direction, Config.TraceDistance)
    actorsToIgnore = actorsToIgnore or {}
    local transparent = { R = 0, G = 0, B = 0, A = 0 }
    local bestInteractionComponentHit = nil
    local function ConsiderInteractionComponentHit(hit)
        if hit
            and IsObjectValid(hit.Component)
            and type(DoesImplementInteractable) == "function"
            and DoesImplementInteractable(hit.Component)
            and (not bestInteractionComponentHit
                or hit.DistanceSquared < bestInteractionComponentHit.DistanceSquared)
        then
            bestInteractionComponentHit = hit
        end
    end
    local channelHit = TraceByChannel(
        systemLibrary,
        worldContext,
        startLocation,
        endLocation,
        actorsToIgnore,
        transparent,
        Config.TraceChannel,
        "Visibility"
    )
    ConsiderInteractionComponentHit(channelHit)
    for _, additionalChannel in ipairs(Config.AdditionalTraceChannels or {}) do
        local additionalHit = TraceByChannel(
            systemLibrary,
            worldContext,
            startLocation,
            endLocation,
            actorsToIgnore,
            transparent,
            additionalChannel,
            "TraceChannel" .. tostring(additionalChannel)
        )
        ConsiderInteractionComponentHit(additionalHit)
        if additionalHit
            and (not channelHit or additionalHit.DistanceSquared < channelHit.DistanceSquared)
        then
            channelHit = additionalHit
        end
    end
    local objectHit = TraceByObjectTypes(
        systemLibrary,
        worldContext,
        startLocation,
        endLocation,
        actorsToIgnore,
        transparent
    )
    ConsiderInteractionComponentHit(objectHit)
    local interactionHit = TraceInteractionProbe(
        systemLibrary,
        worldContext,
        startLocation,
        endLocation,
        actorsToIgnore,
        transparent
    )
    ConsiderInteractionComponentHit(interactionHit)
    local interactionHitEligible = IsInteractionProbeEligible(interactionHit)

    local exactHit = nil
    if channelHit and objectHit then
        if objectHit.DistanceSquared < channelHit.DistanceSquared then
            exactHit = objectHit
        else
            exactHit = channelHit
        end
    else
        exactHit = objectHit or channelHit
    end

    -- A parent mesh can sit slightly in front of its own interaction button.
    -- Promote the button only when both hits belong to the same Actor and the
    -- button is within a small behind-surface tolerance. This cannot select a
    -- button through an unrelated wall or Actor.
    if bestInteractionComponentHit then
        if not exactHit then
            exactHit = bestInteractionComponentHit
        else
            local sameActor = IsActorObject(bestInteractionComponentHit.Actor)
                and IsActorObject(exactHit.Actor)
                and ObjectKey(bestInteractionComponentHit.Actor) == ObjectKey(exactHit.Actor)
            local componentDistance = math.sqrt(bestInteractionComponentHit.DistanceSquared or math.huge)
            local exactDistance = math.sqrt(exactHit.DistanceSquared or math.huge)
            local promotionTolerance = Config.InteractionComponentPromotionTolerance
                or Config.InteractionProbeBehindTolerance
                or 60.0
            if sameActor and componentDistance <= exactDistance + promotionTolerance then
                Debug(string.format(
                    "Promoted interaction component hit: parent_distance=%.1f component_distance=%.1f actor=%s component=%s",
                    exactDistance,
                    componentDistance,
                    tostring(ObjectKey(exactHit.Actor)),
                    tostring(ObjectKey(bestInteractionComponentHit.Component))
                ))
                exactHit = bestInteractionComponentHit
            end
        end
    end

    Debug(string.format(
        "Trace arbitration: exact_actor=%s exact_component=%s sphere_actor=%s sphere_component=%s sphere_eligible=%s",
        tostring(ObjectKey(exactHit and exactHit.Actor or nil)),
        tostring(ObjectKey(exactHit and exactHit.Component or nil)),
        tostring(ObjectKey(interactionHit and interactionHit.Actor or nil)),
        tostring(ObjectKey(interactionHit and interactionHit.Component or nil)),
        tostring(interactionHitEligible)
    ))

    if interactionHit
        and interactionHitEligible
        and IsActorObject(interactionHit.Actor)
        and IsEntityTarget(interactionHit.Actor)
    then
        if not exactHit then
            return interactionHit
        end

        local exactIsEntity = IsActorObject(exactHit.Actor) and IsEntityTarget(exactHit.Actor)
        local sameActor = IsActorObject(interactionHit.Actor)
            and IsActorObject(exactHit.Actor)
            and ObjectKey(interactionHit.Actor) == ObjectKey(exactHit.Actor)
        local exactIsInteractionComponent = IsObjectValid(exactHit.Component)
            and type(DoesImplementInteractable) == "function"
            and DoesImplementInteractable(exactHit.Component)
        local interactionIsInteractionComponent = IsObjectValid(interactionHit.Component)
            and type(DoesImplementInteractable) == "function"
            and DoesImplementInteractable(interactionHit.Component)
        local interactionDistance = math.sqrt(interactionHit.DistanceSquared or math.huge)
        local exactDistance = math.sqrt(exactHit.DistanceSquared or math.huge)
        local tolerance = Config.InteractionProbeBehindTolerance or 60.0
        local preservePreciseComponent = sameActor
            and exactIsInteractionComponent
            and not interactionIsInteractionComponent
        if not preservePreciseComponent and (exactIsEntity or interactionDistance <= exactDistance + tolerance) then
            if not exactIsEntity or interactionHit.DistanceSquared < exactHit.DistanceSquared then
                return interactionHit
            end
        end
    end

    if interactionHit and not interactionHitEligible then
        Debug(string.format(
            "Rejected non-interactable sphere hit: actor=%s component=%s",
            tostring(ObjectKey(interactionHit.Actor)),
            tostring(ObjectKey(interactionHit.Component))
        ))
    end
    return exactHit or (interactionHitEligible and interactionHit or nil)
end

local function IsOwnedByRequestingPlayer(candidate, requestingPlayer)
    if not IsActorObject(candidate) or not IsActorObject(requestingPlayer) then
        return false
    end

    local requestingPlayerKey = ObjectKey(requestingPlayer)
    local queue = { candidate }
    local seen = {}
    local index = 1
    local inspected = 0
    while index <= #queue and inspected < 24 do
        local current = queue[index]
        index = index + 1
        inspected = inspected + 1
        local currentKey = ObjectKey(current)
        if currentKey == requestingPlayerKey then
            return true
        end
        if currentKey and not seen[currentKey] then
            seen[currentKey] = true
            local parents = {}
            pcall(function() table.insert(parents, current:GetOwner()) end)
            pcall(function() table.insert(parents, current:GetAttachParentActor()) end)
            pcall(function() table.insert(parents, current:GetParentActor()) end)
            for _, parent in ipairs(parents) do
                if IsActorObject(parent) then
                    local parentKey = ObjectKey(parent)
                    if parentKey == requestingPlayerKey then
                        return true
                    end
                    if parentKey and not seen[parentKey] then
                        table.insert(queue, parent)
                    end
                end
            end
        end
    end
    return false
end

local function MatchesConfiguredClassPattern(object, patterns)
    if not IsObjectValid(object) then
        return false
    end
    local className = GetObjectClassName(object, "")
    for _, pattern in ipairs(patterns or {}) do
        if type(pattern) == "string" and pattern ~= "" and className:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function IsVisibleMeshComponent(component)
    if not IsObjectValid(component) then
        return false
    end
    local meshClass = StaticFindObject(MESH_COMPONENT_CLASS)
    if not IsObjectValid(meshClass) then
        return false
    end
    local isMesh = false
    pcall(function() isMesh = component:IsA(meshClass) end)
    if not isMesh then
        return false
    end

    local visible = nil
    local hiddenInGame = nil
    pcall(function() visible = component:IsVisible() end)
    pcall(function() hiddenInGame = component.bHiddenInGame end)
    return visible == true and hiddenInGame ~= true
end

local function ActorHasVisibleMesh(actor)
    if not IsActorObject(actor) then
        return false
    end

    local meshClass = StaticFindObject(MESH_COMPONENT_CLASS)
    if not IsObjectValid(meshClass) then
        return false
    end
    local components = nil
    pcall(function() components = actor:GetComponentsByClass(meshClass) end)
    if type(components) == "table" then
        for _, component in pairs(components) do
            if IsVisibleMeshComponent(ParamValue(component)) then
                return true
            end
        end
    elseif components ~= nil then
        local found = false
        pcall(function()
            components:ForEach(function(_, component)
                if IsVisibleMeshComponent(ParamValue(component)) then
                    found = true
                end
            end)
        end)
        if found then
            return true
        end
    end

    local firstMesh = nil
    pcall(function() firstMesh = actor:GetComponentByClass(meshClass) end)
    if IsVisibleMeshComponent(firstMesh) then
        return true
    end
    for _, propertyName in ipairs(Config.EntityMeshProperties or {}) do
        local component = nil
        pcall(function() component = actor[propertyName] end)
        if IsVisibleMeshComponent(component) then
            return true
        end
    end
    return false
end

local function IsStandaloneTransparentHelperHit(hit)
    if not hit or not IsActorObject(hit.Actor) then
        return false
    end
    if not MatchesConfiguredClassPattern(hit.Actor, Config.TransparentStandaloneHelperClassPatterns) then
        return false
    end

    -- A generated helper owned/attached by furniture is meaningful: keep the
    -- hit so ResolveWholeActorHelperParent can promote it exactly one level.
    local parentActor = GetDirectParentActor(hit.Actor)
    if IsActorObject(parentActor) and ObjectKey(parentActor) ~= ObjectKey(hit.Actor) then
        return false
    end

    -- Standalone BuildZone helpers are gameplay/query volumes, not marker
    -- targets. Ignore the whole keyword-matched Actor regardless of whether a
    -- debug hologram happens to be visible; parented variants were preserved
    -- above so furniture can still be promoted normally.
    return true
end

local function Trace(startLocation, direction, worldContext)
    -- Kismet's bIgnoreSelf ignores the requesting Pawn, but equipped weapons
    -- are separate Actors. Re-run after excluding any hit whose Owner,
    -- AttachParentActor or ParentActor chain resolves back to this player.
    local actorsToIgnore = { worldContext }
    local ignoredKeys = {}
    local requestingPlayerKey = ObjectKey(worldContext)
    if requestingPlayerKey then
        ignoredKeys[requestingPlayerKey] = true
    end
    local requestingPlayerSkips = math.max(0, math.floor(Config.MaxRequestingPlayerTraceSkips or 8))
    local transparentHelperSkips = math.max(0, math.floor(Config.MaxTransparentHelperTraceSkips or 8))
    local maximumSkips = math.max(1, requestingPlayerSkips + transparentHelperSkips)
    for _ = 1, maximumSkips + 1 do
        local hit = TraceOnce(startLocation, direction, worldContext, actorsToIgnore)
        if not hit or not IsActorObject(hit.Actor) then
            return hit
        end
        local requestingPlayerOwned = IsOwnedByRequestingPlayer(hit.Actor, worldContext)
        local transparentStandaloneHelper = not requestingPlayerOwned
            and IsStandaloneTransparentHelperHit(hit)
        if not requestingPlayerOwned and not transparentStandaloneHelper then
            return hit
        end

        local hitKey = ObjectKey(hit.Actor)
        if not hitKey or ignoredKeys[hitKey] then
            Debug(string.format(
                "Rejected filtered trace hit without retry: reason=%s actor=%s source=%s distance=%.1f",
                requestingPlayerOwned and "RequestingPlayerOwned" or "StandaloneTransparentHelper",
                tostring(hitKey),
                tostring(hit.Source or "Unknown"),
                math.sqrt(hit.DistanceSquared or 0.0)
            ))
            return nil
        end
        ignoredKeys[hitKey] = true
        table.insert(actorsToIgnore, hit.Actor)
        Debug(string.format(
            "Ignored filtered trace actor and retrying: reason=%s actor=%s component=%s source=%s distance=%.1f",
            requestingPlayerOwned and "RequestingPlayerOwned" or "StandaloneTransparentHelper",
            tostring(hitKey),
            tostring(ObjectKey(hit.Component)),
            tostring(hit.Source or "Unknown"),
            math.sqrt(hit.DistanceSquared or 0.0)
        ))
    end

    Debug("Filtered trace skip limit reached")
    return nil
end

local function GetRepresentativeComponent(actor)
    if not IsObjectValid(actor) then
        return nil
    end

    local component = nil
    pcall(function() component = actor:GetRootComponent() end)
    if IsObjectValid(component) then
        return component
    end

    local primitiveClass = StaticFindObject(PRIMITIVE_COMPONENT_CLASS)
    if IsObjectValid(primitiveClass) then
        pcall(function() component = actor:GetComponentByClass(primitiveClass) end)
    end
    return IsObjectValid(component) and component or nil
end

local function ClassifyHitTarget(actor, component)
    if IsEntityTarget(actor) then
        return "Entity"
    end

    local pawnClass = StaticFindObject(PAWN_CLASS)
    if IsObjectValid(actor) and IsObjectValid(pawnClass) then
        local ok, isPawn = pcall(function() return actor:IsA(pawnClass) end)
        if ok and isPawn then
            return "Pawn"
        end
    end

    local skeletalClass = StaticFindObject(SKELETAL_MESH_COMPONENT_CLASS)
    if IsObjectValid(component) and IsObjectValid(skeletalClass) then
        local ok, isSkeletal = pcall(function() return component:IsA(skeletalClass) end)
        if ok and isSkeletal then
            return "SkeletalMesh"
        end
    end

    local staticClass = StaticFindObject(STATIC_MESH_COMPONENT_CLASS)
    if IsObjectValid(component) and IsObjectValid(staticClass) then
        local ok, isStatic = pcall(function() return component:IsA(staticClass) end)
        if ok and isStatic then
            return "StaticMesh"
        end
    end

    return IsObjectValid(actor) and "WorldActor" or "World"
end

IsEntityTarget = function(actor)
    if not IsObjectValid(actor) then
        return false
    end

    local pawnClass = StaticFindObject(PAWN_CLASS)
    if IsObjectValid(pawnClass) then
        local pawnOk, isPawn = pcall(function()
            return actor:IsA(pawnClass)
        end)
        if pawnOk and isPawn then
            return true
        end
    end

    -- Some game creatures are Actor-based rather than Pawn-based. A skeletal
    -- mesh is a conservative secondary signal that still excludes ordinary
    -- walls, floors and static props.
    local skeletalClass = StaticFindObject(SKELETAL_MESH_COMPONENT_CLASS)
    if IsObjectValid(skeletalClass) then
        local component = nil
        pcall(function() component = actor:GetComponentByClass(skeletalClass) end)
        if IsObjectValid(component) then
            return true
        end
    end

    -- Blueprint Actors such as vending machines, deployed furniture and other
    -- independent props should be outlined and tracked just like Pawns. Keep
    -- the engine's plain StaticMeshActor as a world-surface marker so ordinary
    -- map walls, floors and structural meshes still receive the sphere anchor.
    local actorClassName = GetObjectClassName(actor, "UnknownActorClass")
    if actorClassName ~= "Class /Script/Engine.StaticMeshActor" then
        return IsActorObject(actor)
    end

    return false
end

GetDirectParentActor = function(actor)
    if not IsActorObject(actor) then
        return nil
    end

    local actorKey = ObjectKey(actor)
    local readers = {
        function() return actor:GetAttachParentActor() end,
        function() return actor:GetParentActor() end,
        function() return actor:GetOwner() end,
        function() return actor.Owner end,
        function() return actor:GetOuter() end,
    }
    for _, reader in ipairs(readers) do
        local parent = nil
        local ok = pcall(function() parent = reader() end)
        if ok and IsActorObject(parent) and ObjectKey(parent) ~= actorKey then
            return parent
        end
    end
    return nil
end

local function GetInteractableInterfaceClass()
    local interfaceClass = StaticFindObject(INTERACTABLE_INTERFACE_CLASS)
    if not IsObjectValid(interfaceClass) then
        pcall(function() LoadAsset(INTERACTABLE_INTERFACE_ASSET) end)
        interfaceClass = StaticFindObject(INTERACTABLE_INTERFACE_CLASS)
    end
    return IsObjectValid(interfaceClass) and interfaceClass or nil
end

DoesImplementInteractable = function(object)
    if not IsObjectValid(object) then
        return false
    end

    local interfaceClass = GetInteractableInterfaceClass()
    local systemLibrary = GetKismetSystemLibrary()
    if IsObjectValid(systemLibrary) and IsObjectValid(interfaceClass) then
        local ok, result = pcall(function()
            return systemLibrary:DoesImplementInterface(object, interfaceClass)
        end)
        if ok and result == true then
            return true
        end
    end

    -- Runtime interface reflection is not exposed consistently by every
    -- UE4SS build. Keep a narrow fallback for known interaction object names.
    local className = GetObjectClassName(object, "")
    return className:find("Interactable", 1, true) ~= nil
        or className:find("Interaction", 1, true) ~= nil
        or className:find("Button", 1, true) ~= nil
end

local function AddUniqueObject(result, seen, candidate)
    candidate = ParamValue(candidate)
    if not IsObjectValid(candidate) then
        return
    end
    local key = ObjectKey(candidate)
    if key and not seen[key] then
        seen[key] = true
        table.insert(result, candidate)
    end
end

local function AppendObjectCollection(result, seen, collection)
    if collection == nil then
        return
    end
    if type(collection) == "table" then
        for _, candidate in pairs(collection) do
            AddUniqueObject(result, seen, candidate)
        end
        return
    end
    pcall(function()
        collection:ForEach(function(_, candidate)
            AddUniqueObject(result, seen, candidate)
        end)
    end)
end

local function GetShortRuntimeClassName(object)
    local className = GetObjectClassName(object, "")
    return className:match("([%w_]+_C)$") or className:match("([%w_]+)$") or ""
end

local function BelongsToActor(object, parentActor)
    if not IsObjectValid(object) or not IsActorObject(parentActor) then
        return false
    end
    local owner = IsActorObject(object) and GetDirectParentActor(object) or ResolveActorFromObject(object)
    return IsActorObject(owner) and ObjectKey(owner) == ObjectKey(parentActor)
end

local function GetInteractableChildren(parentActor, hitChild)
    local result = {}
    local seen = {}
    if not IsActorObject(parentActor) then
        return result
    end

    local interfaceClass = GetInteractableInterfaceClass()
    if IsObjectValid(interfaceClass) then
        local interfaceComponents = nil
        pcall(function() interfaceComponents = parentActor:GetComponentsByInterface(interfaceClass) end)
        AppendObjectCollection(result, seen, interfaceComponents)
    end

    local primitiveClass = StaticFindObject(PRIMITIVE_COMPONENT_CLASS)
    if IsObjectValid(primitiveClass) then
        local primitiveComponents = nil
        pcall(function() primitiveComponents = parentActor:GetComponentsByClass(primitiveClass) end)
        AppendObjectCollection(result, seen, primitiveComponents)
    end

    local childActors = {}
    pcall(function() parentActor:GetAllChildActors(childActors, false) end)
    AppendObjectCollection(result, seen, childActors)

    -- If returned TArrays were not bridged back into Lua, scan the exact hit
    -- class and retain only objects owned by the same outer Actor.
    if IsObjectValid(hitChild) then
        local className = GetShortRuntimeClassName(hitChild)
        if className ~= "" then
            local candidates = nil
            pcall(function() candidates = FindAllOf(className) end)
            if type(candidates) == "table" then
                for _, candidate in ipairs(candidates) do
                    if BelongsToActor(candidate, parentActor) then
                        AddUniqueObject(result, seen, candidate)
                    end
                end
            end
        end
    end

    AddUniqueObject(result, seen, hitChild)
    local interactable = {}
    for _, child in ipairs(result) do
        if BelongsToActor(child, parentActor) and DoesImplementInteractable(child) then
            table.insert(interactable, child)
        end
    end
    return interactable
end

local function ResolveWholeActorHelperParent(actor)
    if not IsActorObject(actor) then
        return actor, false
    end

    local className = GetObjectClassName(actor, "")
    local matched = false
    for _, pattern in ipairs(Config.WholeActorHelperClassPatterns or {}) do
        if type(pattern) == "string" and pattern ~= "" and className:find(pattern, 1, true) then
            matched = true
            break
        end
    end
    if not matched then
        return actor, false
    end

    -- Generated helper Actors such as NoBuildZone_GEN_VARIABLE_BuildZone_C
    -- are ChildActorComponent instances owned/parented by the real furniture.
    -- Promote exactly one Actor level; never walk arbitrarily into the map.
    local parentActor = GetDirectParentActor(actor)
    if IsActorObject(parentActor)
        and ObjectKey(parentActor) ~= ObjectKey(actor)
        and IsEntityTarget(parentActor)
    then
        return parentActor, true
    end
    return actor, false
end

local function ResolveHierarchicalMarkerTarget(hit)
    if not hit or not IsActorObject(hit.Actor) then
        return hit
    end

    local originalActor = hit.Actor
    local originalComponent = hit.Component
    local promotedActor, promotedWholeActor = ResolveWholeActorHelperParent(originalActor)
    if promotedWholeActor then
        hit.OriginalActor = originalActor
        hit.OriginalComponent = originalComponent
        hit.Actor = promotedActor
        -- The helper's collision/render-query component is not part of the
        -- parent's visible mesh set and must not become a precise target.
        hit.Component = nil
        Debug(string.format(
            "Promoted helper actor to whole parent actor: helper=%s helper_component=%s parent=%s",
            tostring(ObjectKey(originalActor)),
            tostring(ObjectKey(originalComponent)),
            tostring(ObjectKey(promotedActor))
        ))
    end

    local parentActor = hit.Actor
    local interactionChild = IsObjectValid(hit.Component) and hit.Component or nil
    hit.MarkerTarget = parentActor
    hit.VisualTarget = parentActor
    Debug(string.format(
        "Interaction candidate: object=%s class=%s actor=%s interactable=%s owner=%s",
        tostring(ObjectKey(interactionChild)),
        GetObjectClassName(interactionChild, "NoComponent"),
        tostring(IsActorObject(interactionChild)),
        tostring(DoesImplementInteractable(interactionChild)),
        tostring(ObjectKey(ResolveActorFromObject(interactionChild)))
    ))
    if not IsObjectValid(interactionChild)
        or ObjectKey(interactionChild) == ObjectKey(parentActor)
        or not DoesImplementInteractable(interactionChild)
    then
        hit.SelectedTargetMode = promotedWholeActor and "WholeActorParent" or "DirectActor"
        return hit
    end

    local siblings = GetInteractableChildren(parentActor, interactionChild)
    hit.OriginalActor = hit.Actor
    hit.InteractionChildCount = #siblings
    if #siblings > 1 then
        hit.MarkerTarget = interactionChild
        hit.VisualTarget = interactionChild
        if IsActorObject(interactionChild) then
            hit.Actor = interactionChild
            hit.SelectedTargetMode = "ComplexChildActor"
        else
            hit.PreciseComponentTarget = true
            hit.SelectedTargetMode = "ComplexComponent"
        end
    else
        hit.SelectedTargetMode = "SingleChildParent"
    end

    Debug(string.format(
        "Interaction target resolved: mode=%s children=%d parent=%s child=%s selected=%s",
        tostring(hit.SelectedTargetMode),
        #siblings,
        tostring(ObjectKey(parentActor)),
        tostring(ObjectKey(interactionChild)),
        tostring(ObjectKey(hit.MarkerTarget))
    ))
    return hit
end

local function ResolveInvisibleEntityWorldFallback(hit)
    if not hit or not IsActorObject(hit.Actor) or not IsEntityTarget(hit.Actor) then
        return hit
    end

    local visualTarget = hit.VisualTarget or hit.Actor
    local hasVisibleMesh = IsActorObject(visualTarget)
        and ActorHasVisibleMesh(visualTarget)
        or IsVisibleMeshComponent(visualTarget)
    if hasVisibleMesh then
        return hit
    end

    -- Do not expose collision/query volumes by rendering proxy geometry. Keep
    -- the original impact point and turn this into the normal world-sphere
    -- marker. The replicated sphere then behaves exactly like a wall hit and
    -- never asks clients to outline an invisible Actor or component.
    hit.ForceWorldMarker = true
    hit.PreciseComponentTarget = false
    hit.SelectedTargetMode = "WorldFallbackNoVisibleMesh"
    Debug(string.format(
        "Falling back to world sphere because selected target has no visible mesh: actor=%s visual_target=%s component=%s",
        tostring(ObjectKey(hit.Actor)),
        tostring(ObjectKey(visualTarget)),
        tostring(ObjectKey(hit.Component))
    ))
    return hit
end

local function SetSphereComponentProperties(component)
    if not IsObjectValid(component) then
        return false
    end

    local sphereMesh = StaticFindObject(SPHERE_MESH_PATH)
    if not IsObjectValid(sphereMesh) then
        pcall(function()
            LoadAsset(SPHERE_MESH_PATH)
        end)
        sphereMesh = StaticFindObject(SPHERE_MESH_PATH)
    end

    if IsObjectValid(sphereMesh) then
        pcall(function() component:SetStaticMesh(sphereMesh) end)
    end

    pcall(function() component:SetMobility(2) end)
    pcall(function() component:SetCollisionEnabled(0) end)
    pcall(function() component:SetGenerateOverlapEvents(false) end)
    pcall(function() component:SetCastShadow(false) end)
    pcall(function() component:SetVisibility(true, true) end)
    pcall(function() component:SetHiddenInGame(false, true) end)
    pcall(function() component:SetRenderInMainPass(false) end)
    pcall(function() component:SetRenderInDepthPass(false) end)
    pcall(function() component:SetRenderCustomDepth(true) end)
    local stencilValue = Config.DirectStencilValue or Config.OutlineMode or 5
    local stencilOk, stencilError = pcall(function()
        component:SetCustomDepthStencilValue(stencilValue)
    end)
    if not stencilOk then
        Log("SetCustomDepthStencilValue failed: " .. tostring(stencilError))
    end
    pcall(function() component:SetIsReplicated(true) end)

    return IsObjectValid(sphereMesh) and stencilOk
end

local function ConfigureAnchor(anchor)
    if not IsObjectValid(anchor) then
        return false
    end

    local component = nil
    pcall(function()
        component = anchor.StaticMeshComponent
    end)

    if not IsObjectValid(component) then
        pcall(function()
            component = anchor:GetComponentByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))
        end)
    end

    local configured = SetSphereComponentProperties(component)
    pcall(function()
        anchor:SetActorEnableCollision(false)
    end)
    return configured
end

local function ConfigureEntityAnchor(anchor)
    if not IsObjectValid(anchor) then
        return false
    end

    local component = nil
    pcall(function() component = anchor.StaticMeshComponent end)
    if not IsObjectValid(component) then
        pcall(function()
            component = anchor:GetComponentByClass(StaticFindObject("/Script/Engine.StaticMeshComponent"))
        end)
    end

    if IsObjectValid(component) then
        pcall(function() component:SetRenderCustomDepth(false) end)
        pcall(function() component:SetCustomDepthStencilValue(0) end)
        pcall(function() component:SetVisibility(false, true) end)
        pcall(function() component:SetHiddenInGame(true, true) end)
        pcall(function() component:SetCollisionEnabled(0) end)
    end
    pcall(function() anchor:SetActorEnableCollision(false) end)
    return IsObjectValid(component)
end

local function IsEntityAnchor(anchor)
    if not IsObjectValid(anchor) then
        return false
    end

    local scale = nil
    pcall(function() scale = anchor:GetActorScale3D() end)
    if not scale or scale.X == nil then
        return false
    end

    return math.abs(scale.X) <= (Config.EntityAnchorDetectionScale or 0.02)
end

local function IsPreciseComponentAnchor(anchor)
    if not IsEntityAnchor(anchor) then
        return false
    end
    local rotation = nil
    pcall(function() rotation = anchor:K2_GetActorRotation() end)
    if not rotation or rotation.Pitch == nil then
        return false
    end
    return math.abs(math.abs(tonumber(rotation.Pitch) or 0.0) - (Config.ComponentMarkerPitch or 37.0)) < 0.5
end

local function GetObjectWorldLocation(object)
    if not IsObjectValid(object) then
        return nil
    end
    local location = nil
    if IsActorObject(object) then
        pcall(function() location = object:K2_GetActorLocation() end)
    else
        pcall(function() location = object:K2_GetComponentLocation() end)
        if not location or location.X == nil then
            pcall(function() location = object:GetComponentLocation() end)
        end
    end
    return location and location.X ~= nil and location or nil
end

local function ResolvePreciseComponentTarget(anchor, parentActor)
    if not IsPreciseComponentAnchor(anchor) or not IsActorObject(parentActor) then
        return nil
    end

    local candidates = GetInteractableChildren(parentActor, nil)
    local seen = {}
    for _, candidate in ipairs(candidates) do
        local key = ObjectKey(candidate)
        if key then
            seen[key] = true
        end
    end
    for _, className in ipairs(Config.PreciseInteractionComponentClasses or { "VendingButton_BP_C" }) do
        local classObjects = nil
        pcall(function() classObjects = FindAllOf(className) end)
        if type(classObjects) == "table" then
            for _, candidate in ipairs(classObjects) do
                local key = ObjectKey(candidate)
                if key and not seen[key] and BelongsToActor(candidate, parentActor) and DoesImplementInteractable(candidate) then
                    seen[key] = true
                    table.insert(candidates, candidate)
                end
            end
        end
    end

    local anchorLocation = GetObjectWorldLocation(anchor)
    local selected = nil
    local selectedDistance = math.huge
    if anchorLocation then
        for _, candidate in ipairs(candidates) do
            local candidateLocation = GetObjectWorldLocation(candidate)
            if candidateLocation then
                local distance = TraceDistanceSquared(anchorLocation, candidateLocation)
                if distance < selectedDistance then
                    selected = candidate
                    selectedDistance = distance
                end
            end
        end
    end

    Debug(string.format(
        "Precise component resolved: parent=%s candidates=%d selected=%s distance=%.1f",
        tostring(ObjectKey(parentActor)),
        #candidates,
        tostring(ObjectKey(selected)),
        math.sqrt(selectedDistance)
    ))
    return selected
end

local function PointToActorBoundsDistanceSquared(point, actor)
    if not point or not IsActorObject(actor) then
        return math.huge
    end

    local origin = {}
    local extent = {}
    local boundsOk = pcall(function()
        actor:GetActorBounds(false, origin, extent, true)
    end)
    if not boundsOk or origin.X == nil or extent.X == nil then
        local actorLocation = GetObjectWorldLocation(actor)
        return actorLocation and TraceDistanceSquared(point, actorLocation) or math.huge
    end

    local dx = math.max(math.abs(point.X - origin.X) - math.abs(extent.X or 0.0), 0.0)
    local dy = math.max(math.abs(point.Y - origin.Y) - math.abs(extent.Y or 0.0), 0.0)
    local dz = math.max(math.abs(point.Z - origin.Z) - math.abs(extent.Z or 0.0), 0.0)
    return dx * dx + dy * dy + dz * dz
end

local function ResolveEntityTargetLocally(anchor)
    if not IsEntityAnchor(anchor) then
        return nil
    end

    local anchorLocation = GetObjectWorldLocation(anchor)
    local systemLibrary = GetKismetSystemLibrary()
    local actorClass = StaticFindObject(ACTOR_CLASS)
    if not anchorLocation or not IsObjectValid(systemLibrary) or not IsObjectValid(actorClass) then
        Log("Local entity resolver unavailable: missing anchor location, system library or Actor class")
        return nil
    end

    local objectTypes = {}
    local objectTypeCount = math.max(1, math.floor(Config.LocalResolveObjectTypeCount or 32))
    for objectType = 0, objectTypeCount - 1 do
        table.insert(objectTypes, objectType)
    end

    local ignoredActors = { anchor }
    local overlapOutput = {}
    local overlapOk, overlapped = pcall(function()
        return systemLibrary:SphereOverlapActors(
            anchor,
            anchorLocation,
            Config.LocalResolveRadius or 180.0,
            objectTypes,
            actorClass,
            ignoredActors,
            overlapOutput
        )
    end)

    local rawCandidates = {}
    local rawSeen = {}
    if overlapOk and overlapped then
        AppendObjectCollection(rawCandidates, rawSeen, overlapOutput)
    end

    local scored = {}
    local expectedClassSignature = DecodeMarkerClassSignature(anchor)
    local matchingClassCount = 0
    local selected = nil
    local selectedScore = math.huge
    local selectedBoundsDistance = math.huge
    local candidateSeen = {}
    for _, rawCandidate in ipairs(rawCandidates) do
        local candidate = ResolveActorFromObject(rawCandidate)
        if IsActorObject(candidate) then
            candidate = ResolveWholeActorHelperParent(candidate)
        end
        local candidateKey = ObjectKey(candidate)
        if candidateKey
            and candidateKey ~= ObjectKey(anchor)
            and not candidateSeen[candidateKey]
            and IsEntityTarget(candidate)
            and ActorHasVisibleMesh(candidate)
        then
            candidateSeen[candidateKey] = true
            local boundsDistance = PointToActorBoundsDistanceSquared(anchorLocation, candidate)
            local actorLocation = GetObjectWorldLocation(candidate)
            local originDistance = actorLocation
                and TraceDistanceSquared(anchorLocation, actorLocation)
                or math.huge
            local candidateClassSignature = GetMarkerClassSignature(candidate)
            local classMatches = expectedClassSignature > 0
                and candidateClassSignature == expectedClassSignature
            if classMatches then
                matchingClassCount = matchingClassCount + 1
            end
            -- Bounds distance identifies the surface under the replicated hit
            -- point. Actor-origin distance breaks ties when multiple large
            -- local collision volumes overlap the same point.
            local score = boundsDistance * 1000.0 + math.min(originDistance, 1.0e12)
            if expectedClassSignature > 0 and not classMatches then
                score = score + 1.0e18
            end
            table.insert(scored, {
                Actor = candidate,
                Key = candidateKey,
                Score = score,
                BoundsDistance = boundsDistance,
                OriginDistance = originDistance,
                ClassSignature = candidateClassSignature,
                ClassMatches = classMatches,
            })
            if score < selectedScore then
                selected = candidate
                selectedScore = score
                selectedBoundsDistance = boundsDistance
            end
        end
    end

    table.sort(scored, function(left, right) return left.Score < right.Score end)
    local preview = {}
    local previewCount = math.min(#scored, math.max(1, math.floor(Config.LocalResolveLogCandidateCount or 8)))
    for index = 1, previewCount do
        local record = scored[index]
        table.insert(preview, string.format(
            "%d:%s[class=%d,match=%s,bounds=%.1f,origin=%.1f]",
            index,
            GetObjectName(record.Actor, "Unknown"),
            record.ClassSignature,
            tostring(record.ClassMatches),
            math.sqrt(record.BoundsDistance),
            math.sqrt(record.OriginDistance)
        ))
    end

    local maximumDistance = Config.LocalResolveMaxBoundsDistance or 80.0
    if selectedBoundsDistance > maximumDistance * maximumDistance then
        selected = nil
    end
    Log(string.format(
        "Local entity resolver: overlap_ok=%s overlapped=%s raw=%d eligible=%d expected_class=%d matching_class=%d radius=%.1f selected=%s bounds_distance=%.1f candidates=%s",
        tostring(overlapOk),
        tostring(overlapped),
        #rawCandidates,
        #scored,
        expectedClassSignature,
        matchingClassCount,
        Config.LocalResolveRadius or 180.0,
        tostring(ObjectKey(selected) or "None"),
        math.sqrt(selectedBoundsDistance),
        table.concat(preview, ";")
    ))
    return selected
end

local function ResolveEntityTarget(anchor)
    if not IsEntityAnchor(anchor) then
        return nil
    end

    local anchorKey = ObjectKey(anchor)
    local debugInfo = anchorKey and state.markerDebugInfo[anchorKey] or nil
    if debugInfo and IsObjectValid(debugInfo.EntityTarget) then
        Debug("Entity target resolved from authoritative server marker state")
        return debugInfo.EntityTarget
    end

    -- The anchor Owner is deliberately the replicated requesting character,
    -- never the marked target. Map actors and locally constructed interactables
    -- are resolved independently on every client from the marker descriptor.
    return ResolveEntityTargetLocally(anchor)
end

local function ResolveMarkerTarget(anchor)
    if not IsObjectValid(anchor) then
        return nil
    end

    local anchorKey = ObjectKey(anchor)
    local debugInfo = anchorKey and state.markerDebugInfo[anchorKey] or nil
    if debugInfo and IsObjectValid(debugInfo.Target) then
        return debugInfo.Target
    end

    local target = nil
    pcall(function() target = anchor:GetOwner() end)
    if IsObjectValid(target) then
        return target
    end

    pcall(function() target = anchor:GetAttachParentActor() end)
    return IsObjectValid(target) and target or nil
end

local function GetMarkerDebugInfo(anchor, preferredTarget, preferredComponent)
    local anchorKey = ObjectKey(anchor)
    local stored = anchorKey and state.markerDebugInfo[anchorKey] or nil
    local target = IsObjectValid(preferredTarget) and preferredTarget
        or (stored and IsObjectValid(stored.Target) and stored.Target)
        or ResolveMarkerTarget(anchor)
    local component = IsObjectValid(preferredComponent) and preferredComponent
        or (stored and IsObjectValid(stored.Component) and stored.Component)
        or GetRepresentativeComponent(target)
    local classification = stored and stored.Classification or ClassifyHitTarget(target, component)

    return {
        Target = target,
        Component = component,
        Classification = classification,
        TargetName = GetObjectName(target, "Unavailable"),
        ActorClass = GetObjectClassName(target, "UnknownActorClass"),
        ComponentClass = GetObjectClassName(component, "NoComponent"),
        TraceSource = stored and stored.Source or "Replicated",
    }
end

local function VectorDistance(a, b)
    if not a or not b then
        return 0.0
    end

    local dx = (a.X or 0.0) - (b.X or 0.0)
    local dy = (a.Y or 0.0) - (b.Y or 0.0)
    local dz = (a.Z or 0.0) - (b.Z or 0.0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function UpdateLabelPresentation(textComponent)
    if not IsObjectValid(textComponent) then
        return false
    end

    local playerController = GetPlayerController()
    if not IsObjectValid(playerController) then
        return true
    end

    local cameraManager = playerController.PlayerCameraManager
    local mathLibrary = GetKismetMathLibrary()
    if not IsObjectValid(cameraManager) or not IsObjectValid(mathLibrary) then
        return true
    end

    local textLocation = nil
    local cameraLocation = nil
    pcall(function() textLocation = textComponent:K2_GetComponentLocation() end)
    pcall(function() cameraLocation = cameraManager:GetCameraLocation() end)

    if textLocation and cameraLocation then
        local distance = VectorDistance(textLocation, cameraLocation)
        local viewportWidth = 1920.0
        local widgetLayout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        if IsObjectValid(widgetLayout) then
            pcall(function()
                local viewportSize = widgetLayout:GetViewportSize(playerController)
                if viewportSize and viewportSize.X and viewportSize.X > 0.0 then
                    viewportWidth = viewportSize.X
                end
            end)
        end

        local horizontalFov = 90.0
        pcall(function()
            local cameraFov = cameraManager:GetFOVAngle()
            if type(cameraFov) == "number" and cameraFov > 1.0 and cameraFov < 179.0 then
                horizontalFov = cameraFov
            end
        end)

        local targetPixels = Config.LabelScreenHeightPixels or 80.0
        local worldSize = distance
            * 2.0
            * math.tan(math.rad(horizontalFov) * 0.5)
            * targetPixels
            / viewportWidth
        pcall(function() textComponent:SetWorldSize(worldSize) end)

        -- Keep text out of the sphere's CustomDepth outline even if the native
        -- OutlineComponent refreshed all primitive components on the actor.
        pcall(function() textComponent:SetRenderCustomDepth(false) end)

        local rotationOk, lookRotation = pcall(function()
            return mathLibrary:FindLookAtRotation(textLocation, cameraLocation)
        end)
        if rotationOk and lookRotation then
            pcall(function()
                textComponent:K2_SetWorldRotation(lookRotation, false, {}, true)
            end)
        end
    end

    return true
end

local function TrackLabelComponent(textComponent)
    local key = ObjectKey(textComponent)
    if not key or state.labelComponentKeys[key] then
        return
    end

    state.labelComponentKeys[key] = true
    table.insert(state.labelComponents, { Component = textComponent, Key = key })
end

local function UpdateTrackedLabels()
    for index = #state.labelComponents, 1, -1 do
        local entry = state.labelComponents[index]
        local textComponent = entry.Component
        if IsObjectValid(textComponent) then
            UpdateLabelPresentation(textComponent)
        else
            state.labelComponentKeys[entry.Key] = nil
            table.remove(state.labelComponents, index)
        end
    end
end

local UpdateMarkerWidgets = function() end
local RegisterWaypointPositionHook = function() return false end
local ProcessPendingMarkerWork = function() end
local PlayLocalMarkerSuccessSound = function() return false, "not initialized" end
local ConfigureBroadcastVisualization = function() return false end

local function HandlePlayerControllerTick(contextParam, deltaSecondsParam)
    local tickingController = ParamValue(contextParam)
    local contextOk, localPawn = ValidateLocalPlayerContext(tickingController)
    if not contextOk then
        return
    end

    LogLocalPlayerContext("selected", tickingController, localPawn, "local_controller_tick")
    state.localPlayerController = tickingController
    state.localPlayerPawn = localPawn

    local deltaSeconds = ParamValue(deltaSecondsParam)
    if type(deltaSeconds) ~= "number" or deltaSeconds <= 0.0 then
        deltaSeconds = 1.0 / 60.0
    end

    state.labelUpdateAccumulator = state.labelUpdateAccumulator + deltaSeconds
    if state.labelUpdateAccumulator < (Config.LabelUpdateInterval or 0.05) then
        return
    end

    state.labelUpdateAccumulator = 0.0
    ProcessPendingMarkerWork()
    UpdateTrackedLabels()
    UpdateMarkerWidgets()
end

local function GetMarkerPlayerName(character)
    local playerName = "玩家"
    if not IsObjectValid(character) then
        return playerName
    end

    local playerState = nil
    pcall(function() playerState = character.PlayerState end)
    if IsObjectValid(playerState) then
        local ok, value = pcall(function()
            return playerState:GetPlayerName()
        end)
        if ok and value ~= nil then
            local stringOk, converted = pcall(function()
                return value:ToString()
            end)
            if stringOk and converted ~= nil and converted ~= "" then
                playerName = converted
            elseif type(value) == "string" and value ~= "" then
                playerName = value
            end
        end
    end

    -- FString values can contain a trailing NUL/control byte depending on the
    -- source platform. Remove only ASCII control bytes and trailing whitespace;
    -- preserve Unicode player names and visible punctuation.
    playerName = playerName:gsub("[%z\1-\31\127]", ""):gsub("%s+$", "")
    if playerName == "" then
        playerName = "玩家"
    end

    return playerName
end

local function GetMarkerIndex(anchor)
    if not IsObjectValid(anchor) then
        return 1
    end

    local rotation = nil
    pcall(function() rotation = anchor:K2_GetActorRotation() end)
    if not rotation or rotation.Roll == nil then
        pcall(function() rotation = anchor:GetActorRotation() end)
    end

    local index = 1
    if rotation and type(rotation.Roll) == "number" then
        index = math.floor(math.abs(rotation.Roll) + 0.5)
    end

    local maximum = math.max(1, math.floor(Config.MaxActiveMarkers or 8))
    if index < 1 or index > maximum then
        return 1
    end
    return index
end

local function BuildMarkerLabel(character, anchor, debugTarget, debugComponent)
    -- F5/F6 own diagnostics. Normal markers always stay compact.
    return string.format("%s Mark %d", GetMarkerPlayerName(character), GetMarkerIndex(anchor))
end

local function EnsureFallbackMarkerLabel(anchor, character)
    if not IsObjectValid(anchor) then
        return false
    end

    local textClass = StaticFindObject(TEXT_RENDER_COMPONENT_CLASS)
    if not IsObjectValid(textClass) then
        Log("TextRenderComponent class was not found")
        return false
    end

    local textComponent = nil
    pcall(function()
        textComponent = anchor:GetComponentByClass(textClass)
    end)

    if not IsObjectValid(textComponent) then
        local mathLibrary = GetKismetMathLibrary()
        if not IsObjectValid(mathLibrary) then
            return false
        end

        local relativeTransform = mathLibrary:MakeTransform(
            MakeVector(0.0, 0.0, Config.LabelHeight),
            MakeRotator(0.0, 0.0, 0.0),
            MakeVector(1.0, 1.0, 1.0)
        )
        local ok, created = pcall(function()
            return anchor:AddComponentByClass(textClass, false, relativeTransform, false)
        end)
        if ok and IsObjectValid(created) then
            textComponent = created
        end
    end

    if not IsObjectValid(textComponent) then
        Log("Could not attach TextRenderComponent to marker anchor")
        return false
    end

    local label = BuildMarkerLabel(character, anchor)
    local textOk, textError = pcall(function()
        textComponent:SetText(FText(label))
    end)
    if not textOk then
        Log("TextRenderComponent SetText failed: " .. tostring(textError))
        return false
    end

    pcall(function() textComponent:SetHorizontalAlignment(1) end)
    pcall(function() textComponent:SetVerticalAlignment(1) end)
    local colorOk, colorError = pcall(function()
        textComponent:SetTextRenderColor(Config.LabelColor or { R = 255, G = 220, B = 32, A = 255 })
    end)
    if not colorOk then
        Log("SetTextRenderColor failed: " .. tostring(colorError))
    end
    pcall(function() textComponent:SetVisibility(true, true) end)
    pcall(function() textComponent:SetHiddenInGame(false, true) end)
    pcall(function() textComponent:SetCastShadow(false) end)
    pcall(function() textComponent:SetRenderInMainPass(true) end)
    pcall(function() textComponent:SetRenderCustomDepth(false) end)
    pcall(function() textComponent:SetCustomDepthStencilValue(0) end)
    pcall(function() textComponent.bAlwaysRenderAsText = true end)
    pcall(function() textComponent:SetTranslucentSortPriority(100) end)

    TrackLabelComponent(textComponent)
    UpdateLabelPresentation(textComponent)

    Debug("Marker label configured: " .. label)
    return true
end

local function EnsureMarkerLabel(anchor, character, trackingActor)
    if not IsObjectValid(anchor) then
        return false
    end

    local anchorKey = ObjectKey(anchor)
    if not anchorKey then
        return false
    end

    local existing = state.markerWidgets[anchorKey]
    if existing and IsObjectValid(existing.Widget) then
        existing.TrackingActor = IsObjectValid(trackingActor) and trackingActor or anchor
        existing.Label = BuildMarkerLabel(character, anchor)
        return true
    end

    local playerController = GetPlayerController()
    local widgetLibrary = StaticFindObject(WIDGET_BLUEPRINT_LIBRARY)
    local widgetClass = StaticFindObject(WAYPOINT_WIDGET_CLASS)
    if not IsObjectValid(widgetClass) then
        pcall(function() LoadAsset(WAYPOINT_WIDGET_ASSET) end)
        widgetClass = StaticFindObject(WAYPOINT_WIDGET_CLASS)
    end
    RegisterWaypointPositionHook()

    if not IsObjectValid(playerController)
        or not IsObjectValid(widgetLibrary)
        or not IsObjectValid(widgetClass) then
        Log("Native waypoint UI dependencies were unavailable; using TextRender fallback")
        return EnsureFallbackMarkerLabel(anchor, character)
    end

    local widget = nil
    local createOk, createError = pcall(function()
        widget = widgetLibrary:Create(playerController, widgetClass, playerController)
    end)
    if not createOk or not IsObjectValid(widget) then
        Log("Native waypoint UI creation failed: " .. tostring(createError))
        return EnsureFallbackMarkerLabel(anchor, character)
    end

    local label = BuildMarkerLabel(character, anchor)
    local linkedOk, linkedError = pcall(function()
        widget.LinkedActor = IsActorObject(trackingActor) and trackingActor or anchor
    end)
    local textOk, textError = pcall(function()
        if not IsObjectValid(widget.WaypointText) then
            error("WaypointText was unavailable")
        end
        widget.WaypointText:SetText(FText(label))
    end)
    local viewportOk, viewportError = pcall(function()
        widget:AddToViewport(Config.LabelWidgetZOrder or 100)
    end)

    if not linkedOk or not textOk or not viewportOk then
        pcall(function() widget:RemoveFromParent() end)
        Log(string.format(
            "Native waypoint UI configuration failed: linked=%s text=%s viewport=%s details=%s | %s | %s",
            tostring(linkedOk),
            tostring(textOk),
            tostring(viewportOk),
            tostring(linkedError),
            tostring(textError),
            tostring(viewportError)
        ))
        return EnsureFallbackMarkerLabel(anchor, character)
    end

    -- These presentation calls are optional. Keeping them isolated prevents a
    -- cosmetic struct mismatch from discarding an otherwise functional widget.
    pcall(function()
        local scale = Config.LabelWidgetScale or 1.5
        widget.WaypointText:SetRenderScale({ X = scale, Y = scale })
    end)
    pcall(function() widget:SetRenderOpacity(1.0) end)
    pcall(function() widget.WaypointRoot:SetVisibility(0) end)
    pcall(function() widget.WaypointRoot:SetRenderOpacity(1.0) end)
    pcall(function() widget.WaypointText:SetVisibility(0) end)
    pcall(function() widget.WaypointText:SetRenderOpacity(1.0) end)
    pcall(function()
        local color = Config.LabelColor or { R = 255, G = 220, B = 32, A = 255 }
        widget.WaypointText:SetColorAndOpacity({
            SpecifiedColor = {
                R = (color.R or 255) / 255.0,
                G = (color.G or 220) / 255.0,
                B = (color.B or 32) / 255.0,
                A = (color.A or 255) / 255.0,
            },
            ColorUseRule = 0,
        })
    end)

    -- The outlined world sphere is the marker icon. The parent widget also
    -- exposes a misspelled WaypoointIcon, so both icon fields must be hidden.
    pcall(function()
        if IsObjectValid(widget.WaypointIcon) then
            widget.WaypointIcon:SetVisibility(1)
        end
        if IsObjectValid(widget.WaypoointIcon) then
            widget.WaypoointIcon:SetVisibility(1)
        end
        if IsObjectValid(widget.WaypointProgressBar) then
            widget.WaypointProgressBar:SetVisibility(1)
        end
    end)
    pcall(function() widget:UpdatePosition() end)

    state.markerWidgets[anchorKey] = {
        Widget = widget,
        Anchor = anchor,
        TrackingActor = IsObjectValid(trackingActor) and trackingActor or anchor,
        Label = label,
    }

    Debug("Native screen-space marker label configured: " .. label)
    return true
end

local function SetWidgetElementVisibility(element, visibility)
    if IsObjectValid(element) then
        pcall(function() element:SetVisibility(visibility) end)
    end
end

UpdateMarkerWidgets = function()
    local playerController = GetPlayerController()
    local widgetLayout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not IsObjectValid(playerController) or not IsObjectValid(widgetLayout) then
        return
    end

    if not state.widgetUpdateStarted then
        state.widgetUpdateStarted = true
        Debug("Marker widget screen projection updater is active")
    end

    local viewportScale = 1.0
    pcall(function()
        local value = widgetLayout:GetViewportScale(playerController)
        if type(value) == "number" and value > 0.0 then
            viewportScale = value
        end
    end)

    local viewportSize = nil
    pcall(function()
        viewportSize = widgetLayout:GetViewportSize(playerController)
    end)

    for anchorKey, entry in pairs(state.markerWidgets) do
        local widget = entry.Widget
        local trackingActor = entry.TrackingActor
        if not IsObjectValid(widget) or not IsObjectValid(entry.Anchor) or not IsObjectValid(trackingActor) then
            if IsObjectValid(widget) then
                pcall(function() widget:RemoveFromParent() end)
            end
            state.markerWidgets[anchorKey] = nil
        else
            local worldLocation = nil
            local boundsOrigin = {}
            local boundsExtent = {}
            local boundsOk = false
            if IsActorObject(trackingActor) then
                boundsOk = pcall(function()
                    trackingActor:GetActorBounds(false, boundsOrigin, boundsExtent, true)
                end)
            end
            if boundsOk and boundsOrigin.X ~= nil and boundsExtent.Z ~= nil then
                worldLocation = MakeVector(
                    boundsOrigin.X,
                    boundsOrigin.Y,
                    boundsOrigin.Z + boundsExtent.Z + (Config.LabelWorldOffset or 18.0)
                )
            else
                worldLocation = GetObjectWorldLocation(trackingActor)
                if worldLocation and not IsActorObject(trackingActor) then
                    worldLocation = AddScaledVector(
                        worldLocation,
                        { X = 0.0, Y = 0.0, Z = 1.0 },
                        Config.LabelWorldOffset or 18.0
                    )
                end
            end

            local screenPosition = {}
            local projected = false
            if worldLocation then
                pcall(function()
                    projected = playerController:ProjectWorldLocationToScreen(worldLocation, screenPosition, false)
                end)
            end

            local canvasSlot = nil
            local positionApplied = false
            local positionError = nil
            local positionMode = "none"
            local renderTranslation = nil
            if projected and screenPosition.X ~= nil then
                local uiPosition = {
                    X = screenPosition.X / viewportScale,
                    Y = screenPosition.Y / viewportScale - (Config.LabelScreenOffsetY or 20.0),
                }
                if IsObjectValid(widget.WaypointRoot) then
                    pcall(function()
                        canvasSlot = widgetLayout:SlotAsCanvasSlot(widget.WaypointRoot)
                    end)
                end

                -- W_Waypoint_Generic resets its CanvasSlot during its own
                -- widget tick. Apply a render translation after layout instead;
                -- this survives that reset and moves the Overlay containing text.
                if IsObjectValid(widget.WaypointRoot)
                    and viewportSize ~= nil
                    and viewportSize.X ~= nil
                    and viewportSize.Y ~= nil then
                    renderTranslation = {
                        X = uiPosition.X - ((viewportSize.X / viewportScale) * 0.5),
                        Y = uiPosition.Y - ((viewportSize.Y / viewportScale) * 0.5),
                    }
                    positionMode = "render_translation"
                    positionApplied, positionError = pcall(function()
                        widget.WaypointRoot:SetRenderTranslation(renderTranslation)
                    end)
                elseif IsObjectValid(canvasSlot) then
                    positionMode = "canvas_fallback"
                    positionApplied, positionError = pcall(function() canvasSlot:SetPosition(uiPosition) end)
                else
                    positionMode = "viewport_fallback"
                    positionApplied, positionError = pcall(function() widget:SetPositionInViewport(uiPosition, true) end)
                end
            end

            if not state.widgetDiagnostics[anchorKey] then
                state.widgetDiagnostics[anchorKey] = true
                Debug(string.format(
                    "Marker widget projection: projected=%s screen=(%s,%s) viewport=(%s,%s) mode=%s translation=(%s,%s) canvas_slot=%s position_applied=%s text=%s target=%s error=%s",
                    tostring(projected),
                    tostring(screenPosition.X),
                    tostring(screenPosition.Y),
                    tostring(viewportSize and viewportSize.X),
                    tostring(viewportSize and viewportSize.Y),
                    tostring(positionMode),
                    tostring(renderTranslation and renderTranslation.X),
                    tostring(renderTranslation and renderTranslation.Y),
                    tostring(IsObjectValid(canvasSlot)),
                    tostring(positionApplied),
                    tostring(IsObjectValid(widget.WaypointText)),
                    tostring(ObjectKey(trackingActor)),
                    tostring(positionError)
                ))
            end

            SetWidgetElementVisibility(widget.WaypointRoot, 0)
            SetWidgetElementVisibility(widget.WaypointText, 0)
            SetWidgetElementVisibility(widget.WaypointIcon, 1)
            SetWidgetElementVisibility(widget.WaypoointIcon, 1)
            SetWidgetElementVisibility(widget.WaypointArrow, 1)
            SetWidgetElementVisibility(widget.WaypointProgressBar, 1)
            pcall(function() widget:SetRenderOpacity(1.0) end)
            pcall(function() widget.WaypointRoot:SetRenderOpacity(1.0) end)

            if IsObjectValid(widget.WaypointText) then
                pcall(function()
                    widget.WaypointText:SetText(FText(entry.Label))
                    widget.WaypointText:SetRenderOpacity(1.0)
                    local scale = Config.LabelWidgetScale or 1.5
                    widget.WaypointText:SetRenderScale({ X = scale, Y = scale })
                end)
            end
        end
    end
end

RegisterWaypointPositionHook = function()
    if state.waypointPositionHookRegistered then
        return true
    end

    local updatePositionFunction = StaticFindObject(WAYPOINT_UPDATE_POSITION_PATH)
    if not IsObjectValid(updatePositionFunction) then
        return false
    end

    local hookOk, hookError = pcall(function()
        -- Blueprint hooks use one callback, invoked after UpdatePosition. This
        -- is deliberately later than the widget's own layout reset.
        RegisterHook(WAYPOINT_UPDATE_POSITION_PATH, function()
            if state.waypointPositionHookRunning then
                return
            end
            state.waypointPositionHookRunning = true
            if not state.waypointPositionHookActive then
                state.waypointPositionHookActive = true
                Debug("Waypoint UpdatePosition post hook is active")
            end
            local updateOk, updateError = pcall(UpdateMarkerWidgets)
            state.waypointPositionHookRunning = false
            if not updateOk then
                Log("Waypoint post-position update failed: " .. tostring(updateError))
            end
        end)
    end)
    if not hookOk then
        Log("Failed to register Waypoint UpdatePosition hook: " .. tostring(hookError))
        return false
    end

    state.waypointPositionHookRegistered = true
    Debug("Waypoint UpdatePosition post hook registered")
    return true
end

local HUD_LABEL_PALETTE = {
    { R = 1.00, G = 0.86, B = 0.18, A = 1.00 },
    { R = 0.20, G = 0.92, B = 1.00, A = 1.00 },
    { R = 1.00, G = 0.35, B = 0.62, A = 1.00 },
    { R = 0.42, G = 1.00, B = 0.38, A = 1.00 },
    { R = 1.00, G = 0.55, B = 0.18, A = 1.00 },
    { R = 0.68, G = 0.45, B = 1.00, A = 1.00 },
    { R = 1.00, G = 0.38, B = 0.28, A = 1.00 },
    { R = 0.30, G = 1.00, B = 0.72, A = 1.00 },
}

local function GetHudLabelColor(playerName)
    local hash = 0
    local name = tostring(playerName or "player")
    for index = 1, #name do
        hash = (hash * 33 + string.byte(name, index)) % 2147483647
    end
    return HUD_LABEL_PALETTE[(hash % #HUD_LABEL_PALETTE) + 1]
end

local function GetMarkerDrawLocation(trackingActor, anchor)
    local actorLocation = GetObjectWorldLocation(trackingActor)

    if not IsActorObject(trackingActor) then
        if actorLocation then
            return AddScaledVector(
                actorLocation,
                { X = 0.0, Y = 0.0, Z = 1.0 },
                Config.LabelWorldOffset or 18.0
            )
        end
        return GetObjectWorldLocation(anchor)
    end

    local boundsOrigin = {}
    local boundsExtent = {}
    local boundsOk = pcall(function()
        -- Child actors can contain interaction helpers or other components far
        -- away from the visible entity. Including them produced enormous bounds
        -- and projected entity labels above the viewport.
        trackingActor:GetActorBounds(false, boundsOrigin, boundsExtent, false)
    end)
    if boundsOk and boundsOrigin.X ~= nil and boundsExtent.Z ~= nil then
        local isEntityTracking = IsObjectValid(anchor) and trackingActor ~= anchor
        if isEntityTracking and actorLocation and actorLocation.X ~= nil then
            local dx = boundsOrigin.X - actorLocation.X
            local dy = boundsOrigin.Y - actorLocation.Y
            local dz = boundsOrigin.Z - actorLocation.Z
            local originDistanceSquared = dx * dx + dy * dy + dz * dz
            local maximumOriginOffset = Config.MaxEntityLabelBoundsOffset or 400.0
            local maximumExtent = Config.MaxEntityLabelExtent or 300.0
            local extentZ = tonumber(boundsExtent.Z) or math.huge
            if originDistanceSquared > maximumOriginOffset * maximumOriginOffset
                or extentZ < 0.0
                or extentZ > maximumExtent then
                return AddScaledVector(
                    actorLocation,
                    { X = 0.0, Y = 0.0, Z = 1.0 },
                    Config.EntityLabelFallbackHeight or 60.0
                )
            end
        end

        local heightFactor = 1.0
        if isEntityTracking then
            heightFactor = Config.EntityLabelBoundsHeightFactor or 0.5
        else
            heightFactor = Config.WorldLabelBoundsHeightFactor or 1.0
        end
        local worldOffset = isEntityTracking
            and (Config.EntityLabelWorldOffset or 0.0)
            or (Config.WorldLabelWorldOffset or 0.0)
        return MakeVector(
            boundsOrigin.X,
            boundsOrigin.Y,
            boundsOrigin.Z + boundsExtent.Z * heightFactor + worldOffset
        )
    end

    if actorLocation and IsObjectValid(anchor) and trackingActor ~= anchor then
        return AddScaledVector(
            actorLocation,
            { X = 0.0, Y = 0.0, Z = 1.0 },
            Config.EntityLabelFallbackHeight or 60.0
        )
    end
    return actorLocation
end

local function GetPrimaryHudCanvas()
    if IsObjectValid(state.primaryHudCanvas) then
        return state.primaryHudCanvas
    end

    local playerController = GetPlayerController()
    if not IsObjectValid(playerController) then
        return nil
    end

    local hudCanvas = nil
    pcall(function() hudCanvas = playerController.PrimaryHUDCanvas end)
    if not IsObjectValid(hudCanvas) then
        local pawn = nil
        pcall(function() pawn = playerController.Pawn end)
        if not IsObjectValid(pawn) then
            pcall(function() pawn = playerController:K2_GetPawn() end)
        end
        if IsObjectValid(pawn) then
            pcall(function() hudCanvas = pawn.PrimaryHUDCanvas end)
        end
    end

    local selectedScore = 0
    local selectedKey = nil
    local selectedWidgetKey = nil

    -- The main player HUD owns the full-screen coordinate space. Prefer its
    -- PrimaryHUDCanvas over the nested crosshair canvas when available.
    if not IsObjectValid(hudCanvas) then
        local mainHudWidgets = FindAllOf("W_PlayerHUD_Main_C") or {}
        local runtimeCount = 0
        for _, widget in ipairs(mainHudWidgets) do
            if IsObjectValid(widget) then
                local world = nil
                local inViewport = false
                pcall(function() world = widget:GetWorld() end)
                pcall(function() inViewport = widget:IsInViewport() end)
                if IsObjectValid(world) then
                    runtimeCount = runtimeCount + 1
                    local panel = nil
                    pcall(function() panel = widget.PrimaryHUDCanvas end)
                    if not IsObjectValid(panel) then
                        for _, widgetName in ipairs({ "PrimaryHUDCanvas", "CanvasPanel_0" }) do
                            pcall(function() panel = widget:GetWidgetFromName(FName(widgetName)) end)
                            if IsObjectValid(panel) then break end
                        end
                    end
                    if IsObjectValid(panel) then
                        local className = ""
                        pcall(function() className = panel:GetClass():GetFName():ToString() end)
                        if className == "CanvasPanel" then
                            local score = inViewport and 3000 or 2500
                            if score > selectedScore then
                                selectedScore = score
                                hudCanvas = panel
                                selectedKey = ObjectKey(panel)
                                selectedWidgetKey = ObjectKey(widget)
                            end
                        end
                    end
                end
            end
        end
        Debug(string.format(
            "Runtime main HUD discovery: total=%d runtime=%d selected_widget=%s selected_panel=%s",
            #mainHudWidgets,
            runtimeCount,
            tostring(selectedWidgetKey),
            tostring(selectedKey)
        ))
    end

    -- Prefer a live W_HUD_Crosshair instance. Blueprint asset WidgetTrees have
    -- no valid game world and must never be used as an attachment parent.
    if not IsObjectValid(hudCanvas) then
        local crosshairWidgets = FindAllOf("W_HUD_Crosshair_C") or {}
        local runtimeCount = 0
        for _, widget in ipairs(crosshairWidgets) do
            if IsObjectValid(widget) then
                local world = nil
                local inViewport = false
                pcall(function() world = widget:GetWorld() end)
                pcall(function() inViewport = widget:IsInViewport() end)
                if IsObjectValid(world) then
                    runtimeCount = runtimeCount + 1
                    local panel = nil
                    for _, widgetName in ipairs({ "PrimaryHUDCanvas", "CanvasPanel_71", "CanvasPanel_0" }) do
                        pcall(function() panel = widget:GetWidgetFromName(FName(widgetName)) end)
                        if IsObjectValid(panel) then break end
                    end

                    if not IsObjectValid(panel) then
                        local widgetTree = nil
                        pcall(function() widgetTree = widget.WidgetTree end)
                        if IsObjectValid(widgetTree) then
                            for _, widgetName in ipairs({ "PrimaryHUDCanvas", "CanvasPanel_71", "CanvasPanel_0" }) do
                                pcall(function() panel = widgetTree:FindWidget(FName(widgetName)) end)
                                if IsObjectValid(panel) then break end
                            end
                            if not IsObjectValid(panel) then
                                pcall(function() panel = widgetTree.RootWidget end)
                            end
                        end
                    end

                    if IsObjectValid(panel) then
                        local score = inViewport and 2000 or 1500
                        if score > selectedScore then
                            selectedScore = score
                            hudCanvas = panel
                            selectedKey = ObjectKey(panel)
                            selectedWidgetKey = ObjectKey(widget)
                        end
                    end
                end
            end
        end
        Debug(string.format(
            "Runtime crosshair discovery: total=%d runtime=%d selected_widget=%s selected_panel=%s",
            #crosshairWidgets,
            runtimeCount,
            tostring(selectedWidgetKey),
            tostring(selectedKey)
        ))
    end

    -- Fallback: scan only CanvasPanels that resolve to the current game world.
    -- This excludes paths such as /Game/...:WidgetTree.CanvasPanel_71.
    if not IsObjectValid(hudCanvas) then
        local candidates = FindAllOf("CanvasPanel") or {}
        local candidateCount = 0
        local runtimeCount = 0
        for _, candidate in ipairs(candidates) do
            if IsObjectValid(candidate) then
                candidateCount = candidateCount + 1
                local key = tostring(ObjectKey(candidate) or "")
                local lower = string.lower(key)
                local score = 0
                local world = nil
                pcall(function() world = candidate:GetWorld() end)
                if not IsObjectValid(world) then
                    score = -20000
                elseif string.find(lower, "default__", 1, true) then
                    score = -10000
                elseif string.find(lower, "waypoint", 1, true) then
                    score = -1000
                else
                    runtimeCount = runtimeCount + 1
                    if string.find(lower, "/engine/transient", 1, true) then score = score + 1500 end
                    if string.find(lower, "primaryhudcanvas", 1, true) then score = score + 1000 end
                    if string.find(lower, "w_hud_crosshair", 1, true) then score = score + 800 end
                    if string.find(lower, "w_hud_ammocounter", 1, true) then score = score + 600 end
                    if string.find(lower, "w_hud", 1, true) then score = score + 300 end
                    if string.find(lower, "hud", 1, true) then score = score + 100 end
                end
                if score > selectedScore then
                    selectedScore = score
                    selectedKey = key
                    hudCanvas = candidate
                end
            end
        end
        Debug(string.format(
            "Runtime CanvasPanel discovery: total=%d runtime=%d selected_score=%s selected=%s",
            candidateCount,
            runtimeCount,
            tostring(selectedScore),
            tostring(selectedKey)
        ))
    end

    if IsObjectValid(hudCanvas) then
        state.primaryHudCanvas = hudCanvas
    end

    if not state.primaryHudCanvasDiagnosed then
        state.primaryHudCanvasDiagnosed = true
        local className = "invalid"
        if IsObjectValid(hudCanvas) then
            pcall(function() className = hudCanvas:GetClass():GetFName():ToString() end)
        end
        Debug("Runtime HUD canvas resolved: valid=" .. tostring(IsObjectValid(hudCanvas)) .. " class=" .. tostring(className) .. " object=" .. tostring(ObjectKey(hudCanvas)))
    end
    return hudCanvas
end

local function CreateMarkerTextWidget(entry, anchorKey)
    local playerController = GetPlayerController()
    local hudCanvas = GetPrimaryHudCanvas()
    local widgetLibrary = StaticFindObject(WIDGET_BLUEPRINT_LIBRARY)
    local widgetClass = StaticFindObject(WAYPOINT_WIDGET_CLASS)
    if not IsObjectValid(widgetClass) then
        pcall(function() LoadAsset(WAYPOINT_WIDGET_ASSET) end)
        widgetClass = StaticFindObject(WAYPOINT_WIDGET_CLASS)
    end

    if not IsObjectValid(playerController)
        or not IsObjectValid(hudCanvas)
        or not IsObjectValid(widgetLibrary)
        or not IsObjectValid(widgetClass) then
        return false, "HUD canvas or text template dependency unavailable"
    end

    local templateHost = nil
    local templateText = nil
    local clone = nil
    local slot = nil
    local createOk, createError = pcall(function()
        templateHost = widgetLibrary:Create(playerController, widgetClass, playerController)
        if not IsObjectValid(templateHost) or not IsObjectValid(templateHost.WaypointText) then
            error("WaypointText template unavailable")
        end
        templateText = templateHost.WaypointText

        state.hudLabelSerial = state.hudLabelSerial + 1
        clone = StaticConstructObject(
            templateText:GetClass(),
            hudCanvas,
            FName("AbioticPingHudLabel_" .. tostring(state.hudLabelSerial)),
            0, 0, false, false,
            templateText
        )
        if not IsObjectValid(clone) then
            error("StaticConstructObject returned an invalid TextBlock")
        end

        slot = hudCanvas:AddChildToCanvas(clone)
        if not IsObjectValid(slot) then
            error("PrimaryHUDCanvas:AddChildToCanvas returned an invalid slot")
        end

        clone:SetText(FText(entry.Label))
        clone:SetJustification(1)
        clone:SetVisibility(0)
        clone:SetRenderOpacity(1.0)
        clone:SetRenderScale({ X = Config.HudLabelScale or 1.25, Y = Config.HudLabelScale or 1.25 })
        local boldOk, boldError = pcall(function()
            local fontInfo = clone.Font
            if fontInfo == nil then
                error("TextBlock Font property unavailable")
            end
            fontInfo.TypefaceFontName = FName(Config.HudLabelTypeface or "Bold")
            clone:SetFont(fontInfo)
        end)
        if not boldOk then
            Debug("HUD label bold typeface could not be applied: " .. tostring(boldError))
        end
        clone:SetColorAndOpacity({ SpecifiedColor = entry.Color, ColorUseRule = 0 })
        slot:SetZOrder(Config.LabelWidgetZOrder or 100)
    end)

    if IsObjectValid(templateHost) then
        pcall(function() templateHost:RemoveFromParent() end)
    end
    if not createOk then
        if IsObjectValid(clone) then
            pcall(function() clone:RemoveFromParent() end)
        end
        return false, tostring(createError)
    end

    entry.Widget = clone
    entry.Slot = slot
    entry.ParentCanvas = hudCanvas
    Debug("Primary HUD TextBlock created: " .. entry.Label)
    return true, nil
end

-- v0.2.6 owns a TextBlock directly under PrimaryHUDCanvas. Unlike the game's
-- waypoint widget, no game Blueprint updates this CanvasPanelSlot.
local function RemoveMarkerWidget(anchorKey)
    local entry = state.markerWidgets[anchorKey]
    if not entry then
        return
    end

    if IsObjectValid(entry.Widget) then
        pcall(function() entry.Widget:RemoveFromParent() end)
    end
    if entry.MarkerIndex and state.markerWidgetSlots[entry.MarkerIndex] == anchorKey then
        state.markerWidgetSlots[entry.MarkerIndex] = nil
    end
    state.markerWidgets[anchorKey] = nil
    state.hudDrawDiagnostics[anchorKey] = nil
end

EnsureMarkerLabel = function(anchor, character, trackingActor)
    if not IsObjectValid(anchor) then
        return false
    end

    local anchorKey = ObjectKey(anchor)
    if not anchorKey then
        return false
    end

    local playerName = GetMarkerPlayerName(character)
    local markerIndex = GetMarkerIndex(anchor)
    local previousAnchorKey = state.markerWidgetSlots[markerIndex]
    if previousAnchorKey and previousAnchorKey ~= anchorKey then
        RemoveMarkerWidget(previousAnchorKey)
        Debug("Immediately recycled local marker UI slot " .. tostring(markerIndex))
    end
    state.markerWidgetSlots[markerIndex] = anchorKey

    local entry = state.markerWidgets[anchorKey]
    if not entry then
        entry = {
            Anchor = anchor,
            TrackingActor = IsObjectValid(trackingActor) and trackingActor or anchor,
            Label = BuildMarkerLabel(character, anchor),
            Color = GetHudLabelColor(playerName),
            MarkerIndex = markerIndex,
            Character = character,
            -- UObject wrappers can remain valid briefly after a replicated
            -- anchor is destroyed. Use an explicit UI lifetime so an entity
            -- label cannot survive merely because its tracked Actor is alive.
            ExpiresAt = Now(anchor) + (Config.MarkerDuration or 10.0),
        }
        state.markerWidgets[anchorKey] = entry
    else
        entry.Anchor = anchor
        entry.TrackingActor = IsObjectValid(trackingActor) and trackingActor or anchor
        entry.Label = BuildMarkerLabel(character, anchor)
        entry.Color = GetHudLabelColor(playerName)
        entry.MarkerIndex = markerIndex
        entry.Character = character
        if type(entry.ExpiresAt) ~= "number" then
            entry.ExpiresAt = Now(anchor) + (Config.MarkerDuration or 10.0)
        end
    end

    if IsObjectValid(entry.Widget) and IsObjectValid(entry.Slot) then
        pcall(function() entry.Widget:SetText(FText(entry.Label)) end)
        return true
    end

    local created, createError = CreateMarkerTextWidget(entry, anchorKey)
    if not created then
        Log("Primary HUD TextBlock creation failed: " .. tostring(createError))
    end
    return created
end

UpdateMarkerWidgets = function()
    local playerController = GetPlayerController()
    local widgetLayout = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not IsObjectValid(playerController) or not IsObjectValid(widgetLayout) then
        return
    end

    local viewportScale = 1.0
    pcall(function()
        local value = widgetLayout:GetViewportScale(playerController)
        if type(value) == "number" and value > 0.0 then
            viewportScale = value
        end
    end)

    local now = Now(playerController)
    for anchorKey, entry in pairs(state.markerWidgets) do
        local expired = type(entry.ExpiresAt) == "number" and now >= entry.ExpiresAt
        if expired then
            Debug(string.format(
                "Removed expired marker label: slot=%s",
                tostring(entry.MarkerIndex or "unknown")
            ))
            RemoveMarkerWidget(anchorKey)
        elseif not IsObjectValid(entry.Anchor) or not IsObjectValid(entry.TrackingActor) then
            RemoveMarkerWidget(anchorKey)
        elseif IsObjectValid(entry.Widget) and IsObjectValid(entry.Slot) then
            local worldLocation = GetMarkerDrawLocation(entry.TrackingActor, entry.Anchor)
            local screenPosition = {}
            local projected = false
            if worldLocation then
                pcall(function()
                    projected = playerController:ProjectWorldLocationToScreen(worldLocation, screenPosition, false)
                end)
            end

            local moveOk = false
            local moveError = nil
            local localPosition = {}
            local coordinateMode = "dpi_fallback"
            local convertError = nil
            if projected and screenPosition.X ~= nil and screenPosition.Y ~= nil then
                local width = Config.HudLabelWidth or 600.0
                local height = Config.HudLabelHeight or 64.0
                local uiX = screenPosition.X / viewportScale
                local uiY = screenPosition.Y / viewportScale
                local isEntityTracking = entry.TrackingActor ~= entry.Anchor

                if state.screenToWidgetLocalSupported ~= false and IsObjectValid(entry.ParentCanvas) then
                    local geometry = nil
                    pcall(function() geometry = entry.ParentCanvas:GetCachedGeometry() end)
                    if geometry ~= nil then
                        local convertOk, actualConvertError = pcall(function()
                            widgetLayout:ScreenToWidgetLocal(
                                playerController,
                                geometry,
                                screenPosition,
                                localPosition,
                                false
                            )
                        end)
                        if convertOk and localPosition.X ~= nil and localPosition.Y ~= nil then
                            uiX = localPosition.X
                            uiY = localPosition.Y
                            coordinateMode = "screen_to_local"
                            state.screenToWidgetLocalSupported = true
                        elseif not convertOk then
                            convertError = tostring(actualConvertError)
                            state.screenToWidgetLocalSupported = false
                            Debug("ScreenToWidgetLocal is unavailable; permanently using the verified DPI fallback")
                        end
                    end
                end

                local screenOffset = isEntityTracking
                    and (Config.EntityLabelScreenOffsetY or 0.0)
                    or (Config.WorldLabelScreenOffsetY or 0.0)
                local verticalAlignment = isEntityTracking
                    and (Config.EntityLabelVerticalAlignment or 0.5)
                    or (Config.WorldLabelVerticalAlignment or 0.5)
                uiY = uiY - screenOffset
                moveOk, moveError = pcall(function()
                    entry.Slot:SetOffsets({
                        Left = uiX - (width * 0.5),
                        Top = uiY - (height * verticalAlignment),
                        Right = width,
                        Bottom = height,
                    })
                    entry.Widget:SetVisibility(0)
                    entry.Widget:SetText(FText(entry.Label))
                end)
            else
                pcall(function() entry.Widget:SetVisibility(2) end)
            end

            if not state.hudDrawDiagnostics[anchorKey] then
                state.hudDrawDiagnostics[anchorKey] = true
                Debug(string.format(
                    "Primary HUD label update: projected=%s screen=(%s,%s) local=(%s,%s) mode=%s viewport_scale=%s move=%s target=%s error=%s convert_error=%s",
                    tostring(projected),
                    tostring(screenPosition.X),
                    tostring(screenPosition.Y),
                    tostring(localPosition.X),
                    tostring(localPosition.Y),
                    tostring(coordinateMode),
                    tostring(viewportScale),
                    tostring(moveOk),
                    tostring(ObjectKey(entry.TrackingActor)),
                    tostring(moveError),
                    tostring(convertError)
                ))
            end
        end
    end
end

local function ReadDiagnosticProperty(object, propertyName)
    if not IsObjectValid(object) then
        return nil
    end
    local value = nil
    pcall(function() value = object[propertyName] end)
    return value
end

local function CountDiagnosticCollection(collection)
    if collection == nil then
        return -1, "nil"
    end
    if type(collection) == "table" then
        local count = 0
        for _ in pairs(collection) do
            count = count + 1
        end
        return count, "table"
    end

    local count = nil
    pcall(function() count = #collection end)
    if type(count) == "number" then
        return count, "length"
    end
    pcall(function() count = collection:Num() end)
    if type(count) == "number" then
        return count, "Num"
    end

    count = 0
    local iterated = pcall(function()
        collection:ForEach(function()
            count = count + 1
        end)
    end)
    if iterated then
        return count, "ForEach"
    end
    return -1, type(collection)
end

local function LogOutlineDiagnostics(targetActor, outlineComponent, phase, componentOrigin)
    if Config.OutlineDiagnostics ~= true then
        return
    end

    local isRegistered = nil
    pcall(function() isRegistered = outlineComponent:IsRegistered() end)
    local registeredFlag = ReadDiagnosticProperty(outlineComponent, "Registered")
    local componentEnabled = ReadDiagnosticProperty(outlineComponent, "ComponentEnabled")
    local registeredComponents = ReadDiagnosticProperty(outlineComponent, "RegisteredComponents")
    local registeredCount, registeredCountMode = CountDiagnosticCollection(registeredComponents)
    local pendingComponents = ReadDiagnosticProperty(outlineComponent, "NewComponentsToOutline")
    local pendingCount, pendingCountMode = CountDiagnosticCollection(pendingComponents)

    local primitiveCollection = nil
    local primitiveClass = StaticFindObject(PRIMITIVE_COMPONENT_CLASS)
    if IsObjectValid(primitiveClass) then
        pcall(function() primitiveCollection = targetActor:GetComponentsByClass(primitiveClass) end)
    end
    local primitiveCount, primitiveCountMode = CountDiagnosticCollection(primitiveCollection)

    local furnitureMesh = ReadDiagnosticProperty(targetActor, "FurnitureMesh")
    local furnitureRegistered = nil
    local furnitureCustomDepth = nil
    local furnitureStencil = nil
    if IsObjectValid(furnitureMesh) then
        pcall(function() furnitureRegistered = furnitureMesh:IsRegistered() end)
        pcall(function() furnitureCustomDepth = furnitureMesh.bRenderCustomDepth end)
        pcall(function() furnitureStencil = furnitureMesh.CustomDepthStencilValue end)
    end

    Debug(string.format(
        "Outline diagnostics: phase=%s origin=%s target=%s outline=%s is_registered=%s registered_flag=%s component_enabled=%s registered_components=%s(%s) pending_components=%s(%s) actor_primitives=%s(%s) furniture=%s furniture_registered=%s furniture_custom_depth=%s furniture_stencil=%s",
        tostring(phase),
        tostring(componentOrigin),
        tostring(ObjectKey(targetActor)),
        tostring(ObjectKey(outlineComponent)),
        tostring(isRegistered),
        tostring(registeredFlag),
        tostring(componentEnabled),
        tostring(registeredCount),
        tostring(registeredCountMode),
        tostring(pendingCount),
        tostring(pendingCountMode),
        tostring(primitiveCount),
        tostring(primitiveCountMode),
        tostring(ObjectKey(furnitureMesh)),
        tostring(furnitureRegistered),
        tostring(furnitureCustomDepth),
        tostring(furnitureStencil)
    ))
end

local function EnsureOutlineComponent(targetActor)
    if not IsObjectValid(targetActor) then
        return false
    end

    local outlineClass = StaticFindObject(OUTLINE_COMPONENT_CLASS)
    if not IsObjectValid(outlineClass) then
        pcall(function() LoadAsset(OUTLINE_COMPONENT_ASSET) end)
        outlineClass = StaticFindObject(OUTLINE_COMPONENT_CLASS)
    end

    if not IsObjectValid(outlineClass) then
        Log("Native OutlineComponent class was not found")
        return false
    end

    local outlineComponent = nil
    pcall(function()
        outlineComponent = targetActor:GetComponentByClass(outlineClass)
    end)
    local componentOrigin = IsObjectValid(outlineComponent) and "existing" or "created"

    if not IsObjectValid(outlineComponent) then
        local mathLibrary = GetKismetMathLibrary()
        if not IsObjectValid(mathLibrary) then
            return false
        end

        local identity = mathLibrary:MakeTransform(
            MakeVector(0.0, 0.0, 0.0),
            MakeRotator(0.0, 0.0, 0.0),
            MakeVector(1.0, 1.0, 1.0)
        )

        local ok, created = pcall(function()
            return targetActor:AddComponentByClass(outlineClass, false, identity, false)
        end)
        if ok then
            outlineComponent = created
        end
    end

    if not IsObjectValid(outlineComponent) then
        Log("Could not attach the native OutlineComponent to the outline target")
        return false
    end

    Debug("Native OutlineComponent attached to outline target")
    LogOutlineDiagnostics(targetActor, outlineComponent, "before_toggle", componentOrigin)

    local ok, errorMessage = pcall(function()
        outlineComponent:ToggleOutlineOverlay(Config.OutlineMode, Config.MarkerDuration, false)
    end)
    if not ok then
        Log("ToggleOutlineOverlay failed: " .. tostring(errorMessage))
        return false
    end

    Debug("ToggleOutlineOverlay completed for outline target")
    LogOutlineDiagnostics(targetActor, outlineComponent, "after_toggle", componentOrigin)
    return true, outlineComponent
end

local function CollectPrimitiveComponents(actor)
    local result = {}
    local primitiveClass = StaticFindObject(PRIMITIVE_COMPONENT_CLASS)
    if not IsObjectValid(actor) or not IsObjectValid(primitiveClass) then
        return result
    end

    local components = nil
    local ok = pcall(function()
        components = actor:GetComponentsByClass(primitiveClass)
    end)
    if not ok or components == nil then
        return result
    end

    if type(components) == "table" then
        for _, component in pairs(components) do
            component = ParamValue(component)
            if IsObjectValid(component) then
                table.insert(result, component)
            end
        end
        return result
    end

    pcall(function()
        components:ForEach(function(_, component)
            component = ParamValue(component)
            if IsObjectValid(component) then
                table.insert(result, component)
            end
        end)
    end)
    return result
end

local function ReadComponentOutlineState(component)
    if not IsObjectValid(component) then
        return false, 0, false
    end

    local enabled = false
    local stencil = 0
    local enabledOk = pcall(function() enabled = component.bRenderCustomDepth == true end)
    local stencilOk = pcall(function() stencil = tonumber(component.CustomDepthStencilValue) or 0 end)
    return enabled, stencil, enabledOk and stencilOk
end

local function IsMarkerOutlineState(enabled, stencil)
    return enabled == true and tonumber(stencil) == tonumber(Config.EntityDirectStencilValue or 250)
end

local function ObserveExternalOutlineState(componentRecord)
    if Config.TrackExternalOutlineState ~= true then
        return false
    end
    local enabled, stencil, readOk = ReadComponentOutlineState(componentRecord.Component)
    if not readOk or IsMarkerOutlineState(enabled, stencil) then
        return false
    end

    if componentRecord.LastExternalRenderCustomDepth ~= enabled
        or componentRecord.LastExternalStencilValue ~= stencil
    then
        componentRecord.LastExternalRenderCustomDepth = enabled
        componentRecord.LastExternalStencilValue = stencil
        componentRecord.ExternalRevision = (componentRecord.ExternalRevision or 0) + 1
        return true
    end
    return false
end

local function ApplyDirectEntityOutline(targetObject)
    local targetKey = ObjectKey(targetObject)
    if not targetKey then
        return false
    end

    local record = state.directEntityOutlines[targetKey]
    if not record then
        record = { Components = {}, ExpiresAt = 0.0, ExpiresAtWallTime = 0 }
        local seenComponents = {}
        local primitiveClass = StaticFindObject(PRIMITIVE_COMPONENT_CLASS)
        local meshClass = StaticFindObject(MESH_COMPONENT_CLASS)
        local function AddOutlineComponent(component)
            if not IsObjectValid(component)
                or not IsObjectValid(primitiveClass)
                or not IsObjectValid(meshClass)
            then
                return
            end
            local isPrimitive = false
            pcall(function() isPrimitive = component:IsA(primitiveClass) end)
            if not isPrimitive then
                return
            end
            -- Collision volumes and AbioticTargetingComponent can inherit from
            -- PrimitiveComponent and accept CustomDepth writes, but render no
            -- visible surface. Count only real MeshComponents as outline work.
            local isMesh = false
            pcall(function() isMesh = component:IsA(meshClass) end)
            if not isMesh then
                return
            end
            if GetObjectClassName(component, ""):find("AbioticTargetingComponent", 1, true) then
                return
            end
            local componentKey = ObjectKey(component) or tostring(component)
            if seenComponents[componentKey] then
                return
            end
            seenComponents[componentKey] = true

            local originalEnabled, originalStencil = ReadComponentOutlineState(component)
            table.insert(record.Components, {
                Component = component,
                RenderCustomDepth = originalEnabled,
                StencilValue = originalStencil,
                LastExternalRenderCustomDepth = originalEnabled,
                LastExternalStencilValue = originalStencil,
                ExternalRevision = 0,
            })
        end

        -- A complex interaction target can itself be the hit PrimitiveComponent.
        -- In that case only this component is outlined, never its owning Actor.
        AddOutlineComponent(targetObject)

        if IsActorObject(targetObject) then
            for _, component in ipairs(CollectPrimitiveComponents(targetObject)) do
                AddOutlineComponent(component)
            end

            local rootComponent = nil
            pcall(function() rootComponent = targetObject:GetRootComponent() end)
            AddOutlineComponent(rootComponent)

            local firstPrimitive = nil
            if IsObjectValid(primitiveClass) then
                pcall(function() firstPrimitive = targetObject:GetComponentByClass(primitiveClass) end)
            end
            AddOutlineComponent(firstPrimitive)

            -- Some Blueprint Actors expose visible meshes as named properties
            -- even when UE4SS cannot enumerate their component TArray.
            for _, propertyName in ipairs(Config.EntityMeshProperties or { "FurnitureMesh" }) do
                local component = nil
                pcall(function() component = targetObject[propertyName] end)
                AddOutlineComponent(component)
            end
        end
        state.directEntityOutlines[targetKey] = record
    end

    local now = Now(targetObject)
    record.TargetObject = targetObject
    record.ExpiresAt = now + Config.MarkerDuration
    record.ExpiresAtWallTime = os.time() + math.ceil(Config.MarkerDuration)
    record.NextRefreshAt = now + (Config.EntityOutlineRefreshInterval or 0.25)
    local applied = 0
    for _, componentRecord in ipairs(record.Components) do
        local component = componentRecord.Component
        if IsObjectValid(component) then
            local componentOk = pcall(function()
                component:SetCustomDepthStencilValue(Config.EntityDirectStencilValue or 250)
                component:SetRenderCustomDepth(true)
            end)
            if componentOk then
                applied = applied + 1
            end
            local enabled, stencil, readOk = ReadComponentOutlineState(component)
            local registered = nil
            local visible = nil
            local hiddenInGame = nil
            pcall(function() registered = component:IsRegistered() end)
            pcall(function() visible = component:IsVisible() end)
            pcall(function() hiddenInGame = component.bHiddenInGame end)
            Debug(string.format(
                "Direct outline component state: target=%s component=%s class=%s write_ok=%s read_ok=%s custom_depth=%s stencil=%s registered=%s visible=%s hidden=%s",
                tostring(targetKey),
                tostring(ObjectKey(component)),
                GetObjectClassName(component, "UnknownComponent"),
                tostring(componentOk),
                tostring(readOk),
                tostring(enabled),
                tostring(stencil),
                tostring(registered),
                tostring(visible),
                tostring(hiddenInGame)
            ))
        end
    end

    Debug(string.format("Direct entity outline applied to %d primitive components", applied))
    return applied > 0
end

local function ShouldForceNativeOutlineInitialization(actor)
    if not IsActorObject(actor) then
        return false
    end
    local className = GetObjectClassName(actor, "")
    for _, pattern in ipairs(Config.ForceNativeOutlineActorClassPatterns or {}) do
        if type(pattern) == "string" and pattern ~= "" and className:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function SpawnAnchor(character, hit, markerIndex)
    if not hit or not hit.Point then
        return nil
    end

    local entityTarget = hit.ForceWorldMarker ~= true
        and IsActorObject(hit.Actor)
        and IsEntityTarget(hit.Actor)
        and hit.Actor
        or nil
    local isEntityMarker = IsObjectValid(entityTarget)
    local normal = hit.Normal or { X = 0.0, Y = 0.0, Z = 1.0 }
    local spawnLocation = AddScaledVector(hit.Point, normal, Config.SurfaceOffset)
    local mathLibrary = GetKismetMathLibrary()
    local gameplayStatics = GetGameplayStatics()
    local world = UEHelpers.GetWorld()

    if not IsObjectValid(mathLibrary) or not IsObjectValid(gameplayStatics) or not IsObjectValid(world) then
        return nil
    end

    local actorClass = StaticFindObject(STATIC_MESH_ACTOR_CLASS)
    if not IsObjectValid(actorClass) then
        Log("StaticMeshActor class was not found")
        return nil
    end

    pcall(function() LoadAsset(SPHERE_MESH_PATH) end)

    local anchorScale = isEntityMarker and (Config.EntityAnchorScale or 0.01) or Config.SphereScale
    local scale = MakeVector(anchorScale, anchorScale, anchorScale)
    -- The sphere is rotationally symmetric. Roll is therefore available as a
    -- replicated, presentation-neutral channel for the server-assigned slot.
    local markerPitch = hit.PreciseComponentTarget and (Config.ComponentMarkerPitch or 37.0) or 0.0
    local markerYaw = isEntityMarker and EncodeMarkerClassSignatureYaw(entityTarget) or 0.0
    local rotation = MakeRotator(markerPitch, markerYaw, markerIndex)
    local transform = mathLibrary:MakeTransform(spawnLocation, rotation, scale)
    local deferredActor = gameplayStatics:BeginDeferredActorSpawnFromClass(world, actorClass, transform, 0, character, 0)

    if not IsObjectValid(deferredActor) then
        Log("BeginDeferredActorSpawnFromClass returned an invalid actor")
        return nil
    end

    -- Never pass a raw hit-result reference to SetOwner. UE5.4 may expose a
    -- component or stale weak object through HitObjectHandle.ReferenceObject;
    -- passing that value as AActor caused a native access violation in v0.3.2.
    -- Owner is only the replicated requesting character. Never put a possibly
    -- map-local/non-networked target Actor into a replicated reference; clients
    -- recover their own target instance from class signature + hit location.
    local replicatedOwner = character
    if IsActorObject(replicatedOwner) then
        deferredActor:SetOwner(replicatedOwner)
    else
        Debug("Skipped SetOwner because the candidate was not a verified Actor")
    end
    -- This is now the listen server's local presentation anchor only. The
    -- previous dynamically spawned StaticMeshActor never obtained a usable
    -- NetGUID on remote clients. Marker data is transported separately by the
    -- v0.3.34 symbol packet and each client creates its own local anchor.
    pcall(function() deferredActor:SetReplicates(false) end)
    pcall(function() deferredActor:SetReplicateMovement(false) end)
    pcall(function() deferredActor.bAlwaysRelevant = false end)
    pcall(function() deferredActor.bOnlyRelevantToOwner = false end)
    pcall(function() deferredActor.bNetUseOwnerRelevancy = false end)
    pcall(function() deferredActor.bNetLoadOnClient = true end)
    pcall(function() deferredActor.NetUpdateFrequency = 30.0 end)
    pcall(function() deferredActor.MinNetUpdateFrequency = 10.0 end)
    pcall(function() deferredActor.NetCullDistanceSquared = 3.0e18 end)
    if isEntityMarker then
        ConfigureEntityAnchor(deferredActor)
    else
        ConfigureAnchor(deferredActor)
    end

    local anchor = gameplayStatics:FinishSpawningActor(deferredActor, transform, 0)
    if not IsObjectValid(anchor) then
        Log("FinishSpawningActor returned an invalid actor")
        return nil
    end

    local meshConfigured = isEntityMarker and ConfigureEntityAnchor(anchor) or ConfigureAnchor(anchor)
    pcall(function() anchor:SetReplicates(false) end)
    pcall(function() anchor:SetReplicateMovement(false) end)
    pcall(function() anchor.bAlwaysRelevant = false end)
    pcall(function() anchor.bOnlyRelevantToOwner = false end)
    pcall(function() anchor.bNetUseOwnerRelevancy = false end)
    pcall(function() anchor.bNetLoadOnClient = true end)
    pcall(function() anchor.NetUpdateFrequency = 30.0 end)
    pcall(function() anchor.MinNetUpdateFrequency = 10.0 end)
    pcall(function() anchor.NetCullDistanceSquared = 3.0e18 end)
    pcall(function() anchor:SetLifeSpan(Config.MarkerDuration) end)
    pcall(function() anchor:FlushNetDormancy() end)
    pcall(function() anchor:ForceNetUpdate() end)

    local anchorKey = ObjectKey(anchor)
    if anchorKey then
        state.markerDebugInfo[anchorKey] = {
            Anchor = anchor,
            EntityTarget = entityTarget,
            Target = hit.VisualTarget or hit.Actor,
            Component = hit.Component,
            Classification = hit.ForceWorldMarker == true
                and "WorldFallback"
                or ClassifyHitTarget(hit.Actor, hit.Component),
            Source = hit.Source,
        }
    end

    Debug(string.format(
        "Server anchor visual configured: slot=%d entity=%s precise_component=%s class_signature=%d mesh=%s stencil=%s target=%s",
        markerIndex,
        tostring(isEntityMarker),
        tostring(hit.PreciseComponentTarget == true),
        isEntityMarker and GetMarkerClassSignature(entityTarget) or 0,
        tostring(meshConfigured),
        tostring(Config.DirectStencilValue or Config.OutlineMode or 5),
        tostring(ObjectKey(entityTarget) or "world")
    ))

    Debug(string.format(
        "Spawned server-local anchor at %.1f, %.1f, %.1f",
        spawnLocation.X,
        spawnLocation.Y,
        spawnLocation.Z
    ))
    return anchor
end

local function IsModRequest(linkedActor)
    return not IsObjectValid(linkedActor)
end

local function GetPlayerCooldownKey(character)
    if not IsObjectValid(character) then
        return nil
    end

    local playerState = nil
    pcall(function() playerState = character.PlayerState end)
    return ObjectKey(playerState) or ObjectKey(character)
end

local function ServerRequestAllowed(character)
    local key = GetPlayerCooldownKey(character)
    if not key then
        return false, 0.0
    end

    local now = Now(character)
    local worldKey = GetCurrentWorldKey(character)
    local previousRecord = state.serverRequestTimes[key]
    local previous = -1000.0
    local previousWorldKey = nil
    if type(previousRecord) == "table" then
        previous = tonumber(previousRecord.Time) or -1000.0
        previousWorldKey = previousRecord.WorldKey
    elseif type(previousRecord) == "number" then
        -- Backward-compatible with a state table retained by a live Lua reload.
        previous = previousRecord
    end

    local worldChanged = previousWorldKey ~= nil
        and worldKey ~= nil
        and previousWorldKey ~= worldKey
    local timeWentBack = now < previous
    if worldChanged or timeWentBack then
        Debug(string.format(
            "Server cooldown clock reset for player=%s reason=%s previous=%.2f now=%.2f previous_world=%s current_world=%s",
            GetMarkerPlayerName(character),
            worldChanged and "WorldChanged" or "TimeWentBack",
            previous,
            now,
            tostring(previousWorldKey),
            tostring(worldKey)
        ))
        previous = -1000.0
    end

    local cooldown = Config.PerPlayerCooldown or 3.0
    local elapsed = now - previous
    if elapsed < cooldown then
        return false, cooldown - elapsed
    end

    state.serverRequestTimes[key] = {
        Time = now,
        WorldKey = worldKey,
    }
    return true, 0.0
end

local function GetMarkerTargetKey(hit)
    if hit and hit.ForceWorldMarker == true then
        return nil
    end
    local target = hit and (hit.MarkerTarget or hit.Actor) or nil
    if hit and hit.PreciseComponentTarget == true and IsObjectValid(target) then
        return ObjectKey(target)
    end
    if IsActorObject(target) and IsEntityTarget(target) then
        return ObjectKey(target)
    end
    return nil
end

local function RemoveActiveMarkerTargetForAnchor(anchor)
    local anchorKey = ObjectKey(anchor)
    if not anchorKey then
        return
    end
    local targetKey = state.serverAnchorTargetKeys[anchorKey]
    if not targetKey then
        return
    end
    local record = state.activeMarkerTargets[targetKey]
    if record and record.AnchorKey == anchorKey then
        state.activeMarkerTargets[targetKey] = nil
    end
    state.serverAnchorTargetKeys[anchorKey] = nil
end

local function RegisterActiveMarkerTarget(targetKey, anchor)
    local anchorKey = ObjectKey(anchor)
    if not targetKey or not anchorKey then
        return
    end
    state.activeMarkerTargets[targetKey] = {
        Anchor = anchor,
        AnchorKey = anchorKey,
        ExpiresAtWallTime = os.time() + math.ceil(Config.MarkerDuration),
    }
    state.serverAnchorTargetKeys[anchorKey] = targetKey
end

local function IsDuplicateMarkerTarget(targetKey)
    if not targetKey then
        return false
    end
    local record = state.activeMarkerTargets[targetKey]
    if not record then
        return false
    end
    if not IsObjectValid(record.Anchor) or os.time() >= (record.ExpiresAtWallTime or 0) then
        state.activeMarkerTargets[targetKey] = nil
        if record.AnchorKey then
            state.serverAnchorTargetKeys[record.AnchorKey] = nil
        end
        return false
    end
    return true
end

local function BuildCooldownWarningText(remainingSeconds)
    local remaining = math.max(0.0, tonumber(remainingSeconds) or 0.0)
    return string.format(
        Config.CooldownWarningTextFormat or "Marker cooldown: %.1fs remaining",
        remaining
    )
end

local function NotifyCooldownMarkerRejected(character, remainingSeconds)
    local warningText = BuildCooldownWarningText(remainingSeconds)
    local ok, err = pcall(function()
        character:Client_DisplayWarningMessage(
            FText(warningText),
            Config.WarningSoundCriticality or 2,
            true
        )
    end)
    Debug(string.format(
        "Cooldown warning: played=%s remaining=%.2f text=%s error=%s",
        tostring(ok),
        tonumber(remainingSeconds) or 0.0,
        warningText,
        tostring(err)
    ))
    return ok, err
end

local function NotifyDuplicateMarkerRejected(character)
    local ok, err = pcall(function()
        character:Client_DisplayWarningMessage(
            FText(Config.DuplicateMarkerWarningText or "Target already marked"),
            Config.WarningSoundCriticality or 2,
            true
        )
    end)
    Debug(string.format("Duplicate marker warning sound: played=%s error=%s", tostring(ok), tostring(err)))
end

local function GetActorReplicationSnapshot(actor)
    if not IsObjectValid(actor) then
        return "actor_invalid"
    end

    local replicated = nil
    local alwaysRelevant = nil
    local onlyRelevantToOwner = nil
    local useOwnerRelevancy = nil
    local replicateMovement = nil
    local netDormancy = nil
    local netUpdateFrequency = nil
    local localRole = nil
    local remoteRole = nil
    local netMode = nil
    local owner = nil
    pcall(function() replicated = actor:GetIsReplicated() end)
    if replicated == nil then
        pcall(function() replicated = actor.bReplicates end)
    end
    pcall(function() alwaysRelevant = actor.bAlwaysRelevant end)
    pcall(function() onlyRelevantToOwner = actor.bOnlyRelevantToOwner end)
    pcall(function() useOwnerRelevancy = actor.bNetUseOwnerRelevancy end)
    pcall(function() replicateMovement = actor.bReplicateMovement end)
    pcall(function() netDormancy = actor.NetDormancy end)
    pcall(function() netUpdateFrequency = actor.NetUpdateFrequency end)
    pcall(function() localRole = actor:GetLocalRole() end)
    pcall(function() remoteRole = actor:GetRemoteRole() end)
    pcall(function() owner = actor:GetOwner() end)
    pcall(function()
        local world = actor:GetWorld()
        if IsObjectValid(world) then
            netMode = world:GetNetMode()
        end
    end)

    return string.format(
        "replicates=%s always_relevant=%s only_owner=%s owner_relevancy=%s movement=%s dormancy=%s update_hz=%s local_role=%s remote_role=%s net_mode=%s owner=%s",
        tostring(replicated),
        tostring(alwaysRelevant),
        tostring(onlyRelevantToOwner),
        tostring(useOwnerRelevancy),
        tostring(replicateMovement),
        tostring(netDormancy),
        tostring(netUpdateFrequency),
        tostring(localRole),
        tostring(remoteRole),
        tostring(netMode),
        tostring(ObjectKey(owner) or "None")
    )
end

local PACKET_VERSION_BITS = 4
local PACKET_SLOT_BITS = 3
local PACKET_CLASS_BITS = 7
local PACKET_CHECKSUM_BITS = 8

local function AppendUnsignedPacketBits(bits, value, bitCount)
    local normalized = math.floor(tonumber(value) or 0)
    for shift = bitCount - 1, 0, -1 do
        table.insert(bits, math.floor(normalized / (2 ^ shift)) % 2)
    end
end

local function GetMarkerPacketCoordinateBits()
    return math.max(15, math.min(24, math.floor(Config.MarkerPacketCoordinateBits or 15)))
end

local function EncodeWrappedPacketCoordinate(value, bitCount)
    local quantum = math.max(0.01, tonumber(Config.MarkerPacketCoordinateQuantum) or 4.0)
    local quantized = value >= 0
        and math.floor(value / quantum + 0.5)
        or math.ceil(value / quantum - 0.5)
    local period = 2 ^ bitCount
    return ((quantized % period) + period) % period
end

local function GetMarkerPacketChecksum(version, slot, entityFlag, preciseFlag, classSignature, x, y, z)
    return math.floor(
        version * 17
        + slot * 31
        + entityFlag * 47
        + preciseFlag * 53
        + classSignature * 59
        + x * 3
        + y * 5
        + z * 7
    ) % 256
end

local function BuildMarkerPacket(anchor, markerIndex, hit)
    local location = GetObjectWorldLocation(anchor)
    if not location then
        return nil, "anchor location unavailable"
    end

    local coordinateBits = GetMarkerPacketCoordinateBits()
    local version = math.max(0, math.min(15, math.floor(Config.MarkerPacketProtocolVersion or 1)))
    local slot = math.max(0, math.min(7, markerIndex - 1))
    local entityFlag = IsEntityAnchor(anchor) and 1 or 0
    local preciseFlag = hit and hit.PreciseComponentTarget == true and 1 or 0
    local classSignature = entityFlag == 1 and GetMarkerClassSignature(hit and hit.Actor) or 0
    local x = EncodeWrappedPacketCoordinate(location.X, coordinateBits)
    local y = EncodeWrappedPacketCoordinate(location.Y, coordinateBits)
    local z = EncodeWrappedPacketCoordinate(location.Z, coordinateBits)
    local checksum = GetMarkerPacketChecksum(
        version,
        slot,
        entityFlag,
        preciseFlag,
        classSignature,
        x,
        y,
        z
    )

    local bits = {}
    AppendUnsignedPacketBits(bits, version, PACKET_VERSION_BITS)
    AppendUnsignedPacketBits(bits, slot, PACKET_SLOT_BITS)
    AppendUnsignedPacketBits(bits, entityFlag, 1)
    AppendUnsignedPacketBits(bits, preciseFlag, 1)
    AppendUnsignedPacketBits(bits, classSignature, PACKET_CLASS_BITS)
    AppendUnsignedPacketBits(bits, x, coordinateBits)
    AppendUnsignedPacketBits(bits, y, coordinateBits)
    AppendUnsignedPacketBits(bits, z, coordinateBits)
    AppendUnsignedPacketBits(bits, checksum, PACKET_CHECKSUM_BITS)

    local symbols = {}
    for index = 1, #bits, 2 do
        table.insert(symbols, bits[index] * 2 + (bits[index + 1] or 0))
    end
    return {
        Version = version,
        Slot = slot + 1,
        Entity = entityFlag == 1,
        Precise = preciseFlag == 1,
        ClassSignature = classSignature,
        X = x,
        Y = y,
        Z = z,
        Checksum = checksum,
        BitCount = #bits,
        Symbols = symbols,
        Location = location,
    }
end

local function GetMarkerPacketCarriers(character)
    local playerState = nil
    local gameState = nil
    local world = UEHelpers.GetWorld()
    pcall(function() playerState = character.PlayerState end)
    if IsObjectValid(world) then
        pcall(function() gameState = world.GameState end)
    end
    if not IsObjectValid(gameState) then
        local gameplayStatics = GetGameplayStatics()
        if IsObjectValid(gameplayStatics) then
            pcall(function() gameState = gameplayStatics:GetGameState(character) end)
        end
    end
    return playerState, gameState
end

local function MarkerPacketSymbolActor(symbol, character, playerState, gameState)
    if symbol == 0 then
        return CreateInvalidObject()
    elseif symbol == 1 then
        return character
    elseif symbol == 2 then
        return playerState
    elseif symbol == 3 then
        return gameState
    end
    return CreateInvalidObject()
end

local function ScheduleMarkerPacketBroadcast(character, anchor, markerIndex, hit)
    local packet, packetError = BuildMarkerPacket(anchor, markerIndex, hit)
    if not packet then
        Log("Marker packet build failed: " .. tostring(packetError))
        return false
    end

    local playerState, gameState = GetMarkerPacketCarriers(character)
    if not IsObjectValid(character) or not IsActorObject(playerState) or not IsActorObject(gameState) then
        Log(string.format(
            "Marker packet carriers unavailable: character=%s player_state=%s game_state=%s",
            tostring(ObjectKey(character) or "None"),
            tostring(ObjectKey(playerState) or "None"),
            tostring(ObjectKey(gameState) or "None")
        ))
        return false
    end

    -- PlayerState, Character, PlayerState is the frame preamble. Packet data
    -- then uses nil/Character/PlayerState/GameState as base-4 symbols 0..3.
    local wireSymbols = { 2, 1, 2 }
    for _, symbol in ipairs(packet.Symbols) do
        table.insert(wireSymbols, symbol)
    end
    state.packetSerial = state.packetSerial + 1
    local serial = state.packetSerial
    local symbolDelay = math.max(1, math.floor(Config.MarkerPacketSymbolDelayMs or 4))
    local batchSize = math.max(1, math.min(8, math.floor(Config.MarkerPacketBatchSize or 4)))
    Log(string.format(
        "Marker packet scheduled: serial=%d player=%s slot=%d entity=%s precise=%s class=%d position=(%.1f,%.1f,%.1f) bits=%d symbols=%d batch_size=%d batches=%d checksum=%d carriers={character=%s player_state=%s game_state=%s}",
        serial,
        GetMarkerPlayerName(character),
        packet.Slot,
        tostring(packet.Entity),
        tostring(packet.Precise),
        packet.ClassSignature,
        packet.Location.X,
        packet.Location.Y,
        packet.Location.Z,
        packet.BitCount,
        #wireSymbols,
        batchSize,
        math.ceil(#wireSymbols / batchSize),
        packet.Checksum,
        tostring(ObjectKey(character)),
        tostring(ObjectKey(playerState)),
        tostring(ObjectKey(gameState))
    ))

    local sendNextBatch = nil
    sendNextBatch = function(batchStartIndex)
        ExecuteWithDelay(batchStartIndex == 1 and 0 or symbolDelay, function()
            ExecuteInGameThread(function()
                if not IsObjectValid(character) then
                    Log(string.format(
                        "Marker packet send cancelled: serial=%d next_symbol=%d/%d character invalid",
                        serial,
                        batchStartIndex,
                        #wireSymbols
                    ))
                    return
                end
                local batchEndIndex = math.min(#wireSymbols, batchStartIndex + batchSize - 1)
                for symbolIndex = batchStartIndex, batchEndIndex do
                    local symbolValue = wireSymbols[symbolIndex]
                    local carrier = MarkerPacketSymbolActor(
                        symbolValue,
                        character,
                        playerState,
                        gameState
                    )
                    local ok, sendError = pcall(function()
                        character:Broadcast_TriggerPager(carrier)
                    end)
                    if not ok then
                        Log(string.format(
                            "Marker packet symbol send failed: serial=%d symbol=%d/%d value=%d error=%s",
                            serial,
                            symbolIndex,
                            #wireSymbols,
                            symbolValue,
                            tostring(sendError)
                        ))
                        return
                    end
                end
                if batchEndIndex == #wireSymbols then
                    Log(string.format(
                        "Marker packet send completed: serial=%d player=%s slot=%d symbols=%d batches=%d checksum=%d",
                        serial,
                        GetMarkerPlayerName(character),
                        packet.Slot,
                        #wireSymbols,
                        math.ceil(#wireSymbols / batchSize),
                        packet.Checksum
                    ))
                    return
                end
                sendNextBatch(batchEndIndex + 1)
            end)
        end)
    end
    sendNextBatch(1)
    return true
end

local function HandleServerPagerPre(contextParam, linkedActorParam)
    local character = ParamValue(contextParam)
    local linkedActor = ParamValue(linkedActorParam)

    if not IsObjectValid(character) or not HasAuthority(character) or not IsModRequest(linkedActor) then
        return
    end

    Log(string.format(
        "Multiplayer server request received: player=%s character=%s authority=%s world=%s linked_valid=%s",
        GetMarkerPlayerName(character),
        tostring(ObjectKey(character) or "None"),
        tostring(HasAuthority(character)),
        tostring(GetCurrentWorldKey(character)),
        tostring(IsObjectValid(linkedActor))
    ))

    local requestAllowed, cooldownRemaining = ServerRequestAllowed(character)
    if not requestAllowed then
        Debug(string.format(
            "Server rejected marker for %s: per-player cooldown %.2fs remaining",
            GetMarkerPlayerName(character),
            cooldownRemaining
        ))
        NotifyCooldownMarkerRejected(character, cooldownRemaining)
        return
    end

    local startLocation, direction = GetServerViewRay(character)
    if not startLocation or not direction then
        Log("Server could not obtain the requesting player's view ray")
        return
    end

    local hit = Trace(startLocation, direction, character)
    if not hit or not hit.Point then
        Debug("Server marker trace did not hit anything")
        return
    end

    hit = ResolveHierarchicalMarkerTarget(hit)
    hit = ResolveInvisibleEntityWorldFallback(hit)

    Debug(string.format(
        "Trace hit: source=%s distance=%.1f classification=%s actor=%s actor_class=%s component=%s component_class=%s",
        tostring(hit.Source or "Unknown"),
        math.sqrt(hit.DistanceSquared or 0.0),
        hit.ForceWorldMarker == true and "WorldFallback" or ClassifyHitTarget(hit.Actor, hit.Component),
        GetObjectName(hit.Actor, "Unavailable"),
        GetObjectClassName(hit.Actor, "UnknownActorClass"),
        GetObjectName(hit.Component, "Unavailable"),
        GetObjectClassName(hit.Component, "NoComponent")
    ))

    local markerTargetKey = GetMarkerTargetKey(hit)
    if Config.RejectDuplicateEntityMarks == true and IsDuplicateMarkerTarget(markerTargetKey) then
        Debug(string.format(
            "Server rejected duplicate marker: player=%s mode=%s target=%s",
            GetMarkerPlayerName(character),
            tostring(hit.SelectedTargetMode or "Unknown"),
            tostring(markerTargetKey)
        ))
        NotifyDuplicateMarkerRejected(character)
        return
    end

    local maximumMarkers = math.max(1, math.floor(Config.MaxActiveMarkers or 8))
    local markerIndex = state.nextServerMarkerSlot
    if markerIndex < 1 or markerIndex > maximumMarkers then
        markerIndex = 1
    end

    local anchor = SpawnAnchor(character, hit, markerIndex)
    if not IsObjectValid(anchor) then
        return
    end

    local replacedAnchor = state.serverMarkerSlots[markerIndex]
    state.serverMarkerSlots[markerIndex] = anchor
    state.nextServerMarkerSlot = (markerIndex % maximumMarkers) + 1
    if IsObjectValid(replacedAnchor) and replacedAnchor ~= anchor then
        RemoveActiveMarkerTargetForAnchor(replacedAnchor)
        pcall(function() replacedAnchor:K2_DestroyActor() end)
        Debug("Recycled marker slot " .. tostring(markerIndex) .. " and destroyed its previous anchor")
    end

    RegisterActiveMarkerTarget(markerTargetKey, anchor)

    -- The listen server already owns the authoritative hit and local anchor;
    -- do not wait for the transport packet to loop back before creating its
    -- label/outline. Remote clients still render only after validated decode.
    local immediateConfigured = ConfigureBroadcastVisualization(
        anchor,
        character,
        "Authoritative immediate"
    )
    local anchorKey = ObjectKey(anchor)
    if immediateConfigured and anchorKey then
        state.processedBroadcastAnchors[anchorKey] = {
            Anchor = anchor,
            Character = character,
        }
    end
    Log(string.format(
        "Authoritative immediate visualization: configured=%s entity=%s player=%s slot=%d anchor=%s",
        tostring(immediateConfigured),
        tostring(IsEntityAnchor(anchor)),
        GetMarkerPlayerName(character),
        markerIndex,
        tostring(anchorKey or "None")
    ))

    ScheduleMarkerPacketBroadcast(character, anchor, markerIndex, hit)
end

ConfigureBroadcastVisualization = function(anchor, character, phase)
    local entityMarker = IsEntityAnchor(anchor)
    if entityMarker then
        local anchorHidden = ConfigureEntityAnchor(anchor)
        local targetActor = ResolveEntityTarget(anchor)
        if not IsObjectValid(targetActor) then
            Debug(string.format("%s entity marker is waiting for its replicated target", phase))
            return false
        end

        local preciseComponent = IsPreciseComponentAnchor(anchor)
        local visualTarget = preciseComponent and ResolvePreciseComponentTarget(anchor, targetActor) or targetActor
        if preciseComponent and not IsObjectValid(visualTarget) then
            Debug(string.format("%s precise component marker is waiting for its interaction component", phase))
            return false
        end

        -- Resource micro-nodes can expose a writable StaticMeshComponent while
        -- remaining absent from the outline pass until the game's native
        -- component initializes them. Keep this targeted by actor class.
        local forceNativeInitialization = ShouldForceNativeOutlineInitialization(targetActor)
        local nativeOutline = false
        local nativeOutlineComponent = nil
        if forceNativeInitialization then
            nativeOutline, nativeOutlineComponent = EnsureOutlineComponent(targetActor)
        end
        -- Prefer direct mesh state for deterministic refresh and restoration.
        -- Native initialization above runs first so this write remains final.
        local directOutline = ApplyDirectEntityOutline(visualTarget)
        if not directOutline and not nativeOutline and IsActorObject(visualTarget) then
            nativeOutline, nativeOutlineComponent = EnsureOutlineComponent(targetActor)
        end
        if IsObjectValid(nativeOutlineComponent) then
            LogOutlineDiagnostics(targetActor, nativeOutlineComponent, "native_fallback", "existing")
        end
        local label = EnsureMarkerLabel(anchor, character, visualTarget)
        RegisterActiveMarkerTarget(ObjectKey(visualTarget), anchor)
        Debug(string.format(
            "%s entity visualization result: anchor_hidden=%s precise_component=%s forced_native=%s native_outline=%s direct_outline=%s label=%s target=%s visual_target=%s",
            phase,
            tostring(anchorHidden),
            tostring(preciseComponent),
            tostring(forceNativeInitialization),
            tostring(nativeOutline),
            tostring(directOutline),
            tostring(label),
            tostring(ObjectKey(targetActor)),
            tostring(ObjectKey(visualTarget))
        ))
        return nativeOutline or directOutline
    end

    local meshConfigured = ConfigureAnchor(anchor)
    local nativeOutlineConfigured = EnsureOutlineComponent(anchor)
    local labelConfigured = EnsureMarkerLabel(anchor, character)
    Debug(string.format(
        "%s world visualization result: mesh=%s native_outline=%s label=%s stencil=%s",
        phase,
        tostring(meshConfigured),
        tostring(nativeOutlineConfigured),
        tostring(labelConfigured),
        tostring(Config.DirectStencilValue or Config.OutlineMode or 5)
    ))
    return meshConfigured or nativeOutlineConfigured
end

local function ReadUnsignedPacketBits(bits, offset, bitCount)
    local value = 0
    for index = offset, offset + bitCount - 1 do
        if bits[index] == nil then
            return nil, offset
        end
        value = value * 2 + bits[index]
    end
    return value, offset + bitCount
end

local function DecodeWrappedPacketCoordinate(value, bitCount, referenceValue)
    local quantum = math.max(0.01, tonumber(Config.MarkerPacketCoordinateQuantum) or 4.0)
    local referenceQuantized = referenceValue >= 0
        and math.floor(referenceValue / quantum + 0.5)
        or math.ceil(referenceValue / quantum - 0.5)
    local period = 2 ^ bitCount
    local nearestPeriod = math.floor((referenceQuantized - value) / period + 0.5)
    return (value + nearestPeriod * period) * quantum
end

local function DecodeMarkerPacket(symbols, referenceLocation)
    if not referenceLocation or referenceLocation.X == nil then
        return nil, "sender reference location unavailable"
    end
    local coordinateBits = GetMarkerPacketCoordinateBits()
    local bits = {}
    for _, symbol in ipairs(symbols) do
        table.insert(bits, math.floor(symbol / 2) % 2)
        table.insert(bits, symbol % 2)
    end

    local offset = 1
    local version
    local slot
    local entityFlag
    local preciseFlag
    local classSignature
    local x
    local y
    local z
    local checksum
    version, offset = ReadUnsignedPacketBits(bits, offset, PACKET_VERSION_BITS)
    slot, offset = ReadUnsignedPacketBits(bits, offset, PACKET_SLOT_BITS)
    entityFlag, offset = ReadUnsignedPacketBits(bits, offset, 1)
    preciseFlag, offset = ReadUnsignedPacketBits(bits, offset, 1)
    classSignature, offset = ReadUnsignedPacketBits(bits, offset, PACKET_CLASS_BITS)
    x, offset = ReadUnsignedPacketBits(bits, offset, coordinateBits)
    y, offset = ReadUnsignedPacketBits(bits, offset, coordinateBits)
    z, offset = ReadUnsignedPacketBits(bits, offset, coordinateBits)
    checksum, offset = ReadUnsignedPacketBits(bits, offset, PACKET_CHECKSUM_BITS)
    if checksum == nil then
        return nil, "truncated packet"
    end

    local expectedChecksum = GetMarkerPacketChecksum(
        version,
        slot,
        entityFlag,
        preciseFlag,
        classSignature,
        x,
        y,
        z
    )
    if checksum ~= expectedChecksum then
        return nil, string.format("checksum mismatch expected=%d actual=%d", expectedChecksum, checksum)
    end
    local configuredVersion = math.max(0, math.min(15, math.floor(Config.MarkerPacketProtocolVersion or 1)))
    if version ~= configuredVersion then
        return nil, string.format("protocol mismatch expected=%d actual=%d", configuredVersion, version)
    end

    local decodedLocation = {
        X = DecodeWrappedPacketCoordinate(x, coordinateBits, referenceLocation.X),
        Y = DecodeWrappedPacketCoordinate(y, coordinateBits, referenceLocation.Y),
        Z = DecodeWrappedPacketCoordinate(z, coordinateBits, referenceLocation.Z),
    }
    local maximumDistance = (Config.TraceDistance or 50000.0)
        + (Config.MarkerPacketDecodedDistanceMargin or 5000.0)
    local referenceDistanceSquared = TraceDistanceSquared(referenceLocation, decodedLocation)
    if referenceDistanceSquared > maximumDistance * maximumDistance then
        return nil, string.format(
            "wrapped coordinate outside safe range distance=%.1f maximum=%.1f",
            math.sqrt(referenceDistanceSquared),
            maximumDistance
        )
    end

    return {
        Version = version,
        Slot = slot + 1,
        Entity = entityFlag == 1,
        Precise = preciseFlag == 1,
        ClassSignature = classSignature,
        Location = decodedLocation,
        ReferenceDistance = math.sqrt(referenceDistanceSquared),
        Checksum = checksum,
    }, nil
end

local function SpawnClientLocalPacketAnchor(character, packet)
    local mathLibrary = GetKismetMathLibrary()
    local gameplayStatics = GetGameplayStatics()
    local world = UEHelpers.GetWorld()
    local actorClass = StaticFindObject(STATIC_MESH_ACTOR_CLASS)
    if not IsObjectValid(mathLibrary)
        or not IsObjectValid(gameplayStatics)
        or not IsObjectValid(world)
        or not IsObjectValid(actorClass)
    then
        return nil, "spawn dependencies unavailable"
    end

    pcall(function() LoadAsset(SPHERE_MESH_PATH) end)
    local anchorScale = packet.Entity and (Config.EntityAnchorScale or 0.01) or Config.SphereScale
    local scale = MakeVector(anchorScale, anchorScale, anchorScale)
    local pitch = packet.Precise and (Config.ComponentMarkerPitch or 37.0) or 0.0
    local yaw = packet.Entity and packet.ClassSignature * (360.0 / 128.0) or 0.0
    local rotation = MakeRotator(pitch, yaw, packet.Slot)
    local transform = mathLibrary:MakeTransform(packet.Location, rotation, scale)
    local deferredActor = gameplayStatics:BeginDeferredActorSpawnFromClass(
        world,
        actorClass,
        transform,
        0,
        character,
        0
    )
    if not IsObjectValid(deferredActor) then
        return nil, "BeginDeferredActorSpawnFromClass returned invalid"
    end

    if IsActorObject(character) then
        pcall(function() deferredActor:SetOwner(character) end)
    end
    pcall(function() deferredActor:SetReplicates(false) end)
    pcall(function() deferredActor:SetReplicateMovement(false) end)
    if packet.Entity then
        ConfigureEntityAnchor(deferredActor)
    else
        ConfigureAnchor(deferredActor)
    end

    local anchor = gameplayStatics:FinishSpawningActor(deferredActor, transform, 0)
    if not IsObjectValid(anchor) then
        return nil, "FinishSpawningActor returned invalid"
    end
    pcall(function() anchor:SetReplicates(false) end)
    pcall(function() anchor:SetReplicateMovement(false) end)
    pcall(function() anchor:SetLifeSpan(Config.MarkerDuration) end)
    if packet.Entity then
        ConfigureEntityAnchor(anchor)
    else
        ConfigureAnchor(anchor)
    end

    local anchorKey = ObjectKey(anchor)
    if anchorKey then
        state.markerDebugInfo[anchorKey] = {
            Anchor = anchor,
            Classification = packet.Entity and "PacketEntity" or "PacketWorld",
            Source = "MarkerPacket",
        }
    end
    return anchor, nil
end

local function HandleDecodedMarkerPacket(character, packet)
    local anchor = nil
    local source = "client_local_spawn"
    if HasAuthority(character) then
        anchor = state.serverMarkerSlots[packet.Slot]
        source = "authoritative_server_slot"
    end
    if not IsObjectValid(anchor) then
        local spawnError = nil
        anchor, spawnError = SpawnClientLocalPacketAnchor(character, packet)
        if not IsObjectValid(anchor) then
            Log(string.format(
                "Marker packet local anchor failed: sender=%s slot=%d error=%s",
                GetMarkerPlayerName(character),
                packet.Slot,
                tostring(spawnError)
            ))
            return false
        end
    end

    local previousAnchor = state.packetLocalSlots[packet.Slot]
    if IsObjectValid(previousAnchor) and previousAnchor ~= anchor then
        RemoveActiveMarkerTargetForAnchor(previousAnchor)
        pcall(function() previousAnchor:K2_DestroyActor() end)
    end
    state.packetLocalSlots[packet.Slot] = anchor

    local anchorKey = ObjectKey(anchor)
    if Config.LocalMarkerSuccessSound == true then
        local _, localPawn = GetVerifiedLocalPlayerContext()
        if IsObjectValid(localPawn)
            and ObjectKey(character) == ObjectKey(localPawn)
            and anchorKey
            and not state.localSuccessSoundAnchors[anchorKey]
        then
            state.localSuccessSoundAnchors[anchorKey] = anchor
            local soundOk, soundError = PlayLocalMarkerSuccessSound(character)
            Debug(string.format(
                "Marker packet local success sound: played=%s error=%s anchor=%s",
                tostring(soundOk),
                tostring(soundError),
                tostring(anchorKey)
            ))
        end
    end

    local existingVisualization = anchorKey and state.processedBroadcastAnchors[anchorKey] or nil
    local alreadyConfigured = existingVisualization
        and IsObjectValid(existingVisualization.Anchor)
    local configured = alreadyConfigured
        or ConfigureBroadcastVisualization(anchor, character, "Marker packet")
    if alreadyConfigured then
        source = source .. "+already_configured"
    end
    if configured and anchorKey then
        state.processedBroadcastAnchors[anchorKey] = {
            Anchor = anchor,
            Character = character,
        }
    elseif packet.Entity and anchorKey then
        state.pendingVisualizations[anchorKey] = {
            Anchor = anchor,
            Character = character,
            DueAt = Now(anchor) + 0.1,
            AttemptsRemaining = 3,
        }
    end
    Log(string.format(
        "Marker packet visualization handled: configured=%s entity=%s sender=%s slot=%d source=%s anchor=%s queued_retry=%s",
        tostring(configured),
        tostring(packet.Entity),
        GetMarkerPlayerName(character),
        packet.Slot,
        source,
        tostring(anchorKey or "None"),
        tostring(not configured and packet.Entity)
    ))
    return configured
end

local function GetCachedMarkerPacketCarriers(character, senderKey)
    local cached = state.packetCarrierCache[senderKey]
    if cached
        and IsObjectValid(cached.Character)
        and IsObjectValid(cached.PlayerState)
        and IsObjectValid(cached.GameState)
        and cached.CharacterKey == senderKey
    then
        return cached
    end

    local playerState, gameState = GetMarkerPacketCarriers(character)
    if not IsObjectValid(playerState) or not IsObjectValid(gameState) then
        return nil
    end
    cached = {
        Character = character,
        PlayerState = playerState,
        GameState = gameState,
        CharacterKey = senderKey,
        PlayerStateKey = ObjectKey(playerState),
        GameStateKey = ObjectKey(gameState),
    }
    state.packetCarrierCache[senderKey] = cached
    Debug(string.format(
        "Marker packet carriers cached: sender=%s player_state=%s game_state=%s",
        senderKey,
        tostring(cached.PlayerStateKey or "None"),
        tostring(cached.GameStateKey or "None")
    ))
    return cached
end

local function ClassifyMarkerPacketSymbol(linkedActor, carriers)
    if not IsObjectValid(linkedActor) then
        return 0
    end
    if not carriers then
        return nil
    end
    if linkedActor == carriers.Character then
        return 1
    elseif linkedActor == carriers.PlayerState then
        return 2
    elseif linkedActor == carriers.GameState then
        return 3
    end
    local linkedKey = ObjectKey(linkedActor)
    if linkedKey == carriers.CharacterKey then
        return 1
    elseif linkedKey == carriers.PlayerStateKey then
        return 2
    elseif linkedKey == carriers.GameStateKey then
        return 3
    end
    return nil
end

local function TryConsumeMarkerPacketSymbol(character, linkedActor)
    local senderKey = ObjectKey(character)
    if not senderKey then
        return false
    end
    local receiver = state.packetReceivers[senderKey]
    local carriers = receiver and receiver.Carriers
        or GetCachedMarkerPacketCarriers(character, senderKey)
    local symbol = ClassifyMarkerPacketSymbol(linkedActor, carriers)
    local now = Now(character)
    if receiver
        and receiver.Active
        and now - (receiver.LastAt or receiver.StartedAt or now) > (Config.MarkerPacketReceiveTimeout or 2.0)
    then
        Log(string.format(
            "Marker packet receive timeout: sender=%s received=%d expected=%d",
            GetMarkerPlayerName(character),
            #(receiver.Symbols or {}),
            receiver.ExpectedSymbols or 0
        ))
        state.packetReceivers[senderKey] = nil
        receiver = nil
    end

    if receiver and receiver.Active then
        if symbol == nil then
            Log(string.format(
                "Marker packet aborted by unknown carrier: sender=%s actor=%s received=%d",
                GetMarkerPlayerName(character),
                tostring(ObjectKey(linkedActor) or "None"),
                #receiver.Symbols
            ))
            state.packetReceivers[senderKey] = nil
            return false
        end
        table.insert(receiver.Symbols, symbol)
        receiver.LastAt = now
        if #receiver.Symbols >= receiver.ExpectedSymbols then
            state.packetReceivers[senderKey] = nil
            local packet, decodeError = DecodeMarkerPacket(
                receiver.Symbols,
                receiver.ReferenceLocation
            )
            if not packet then
                Log(string.format(
                    "Marker packet rejected: sender=%s symbols=%d error=%s",
                    GetMarkerPlayerName(character),
                    #receiver.Symbols,
                    tostring(decodeError)
                ))
            else
                Log(string.format(
                    "Marker packet decoded: sender=%s slot=%d entity=%s precise=%s class=%d position=(%.1f,%.1f,%.1f) reference_distance=%.1f symbols=%d checksum=%d",
                    GetMarkerPlayerName(character),
                    packet.Slot,
                    tostring(packet.Entity),
                    tostring(packet.Precise),
                    packet.ClassSignature,
                    packet.Location.X,
                    packet.Location.Y,
                    packet.Location.Z,
                    packet.ReferenceDistance or -1.0,
                    #receiver.Symbols,
                    packet.Checksum
                ))
                HandleDecodedMarkerPacket(character, packet)
            end
        end
        return true
    end

    receiver = receiver or { PreambleStage = 0 }
    if symbol == 2 then
        if receiver.PreambleStage == 2 then
            local coordinateBits = GetMarkerPacketCoordinateBits()
            local expectedBits = PACKET_VERSION_BITS
                + PACKET_SLOT_BITS
                + 1
                + 1
                + PACKET_CLASS_BITS
                + coordinateBits * 3
                + PACKET_CHECKSUM_BITS
            receiver.Active = true
            receiver.PreambleStage = 0
            receiver.Symbols = {}
            receiver.ExpectedSymbols = math.ceil(expectedBits / 2)
            receiver.ReferenceLocation = GetObjectWorldLocation(character)
            receiver.Carriers = carriers
            receiver.StartedAt = now
            receiver.LastAt = now
            state.packetReceivers[senderKey] = receiver
            Log(string.format(
                "Marker packet frame started: sender=%s expected_symbols=%d character=%s reference=(%.1f,%.1f,%.1f)",
                GetMarkerPlayerName(character),
                receiver.ExpectedSymbols,
                senderKey,
                receiver.ReferenceLocation and receiver.ReferenceLocation.X or 0.0,
                receiver.ReferenceLocation and receiver.ReferenceLocation.Y or 0.0,
                receiver.ReferenceLocation and receiver.ReferenceLocation.Z or 0.0
            ))
        else
            receiver.PreambleStage = 1
            state.packetReceivers[senderKey] = receiver
        end
        return true
    elseif symbol == 1 and receiver.PreambleStage == 1 then
        receiver.PreambleStage = 2
        state.packetReceivers[senderKey] = receiver
        return true
    end

    state.packetReceivers[senderKey] = nil
    return false
end

ProcessPendingMarkerWork = function()
    local world = UEHelpers.GetWorld()
    if not IsObjectValid(world) then
        return
    end
    local now = Now(world)

    for senderKey, receiver in pairs(state.packetReceivers) do
        if receiver.Active
            and now - (receiver.LastAt or receiver.StartedAt or now) > (Config.MarkerPacketReceiveTimeout or 2.0)
        then
            Log(string.format(
                "Marker packet receive timeout during tick: sender=%s received=%d expected=%d",
                tostring(senderKey),
                #(receiver.Symbols or {}),
                receiver.ExpectedSymbols or 0
            ))
            state.packetReceivers[senderKey] = nil
        end
    end
    for senderKey, carriers in pairs(state.packetCarrierCache) do
        if not carriers
            or not IsObjectValid(carriers.Character)
            or not IsObjectValid(carriers.PlayerState)
            or not IsObjectValid(carriers.GameState)
        then
            state.packetCarrierCache[senderKey] = nil
        end
    end

    for taskKey, task in pairs(state.pendingBroadcasts) do
        if not IsObjectValid(task.Character) or not IsObjectValid(task.Anchor) then
            state.pendingBroadcasts[taskKey] = nil
        elseif now >= task.DueAt then
            state.pendingBroadcasts[taskKey] = nil
            local ok, err = pcall(function()
                task.Character:Broadcast_TriggerPager(task.Anchor)
            end)
            if ok then
                Debug("Queued Broadcast_TriggerPager sent with a valid anchor")
            else
                Log("Queued Broadcast_TriggerPager failed: " .. tostring(err))
            end
        end
    end

    for taskKey, task in pairs(state.pendingVisualizations) do
        if not IsObjectValid(task.Anchor) then
            state.pendingVisualizations[taskKey] = nil
        elseif now >= task.DueAt then
            local configured = ConfigureBroadcastVisualization(task.Anchor, task.Character, "Queued entity retry")
            task.AttemptsRemaining = task.AttemptsRemaining - 1
            if configured then
                state.processedBroadcastAnchors[taskKey] = {
                    Anchor = task.Anchor,
                    Character = task.Character,
                }
            end
            if configured or task.AttemptsRemaining <= 0 then
                state.pendingVisualizations[taskKey] = nil
            else
                task.DueAt = now + 0.1
            end
        end
    end

    local wallTimeNow = os.time()
    for targetKey, record in pairs(state.directEntityOutlines) do
        local expiredByWorld = now >= (record.ExpiresAt or 0.0)
        local expiredByWallTime = wallTimeNow >= (record.ExpiresAtWallTime or math.huge)
        if expiredByWorld or expiredByWallTime then
            local restored = 0
            local released = 0
            for _, componentRecord in ipairs(record.Components) do
                local component = componentRecord.Component
                if IsObjectValid(component) then
                    local enabled, stencil, readOk = ReadComponentOutlineState(component)
                    if readOk and IsMarkerOutlineState(enabled, stencil) then
                        local restoredOk = pcall(function()
                            component:SetCustomDepthStencilValue(componentRecord.LastExternalStencilValue)
                            component:SetRenderCustomDepth(componentRecord.LastExternalRenderCustomDepth)
                        end)
                        if restoredOk then
                            restored = restored + 1
                        end
                    elseif readOk then
                        -- The game or another mod has already taken ownership.
                        -- Do not overwrite the newer state during cleanup.
                        released = released + 1
                    end
                end
            end
            state.directEntityOutlines[targetKey] = nil
            Debug(string.format(
                "Direct entity outline expired: target=%s restored=%d released=%d components=%d world_expired=%s wall_time_expired=%s",
                tostring(targetKey),
                restored,
                released,
                #record.Components,
                tostring(expiredByWorld),
                tostring(expiredByWallTime)
            ))
        elseif now >= (record.NextRefreshAt or 0.0) then
            local reapplied = 0
            for _, componentRecord in ipairs(record.Components) do
                local component = componentRecord.Component
                if IsObjectValid(component) then
                    ObserveExternalOutlineState(componentRecord)
                    local componentOk = pcall(function()
                        component:SetCustomDepthStencilValue(Config.EntityDirectStencilValue or 250)
                        component:SetRenderCustomDepth(true)
                    end)
                    if componentOk then
                        reapplied = reapplied + 1
                    end
                end
            end

            record.NextRefreshAt = now + (Config.EntityOutlineRefreshInterval or 0.25)
        end
    end

    for targetKey, record in pairs(state.activeMarkerTargets) do
        if not IsObjectValid(record.Anchor) or wallTimeNow >= (record.ExpiresAtWallTime or 0) then
            state.activeMarkerTargets[targetKey] = nil
            if record.AnchorKey then
                state.serverAnchorTargetKeys[record.AnchorKey] = nil
            end
        end
    end

    for anchorKey, info in pairs(state.markerDebugInfo) do
        if not IsObjectValid(info.Anchor) then
            state.markerDebugInfo[anchorKey] = nil
            state.localSuccessSoundAnchors[anchorKey] = nil
        end
    end
    for anchorKey, anchor in pairs(state.localSuccessSoundAnchors) do
        if not IsObjectValid(anchor) then
            state.localSuccessSoundAnchors[anchorKey] = nil
        end
    end
    for anchorKey, record in pairs(state.processedBroadcastAnchors) do
        if not record or not IsObjectValid(record.Anchor) then
            state.processedBroadcastAnchors[anchorKey] = nil
        end
    end
    for slot, anchor in pairs(state.packetLocalSlots) do
        if not IsObjectValid(anchor) then
            state.packetLocalSlots[slot] = nil
        end
    end
end

PlayLocalMarkerSuccessSound = function(character)
    local soundPath = Config.LocalMarkerSuccessSoundPath
    if type(soundPath) ~= "string" or soundPath == "" then
        return false, "success sound path is empty"
    end

    local sound = StaticFindObject(soundPath)
    if not IsObjectValid(sound) then
        pcall(function() LoadAsset(soundPath) end)
        sound = StaticFindObject(soundPath)
    end
    if not IsObjectValid(sound) then
        return false, "success sound asset was not found: " .. soundPath
    end

    local gameplayStatics = GetGameplayStatics()
    if not IsObjectValid(gameplayStatics) then
        return false, "GameplayStatics was unavailable"
    end

    local ok, errorMessage = pcall(function()
        gameplayStatics:PlaySound2D(
            character,
            sound,
            1.0,
            1.0,
            0.0,
            nil,
            character,
            true
        )
    end)
    return ok, errorMessage
end

local function HandleBroadcastPager(contextParam, linkedActorParam)
    local character = ParamValue(contextParam)
    local linkedActor = ParamValue(linkedActorParam)
    if IsObjectValid(character) and TryConsumeMarkerPacketSymbol(character, linkedActor) then
        return
    end
    local localController, localPawn = GetVerifiedLocalPlayerContext()
    if not IsObjectValid(linkedActor) then
        Log(string.format(
            "Multiplayer broadcast received: linked_valid=false sender=%s character=%s authority=%s local_controller=%s local_pawn=%s world=%s",
            GetMarkerPlayerName(character),
            tostring(ObjectKey(character) or "None"),
            tostring(HasAuthority(character)),
            tostring(ObjectKey(localController) or "None"),
            tostring(ObjectKey(localPawn) or "None"),
            tostring(GetCurrentWorldKey(localPawn))
        ))
        return
    end

    local anchorKey = ObjectKey(linkedActor)
    Log(string.format(
        "Multiplayer broadcast received: linked_valid=true sender=%s character=%s authority=%s local_controller=%s local_pawn=%s anchor=%s snapshot={%s}",
        GetMarkerPlayerName(character),
        tostring(ObjectKey(character) or "None"),
        tostring(HasAuthority(character)),
        tostring(ObjectKey(localController) or "None"),
        tostring(ObjectKey(localPawn) or "None"),
        tostring(anchorKey or "None"),
        GetActorReplicationSnapshot(linkedActor)
    ))

    local isStaticMeshActor = false
    local staticMeshActorClass = StaticFindObject(STATIC_MESH_ACTOR_CLASS)
    if IsObjectValid(staticMeshActorClass) then
        pcall(function()
            isStaticMeshActor = linkedActor:IsA(staticMeshActorClass)
        end)
    end

    if not isStaticMeshActor then
        Debug("Broadcast LinkedActor was not a StaticMeshActor; treating it as an original Pager call")
        return
    end

    local processed = anchorKey and state.processedBroadcastAnchors[anchorKey] or nil
    if processed and IsObjectValid(processed.Anchor) then
        Log(string.format(
            "Multiplayer broadcast duplicate ignored: sender=%s anchor=%s",
            GetMarkerPlayerName(character),
            tostring(anchorKey)
        ))
        return
    end

    if Config.LocalMarkerSuccessSound == true then
        if IsObjectValid(localPawn)
            and ObjectKey(character) == ObjectKey(localPawn)
            and anchorKey
            and not state.localSuccessSoundAnchors[anchorKey]
        then
            state.localSuccessSoundAnchors[anchorKey] = linkedActor
            local soundOk, soundError = PlayLocalMarkerSuccessSound(character)
            Debug(string.format(
                "Local marker success sound: played=%s error=%s anchor=%s",
                tostring(soundOk),
                tostring(soundError),
                tostring(anchorKey)
            ))
        end
    end

    local configured = ConfigureBroadcastVisualization(linkedActor, character, "Immediate")
    if configured and anchorKey then
        state.processedBroadcastAnchors[anchorKey] = {
            Anchor = linkedActor,
            Character = character,
        }
    end
    if not configured and IsEntityAnchor(linkedActor) then
        if anchorKey then
            state.pendingVisualizations[anchorKey] = {
                Anchor = linkedActor,
                Character = character,
                DueAt = Now(linkedActor) + 0.1,
                AttemptsRemaining = 3,
            }
        end
    end
    Log(string.format(
        "Multiplayer visualization handled: configured=%s entity=%s sender=%s anchor=%s queued_retry=%s",
        tostring(configured),
        tostring(IsEntityAnchor(linkedActor)),
        GetMarkerPlayerName(character),
        tostring(anchorKey or "None"),
        tostring(not configured and IsEntityAnchor(linkedActor))
    ))
end

local function RegisterHooks()
    if state.hookRegistered then
        return true
    end

    local serverFunction = StaticFindObject(SERVER_PAGER_PATH)
    if not IsObjectValid(serverFunction) then
        return false
    end

    local ok, errorMessage = pcall(function()
        RegisterHook(SERVER_PAGER_PATH, HandleServerPagerPre)
    end)
    if not ok then
        Log("Failed to register Server_TriggerPager hook: " .. tostring(errorMessage))
        return false
    end

    state.hookRegistered = true

    local broadcastFunction = StaticFindObject(BROADCAST_PAGER_PATH)
    if IsObjectValid(broadcastFunction) then
        local broadcastOk, broadcastError = pcall(function()
            RegisterHook(BROADCAST_PAGER_PATH, HandleBroadcastPager)
        end)
        if broadcastOk then
            state.broadcastHookRegistered = true
        else
            Log("Failed to register Broadcast_TriggerPager hook: " .. tostring(broadcastError))
        end
    end

    local playerTickFunction = StaticFindObject(PLAYER_CONTROLLER_TICK_PATH)
    if IsObjectValid(playerTickFunction) and not state.labelTickHookRegistered then
        local tickOk, tickError = pcall(function()
            -- Blueprint UFunction hooks use the single callback form here.
            -- UE4SS invokes this callback after the Blueprint function.
            RegisterHook(PLAYER_CONTROLLER_TICK_PATH, HandlePlayerControllerTick)
        end)
        if tickOk then
            state.labelTickHookRegistered = true
            Debug("Label presentation tick hook registered")
        else
            Log("Failed to register label presentation tick hook: " .. tostring(tickError))
        end
    end

    Log("Pager network hooks registered")
    return true
end

local function RegisterHooksWithRetry(attempt)
    attempt = attempt or 1
    ExecuteInGameThread(function()
        if RegisterHooks() then
            return
        end

        if attempt >= 300 then
            Log("Pager functions were not loaded after 300 attempts; join or reload a world to retry")
            return
        end

        ExecuteWithDelay(1000, function()
            RegisterHooksWithRetry(attempt + 1)
        end)
    end)
end

local function LocalTraceHasHit(character, playerController)
    local startLocation, direction = GetLocalCrosshairRay(playerController)
    if not startLocation or not direction then
        return false
    end

    local hit = Trace(startLocation, direction, character)
    return hit ~= nil and hit.Point ~= nil
end

local function RequestMarker()
    ExecuteInGameThread(function()
        local playerController, character = GetVerifiedLocalPlayerContext()
        if not IsObjectValid(playerController) or not IsObjectValid(character) then
            Log("Marker request ignored: verified local PlayerController/Pawn unavailable")
            return
        end

        local now = Now(character)
        local worldKey = GetCurrentWorldKey(character)
        local worldChanged = state.lastClientRequestWorldKey ~= nil
            and worldKey ~= nil
            and state.lastClientRequestWorldKey ~= worldKey
        local timeWentBack = now < state.lastClientRequestTime
        if worldChanged or timeWentBack then
            Debug(string.format(
                "Client cooldown clock reset: reason=%s previous=%.2f now=%.2f previous_world=%s current_world=%s",
                worldChanged and "WorldChanged" or "TimeWentBack",
                state.lastClientRequestTime,
                now,
                tostring(state.lastClientRequestWorldKey),
                tostring(worldKey)
            ))
            ResetLocalCooldownState(worldChanged and "WorldChanged" or "TimeWentBack")
        end
        local clientCooldown = Config.ClientCooldown or Config.PerPlayerCooldown or 3.0
        local elapsed = now - state.lastClientRequestTime
        if elapsed < clientCooldown then
            if Config.CooldownWarningSound == true
                and now - state.lastCooldownWarningTime >= (Config.CooldownWarningSoundThrottle or 0.25)
            then
                state.lastCooldownWarningTime = now
                NotifyCooldownMarkerRejected(character, clientCooldown - elapsed)
            end
            Debug(string.format(
                "Local marker request rejected by cooldown: %.2fs remaining; existing outlines unchanged",
                clientCooldown - elapsed
            ))
            return
        end

        if not LocalTraceHasHit(character, playerController) then
            Debug("Local marker trace did not hit anything")
            return
        end

        Log(string.format(
            "Multiplayer local request ready: player=%s controller=%s pawn=%s authority=%s world=%s pawn_snapshot={%s}",
            GetMarkerPlayerName(character),
            tostring(ObjectKey(playerController) or "None"),
            tostring(ObjectKey(character) or "None"),
            tostring(HasAuthority(character)),
            tostring(worldKey),
            GetActorReplicationSnapshot(character)
        ))

        state.lastClientRequestTime = now
        state.lastClientRequestWorldKey = worldKey
        local nullActor = CreateInvalidObject()
        local ok, errorMessage = pcall(function()
            character:Server_TriggerPager(nullActor)
        end)

        if not ok then
            Log("Server_TriggerPager request failed: " .. tostring(errorMessage))
            return
        end

        Log(string.format(
            "Multiplayer local request sent: player=%s pawn=%s",
            GetMarkerPlayerName(character),
            tostring(ObjectKey(character) or "None")
        ))
    end)
end

local function RunUniversalCollisionDebugTrace()
    if state.debugDisplayTargetInfo ~= true then
        return
    end
    ExecuteInGameThread(function()
        local playerController, character = GetVerifiedLocalPlayerContext()
        if not IsObjectValid(playerController) or not IsObjectValid(character) then
            Log("F6 collision diagnostic skipped: verified local PlayerController/Pawn unavailable")
            return
        end

        local startLocation, direction = GetLocalCrosshairRay(playerController)
        local systemLibrary = GetKismetSystemLibrary()
        if not startLocation or not direction or not IsObjectValid(systemLibrary) then
            Log("F6 collision diagnostic could not obtain the local crosshair ray")
            return
        end

        local endLocation = AddScaledVector(startLocation, direction, Config.TraceDistance)
        local actorsToIgnore = {}
        local transparent = { R = 0, G = 0, B = 0, A = 0 }
        local records = {}
        local queries = 0
        local failures = 0

        local function RecordHit(hitResult, source)
            local hit = BuildTraceHit(hitResult, startLocation, source)
            if not hit then
                return
            end

            local key = tostring(ObjectKey(hit.Actor) or "NoActor")
                .. "|" .. tostring(ObjectKey(hit.Component) or "NoComponent")
            local record = records[key]
            if not record then
                record = {
                    Hit = hit,
                    Sources = {},
                    SourceSet = {},
                }
                records[key] = record
            elseif hit.DistanceSquared < record.Hit.DistanceSquared then
                record.Hit = hit
            end

            if not record.SourceSet[source] then
                record.SourceSet[source] = true
                table.insert(record.Sources, source)
            end
        end

        local objectTypes = {}
        local objectTypeCount = math.max(1, math.floor(Config.UniversalDebugObjectTypeCount or 32))
        for objectType = 0, objectTypeCount - 1 do
            table.insert(objectTypes, objectType)
        end

        for _, traceComplex in ipairs({ false, true }) do
            queries = queries + 1
            local hitResult = {}
            local ok, wasHit = pcall(function()
                return systemLibrary:LineTraceSingleForObjects(
                    character,
                    startLocation,
                    endLocation,
                    objectTypes,
                    traceComplex,
                    actorsToIgnore,
                    0,
                    hitResult,
                    true,
                    transparent,
                    transparent,
                    0.0
                )
            end)
            if ok and wasHit then
                RecordHit(hitResult, traceComplex and "AllObjects-Complex" or "AllObjects-Simple")
            elseif not ok then
                failures = failures + 1
                Log("F6 all-object collision query failed: " .. tostring(wasHit))
            end
        end

        local channelCount = math.max(1, math.floor(Config.UniversalDebugTraceChannelCount or 32))
        for traceChannel = 0, channelCount - 1 do
            for _, traceComplex in ipairs({ false, true }) do
                queries = queries + 1
                local hitResult = {}
                local ok, wasHit = pcall(function()
                    return systemLibrary:LineTraceSingle(
                        character,
                        startLocation,
                        endLocation,
                        traceChannel,
                        traceComplex,
                        actorsToIgnore,
                        0,
                        hitResult,
                        true,
                        transparent,
                        transparent,
                        0.0
                    )
                end)
                if ok and wasHit then
                    local complexity = traceComplex and "Complex" or "Simple"
                    RecordHit(hitResult, string.format("TraceChannel%d-%s", traceChannel, complexity))
                elseif not ok then
                    failures = failures + 1
                    Log(string.format(
                        "F6 TraceChannel%d collision query failed (%s): %s",
                        traceChannel,
                        traceComplex and "complex" or "simple",
                        tostring(wasHit)
                    ))
                end
            end
        end

        local ordered = {}
        for _, record in pairs(records) do
            table.insert(ordered, record)
        end
        table.sort(ordered, function(left, right)
            return left.Hit.DistanceSquared < right.Hit.DistanceSquared
        end)

        local function CompactName(value, maximumLength)
            local text = tostring(value or "Unknown")
            text = text:match("([^%.]+)$") or text
            if #text > maximumLength then
                text = text:sub(1, maximumLength - 3) .. "..."
            end
            return text
        end

        local function CompactSource(source)
            local text = tostring(source or "Unknown")
            text = text:gsub("TraceChannel", "Ch")
                :gsub("AllObjects", "AllObj")
                :gsub("Complex", "C")
                :gsub("Simple", "S")
            return text
        end

        local maxResults = math.max(1, math.floor(Config.UniversalDebugTraceMaxResults or 4))
        local displayLines = {
            string.format("F6: %d hits (full details in UE4SS.log)", #ordered),
        }
        local displayed = 0
        for index, record in ipairs(ordered) do
            local hit = record.Hit
            local sourcePreview = {}
            for sourceIndex = 1, math.min(8, #record.Sources) do
                table.insert(sourcePreview, record.Sources[sourceIndex])
            end
            local sourceText = table.concat(sourcePreview, ",")
            if #record.Sources > #sourcePreview then
                sourceText = sourceText .. string.format(" +%d", #record.Sources - #sourcePreview)
            end
            local distance = math.sqrt(hit.DistanceSquared or 0.0)

            Log(string.format(
                "F6 collision hit #%d: distance=%.1f actor=%s actor_class=%s component=%s component_class=%s sources=%s",
                index,
                distance,
                GetObjectName(hit.Actor, "NoActor"),
                GetObjectClassName(hit.Actor, "NoActorClass"),
                GetObjectName(hit.Component, "NoComponent"),
                GetObjectClassName(hit.Component, "NoComponentClass"),
                sourceText
            ))

            local actorClass = GetObjectClassName(hit.Actor, "NoActorClass")
            local screenNoise = distance < 1.0
                and actorClass:find("LevelStreamingVolume", 1, true) ~= nil
            if not screenNoise and displayed < maxResults then
                displayed = displayed + 1
                local compactSource = CompactSource(record.Sources[1])
                if #record.Sources > 1 then
                    compactSource = compactSource .. string.format(" (+%d)", #record.Sources - 1)
                end
                table.insert(displayLines, string.format(
                    "%d) %s",
                    displayed,
                    CompactName(GetObjectName(hit.Actor, "NoActor"), 38)
                ))
                table.insert(displayLines, string.format(
                    "   Comp: %s | %.1fm",
                    CompactName(GetObjectName(hit.Component, "NoComponent"), 32),
                    distance / 100.0
                ))
                table.insert(displayLines, string.format(
                    "   Via: %s",
                    compactSource
                ))
            end
        end

        if #ordered == 0 then
            table.insert(displayLines, "No collision-enabled object was hit")
        end
        local displayText = table.concat(displayLines, "\n")
        local displayOk, displayError = pcall(function()
            character:Client_DisplayWarningMessage(FText(displayText), 1, false)
        end)
        Log(string.format(
            "F6 collision diagnostic complete: queries=%d failures=%d unique_hits=%d display=%s error=%s",
            queries,
            failures,
            #ordered,
            tostring(displayOk),
            tostring(displayError)
        ))
    end)
end

local function RegisterMarkerKey(key, displayName)
    local keyOk, keyError = pcall(function()
        RegisterKeyBind(key, RequestMarker)
    end)
    if not keyOk then
        Log("Could not bind " .. displayName .. ": " .. tostring(keyError))
        return false
    end
    return true
end

local function RegisterModifiedMarkerKey(key, modifiers, displayName)
    local keyOk, keyError = pcall(function()
        RegisterKeyBind(key, modifiers, RequestMarker)
    end)
    if not keyOk then
        Log("Could not bind " .. displayName .. ": " .. tostring(keyError))
        return false
    end
    return true
end

local function ToggleDebugDisplay()
    ExecuteInGameThread(function()
        state.debugDisplayTargetInfo = not state.debugDisplayTargetInfo
        Log(string.format(
            "F6 collision debug mode %s via F5",
            state.debugDisplayTargetInfo and "enabled" or "disabled"
        ))
    end)
end

local function RegisterDebugToggleKey()
    local keyOk, keyError = pcall(function()
        RegisterKeyBind(Key.F5, ToggleDebugDisplay)
    end)
    if not keyOk then
        Log("Could not bind F5 debug toggle: " .. tostring(keyError))
        return false
    end
    return true
end

local function RegisterUniversalDebugTraceKey()
    local keyOk, keyError = pcall(function()
        RegisterKeyBind(Key.F6, RunUniversalCollisionDebugTrace)
    end)
    if not keyOk then
        Log("Could not bind F6 collision diagnostic: " .. tostring(keyError))
        return false
    end
    return true
end

RegisterMarkerKey(Key.MIDDLE_MOUSE_BUTTON, "the middle mouse button")
RegisterMarkerKey(Key.Q, "Q")
RegisterModifiedMarkerKey(Key.Q, { ModifierKey.CONTROL }, "Ctrl+Q")
RegisterModifiedMarkerKey(Key.Q, { ModifierKey.SHIFT }, "Shift+Q")
RegisterModifiedMarkerKey(
    Key.Q,
    { ModifierKey.CONTROL, ModifierKey.SHIFT },
    "Ctrl+Shift+Q"
)
RegisterDebugToggleKey()
RegisterUniversalDebugTraceKey()

pcall(function()
    RegisterHook(CLIENT_RESTART_PATH, function(contextParam)
        local restartedController = ParamValue(contextParam)
        local isLocalRestart = IsStrictlyLocalController(restartedController)
        if isLocalRestart then
            ClearLocalPlayerContext("LocalClientRestart")
            ResetLocalCooldownState("ClientRestart")
        else
            Debug(string.format(
                "Ignored remote ClientRestart for local state: controller=%s",
                tostring(ObjectKey(restartedController) or "None")
            ))
        end
        if not state.hookRegistered then
            ExecuteWithDelay(100, function()
                RegisterHooksWithRetry(1)
            end)
        end
    end)
end)

RegisterHooksWithRetry(1)
Log("Loaded v" .. MOD_VERSION .. "; optimized actor-free marker packet transport enabled")
