# Toss Buildings

Pretty simple idea: Engi can now throw his buildings while carrying them.
To throw buildings, press your Reload key. They will construct while in air, bounce off walls and finally be usable at the desitnation.
You can't throw during Waiting For Players, If a building lands in a spawn room or sticks into other things, it will blow up.

Credits to zen for the idea :)

## Dependencies
* VPhysics Extension - because it's the best way to accelerate physics props
* TF2Utils - because that can check if things are in spawn rooms
* tf2hudmsg - because HudNotifications are prettier than PrintHintText (*OPTIONAL*)
* tf_custom_attributes - get crazy with custom weapons (*OPTIONAL*)
* SMLib Transitional-Syntax - because it makes things easier for me (*COMPILE ONLY*)

## ConVars
* sm_toss_building_types "dispenser teleporter sentrygun" - Space separated building types that can be tossed. Remove a word to block that building from being tossed.
* sm_toss_building_force 520 - The force with with to yeet the buildings. 520 felt good, 320 still works, idk keep it default i guess.
* sm_toss_building_upright 0 - How much to pull the prop upright in degree/sec. Will somethwat prevent the prop twriling, 0 to disable.
* sm_toss_building_breakoob "dispenser teleporter sentrygun" - Space separated list of building names that break out of bounds: Dispenser Teleporter Sentrygun.
* sm_toss_building_allowstacking 0 - Set to 1 to allow tossing buildings on top of each other.
* sm_toss_building_version - Version convar for version

ConVars go into `cfg/sourcemod/plugin.tossbuildings.cfg`.

## Custom Attribute
This plugin also works as [custom attributes](https://github.com/nosoop/SM-TFCustAttr) plugin.
Add the "`toss buildings`" attribute to the building tool (base item def index `28`) with the following values (add up to combine)
* 1 : Dispenser
* 2 : Teleporter
* 4 : Sentries

## Library
Other plugins can listen to buildings being tossed and landing. For more info check the include.
If you block a building from being tossed, maybe tell the player why it's blocked (UX is important, mmkay).