#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <smlib>
#include <vphysics>
#include <tf2utils>

#tryinclude <tf2hudmsg>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "22w23b"

public Plugin myinfo = {
	name = "[TF2] Toss Buildings",
	description = "Use your reload button to toss carried buildings",
	author = "reBane, zen",
	version = PLUGIN_VERSION,
	url = "N/A",
};

#define MASK_BUILDINGS MASK_PLAYERSOLID_BRUSHONLY

enum {
	BUILDING_INVALID_OBJECT = ((1<<8)-1), // s8_t:-1
	BUILDING_DISPENSER = 0,
	BUILDING_TELEPORTER,
	BUILDING_SENTRYGUN,
	BUILDING_ATTACHMENT_SAPPER,
}
enum {
	BS_IDLE,
	BS_SELECTING,
	BS_PLACING,
	BS_PLACING_INVALID,
};

enum struct AirbornData {
	int physObject;
	int building;
	float yaw;
	bool newBuild;
}

bool g_bPlayerThrow[MAXPLAYERS+1];
Handle sdk_fnStartBuilding;
//Handle sdk_fnIsPlacementPosValid;
ArrayList g_aAirbornObjects;
float g_flClientLastBeep[MAXPLAYERS+1];
float g_flClientLastNotif[MAXPLAYERS+1]; //for hud notifs, as those make noise

#define TBLOCK_WFP (1<<0)
int g_iBlockFlags;
#define TBFLAG_DISPENSER (1<<BUILDING_DISPENSER)
#define TBFLAG_TELEPORTER (1<<BUILDING_TELEPORTER)
#define TBFLAG_SENTRYGUN (1<<BUILDING_SENTRYGUN)
int g_iBlockTypes;
float g_flThrowForce;

GlobalForward g_fwdToss, g_fwdTossPost, g_fwdLanded;

bool g_bDepHudMsg; //for fancy messages

public void OnPluginStart() {
	GameData data = new GameData("tbobj.games");
	if (data == null)
		SetFailState("Could not load gamedata: File is missing");
	
	StartPrepSDKCall(SDKCall_Entity); //weapon
	PrepSDKCall_SetFromConf(data, SDKConf_Signature, "StartBuilding");
	if ((sdk_fnStartBuilding = EndPrepSDKCall())==null)
		SetFailState("Could not load gamedata: StartBuilding Signature missing or outdated");
	
//	StartPrepSDKCall(SDKCall_Entity); //building
//	PrepSDKCall_SetFromConf(data, SDKConf_Virtual, "IsPlacementPosValid");
//	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
//	if ((sdk_fnIsPlacementPosValid = EndPrepSDKCall())==null)
//		SetFailState("Could not load gamedata: IsPlacementPosValid Offset missing or outdated");
	
	delete data;
	
	ConVar cvarTypes = CreateConVar("sm_toss_building_types", "dispenser teleporter sentrygun", "Space separated list of building names that can be tossed: Dispenser Teleporter Sentrygun");
	ConVar cvarForce = CreateConVar("sm_toss_building_force", "520", "Base force to use when throwing buildings", _, true, 100.0, true, 10000.0);
	cvarTypes.AddChangeHook(OnTossBuildingTypesChanged);
	cvarForce.AddChangeHook(OnTossBuildingForceChanged);
	//always load values on startup
	char buffer[128];
	cvarTypes.GetString(buffer, sizeof(buffer));
	OnTossBuildingTypesChanged(cvarTypes, buffer, buffer);
	OnTossBuildingForceChanged(cvarForce, NULL_STRING, NULL_STRING);//doesn't use passed string
	//load actual values from config
	AutoExecConfig();
	
	ConVar cvarVersion = CreateConVar("sm_toss_building_version", PLUGIN_VERSION, "", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	cvarVersion.AddChangeHook(LockConVar);
	cvarVersion.SetString(PLUGIN_VERSION);
	delete cvarVersion;
	
	HookEvent("player_carryobject", OnPlayerCarryObject);
	HookEvent("player_builtobject", OnPlayerBuiltObject);
	HookEvent("player_dropobject", OnPlayerBuiltObject);
	
	g_aAirbornObjects = new ArrayList(sizeof(AirbornData)); //phys parent, object, thrown angle (yaw)
	
	//let other plugins integrate :)
	g_fwdToss = CreateGlobalForward("TF2_OnTossBuilding", ET_Event, Param_Cell, Param_Cell, Param_Cell);
	g_fwdTossPost = CreateGlobalForward("TF2_OnTossBuildingPost", ET_Ignore, Param_Cell, Param_Cell, Param_Cell);
	g_fwdLanded = CreateGlobalForward("TF2_OnBuildingLanded", ET_Ignore, Param_Cell, Param_Cell);
}
public void LockConVar(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (!StrEqual(newValue, PLUGIN_VERSION)) convar.SetString(PLUGIN_VERSION);
}
public void OnTossBuildingTypesChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (StrContains(newValue, "dispenser", false)>=0) {
		g_iBlockTypes &=~ TBFLAG_DISPENSER;
	} else {
		g_iBlockTypes |= TBFLAG_DISPENSER;
	}
	if (StrContains(newValue, "teleporter", false)>=0) {
		g_iBlockTypes &=~ TBFLAG_TELEPORTER;
	} else {
		g_iBlockTypes |= TBFLAG_TELEPORTER;
	}
	if (StrContains(newValue, "sentry", false)>=0) {
		g_iBlockTypes &=~ TBFLAG_SENTRYGUN;
	} else {
		g_iBlockTypes |= TBFLAG_SENTRYGUN;
	}
}
public void OnTossBuildingForceChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_flThrowForce = convar.FloatValue;
}

