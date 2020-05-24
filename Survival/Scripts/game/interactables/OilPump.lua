-- OilPump.lua --
dofile( "$SURVIVAL_DATA/Scripts/game/util/Curve.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_shapes.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/util/pipes.lua" )

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

OilPump = class()
OilPump.poseWeightCount = 1
OilPump.connectionInput = sm.interactable.connectionType.logic
OilPump.maxParentCount = 1
OilPump.maxChildCount = 0
OilPump.fireDelay = 40 -- ticks

function OilPump.server_onCreate( self )
	self.sv = {}

	-- client table goes to client
	self.sv.client = {}
	self.sv.client.pipeNetwork = {}
	self.sv.client.state = PipeState.off
	self.sv.client.showBlockVisualization = false

	-- storage table goes to storage
	self.sv.storage = self.storage:load()
	if self.sv.storage == nil then
		self.sv.storage = {}
		self.storage:save( self.sv.storage )
	end

	self.sv.dirtyClientTable = false
	self.sv.dirtyStorageTable = false

	self.sv.fireDelayProgress = 0
	self.sv.canFire = true
	self.sv.areaTrigger = nil
	self.sv.connectedContainers = {}
	self.sv.foundContainer = nil
	self.sv.foundItem = sm.uuid.getNil()
	self.sv.parentActive = false
	self:sv_buildPipeNetwork()
	self:sv_updateStates()

	-- public data used to interface with the packing station
	self.interactable:setPublicData( { packingStationTick = 0 } )
end

function OilPump.sv_markClientTableAsDirty( self )
	self.sv.dirtyClientTable = true
end

function OilPump.sv_markStorageTableAsDirty( self )
	self.sv.dirtyStorageTable = true
	self:sv_markClientTableAsDirty()
end

function OilPump.sv_n_toogle( self )
end

function OilPump.sv_updateStates( self )
  if not self.sv.areaTrigger then
    local size = sm.vec3.new( 0.5, 0.5, 0.5 )
    local filter = sm.areaTrigger.filter.staticBody + sm.areaTrigger.filter.dynamicBody + sm.areaTrigger.filter.areaTrigger + sm.areaTrigger.filter.harvestable
    self.sv.areaTrigger = sm.areaTrigger.createAttachedBox( self.interactable, size, sm.vec3.new(0.0, -1.0, 0.0), sm.quat.identity(), filter )
    self.sv.areaTrigger:bindOnProjectile( "trigger_onProjectile", self )
  end
end

function OilPump.sv_buildPipeNetwork( self )

	self.sv.client.pipeNetwork = {}
	self.sv.connectedContainers = {}

	local function fnOnVertex( vertex )

		if isAnyOf( vertex.shape:getShapeUuid(), ContainerUuids ) then -- Is Container
			assert( vertex.shape:getInteractable():getContainer() )
			local container = {
				shape = vertex.shape,
				distance = vertex.distance,
				shapesOnContainerPath = vertex.shapesOnPath
			}

			table.insert( self.sv.connectedContainers, container )
		elseif isAnyOf( vertex.shape:getShapeUuid(), PipeUuids ) then -- Is Pipe
			assert( vertex.shape:getInteractable() )
			local pipe = {
				shape = vertex.shape,
				state = PipeState.off
			}

			table.insert( self.sv.client.pipeNetwork, pipe )
		end

		return true
	end

	ConstructPipedShapeGraph( self.shape, fnOnVertex )

	-- Sort container by closests
	table.sort( self.sv.connectedContainers, function(a, b) return a.distance < b.distance end )

	-- Synch the pipe network and initial state to clients
	local state = PipeState.off

	for _, container in ipairs( self.sv.connectedContainers ) do
		for _, shape in ipairs( container.shapesOnContainerPath ) do
			for _, pipe in ipairs( self.sv.client.pipeNetwork ) do
				if pipe.shape:getId() == shape:getId() then
					pipe.state = PipeState.connected
				end
			end
		end
	end

	self.sv.client.state = state
	self:sv_markClientTableAsDirty()
end

