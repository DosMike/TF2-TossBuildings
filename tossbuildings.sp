#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <smlib>
#include <vphysics>
#include <tf2utils>

#undef REQUIRE_PLUGIN
#tryinclude <tf2hudmsg>
 #if !defined _inc_tf2hudmsg
  #warning Compiling without TF2hudmsg
 #endif
#tryinclude <tf_custom_attributes>
 #if !defined __tf_custom_attributes_included
  #warning Compiling without TF Custom Attributes
 #endif
#tryinclude <tf2attributes>
 #if !defined _tf2attributes_included
  #warning Compiling without TF2Attributes
 #endif
#define REQUIRE_PLUGIN

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "22w47a"

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
	int upright;
	float yaw;
	bool newBuild;
	float prevPos[3];
}

bool g_bPlayerThrow[MAXPLAYERS+1];
Handle sdk_fnStartBuilding;
ArrayList g_aAirbornObjects;
float g_flClientLastBeep[MAXPLAYERS+1];
float g_flClientLastNotif[MAXPLAYERS+1]; //for hud notifs, as those make noise

#define TBLOCK_WFP (1<<0)
int g_iBlockFlags;
#define TBFLAG_DISPENSER (1<<BUILDING_DISPENSER)
#define TBFLAG_TELEPORTER (1<<BUILDING_TELEPORTER)
#define TBFLAG_SENTRYGUN (1<<BUILDING_SENTRYGUN)
int g_iAllowTypes;
int g_iNoOOBTypes;
float g_flThrowForce;
float g_flUprightForce;
int g_iBuildingModelIndexLV1[3];
bool g_bAllowStacking;

GlobalForward g_fwdToss, g_fwdTossPost, g_fwdLanded;

bool g_bDepHudMsg; //for fancy messages
bool g_bDepAttribHooks; //for hidden dev attributes, works better than custom attributes
bool g_bDepCustomAttribs; //for custom attributes / custom weapons integration

public void OnPluginStart() {
	GameData data = new GameData("tbobj.games");
	if (data == null)
		SetFailState("Could not load gamedata: File is missing");
	
	StartPrepSDKCall(SDKCall_Entity); //weapon
	PrepSDKCall_SetFromConf(data, SDKConf_Signature, "CTFWeaponBuilder::StartBuilding()");
	if ((sdk_fnStartBuilding = EndPrepSDKCall())==null)
		SetFailState("Could not load gamedata: CTFWeaponBuilder::StartBuilding() Signature missing or outdated");
	
	delete data;
	
	ConVar cvarTypes = CreateConVar("sm_toss_building_types", "dispenser teleporter sentrygun", "Space separated list of building names that can be tossed: Dispenser Teleporter Sentrygun");
	ConVar cvarForce = CreateConVar("sm_toss_building_force", "520", "Base force to use when throwing buildings", _, true, 100.0, true, 10000.0);
	ConVar cvarUpright = CreateConVar("sm_toss_building_upright", "0", "How much to pull the prop upright in degree/sec. Will somethwat prevent the prop twriling, 0 to disable", _, true, 0.0, true, 3600.0);
	ConVar cvarOOB = CreateConVar("sm_toss_building_breakoob", "dispenser teleporter sentrygun", "Space separated list of building names that break out of bounds: Dispenser Teleporter Sentrygun");
	ConVar cvarStack = CreateConVar("sm_toss_building_allowstacking", "0", "Set to 1 to allow tossing builings on top of each other", _, true, 0.0, true, 1.0);
	cvarTypes.AddChangeHook(OnTossBuildingTypesChanged);
	cvarForce.AddChangeHook(OnTossBuildingForceChanged);
	cvarUpright.AddChangeHook(OnTossBuildingUprightChanged);
	cvarOOB.AddChangeHook(OnTossBuildingOOBChanged);
	cvarStack.AddChangeHook(OnTossBuildingStackingChanged);
	//always load values on startup
	char buffer[128];
	cvarTypes.GetString(buffer, sizeof(buffer));
	OnTossBuildingTypesChanged(cvarTypes, buffer, buffer);
	OnTossBuildingForceChanged(cvarForce, NULL_STRING, NULL_STRING);//doesn't use passed string
	OnTossBuildingUprightChanged(cvarUpright, NULL_STRING, NULL_STRING);//doesn't use passed string
	cvarOOB.GetString(buffer, sizeof(buffer));
	OnTossBuildingOOBChanged(cvarOOB, buffer, buffer);
	OnTossBuildingStackingChanged(cvarStack, NULL_STRING, NULL_STRING);//doesn't use passed string
	//load actual values from config
	AutoExecConfig();
	delete cvarTypes;
	delete cvarForce;
	delete cvarUpright;
	delete cvarOOB;
	delete cvarStack;
	
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
	_ParseTypesTo(g_iAllowTypes, newValue);
}
public void OnTossBuildingForceChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_flThrowForce = convar.FloatValue;
}
public void OnTossBuildingOOBChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	_ParseTypesTo(g_iNoOOBTypes, newValue);
}
public void OnTossBuildingUprightChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_flUprightForce = convar.FloatValue;
}
public void OnTossBuildingStackingChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	g_bAllowStacking = convar.BoolValue;
}
static void _ParseTypesTo(int& value, const char[] typesString) {
	if (StrContains(typesString, "dispenser", false)>=0) {
		value |= TBFLAG_DISPENSER;
	} else {
		value &=~ TBFLAG_DISPENSER;
	}
	if (StrContains(typesString, "teleporter", false)>=0) {
		value |= TBFLAG_TELEPORTER;
	} else {
		value &=~ TBFLAG_TELEPORTER;
	}
	if (StrContains(typesString, "sentry", false)>=0) {
		value |= TBFLAG_SENTRYGUN;
	} else {
		value &=~ TBFLAG_SENTRYGUN;
	}
}