public void OnMapStart() {
	g_aAirbornObjects.Clear();
	CreateTimer(0.1, Timer_PlaceBuildings, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);	
}

public void OnClientDisconnect(int client) {
	g_bPlayerThrow[client] = false;
	g_flClientLastBeep[client] = 0.0;
	g_flClientLastNotif[client] = 0.0;
}

public void OnAllPluginsLoaded() {
	g_bDepHudMsg = LibraryExists("tf2hudmsg");
}
public void OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "tf2hudmsg")) g_bDepHudMsg = true;
}
public void OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "tf2hudmsg")) g_bDepHudMsg = false;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
	if (!(1<=client<=MaxClients) || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Continue;
	if ((buttons & IN_RELOAD)!=0 && !g_bPlayerThrow[client]) {
		if ( IsThrowBlocked(client) ) {
			if (GetClientTime(client) - g_flClientLastNotif[client] >= 1.0) {
				g_flClientLastNotif[client] = GetClientTime(client);
				HudNotify(client, 0, "You can't toss this building");
			}
		} else {
			//trigger force build and throw on Reload
			g_bPlayerThrow[client] = true;
			if (CheckThrowPos(client)) StartBuilding(client);
			g_bPlayerThrow[client] = false;
		}
	}
	return Plugin_Continue;
}

public void OnPlayerCarryObject(Event event, const char[] name, bool dontBroadcast) {
	int owner = GetClientOfUserId(event.GetInt("userid"));
	int objecttype = event.GetInt("object");
	int building = event.GetInt("index");
	if ((BUILDING_DISPENSER <= objecttype <= BUILDING_SENTRYGUN) && IsClientInGame(owner) && IsValidEdict(building) && ( g_iBlockTypes&(1<<objecttype) )==0) {
		//small sanity check: was this building picked up while flagged as thrown?
		if (g_aAirbornObjects.FindValue(EntIndexToEntRef(building), AirbornData::building) != -1) {
			//visually destory the building, the check timer will clean up the phys prop later
			SetVariantInt(1000);
			AcceptEntityInput(building, "RemoveHealth");
		} else {
			HudNotify(owner, _, "Press [RELOAD] to toss the building");
		}
	}
}
public void OnPlayerBuiltObject(Event event, const char[] name, bool dontBroadcast) {
	int owner = GetClientOfUserId(event.GetInt("userid"));
	int objecttype = event.GetInt("object");
	int building = event.GetInt("index");
	
	if ((BUILDING_DISPENSER <= objecttype <= BUILDING_SENTRYGUN) && IsClientInGame(owner) && IsValidEdict(building) && g_bPlayerThrow[owner]) {
		g_bPlayerThrow[owner] = false;
		RequestFrame(ThrowBuilding,EntIndexToEntRef(building));
	}
}