function OilPump.constructionRayCast( self )
	local start = self.shape:getWorldPosition()
	local stop = self.shape:getWorldPosition() - self.shape.at * 4
	local valid, result = sm.physics.raycast( start, stop, self.shape:getBody() )
	if valid then
		local groundPointOffset = -( sm.construction.constants.subdivideRatio_2 - 0.04 + sm.construction.constants.shapeSpacing + 0.005 )
		local pointLocal = result.pointLocal
		if result.type ~= "body" and result.type ~= "joint" then
			pointLocal = pointLocal + result.normalLocal * groundPointOffset
		end

		local n = sm.vec3.closestAxis( result.normalLocal )
		local a = pointLocal * sm.construction.constants.subdivisions - n * 0.5
		local gridPos = sm.vec3.new( math.floor( a.x ), math.floor( a.y ), math.floor( a.z ) ) + n

		local function getTypeData()
			local shapeOffset = sm.vec3.new( sm.construction.constants.subdivideRatio_2, sm.construction.constants.subdivideRatio_2, sm.construction.constants.subdivideRatio_2 )
			local localPos = gridPos * sm.construction.constants.subdivideRatio + shapeOffset
			if result.type == "body" then
				local shape = result:getShape()
				if shape and sm.exists( shape ) then
					return shape:getBody():transformPoint( localPos ), shape
				else
					valid = false
				end
			elseif result.type == "joint" then
				local joint = result:getJoint()
				if joint and sm.exists( joint ) then
					return joint:getShapeA():getBody():transformPoint( localPos ), joint
				else
					valid = false
				end
			elseif result.type == "lift" then
				local lift, topShape = result:getLiftData()
				if lift and ( not topShape or lift:hasBodies() ) then
					valid = false
				end
				return localPos, lift
			end
			return localPos
		end

		local worldPos, obj = getTypeData()
		return valid, gridPos, result.normalLocal, worldPos, obj
	end
	return valid
end

function OilPump.server_outgoingReload( self, container, item )
	self.sv.foundContainer, self.sv.foundItem = container, item

	local isBlock = sm.item.isBlock( self.sv.foundItem )
	if self.sv.client.showBlockVisualization ~= isBlock then
		self.sv.client.showBlockVisualization = isBlock
		self:sv_markClientTableAsDirty()
	end

	if self.sv.canFire then
		self.sv.fireDelayProgress = OilPump.fireDelay
		self.sv.canFire = false
	end

	if self.sv.foundContainer then
		self.network:sendToClients( "cl_n_onOutgoingReload", { shapesOnContainerPath = self.sv.foundContainer.shapesOnContainerPath, item = self.sv.foundItem } )
	end
end

function OilPump.server_outgoingReset( self )
	self.sv.canFire = false
	self.sv.foundContainer = nil
	self.sv.foundItem = sm.uuid.getNil()

	if self.sv.client.showBlockVisualization then
		self.sv.client.showBlockVisualization = false
		self:sv_markClientTableAsDirty()
	end
end

function OilPump.server_outgoingLoaded( self )
	return self.sv.foundContainer and self.sv.foundItem ~= sm.uuid.getNil()
end

function OilPump.server_outgoingShouldReload( self, container, item )
	return self.sv.foundItem ~= item
end