public void OnMapStart() {
	g_aAirbornObjects.Clear();
	CreateTimer(0.1, Timer_PlaceBuildings, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);	
	
	for (int i=0;i<3;i++) {
		char buffer[PLATFORM_MAX_PATH];
		GetModelForBuilding(i, buffer, sizeof(buffer));
		if ((g_iBuildingModelIndexLV1[i] = PrecacheModel(buffer, true))==0)
			ThrowError("Could not precache building model for type %i", i);
	}
}

public void OnClientDisconnect(int client) {
	g_bPlayerThrow[client] = false;
	g_flClientLastBeep[client] = 0.0;
	g_flClientLastNotif[client] = 0.0;
}

public void OnAllPluginsLoaded() {
	g_bDepHudMsg = LibraryExists("tf2hudmsg");
	g_bDepCustomAttribs = LibraryExists("tf2custattr");
	g_bDepAttribHooks = LibraryExists("tf2attributes");
}
public void OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "tf2hudmsg")) g_bDepHudMsg = true;
	else if (StrEqual(name, "tf2custattr")) g_bDepCustomAttribs = true;
	else if (StrEqual(name, "tf2attributes")) g_bDepAttribHooks = true;
}
public void OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "tf2hudmsg")) g_bDepHudMsg = false;
	else if (StrEqual(name, "tf2custattr")) g_bDepCustomAttribs = false;
	else if (StrEqual(name, "tf2attributes")) g_bDepAttribHooks = false;
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
	if ((BUILDING_DISPENSER <= objecttype <= BUILDING_SENTRYGUN) && IsClientInGame(owner) && IsValidEdict(building) && ( g_iAllowTypes&(1<<objecttype) )!=0) {
		//small sanity check: was this building picked up while flagged as thrown?
		if (g_aAirbornObjects.FindValue(EntIndexToEntRef(building), AirbornData::building) != -1) {
			//visually destory the building, the check timer will clean up the phys prop later
			BreakBuilding(building);
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
	return Plugin_Continue;
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
	angles[0] = angles[2] = 0.0; //upright angle = 0.0 yaw 0.0
	
	//double up the CheckThrowPos trace, since we're a tick later
	TR_TraceRayFilter(eyes, origin, MASK_PLAYERSOLID, RayType_EndPoint, TEF_HitSelfFilterPassClients, owner);
	if (TR_DidHit()) {
		// the building is already going up, we need to either handle the refund or break the building
		BreakBuilding(building);
		return;
	}
	
	int phys = CreateEntityByName("prop_physics_multiplayer");
	if (phys == INVALID_ENT_REFERENCE) return;
	
	char targetName[24];
	Format(targetName, sizeof(targetName), "physbuilding_%08X", EntIndexToEntRef(phys));
	char buffer[PLATFORM_MAX_PATH];
	GetModelForBuilding(type, buffer, sizeof(buffer));
	DispatchKeyValue(phys, "targetname", targetName);
	DispatchKeyValue(phys, "model", buffer);
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
//	Entity_SetCollisionGroup(phys, COLLISION_GROUP_DEBRIS_TRIGGER);
	SetEntityRenderMode(phys, RENDER_NORMAL); //why is it sometimes not rendered?
	
	int angleMgr = INVALID_ENT_REFERENCE;
	if (g_flUprightForce > 0.01) {
		angleMgr = CreateEntityByName("phys_keepupright");
		if (angleMgr != INVALID_ENT_REFERENCE) {
			DispatchKeyValue(angleMgr, "attach1", targetName);
			DispatchKeyValueFloat(angleMgr, "angularlimit", g_flUprightForce);
			DispatchKeyValueVector(angleMgr, "angles", angles);
			if (!DispatchSpawn(angleMgr))
				//oops; edict should go away on it's own
				angleMgr = INVALID_ENT_REFERENCE;
			else {
				ActivateEntity(angleMgr);
				AcceptEntityInput(angleMgr, "TurnOn");
			}
		}
	}
	
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
	onade.upright= (angleMgr != INVALID_ENT_REFERENCE) ? EntIndexToEntRef(angleMgr) : INVALID_ENT_REFERENCE;
	onade.yaw=angles[1];
	onade.newBuild=newlyBuilt;
	onade.prevPos=origin;
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
		int angMgr = (data.upright != INVALID_ENT_REFERENCE) ? EntRefToEntIndex(data.upright) : INVALID_ENT_REFERENCE;
		//if at least one of the entities went away, something went wrong
		// -> remove and continue
		if (!IsValidEdict(phys)) {
			if (IsValidEdict(angMgr)) AcceptEntityInput(angMgr, "Kill");
			if (IsValidEdict(obj)) BreakBuilding(obj);
			g_aAirbornObjects.Erase(i);
			PrintToServer("Phys entity invalid");
			continue;
		} else if (!IsValidEdict(obj)) {
			if (IsValidEdict(angMgr)) AcceptEntityInput(angMgr, "Kill");
			if (IsValidEdict(phys)) AcceptEntityInput(phys, "Kill");
			g_aAirbornObjects.Erase(i);
			PrintToServer("Building entity invalid");
			continue;
		}
		int type = GetEntProp(obj, Prop_Send, "m_iObjectType");
		
		float mins[3],maxs[3],pos[3],vec[3];
		//get bounds for collision
		Entity_GetMinSize(obj,mins);
		Entity_GetMaxSize(obj,maxs);
		//find local center point, as mins/maxs is for the AABB
		AddVectors(mins,maxs,vec);
		ScaleVector(vec,0.5);
		//using this call we can get the world center
		Phys_LocalToWorld(obj, pos, vec);
		//check for playerclips
		if (BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN && (g_iNoOOBTypes & (1<<type))!=0 ) {
			TR_TraceRayFilter(data.prevPos, pos, CONTENTS_PLAYERCLIP, RayType_EndPoint, TEF_HitThrownFilter, i);
			if (TR_DidHit()) {
				BreakBuilding(obj);
				if (IsValidEdict(angMgr)) AcceptEntityInput(angMgr, "Kill");
				AcceptEntityInput(phys, "Kill");
				g_aAirbornObjects.Erase(i);
				continue;
			}
		}
		data.prevPos = pos;
		g_aAirbornObjects.SetArray(i, data); //update position vector
		//get ray end
		//teles are wider than high, find the largest dimension for ground testing
		SubtractVectors(maxs,mins,vec);
		float offz = vec[2] * 0.55;
		if (offz < 24.0) offz = 24.0;
		//from pos, send the ray over half maxdim down, so we can always find ground
		vec = pos;
		vec[2] -= offz;
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
		TR_TraceHullFilter(pos,vec, mins,maxs, MASK_BUILDINGS, TEF_HitThrownFilter, i);
		if (!TR_DidHit()) {
			continue;
		}
		TR_GetEndPosition(pos);
		TR_GetPlaneNormal(INVALID_HANDLE, vec); //vanilla is not snapping to this
		//check if we are placed on top of another building
		if (!g_bAllowStacking) {
			int landedOn = TR_GetEntityIndex();
			if (landedOn > 0 && IsValidEdict(landedOn) && HasEntProp(landedOn, Prop_Send, "m_iObjectType")) {
				//validate the classname prefix. they all start with obj_, so no need to read more chars
				char classname[5];
				GetEntityClassname(landedOn, classname, sizeof(classname));
				if (StrEqual(classname, "obj_")) {
					//we actually landed on another building, die please
					BreakBuilding(obj);
					if (IsValidEdict(angMgr)) AcceptEntityInput(angMgr, "Kill");
					AcceptEntityInput(phys, "Kill");
					g_aAirbornObjects.Erase(i);
					continue;
				}
			}
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
		SetEntProp(obj, Prop_Send, "m_bCarryDeploy", data.newBuild?0:1);
		if (data.newBuild) {
			Entity_SetHealth(obj,1,_,false);
		} else if (GetEntProp(obj, Prop_Send, "m_iUpgradeLevel") > 1) {
			//properly appear as level 1 building after placement
			Entity_SetModelIndex(obj, g_iBuildingModelIndexLV1[type]);
			SetEntProp(obj, Prop_Send, "m_iUpgradeLevel", 1);
			//the sequence would have to be restarted as well, but i couldn't find any way to do that
		}
		Entity_RemoveSolidFlags(obj, FSOLID_NOT_SOLID);
		SetEntityRenderMode(obj, RENDER_NORMAL);
		//check valid
		CreateTimer(0.1, ValidateBuilding, EntIndexToEntRef(obj), TIMER_FLAG_NO_MAPCHANGE);
		//we no longer need the "carrier"
		if (IsValidEdict(angMgr)) AcceptEntityInput(angMgr, "Kill");
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
		return false; //no object being built!?
	}
	int type = GetEntProp(objectToBuild, Prop_Send, "m_iObjectType");
	if (!(BUILDING_DISPENSER <= type <= BUILDING_SENTRYGUN))
		return false; //supported buildings, not always correct on weapon_builder

#if defined _tf2attributes_included
	if (g_bDepAttribHooks) {
		int cwAllowed = TF2Attrib_HookValueInt(0, "toss buildings", client);
		if ((cwAllowed & (1<<type)) != 0) return false; // allowed by attributes superseeds config
	}
#endif
#if defined __tf_custom_attributes_included
	if (g_bDepCustomAttribs) {
		int cwAllowed = CA_HookValueIntOR(weapon, "toss buildings");
		if ((cwAllowed & (1<<type)) != 0) return false; // allowed by custattr superseeds config
	}
#endif
	
	return ( g_iAllowTypes&(1<<type) )==0;
}

#if defined __tf_custom_attributes_included
//Custom Attributes Framework has no automatic combination like the games HookValue functions.
//So this function will go through the weapons equipped and combine the values for each onto
//the players value to get the complete bit mask.
int CA_HookValueIntOR(int client, const char[] name) {
	int value = TF2CustAttr_GetInt(client, name);
	for (int slot=0; slot<6; slot+=1) {
		int weapon = GetPlayerWeaponSlot(client, slot);
		if (IsValidEdict(weapon)) value |= TF2CustAttr_GetInt(weapon, name);
	}
	return value;
}
#endif

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
	TR_TraceRayFilter(eyes, origin, MASK_PLAYERSOLID, RayType_EndPoint, TEF_HitSelfFilterPassClients, client);
	bool hit = TR_DidHit();
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

//wow, searching a type of entity at a certain location sure sucks
static bool bTEEFuncNobuildFound;
//return true to continue search
public bool TEE_SearchFuncNobuild(int entity, any data) {
	char classname[32];
	if (entity == data) return true;
	GetEntityClassname(entity, classname, sizeof(classname));
	// TF2Util_IsPointInRespawnRoom is only checking for same team spawn room - daheck?
	if (StrEqual(classname, "func_nobuild") || StrEqual(classname, "func_respawnroom")) {
		bTEEFuncNobuildFound = true;
		return false;
	}
	return true;
}

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
	
	TR_TraceHullFilter(origin, origin, mins, maxs, MASK_BUILDINGS, TEF_HitSelfFilter, obj);
	bool invalid = TR_DidHit() || TF2Util_IsPointInRespawnRoom(origin, obj);
	if (!invalid) {
		//look for nobuild areas
		bTEEFuncNobuildFound = false;
		TR_EnumerateEntitiesHull(origin, origin, mins, maxs, PARTITION_TRIGGER_EDICTS, TEE_SearchFuncNobuild, obj);
		if (bTEEFuncNobuildFound) {
			invalid = true;
		}
	}
	
	if (invalid) BreakBuilding(obj);
	if (g_fwdLanded.FunctionCount>0) {
		Call_StartForward(g_fwdLanded);
		Call_PushCell(building);
		Call_PushCell(!invalid);
		Call_Finish();
	}
	return Plugin_Stop;
}

void BreakBuilding(int building) {
	SetVariantInt(RoundToCeil(Entity_GetHealth(building)*1.5));
	AcceptEntityInput(building, "RemoveHealth");
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

void GetModelForBuilding(int buildingType, char[] model, int maxlen) {
	switch (buildingType) {
		case BUILDING_SENTRYGUN: strcopy(model, maxlen, "models/buildables/sentry1.mdl");
		case BUILDING_DISPENSER: strcopy(model, maxlen, "models/buildables/dispenser_light.mdl");
		case BUILDING_TELEPORTER: strcopy(model, maxlen, "models/buildables/teleporter_light.mdl");
		default: ThrowError("Unsupported Building Type %i", buildingType);
	}
}