public void TF2_OnWaitingForPlayersStart() {
	g_iBlockFlags |= TBLOCK_WFP;
}
public void TF2_OnWaitingForPlayersEnd() {
	g_iBlockFlags &=~ TBLOCK_WFP;
}

public Action Timer_PlaceBuildings(Handle timer) {
	ValidateThrown();
}

public bool TEF_HitSelfFilter(int entity, int contentsMask, any data) {
	return entity != data;
}
public bool TEF_HitSelfFilterPassClients(int entity, int contentsMask, any data) {
	return entity > MaxClients && entity != data;
}
public bool TEF_HitThrownFilter(int entity, int contentsMask, any data) {
	if (!entity) return contentsMask != CONTENTS_EMPTY;
	AirbornData edicts;
	g_aAirbornObjects.GetArray(data,edicts);
	int entref = EntIndexToEntRef(entity);
	return entity > MaxClients && entref != edicts.physObject && entref != edicts.building;
}


public void ThrowBuilding(any buildref) {
	int building = EntRefToEntIndex(buildref);
	if (building == INVALID_ENT_REFERENCE) return;
	int owner = GetEntPropEnt(building, Prop_Send, "m_hBuilder");
	if (owner < 1 || owner > MaxClients || !IsClientInGame(owner)) return;
	int type = GetEntProp(building, Prop_Send, "m_iObjectType");
	
	if (g_fwdToss.FunctionCount>0) {
		Action result;
		Call_StartForward(g_fwdToss);
		Call_PushCell(building);
		Call_PushCell(type);
		Call_PushCell(owner);
		if (Call_Finish(result) != SP_ERROR_NONE || result != Plugin_Continue) {
			return;
		}
	}
	
	float eyes[3];
	float origin[3];
	float angles[3];
	float fwd[3];
	float velocity[3];
	GetClientEyePosition(owner, origin);
	eyes = origin;
	//set origin in front of player
	GetClientEyeAngles(owner, angles);
	angles[0]=angles[2]=0.0;
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 64.0);
	AddVectors(origin, fwd, origin);
	//get angles/velocity
	GetClientEyeAngles(owner, angles);
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, g_flThrowForce);
	fwd[2] += (g_flThrowForce/3.25);//bit more archy
	Entity_GetAbsVelocity(owner, velocity);
	AddVectors(velocity, fwd, velocity);
	
	int phys = CreateEntityByName("prop_physics_multiplayer");
	if (phys == INVALID_ENT_REFERENCE) return;
	
	char buffer[PLATFORM_MAX_PATH];
	switch (type) {
		case BUILDING_SENTRYGUN: DispatchKeyValue(phys, "model", "models/buildables/sentry1.mdl");
		case BUILDING_DISPENSER: DispatchKeyValue(phys, "model", "models/buildables/dispenser_light.mdl");
		case BUILDING_TELEPORTER: DispatchKeyValue(phys, "model", "models/buildables/teleporter_light.mdl");
	}
	DispatchKeyValue(phys, "physicsmode", "2"); //don't push (hard collide) with player (1), but get pushed (soft collide)
	DispatchKeyValueVector(phys, "origin", origin);
	DispatchKeyValueVector(phys, "angles", angles);
	Format(buffer, sizeof(buffer), "%i", GetEntProp(building, Prop_Send, "m_nSkin"));
	DispatchKeyValue(phys, "skin", buffer);
	if (GetEntProp(building, Prop_Send, "m_bDisposableBuilding")) buffer = "0.66";
	else if (GetEntProp(building, Prop_Send, "m_bMiniBuilding")) buffer = "0.75";
	else buffer = "1.0";
	DispatchKeyValue(phys, "modelscale", buffer);//mini sentries are .75