function OilPump.server_onFixedUpdate( self )

	local function setVacuumState( state, shapes )
		if self.sv.client.state ~= state then
			self.sv.client.state = state
			self:sv_markClientTableAsDirty()
		end

		for _, obj in ipairs( self.sv.client.pipeNetwork ) do
			for _, shape in ipairs( shapes ) do
				if obj.shape:getId() == shape:getId() then
					if obj.state ~= state then
						obj.state = state
						self:sv_markClientTableAsDirty()
					end
				end
			end
		end
	end

	local function setVacuumStateOnAllShapes( state )
		if self.sv.client.state ~= state then
			self.sv.client.state = state
			self:sv_markClientTableAsDirty()
		end

		for _, container in ipairs( self.sv.connectedContainers ) do
			for _, shape in ipairs( container.shapesOnContainerPath ) do
				for _, pipe in ipairs( self.sv.client.pipeNetwork ) do
					if pipe.shape:getId() == shape:getId() then
						pipe.state = state
						self:sv_markClientTableAsDirty()
					end
				end
			end
		end

	end

	-- Update fire delay progress
	if not self.sv.canFire then
		self.sv.fireDelayProgress = self.sv.fireDelayProgress - 1
		if self.sv.fireDelayProgress <= 0 then
			self.sv.fireDelayProgress = OilPump.fireDelay
			self.sv.canFire = true
		end
	end

	-- Optimize this either through a simple has changed that only checks the body and not shapes
	-- Or let the body check and fire an event whenever it detects a change
	if  self.shape:getBody():hasChanged( sm.game.getCurrentTick() - 1 ) then
		self:sv_buildPipeNetwork()
  end
  
  if #self.sv.connectedContainers > 0 then
    local incomingObjects = {}

    for _, result in ipairs(  self.sv.areaTrigger:getContents() ) do
      if sm.exists( result ) and type( result ) == "Harvestable" and result:getUuid() == hvs_farmables_oilgeyser then
        print('oil geyser!')
        local amount = 1
        local container = FindContainerToCollectTo( self.sv.connectedContainers, obj_resource_crudeoil, amount )
        table.insert( incomingObjects, { container = container, harvestable = result, uuid = obj_resource_crudeoil, amount = amount } )
      end
    end

    -- If active
    local parent = self.shape:getInteractable():getSingleParent()
    if parent and parent.active and self.sv.canFire then
      for _, incomingObject in ipairs( incomingObjects ) do
        print(incomingObject)
        if incomingObject.container then
          sm.container.beginTransaction()

          sm.container.collect( incomingObject.container.shape:getInteractable():getContainer(), incomingObject.uuid, incomingObject.amount, true)

          if sm.container.endTransaction() then
            self.network:sendToClients( "cl_n_onIncomingFire", { shapesOnContainerPath = incomingObject.container.shapesOnContainerPath, item = incomingObject.uuid } )

            if incomingObject.harvestable then
              print('picked')
              sm.effect.playEffect( "Oilgeyser - Picked", sm.harvestable.getPosition( incomingObject.harvestable ) )
              sm.harvestable.create( hvs_farmables_growing_oilgeyser, sm.harvestable.getPosition( incomingObject.harvestable ), sm.harvestable.getRotation( incomingObject.harvestable ) )
              sm.harvestable.destroy( incomingObject.harvestable )
            end
          end
        else
          self.network:sendToClients( "cl_n_onError", { shapesOnContainerPath = self.sv.connectedContainers[1].shapesOnContainerPath } )
        end
      end

      if #incomingObjects == 0 then
        self.network:sendToClients( "cl_n_onError", { shapesOnContainerPath = self.sv.connectedContainers[1].shapesOnContainerPath } )
      end
      self.sv.canFire = false
    end

		-- Synch visual feedback
		if #incomingObjects > 0 then

			-- Highlight the longest connection
			local longestConnection = incomingObjects[1].container
			for _, incomingObject in ipairs( incomingObjects ) do
				if #incomingObject.container.shapesOnContainerPath > #longestConnection.shapesOnContainerPath then
					longestConnection = incomingObject.container
				end
			end

			setVacuumState( PipeState.valid, longestConnection.shapesOnContainerPath )
		else
			setVacuumStateOnAllShapes( PipeState.connected )
		end
	end

	-- Storage table dirty
	if self.sv.dirtyStorageTable then
		self.storage:save( self.sv.storage )
		self.sv.dirtyStorageTable = false
	end

	-- Client table dirty
	if self.sv.dirtyClientTable then
		self.network:setClientData( { pipeNetwork = self.sv.client.pipeNetwork, state = self.sv.client.state, showBlockVisualization = self.sv.client.showBlockVisualization } )
		self.sv.dirtyClientTable = false
	end

end

