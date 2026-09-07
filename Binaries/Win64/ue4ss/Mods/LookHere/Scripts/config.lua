return {
    -- Maximum server-side ray distance in Unreal units (100 units = 1 metre).
    TraceDistance = 50000.0,

    -- Ignore the requesting player's Pawn plus separately owned/attached
    -- equipment Actors, retrying the trace so the object behind them can win.
    MaxRequestingPlayerTraceSkips = 8,

    -- Build-zone volumes are never visual targets, including furniture children.
    IgnoreBuildZones = true,
    -- Other standalone query/render helpers can be skipped independently.
    MaxTransparentHelperTraceSkips = 8,
    TransparentStandaloneHelperClassPatterns = {
        "BuildZone",
    },

    -- Visibility trace channel. TraceTypeQuery1 / Visibility is 0 in this game.
    TraceChannel = 0,

    -- F6 confirmed that Abiotic_Item_Dropped.WorldMesh blocks channel 2 using
    -- simple collision while the normal Visibility channel passes through it.
    AdditionalTraceChannels = { 2 },

    -- Additional zero-based EObjectTypeQuery values. Cover all six standard UE
    -- object types as a fallback for interactables that ignore Visibility.
    -- The nearer result still wins, so a foreground prop cannot be skipped in
    -- favour of a wall behind it.
    ObjectTraceTypes = { 0, 1, 2, 3, 4, 5 },

    -- Narrow sweep for small/query-only interaction components on wall props.
    InteractionProbeRadius = 12.0,
    InteractionProbeBehindTolerance = 60.0,
    -- A button slightly behind its own parent FurnitureMesh wins only when both
    -- hits resolve to the same Actor. Unrelated walls/Actors remain blockers.
    InteractionComponentPromotionTolerance = 60.0,

    -- F6 runs a separate exhaustive collision diagnostic without creating a
    -- marker or changing the normal Q/middle-mouse trace path.
    UniversalDebugTraceMaxResults = 4,
    UniversalDebugTraceChannelCount = 32,
    UniversalDebugObjectTypeCount = 32,

    -- Do not create markers while a UMG text input owns keyboard/user focus.
    -- This covers chat plus other editable fields without depending on one
    -- game-specific chat widget name. The check runs only when a marker key is
    -- pressed, not every frame.
    IgnoreMarkerWhileTyping = true,
    TextInputWidgetClasses = {
        "EditableText",
        "EditableTextBox",
        "MultiLineEditableText",
        "MultiLineEditableTextBox",
    },

    -- Blueprint-visible PrimitiveComponent properties used when this UE4SS
    -- build cannot enumerate an Actor's component TArray.
    EntityMeshProperties = {
        "FurnitureMesh",
        "ChairTop",
        "ButtonMesh",
        "DoorMesh",
        "ItemMesh",
        "WorldMesh",
        "SM_ResourceNode",
        "StaticMesh",
        "Cube",
        "base",
        "Monitor",
        "Mesh",
        "SkeletalMesh",
    },

    -- ChildActorComponent-generated helpers that should resolve exactly one
    -- Actor level upward to their visible owning furniture. Standalone helpers
    -- without a valid entity parent are handled by the helper trace filter.
    WholeActorHelperClassPatterns = {
        "BuildZone",
    },

    -- /Engine/BasicShapes/Sphere has a diameter of 100 Unreal units at scale 1.
    SphereScale = 0.35,

    -- Entity hits use an invisible replicated anchor. Its tiny scale is also a
    -- network-safe marker type discriminator on every client.
    EntityAnchorScale = 0.01,
    EntityAnchorDetectionScale = 0.02,
    -- If the server-side target Actor has no usable network reference, each
    -- client checks a short ray segment around the replicated hit anchor.
    -- Exact line traces run first; one narrow swept ray covers the anchor's
    -- surface offset. No broad SphereOverlapActors query is used.
    LocalResolveRayBacktrack = 120.0,
    LocalResolveRayForward = 80.0,
    LocalResolveRaySweepRadius = 24.0,
    LocalResolveTraceChannels = { 0, 2 },
    LocalResolveObjectTypes = { 0, 1, 2, 3, 4, 5 },
    LocalResolveMaxBoundsDistance = 80.0,
    -- Hidden entity anchors encode a precise-component flag in replicated Pitch.
    ComponentMarkerPitch = 37.0,

    -- Push the sphere away from the surface so the outline is not buried in geometry.
    SurfaceOffset = 18.0,

    -- Seconds before the server destroys the replicated anchor.
    MarkerDuration = 10.0,

    -- Global session-wide marker pool. New markers allocate 1..N in a ring;
    -- allocating an occupied slot removes the older marker in that slot.
    MaxActiveMarkers = 8,

    -- Native E_OutlineMode value. Teammate Highlight uses 5 for its yellow outline.
    OutlineMode = 5,

    -- Write Custom Depth to the target's real visible Meshes once. Whole-Actor
    -- marks enumerate MeshComponents through the UE Blueprint reflection entry
    -- and include child Actors so multi-part furniture can light as one object.
    -- No Lua refresh or mid-lifetime state polling is performed.
    EntityDirectStencilValue = 250,
    EntityOutlineIncludeChildActors = true,
    -- Cleanup reads each Mesh once. It restores the captured pre-Mark value only
    -- if the Mesh still has this exact marker state; any changed state is left
    -- untouched for the game or another Mod to own.
    OutlineDiagnostics = true,

    -- One-shot structure logging for known partial-outline targets.
    -- This does not change trace selection or outline collection. It records
    -- Actor/component attachment data once per matching Actor for diagnosis.
    OutlineStructureDiagnostics = false,
    OutlineStructureDiagnosticActorPatterns = {
        "Cart",
        "ElectricFan",
    },
    OutlineStructureDiagnosticMaxActors = 24,
    OutlineStructureDiagnosticMaxComponentsPerActor = 64,

    -- Custom Depth Stencil written directly to the marker sphere. Zero is ignored
    -- by the game's outline post-process, so keep this non-zero.
    -- Outline modes are stored as bits; mode 5 maps to bit 5 (32).
    DirectStencilValue = 32,

    -- Screen-space TextBlock attached directly to the game's PrimaryHUDCanvas.
    -- Its size is fixed in UI pixels and independent of world distance.
    LabelHeight = 62.0,
    LabelWidgetScale = 1.5,
    LabelWidgetZOrder = 100,
    LabelWorldOffset = 18.0,
    -- World-surface markers use the replicated sphere's actual scaled bounds.
    -- Project the sphere top and centre the fixed-size text box on that point,
    -- instead of stacking an extra world offset plus a full text-box height.
    WorldLabelBoundsHeightFactor = 1.0,
    WorldLabelWorldOffset = 0.0,
    WorldLabelScreenOffsetY = 0.0,
    WorldLabelVerticalAlignment = 0.5,
    -- Entity labels use bounds without Child Actors. Implausibly large or
    -- displaced bounds fall back to a stable point above the Actor origin.
    EntityLabelBoundsHeightFactor = 0.5,
    EntityLabelFallbackHeight = 60.0,
    -- Put the centre of the entity TextBlock at 75% of the Actor bounds:
    -- bounds centre + 0.5 * half-height, with no extra upward displacement.
    EntityLabelWorldOffset = 0.0,
    EntityLabelScreenOffsetY = 0.0,
    EntityLabelVerticalAlignment = 0.5,
    MaxEntityLabelBoundsOffset = 400.0,
    MaxEntityLabelExtent = 300.0,
    LabelScreenOffsetY = 20.0,
    -- 20 Hz remains responsive while reducing HUD work with eight markers.
    LabelUpdateInterval = 0.05,
    -- Refresh shape-derived label offsets at 4 Hz; position still follows at 20 Hz.
    LabelBoundsUpdateInterval = 0.25,
    -- Expiry/object cleanup runs twice a second; label projection stays at 20 Hz.
    MaintenanceInterval = 0.5,
    InputDiagnostics = true,
    InputDiagnosticsInterval = 5,
    -- Only active marker work reaches the 20 Hz updater. Slow active updates
    -- are logged at most once per throttle window for real-game profiling.
    PerformanceDiagnostics = true,
    PerformanceSlowTickThresholdMs = 2.0,
    PerformanceLogThrottleSeconds = 2.0,
    -- 2.5 is exactly twice the previous 1.25 screen-space scale.
    HudLabelScale = 2.5,
    HudLabelTypeface = "Bold",
    HudLabelWidth = 900.0,
    HudLabelHeight = 108.0,
    LabelColor = { R = 255, G = 220, B = 32, A = 255 },

    -- Initial state for the F5 runtime toggle. F6 is inert while false.
    -- Normal marker labels remain compact in both states.
    DebugDisplayTargetInfo = false,

    -- The first attempt keeps listen-server feedback responsive. Later retries
    -- let remote clients finish receiving the dynamic anchor Actor and NetGUID
    -- before that Actor is passed through the multicast RPC. Clients dedupe the
    -- first valid anchor, so successful retries do not duplicate the marker.
    BroadcastDelayMs = 100,
    BroadcastRetryDelaysMs = { 100, 750, 1500, 2500 },
    -- v0.3.34 no longer sends a dynamically spawned marker Actor as an RPC
    -- argument. A compact base-4 packet is sent with already replicated actors
    -- as symbols, then every client creates and resolves the marker locally.
    MarkerPacketProtocolVersion = 2,
    MarkerPacketCoordinateQuantum = 4.0,
    -- 15 wrapped bits at 4 cm cover the nearest +/-655.36 m interval, which
    -- exceeds the configured 500 m trace distance while reducing packet size.
    MarkerPacketCoordinateBits = 15,
    -- Batches now run on the existing label Tick, with no delayed callbacks.
    -- Protocol 2 wire symbols are unchanged. BatchSize remains a per-Tick cap.
    MarkerPacketBatchSize = 4,
    MarkerPacketReceiveTimeout = 2.0,
    MarkerPacketDecodedDistanceMargin = 5000.0,

    -- Each player has an independent authoritative server cooldown. One
    -- player's marker does not delay another player's marker.
    PerPlayerCooldown = 3.0,

    -- Local pre-filter; the server still makes the authoritative decision.
    ClientCooldown = 3.0,

    -- Cooldown uses the game's warning beep; success uses a distinct Pager click.
    CooldownWarningSound = true,
    -- At most one warning per successful local request's cooldown cycle.
    CooldownWarningTextFormat = "Marker cooldown: %.1fs remaining",
    LocalMarkerSuccessSound = true,
    LocalMarkerSuccessSoundPath = "/Game/Audio/UI/Pager/ui_pager_click.ui_pager_click",
    WarningSoundCriticality = 2,
    RejectDuplicateEntityMarks = true,
    DuplicateMarkerWarningText = "Target already marked",

    -- Verbose per-marker diagnostics are opt-in in release builds. Slow marker
    -- tick warnings above remain available while this is false.
    DebugLogging = false,
    -- Per accepted trace only: records exact/probe arbitration and authoritative
    -- ray source for reproducing small-target selection. Does not add HUD text.
    TraceSelectionDiagnostics = true,
}