//	DispatchKeyValue(phys, "solid", "2"); //2 bbox 6 vphysics
	if (!DispatchSpawn(phys)) {
		PrintToChat(owner, "Failed to spawn physics prop");
		return;
	}
	ActivateEntity(phys);
	SetEntityRenderMode(phys, RENDER_NORMAL); //why is it sometimes not rendered?
	
	//set properties to prevent the building from progressing construction
	bool newlyBuilt = GetEntProp(building, Prop_Send, "m_bCarryDeploy")==0;
	SetEntProp(building, Prop_Send, "m_bCarried", 1);
	SetEntProp(building, Prop_Send, "m_bBuilding", 0);
	if (newlyBuilt) { //set health above 66% to suppress the client side alert
		int maxhp = TF2Util_GetEntityMaxHealth(building);
		Entity_SetHealth(building, maxhp);
	}
	//put it in a state similar to carried for collision/rendering
	Entity_SetSolidFlags(building, FSOLID_NOT_SOLID);
	SetEntityRenderMode(building, RENDER_NONE);
	TeleportEntity(building, origin, NULL_VECTOR, NULL_VECTOR);
	//parent to phys and throw
	SetVariantString("!activator");
	AcceptEntityInput(building, "SetParent", phys);
	Phys_ApplyForceCenter(phys, velocity);// works best
	
	AirbornData onade;
	onade.physObject=EntIndexToEntRef(phys);
	onade.building=EntIndexToEntRef(building);
	onade.yaw=angles[1];
	onade.newBuild=newlyBuilt;
	g_aAirbornObjects.PushArray(onade);
	
	if (g_fwdTossPost.FunctionCount>0) {
		Call_StartForward(g_fwdToss);
		Call_PushCell(building);
		Call_PushCell(type);
		Call_PushCell(owner);
		Call_Finish();
	}
}

void ValidateThrown() {
	for (int i=g_aAirbornObjects.Length-1; i>=0; i--) {
		AirbornData data;
		g_aAirbornObjects.GetArray(i,data);
		int phys = EntRefToEntIndex(data.physObject);
		int obj = EntRefToEntIndex(data.building);
		//if at least one of the entities went away, something went wrong
		// -> remove and continue
		if (!IsValidEdict(phys)) {
			if (IsValidEdict(obj)) AcceptEntityInput(obj, "Kill");
			g_aAirbornObjects.Erase(i);
			PrintToServer("Phys entity invalid");
			continue;
		} else if (!IsValidEdict(obj)) {
			if (IsValidEdict(phys)) AcceptEntityInput(phys, "Kill");
			g_aAirbornObjects.Erase(i);
			PrintToServer("Building entity invalid");
			continue;
		}
		
		float mins[3],maxs[3],pos[3],vec[3];
		//get a "disc" for collision
		Entity_GetMinSize(phys,mins);
		Entity_GetMaxSize(phys,maxs);
		//find local center point, as mins/maxs is for the AABB
		AddVectors(mins,maxs,vec);
		ScaleVector(vec,0.5);
		//using this call we can get the world center
		Phys_LocalToWorld(phys, pos, vec);
		//ray end
		//teles are wider than high, find the largest dimension for ground testing
		SubtractVectors(maxs,mins,vec);
		float maxdim = vec[0];
		if (vec[1] > maxdim) maxdim = vec[1];
		if (vec[2] > maxdim) maxdim = vec[2];
		//from pos, send the ray over half maxdim down, so we can always find ground
		vec = pos;
		vec[2] -= (maxdim)*0.55;
		//make trace hull discy
		mins[2] = 0.0; //7 up from bottom
		maxs[2] = 1.0; //8 up from bottom
		//scan
//		if (TR_PointOutsideWorld(pos)) {
//			AcceptEntityInput(phys, "Kill");
//			AcceptEntityInput(obj, "Kill");
//			g_aAirbornObjects.Erase(i);
//			PrintToServer("Building fell out of world, destroying!");
//			continue;
//		}
		Handle trace = TR_TraceHullFilterEx(pos,vec, mins,maxs, MASK_BUILDINGS, TEF_HitThrownFilter, i);
		if (TR_DidHit(trace)) {
			TR_GetEndPosition(pos, trace);
			TR_GetPlaneNormal(trace, vec); //vanilla is not snapping to this
			delete trace;
		} else {
			delete trace;
			continue;
		}
		
		//check surface slope
		float up[3]; up[2]=1.0;
		float slope = ArcCosine( GetVectorDotProduct(vec, up) ) * 180.0/3.1415927;
		if (slope > 35.0) {
			//this slope is too steep to place a building. let it roll
			continue;
		}
		//construct angles by random direction, using standard right to get propper forward
		float angles[3];
		angles[1]=data.yaw;
		//clear parent
		AcceptEntityInput(obj, "ClearParent");
		//fix building
		float zeros[3];
		TeleportEntity(obj, pos, angles, zeros); //use 0-velocity to calm down bouncyness
		//restore other props: get it out of peudo carry state 
		SetEntProp(obj, Prop_Send, "m_bBuilding", 1);
		SetEntProp(obj, Prop_Send, "m_bCarried", 0);
		if (data.newBuild) Entity_SetHealth(obj,1,_,false);
		Entity_RemoveSolidFlags(obj, FSOLID_NOT_SOLID);
		SetEntityRenderMode(obj, RENDER_NORMAL);
		//check valid
		CreateTimer(0.1, ValidateBuilding, EntIndexToEntRef(obj), TIMER_FLAG_NO_MAPCHANGE);
		//we no longer need the "carrier"
		AcceptEntityInput(phys, "Kill");
		g_aAirbornObjects.Erase(i);
	}
}