-- Client
function OilPump.client_onCreate( self )
	self.cl = {}

	-- Update from onClientDataUpdate
	self.cl.pipeNetwork = {}
	self.cl.state = PipeState.off
	self.cl.showBlockVisualization = false

	self.cl.overrideUvFrameIndexTask = nil
	self.cl.poseAnimTask = nil
	self.cl.vacuumEffect = nil

	self.cl.pipeEffectPlayer = PipeEffectPlayer()
	self.cl.pipeEffectPlayer:onCreate()
end

function OilPump.client_onClientDataUpdate( self, clientData )
	assert( clientData.state )
	self.cl.pipeNetwork = clientData.pipeNetwork
	self.cl.state = clientData.state
	self.cl.showBlockVisualization = clientData.showBlockVisualization
end

function OilPump.client_onInteract( self, character, state )
	if state == true then
		self.network:sendToServer( "sv_n_toogle" )
	end
end

function OilPump.client_onUpdate( self, dt )

	-- Update pose anims
	self:cl_updatePoseAnims( dt )

	-- Update Uv Index frames
	self:cl_updateUvIndexFrames( dt )

	-- Update effects through pipes
	self.cl.pipeEffectPlayer:update( dt )

	-- Visualize block if a block is loaded
	if self.cl.state == PipeState.connected and self.cl.showBlockVisualization then
		local valid, gridPos, localNormal, worldPos, obj = self:constructionRayCast()
		if valid then
			local function countTerrain()
				if type(obj) == "Shape" then
					return obj:getBody():isDynamic()
				end
				return false
			end
			sm.visualization.setBlockVisualization(gridPos,
				sm.physics.sphereContactCount( worldPos, sm.construction.constants.subdivideRatio_2, countTerrain() ) > 0 or not sm.construction.validateLocalPosition( blk_cardboard, gridPos, localNormal, obj ),
				obj)
		end
	end
end

-- Events

function OilPump.cl_n_onOutgoingReload( self, data )

	local shapeList = {}
	for idx, shape in reverse_ipairs( data.shapesOnContainerPath ) do
		table.insert( shapeList, shape )
	end
	table.insert( shapeList, self.shape )

	self.cl.pipeEffectPlayer:pushShapeEffectTask( shapeList, data.item )

	self:cl_setOverrideUvIndexFrame( shapeList, PipeState.valid )
end

function OilPump.cl_n_onOutgoingFire( self, data )
	local shapeList = data.shapesOnContainerPath
	if shapeList then
		table.insert( shapeList, self.shape )
	end

	self:cl_setOverrideUvIndexFrame( shapeList, PipeState.valid )
	self:cl_setPoseAnimTask( "outgoingFire" )

	self.cl.vacuumEffect = sm.effect.createEffect( "Vacuumpipe - Blowout", self.interactable )
	self.cl.vacuumEffect:setOffsetRotation( sm.quat.angleAxis( math.pi*0.5, sm.vec3.new( 1, 0, 0 ) ) )
	self.cl.vacuumEffect:start()
end

function OilPump.cl_n_onIncomingFire( self, data )

	table.insert( data.shapesOnContainerPath, 1, self.shape )

	self.cl.pipeEffectPlayer:pushShapeEffectTask( data.shapesOnContainerPath, data.item )

	self:cl_setOverrideUvIndexFrame( data.shapesOnContainerPath, PipeState.valid )
	self:cl_setPoseAnimTask( "incomingFire" )

	self.cl.vacuumEffect = sm.effect.createEffect( "Vacuumpipe - Suction", self.interactable )
	self.cl.vacuumEffect:setOffsetRotation( sm.quat.angleAxis( math.pi*0.5, sm.vec3.new( 1, 0, 0 ) ) )
	self.cl.vacuumEffect:start()
end

function OilPump.cl_n_onError( self, data )
	self:cl_setOverrideUvIndexFrame( data.shapesOnContainerPath, PipeState.invalid )
end

-- State sets

function OilPump.cl_pushEffectTask( self, shapeList, effect )
	self.cl.pipeEffectPlayer:pushEffectTask( shapeList, effect )
end

function OilPump.cl_setOverrideUvIndexFrame( self, shapeList, state )
	local shapeMap = {}
	if shapeList then
		for _, shape in ipairs( shapeList ) do
			shapeMap[shape:getId()] = state
		end
	end
	self.cl.overrideUvFrameIndexTask = { shapeMap = shapeMap, state = state, progress = 0 }
