#if defined _toss_buildings_included
#endinput
#endif
#define _toss_buildings_included

// object (aka building) types
#define BUILDING_DISPENSER 0
#define BUILDING_TELEPORTER 1
#define BUILDING_SENTRYGUN 2
#define BUILDING_ATTACHMENT_SAPPER 3

// build states
#define BS_IDLE 0
#define BS_SELECTING 1
#define BS_PLACING 2
#define BS_PLACING_INVALID 3

/**
 * Player is about to throw a building
 * 
 * @param building - entity index of the building, doesn't change from the moment the building is SELECTED
 * @param objectType - type of BUILDING_*
 * @param owner - the player currently trying to throw the building
 * @return >= Plugin_Handled to cancel
 */
forward Action TF2_OnTossBuilding(int building, int objectType, int owner);

/**
 * Player has just thrown a building
 * 
 * @param building - entity index of the building, doesn't change from the moment the building is SELECTED
 * @param phys - entity index of the prop pretending to be a building to display the throw 
 * @param objectType - type of BUILDING_*
 * @param owner - the player currently trying to throw the building
 * @noreturn
 */
forward void TF2_OnTossBuildingPost(int building, int phys, int objectType, int owner);

/**
 * The building has landed. Not guaranteed to be called after a throw (class might change, etc).
 * 
 * @param building - entity index of the building, doesn't change from the moment the building is SELECTED
 * @param validLocation - true if the building landed in a valid location, false if it's going to destruct
 */
forward void TF2_OnBuildingLanded(int building, bool validLocation);