/** Invalid preconditions PASS! as this is used for message printing only */
bool IsThrowBlocked(int client) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return false;
	int weapon = Client_GetActiveWeapon(client);
	int item = IsValidEdict(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	if (item != 28)
		return false; //require builder
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return false; //currently not placing
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		RequestFrame(FixNoObjectBeingHeld, GetClientUserId(client));
		return false; //no object being buil!?
	}
	int type = GetEntProp(objectToBuild, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return false; //supported buildings, not always correct on weapon_builder
	
	return ( g_iBlockTypes&(1<<type) )!=0;
}

bool CheckThrowPos(int client) {
	if (g_iBlockFlags != 0) return false;
	float eyes[3];
	float origin[3];
	float angles[3];
	float fwd[3];
	GetClientEyePosition(client, origin);
	eyes = origin;
	//set origin in front of player
	GetClientEyeAngles(client, angles);
	angles[0]=angles[2]=0.0;
	GetAngleVectors(angles, fwd, NULL_VECTOR, NULL_VECTOR);
	ScaleVector(fwd, 64.0);
	AddVectors(origin, fwd, origin);
	//ensure we see the target
	Handle trace = TR_TraceRayFilterEx(eyes, origin, MASK_PLAYERSOLID, RayType_EndPoint, TEF_HitSelfFilterPassClients, client);
	bool hit = TR_DidHit(trace);
	delete trace;
	//can't see throw point (prevent through walls)? make noise
	if (hit) Beep(client);
	return !hit;
}