end

function OilPump.cl_setPoseAnimTask( self, name )
	self.cl.poseAnimTask = { name = name, progress = 0 }
end

-- Updates

PoseCurves = {}
PoseCurves["outgoingFire"] = Curve()
PoseCurves["outgoingFire"]:init({{v=0.5, t=0.0},{v=1.0, t=0.1},{v=0.5, t=0.2},{v=0.0, t=0.3},{v=0.5, t=0.6}})

PoseCurves["incomingFire"] = Curve()
PoseCurves["incomingFire"]:init({{v=0.5, t=0.0},{v=0.0, t=0.1},{v=0.5, t=0.2},{v=1.0, t=0.3},{v=0.5, t=0.6}})

function OilPump.cl_updatePoseAnims( self, dt )

	if self.cl.poseAnimTask then

		self.cl.poseAnimTask.progress = self.cl.poseAnimTask.progress + dt

		local curve = PoseCurves[self.cl.poseAnimTask.name]
		if curve then
			self.shape:getInteractable():setPoseWeight( 0, curve:getValue( self.cl.poseAnimTask.progress ) )

			if self.cl.poseAnimTask.progress > curve:duration() then
				self.cl.poseAnimTask = nil
			end
		else
			self.cl.poseAnimTask = nil
		end
	end

end

local GlowCurve = Curve()
GlowCurve:init({{v=1.0, t=0.0}, {v=0.5, t=0.05}, {v=0.0, t=0.1}, {v=0.5, t=0.3}, {v=1.0, t=0.4}, {v=0.5, t=0.5}, {v=0.0, t=0.7}, {v=0.5, t=0.75}, {v=1.0, t=0.8}})

function OilPump.cl_updateUvIndexFrames( self, dt )

	local glowMultiplier = 1.0

	-- Events allow for overriding the uv index frames, time it out
	if self.cl.overrideUvFrameIndexTask then
		self.cl.overrideUvFrameIndexTask.progress = self.cl.overrideUvFrameIndexTask.progress + dt

		glowMultiplier = GlowCurve:getValue( self.cl.overrideUvFrameIndexTask.progress )

		if self.cl.overrideUvFrameIndexTask.progress > 0.1 then

			self.cl.overrideUvFrameIndexTask.change = true
		end

		if self.cl.overrideUvFrameIndexTask.progress > 0.7 then

			self.cl.overrideUvFrameIndexTask.change = false
		end

		if self.cl.overrideUvFrameIndexTask.progress > GlowCurve:duration() then

			self.cl.overrideUvFrameIndexTask = nil
		end
	end

	-- Light up vacuum
	local state = self.cl.state
	if self.cl.overrideUvFrameIndexTask and self.cl.overrideUvFrameIndexTask.change == true then
		state = self.cl.overrideUvFrameIndexTask.state
	end

	VacuumFrameIndexTable = {
    [PipeState.off] = 0,
    [PipeState.invalid] = 1,
    [PipeState.connected] = 3,
    [PipeState.valid] = 5
	}
	assert( state > 0 and state <= 4 )
	local vacuumFrameIndex = VacuumFrameIndexTable[state]
	self.interactable:setUvFrameIndex( vacuumFrameIndex )
	if self.cl.overrideUvFrameIndexTask then
		self.interactable:setGlowMultiplier( glowMultiplier )
	else
		self.interactable:setGlowMultiplier( 1.0 )
	end

	local function fnOverride( pipe )

		local state = pipe.state
		local glow = 1.0

		if self.cl.overrideUvFrameIndexTask then
			local overrideState = self.cl.overrideUvFrameIndexTask.shapeMap[pipe.shape:getId()]
			if overrideState then
				if self.cl.overrideUvFrameIndexTask.change == true then
					state = overrideState
				end
				glow = glowMultiplier
			end
		end

		return state, glow
	end

	-- Light up pipes
	LightUpPipes( self.cl.pipeNetwork, fnOverride )
end