int StartBuilding(int client) {
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
		return -1;
	int weapon = Client_GetActiveWeapon(client);
	int item = IsValidEdict(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	if (item != 28)
		return -1; //require builder
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return -1; //currently not placing
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		RequestFrame(FixNoObjectBeingHeld, GetClientUserId(client));
		return -1; //no object being buil!?
	}
	int type = GetEntProp(objectToBuild, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return -1; //supported buildings, not always correct on weapon_builder
	
	SetEntPropEnt(weapon, Prop_Send, "m_hOwner", client);
	SetEntProp(weapon, Prop_Send, "m_iBuildState", BS_PLACING); //if placing_invalid
	SDKCall(sdk_fnStartBuilding, weapon);
	return objectToBuild;
}

void FixNoObjectBeingHeld(int user) {
	//go through all validation again
	int client = GetClientOfUserId(user);
	if (!client || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	int weapon = Client_GetActiveWeapon(client);
	int item = IsValidEdict(weapon) ? GetEntProp(weapon, Prop_Send, "m_iItemDefinitionIndex") : -1;
	if (item != 28)
		return; //weapon switched
	int type = GetEntProp(weapon, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return; //unsupported building
	int bstate = GetEntProp(weapon, Prop_Send, "m_iBuildState");
	if (bstate != BS_PLACING && bstate != BS_PLACING_INVALID)
		return; //not in a glitched state
	int objectToBuild = GetEntPropEnt(weapon, Prop_Send, "m_hObjectBeingBuilt");
	if (objectToBuild == INVALID_ENT_REFERENCE) {
		//holding empty box, try to find another weapon to switch to
		for (int i=2;i>=0;i-=1) {
			weapon = Client_GetWeaponBySlot(client, i);
			if (weapon != INVALID_ENT_REFERENCE) {
				Client_SetActiveWeapon(client, weapon);
			}
		}
	}
}

//crashes, idk why
//bool IsPlacementPosValid(int building) {
//	char classname[64];
//	if (!IsValidEdict(building)
//	|| !GetEntityClassname(building, classname, sizeof(classname))
//	|| !(StrEqual(classname, "obj_sentrygun")
//	   || StrEqual(classname, "obj_teleporter")
//	   || StrEqual(classname, "obj_dispenser")
//	   ))
//		ThrowError("Entity is not a building");
//	return SDKCall(sdk_fnIsPlacementPosValid, building);
//}

public Action ValidateBuilding(Handle timer, any building) {
	int obj = EntRefToEntIndex(building);
	if (obj == INVALID_ENT_REFERENCE) return Plugin_Stop;
	
	float mins[3],maxs[3],origin[3];
	float four[3];
	four[0]=four[1]=four[2]=4.0;
	Entity_GetAbsOrigin(obj,origin);
	Entity_GetMinSize(obj,mins);
	Entity_GetMaxSize(obj,maxs);
	AddVectors(mins,four,mins);
	SubtractVectors(maxs,four,maxs);
	
	Handle trace = TR_TraceHullFilterEx(origin, origin, mins, maxs, MASK_BUILDINGS, TEF_HitSelfFilter, obj);
	bool invalid = TR_DidHit(trace) || TF2Util_IsPointInRespawnRoom(origin, obj);
	if (TR_DidHit(trace)) PrintToServer("Collided with %i", TR_GetEntityIndex(trace));
	delete trace;
	if (invalid) {
		SetVariantInt(1000);
		AcceptEntityInput(obj, "RemoveHealth");
	}
	if (g_fwdLanded.FunctionCount>0) {
		Call_StartForward(g_fwdLanded);
		Call_PushCell(building);
		Call_PushCell(!invalid);
		Call_Finish();
	}
	return Plugin_Stop;
}

void Beep(int client) {
	if (!(1<=client<=MaxClients) || !IsClientInGame(client) || IsFakeClient(client)) return;
	if (GetClientTime(client) - g_flClientLastBeep[client] >= 1.0) {
		g_flClientLastBeep[client] = GetClientTime(client);
		EmitSoundToClient(client, "common/wpn_denyselect.wav");//should aready be precached by game
	}
}

void HudNotify(int client, int color=-1, const char[] format, any ...) {
	char buffer[128];
	VFormat(buffer, sizeof(buffer), format, 3);
#if defined _inc_tf2hudmsg
	if (g_bDepHudMsg)
//		TF2_HudNotificationCustom(client, "obj_status_icon_wrench", TFTeam_Red, _, "%s", buffer);
		TF2_HudNotificationCustom(client, "ico_build", color, _, "%s", buffer);
	else
		PrintHintText(client, "%s", buffer);
#else
	PrintHintText(client, "%s", buffer);
#endif
}