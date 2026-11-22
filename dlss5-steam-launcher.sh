#!/usr/bin/env bash
# dlss5-steam-launcher.sh — DLSS 5 Neural Rendering override manager for Steam
# and Epic Games Launcher (EGL v2) games on Linux/Proton (NVIDIA RTX 50).
#
# Wraps the Retoque v0.3.3 deploy engine (an OptiScaler fork, GPL-3.0) and the
# NVIDIA-signed DLSS 5 NR model nvngx_dlssnr.dll 310.9.16, both pinned by
# SHA-256. Every change the engine makes is journaled to <game>/.retoque/
# receipt.txt and reversible with `restore`; the NR model itself is journaled
# to <game>/.dlss5-launcher/journal.txt. The game's own Streamline (sl.*) and
# NGX (nvngx_dlss/dlssd/dlssg) files are never modified.
#
# Usage: dlss5-steam-launcher.sh <command> [args]
#   list | doctor | setup | refresh | preset | status | restore | launch
# See README.md in this folder for the full manual.
set -euo pipefail

VERSION='1.1.0'
PROG=${0##*/}

# ------------------------------------------------------------------ pins ---
# OptiScaler.dll from the SHA-verified Retoque-v0.3.3.zip (Retoque 0.3.3)
PIN_OPTISCALER='2c8fccd7e9f2a5038f93262e449ddebe51d6ec9bec93aa2ce73d58bcdd2697dc'
# nvngx.dll_dlssnr.dll forwarder (Retoque 0.3.3)
PIN_FORWARDER='a3c9bee2078c2fe351e9eff17ba1b9e4cf55837e301d16c3c27cbb3317301936'
# nvngx_dlssnr.dll — NVIDIA-signed DLSS 5 NR model 310.9.16 (model A + model B)
PIN_MODEL='2bc19bc09a7b89dd44f73e2ac0108fcc586e2154bdd0830f242f4f040e28789f'
# Provenance of the cached component archives (verified at download time)
PIN_RETOQUE_ZIP='0570602a68f0cba3d3b886e89583c1f1cee86307b4619358af30b2ecb56c83b1'
PIN_WINELAND_TAR='dfec653a7f167ba412b74d2d52de274d467f1bf8b0dfbd07c52a12d6f08e49b8'

WINELAND_NAME='proton-wineland-11.0-20261119-x86_64_v3'
DRIVER_WINE_NVNGX_CANDIDATES=(
    /usr/lib/x86_64-linux-gnu/nvidia/wine/_nvngx.dll
    /usr/lib/nvidia/wine/_nvngx.dll
    /usr/lib64/nvidia/wine/_nvngx.dll
)
DEFAULT_COMPONENTS_DIR="$HOME/dev/workbench/tmp/dlss5-linux"
DEFAULT_STEAM_ROOTS=(
    "$HOME/snap/steam/common/.local/share/Steam"
    "$HOME/.local/share/Steam"
    "$HOME/.steam/steam"
)

# ------------------------------------------------------- per-game table ---
# exe dir is relative to the game install dir; '.' means the install root.
declare -A GAME_EXE_SUBDIR=( ['292030']='bin/x64_dx12' ['1371980']='.' )
declare -A GAME_EXE_NAME=( ['292030']='witcher3.exe' ['1371980']='NoRestForTheWicked.exe' )
declare -A GAME_LAUNCH_ARGS=( ['292030']='--launcher-skip' )
declare -A GAME_EXCLUDE_REASON=(
    ['553850']='EasyAntiCheat kernel anti-cheat is present: a proxy DLL can trigger a ban, and Helldivers 2 does not run under Proton in any case'
)
declare -A GAME_NOTE=(
    ['292030']='D3D12 Remastered build, native DLSS via Streamline; the NR pass runs on the upscaler route; the RED pre-launcher window still appears despite --launcher-skip — click Play, then enter the game world'
    ['1371980']='Unity IL2CPP with D3D12Core and native DLSS; not on the Retoque measured list (verify with launch --verify)'
)
TOOL_APPIDS=' 228980 1493710 4183110 1628350 1391110 '

# ------------------------------------------------ epic games (EGL v2) ---
# The native Epic Games Launcher v2 (Tauri app, EpicGamesLauncher on PATH)
# caches this account's owned library under
# ~/.local/share/com.epicgames.eglv2/cache/prod/account/<id>/ and installs
# games into the defaultInstallDir from its settings (~/Games here). Epic
# games are addressed as 'epic:<appName>': appName is Epic's launch id,
# the same id the com.epicgames.launcher://apps/<appName> URL scheme uses.
#
# Every item in this machine's Epic library is assessed for the override
# (as of 2026-11-22; 166 owned items):
#   eligible  D3D11/D3D12 64-bit, no kernel anti-cheat
#   excluded  kernel anti-cheat (ban risk) or D3D9/OpenGL/2D-only renderer
#   skip      DLC, tools, extras and beta branches (not games)
# Upscaler facts verified against PCGamingWiki + vendor lists; anti-cheat
# facts against AreWeAntiCheatYet + publisher support pages.
DEFAULT_EGLV2_DATA="$HOME/.local/share/com.epicgames.eglv2"
DEFAULT_EPIC_ROOTS=("$HOME/Games")
EPIC_LAUNCH_CMD=EpicGamesLauncher

# titles for every owned item (the launcher can read names from here
# even before the game is installed, and cross-checks this table against
# the EGL v2 library cache to catch new, unassessed purchases)
declare -A EPIC_GAME_TITLE=(
    ['epic:e0fa47ae79514345823bff209ae29451']='A Plague Tale: Innocence'
    ['epic:11e598b192324994abce05bad4f81b50']='A Total War Saga: TROY'
    ['epic:8a0173bbe3ac48ac903f5bc7277e7b4e']='Alba - A Wildlife Adventure'
    ['epic:8935bb3e1420443a9789fe01758039a5']='Alien: Isolation'
    ['epic:aafc587fbf654758802c8e41e4fb3255']='ARK: Survival Evolved'
    ['epic:dc07b9ead8214591b8df6d2546d2a0e3']='Aven Colony'
    ['epic:5d31a6c96b204613b17d690ca88cf9f9']='Bakerloo Line'
    ['epic:b22ce34b4ce0408c97a888554447479b']='BioShock 2 Remastered'
    ['epic:f9d6f0530ea140909f8e8a997a7532d7']='BioShock Infinite: Complete Edition'
    ['epic:bc2c95c6ff564a16b26644f1d3ac3c55']='BioShock Remastered'
    ['epic:Dodo']='Borderlands 2'
    ['epic:Turkey']='Borderlands: The Pre-Sequel'
    ['epic:1712357717804dce97a6598c0d91d1d2']='BURIED STARS'
    ['epic:051eaac0842c46d7a5a62858ad534d5a']='Cat Quest'
    ['epic:Peppermint']='Chivalry 2'
    ['epic:ca02598c9a5c4d5491d6431ce8e8d6e7']='Chivalry 2 - Public Testing'
    ['epic:KingletAztec']='Civilization VI : Aztec DLC'
    ['epic:f4f0d39fbb4640e0be62aa91d9eca87d']='DAEMON X MACHINA'
    ['epic:Boga']='Death Stranding'
    ['epic:5bf67f3153364181b54cb9e40ca7fa82']='Death Stranding Content'
    ['epic:84067e3ec8f149b2bbf2342d7a136065']='DEATH STRANDING DIGITAL SOUNDTRACK'
    ['epic:fa5aa7e6c28c4c94aeac239eee700d5f']='Deliver At All Costs'
    ['epic:592c359fb0e0413fb46dee2d24448eb4']='Destiny 2'
    ['epic:d2da64bd4c4e422da4b1a88041492a3a']='Dishonored - Definitive Edition'
    ['epic:verdi']='Dragon Age: Inquisition – Game of the Year Edition'
    ['epic:351fe5b32e22412d8fa41f4c7395fed1']='Dungeons 3'
    ['epic:04a54ed532ce4fbfbf8fd5833f60def0']='Dying Light'
    ['epic:71816b992ef04030b1c58af6b9845fe5']='Dying Light The Bozak'
    ['epic:f653266870894ee1acbb5250e3b04bd1']='Dying Light The Following'
    ['epic:Pelican']='Everything'
    ['epic:70f92598b33d42e290e411f07397aeee']='Eximius: Seize the Frontline'
    ['epic:bf4808b3395b43fb80afbe6773e1661f']='F.I.S.T.: Forged In Shadow Torch'
    ['epic:74034e8449f2470d9f45115f3a49f9aa']='Fallout 2: A Post Nuclear Role Playing Game'
    ['epic:adeae8bbfc94427db57c7dfecce3f1d4']='Fallout 3: Game of the Year Edition'
    ['epic:ee9a44b4530942499ef1c8c390731fce']='Fallout New Vegas: Courier'\''s Stash'
    ['epic:b290229eb58045cbab9501640f3278f3']='Fallout New Vegas®: Dead Money'
    ['epic:7dcfb9cd9d134728b2646466c34c7b3b']='Fallout New Vegas®: Gun Runners’ Arsenal™'
    ['epic:562d4a2c1b3147b089a7c453e3ddbcbe']='Fallout New Vegas®: Honest Hearts'
    ['epic:4fa3d8d9b2cb4714a19a38d1a598be8f']='Fallout New Vegas®: Lonesome Road™'
    ['epic:c8dae1ab0570475a8b38a9041e614840']='Fallout New Vegas®: Old World Blues'
    ['epic:908f75e7f1624819a70c27f543741dcd']='Fallout Tactics: Brotherhood of Steel'
    ['epic:f8ef168f3522419caad27d82878e0329']='Fallout: A Post Nuclear Role Playing Game'
    ['epic:5daeb974a22a435988892319b3a4f476']='Fallout: New Vegas'
    ['epic:Larkspur']='Far Cry Primal'
    ['epic:b2e00fc16632475782a7730d1bd7cb60']='Frostpunk'
    ['epic:5f1c66366b2c4a6496d535d88c56e6cf']='Galactic Civilizations III'
    ['epic:8931f79300d04c5889799bffc8ef70bd']='Galactic Civilizations III (Test branch)'
    ['epic:a01150ee6deb406c92dd2b2445186163']='Gamedec - Definitive Edition'
    ['epic:41869934302e4b8cafac2d3c0e7c293d']='Genshin Impact'
    ['epic:007ff8f4e30845a687e66aa77eb3e965']='Ghostwire Tokyo'
    ['epic:69911638c74449d2a2651241be1b3ad4']='Gods Will Fall'
    ['epic:aabbfd8f324543be8b8a58c368326315']='GOG GALAXY'
    ['epic:9d2d0eb64d5c44529cece33fe2a46482']='Grand Theft Auto V'
    ['epic:8769e24080ea413b8ebca3f1b8c50951']='Grand Theft Auto V Enhanced'
    ['epic:fab83c3bf3d449718e042d44369e7fb6']='Guacamelee! 2'
    ['epic:25b902f42cf04b17bc8a3db2f7292d58']='Guacamelee! Super Turbo Championship Edition'
    ['epic:808f0dfbf3b84c2680793724d7f207bf']='Hand of Fate 2'
    ['epic:f8bf1e29bbef480a9b28115ad0d644a0']='HD Wallpaper'
    ['epic:Barbet']='HITMAN'
    ['epic:dcfccf8d965a4f2281dddf9fead042de']='Homeworld Remastered Collection'
    ['epic:c9b51edbca4d496cb39c6871f510620b']='Homeworld: Deserts of Kharak'
    ['epic:29ee5d32f328471590b3bd3ac03ed7d0']='In Sound Mind'
    ['epic:Grouse']='Jotun Valhalla Edition'
    ['epic:373a4372c20540aca7fdd880d27fa49a']='Jurassic World Evolution'
    ['epic:Kakopo']='Just Cause 4'
    ['epic:Finch']='Killing Floor 2'
    ['epic:3223ccf6ac9b4189bd4e144c047d33fb']='KillingFloor2Beta'
    ['epic:473e24df09f843a1acc4aa16b01dae83']='Layers of Fear 2'
    ['epic:806f3b7734764e2498962ce7b55c0dda']='LEGO® Builder'\''s Journey'
    ['epic:Hazelnut']='Limbo'
    ['epic:c53b738a47724c64acd227a6dbffb1fa']='Little Nightmares'
    ['epic:63a665088eb1480298f1e57943b225d8']='Marvel'\''s Guardians of the Galaxy'
    ['epic:9596620d263b40c083ddf1f0c662c8ff']='Marvel'\''s Guardians of the Galaxy: Social-Lord Outfit'
    ['epic:a477f73fc8b54e09ba7a35f9579797cb']='Mechabellum'
    ['epic:HoopoeContent']='MechWarrior 5 Content'
    ['epic:HoopoeEditor']='MechWarrior 5 Editor'
    ['epic:Hoopoe']='MechWarrior 5 Mercenaries'
    ['epic:HoopoeManual']='MechWarrior 5 Tech Manual'
    ['epic:Petunia']='Metro 2033 Redux'
    ['epic:Speedwell']='Metro Last Light Redux'
    ['epic:456f53b28c384f02865874299f956501']='Midnight Ghost Hunt'
    ['epic:2e26af55c1a146e7a939dcc1014fc9fd']='MORDHAU'
    ['epic:0055e45ce7654c55aade646467349e83']='Mortal Shell'
    ['epic:f0ac8218ef7d4b5aabec153e3f193db6']='Mortal Shell Tech Beta'
    ['epic:ee5c6a659d0f478fba0049fa44429a1f']='Mothergunship'
    ['epic:Bulbul']='MudRunner'
    ['epic:b5e42b0dc2f544a5bbb4080a433b8b71']='Nioh: The Complete Edition'
    ['epic:7c566548d24343e48151125ced4b494c']='Oddworld: New '\''n'\'' Tasty'
    ['epic:Sage']='Overcooked'
    ['epic:b21f394024ef4b75afc2f09c04f0b9f1']='Pathfinder Kingmaker - Enhanced Plus Edition'
    ['epic:8fceb562623c430db9bb6abf0549c43e']='Pathway'
    ['epic:bcc75c246fe04e45b0c1f1c3fd52503a']='Pillars of Eternity - Definitive Edition'
    ['epic:8e975c15166a4a1ca28d65fdfa411248']='Pillars of Eternity - Definitive Edition Pack'
    ['epic:52d88e9a6df248da913c8e99f1e4c526']='PREY'
    ['epic:8cf7c6b964514532ad8284a376a517bf']='Railway Empire'
    ['epic:Weaver']='Rebel Galaxy'
    ['epic:1be5efb848844b1dabf9d67f8017a7ae']='Redout: Enhanced Edition'
    ['epic:b4a0d2d15acb4db894a599b810297543']='Remnant: From the Ashes'
    ['epic:f7cc1c999ac146f39b356f53e3489514']='Rise of the Tomb Raider: 20 Year Celebration'
    ['epic:281a47e363284108b82bf05c1a612145']='RollerCoaster Tycoon® 3: Complete Edition'
    ['epic:Loon']='Saints Row The Third Remastered'
    ['epic:499f085e442048aa854d6250b21c42fb']='Salt and Sanctuary'
    ['epic:098b530746fa4cfb8b11484bfdc18a2d']='Sand Patch Grade'
    ['epic:Cobia']='Saturnalia'
    ['epic:4fec3df59df9406c9a243d40fbd7bdfb']='Schnellfahrstrecke Köln-Aachen'
    ['epic:18a85afedeac4ea885b27fee3e0c81db']='Second Extinction™'
    ['epic:c311b22f878749449886949eeb588999']='SELECTIONS OF TITAN ART BOOK'
    ['epic:7179f095efcc4f92a950a6d9dbd9c602']='Severed Steel'
    ['epic:890d9cf396d04922a1559333df419fed']='Shadow of the Tomb Raider: Definitive Edition'
    ['epic:a334978574a840d594c31521592925f3']='Shadow Tactics: Aiko'\''s Choice'
    ['epic:Fangtooth']='Shadow Tactics: Blades of the Shogun'
    ['epic:41470cb5755440b8b55ec3f94351133a']='Shadowrun Hong Kong'
    ['epic:dc29cb42f32e4a17af1d68c715fa459c']='Shadowrun Returns'
    ['epic:5b41454974be4d5883056ba298e53675']='Shadowrun: Dragonfall - Director’s Cut'
    ['epic:Kinglet']='Sid Meier'\''s Civilization VI'
    ['epic:d36336f190094951873ed6138ac208d8']='Sifu'
    ['epic:Morganite']='Sludge Life'
    ['epic:a2b2ed0324c44902b9058e23dedc76e3']='Spelldrifter'
    ['epic:7b92cb9582b04a36b629321e848b12a1']='SpellForce 3: Versus'
    ['epic:MtMassive']='STAR WARS™ Battlefront™ II: Celebration Edition'
    ['epic:Ovenbird']='Surviving Mars'
    ['epic:2feb2f328922458e9f698f620fbddc13']='System Shock 2: 25th Anniversary Remaster'
    ['epic:74977fee80de4e5e9f663e62560a0f2f']='The Evil Within 2'
    ['epic:ed93b18355a84230938c705121c63661']='The Long Dark'
    ['epic:87441b64c6d746b7a7c90017c227dd0c']='The Long Dark: Wintermute'
    ['epic:Rosemallow']='The Outer Worlds'
    ['epic:0d5096d5f109405d814ccab3dc6d94f3']='The Outer Worlds Peril on Gorgon'
    ['epic:f5f1f25431bf43ec827656b41123c01b']='The Outer Worlds: Murder on Eridanos'
    ['epic:cb3bf7ba89574a66ae3b795e039d4dbc']='The Outer Worlds: Spacer'\''s Choice Edition'
    ['epic:7b8fb449c8d3404ba7eda9cd4da1401b']='The Spectrum Retreat'
    ['epic:9447b19ffb6a47e1a654b75178779a28']='The Vanishing of Ethan Carter'
    ['epic:58a6b5e81c644fba8bab2e05137429d9']='The Vanishing of Ethan Carter Redux'
    ['epic:Cardinal']='This War of Mine'
    ['epic:eb6ddfb245f647e2bb6902f52f38a535']='Tiny Tina'\''s Wonderlands'
    ['epic:d6264d56f5ba434e91d4b0a0b056c83a']='Tomb Raider GAME OF THE YEAR EDITION'
    ['epic:8e425d507bd6473dbb927f0fea8ef4f6']='Torchlight II'
    ['epic:c90f02864e054feba10b315af7592fa3']='Total War: PHARAOH DYNASTIES'
    ['epic:769f2fee68e9477180da900ccccbbcf0']='Total War: THREE KINGDOMS'
    ['epic:dd75b5c168d546cc869582c0389f0a1d']='Train Sim World 2'
    ['epic:09c5bee2ad8940d7b923314b60ec8265']='Train Sim World® 4 Compatible: Bakerloo Line'
    ['epic:909591bfde364a0da9e121df661c8484']='Train Sim World® 4 Compatible: Sand Patch Grade'
    ['epic:348930511a4b4694b1c6bfb5f9f76ae0']='Train Sim World® 4 Compatible: Schnellfahrstrecke Köln-Aachen'
    ['epic:ee596311b7e14e2d925c75e35ddd2721']='Train Sim World® 5: Bakerloo Line'
    ['epic:0e07b42c0ffe4cfdb2095568f461f38f']='Train Sim World® 5: Sand Patch Grade'
    ['epic:19ef3873bd3e4a0db73bfc5422acf949']='Train Sim World® 5: Schnellfahrstrecke Köln-Aachen'
    ['epic:90c4ae1c4d1c40469835d0c776cb53a7']='Train Sim World® 6: Bakerloo Line'
    ['epic:a7104176e36643c59707a2d2e3d77206']='Train Sim World® 6: Sand Patch Grade'
    ['epic:57b7918bc8144858ade791e1dec267f0']='Train Sim World® 6: Schnellfahrstrecke Köln-Aachen Remastered'
    ['epic:eb9d3124ce7f4442ad6742fec8df54ac']='Train Sim World® 7: Bakerloo Line'
    ['epic:0680ef8605d04d2ab1d53b073a3f2fda']='Train Sim World® 7: Sand Patch Grade'
    ['epic:7e6e273823b8478e85f27d52abd80fe1']='Train Sim World® 7: Schnellfahrstrecke Köln-Aachen Remastered'
    ['epic:a617890cec1542d6ba760ba13f79225e']='Train Valley 2'
    ['epic:Dill']='Transistor'
    ['epic:TM_2020.1']='Twinmotion 2020.1.2'
    ['epic:06b2bd7550d146c190c1f61e3f1e2fb6']='Twinmotion 2020.2.3'
    ['epic:d919e78b3fc049678e63df7ff49cf65d']='Twinmotion 2021.1.4'
    ['epic:cc7d703badf64f299f49779a4b7be03a']='Twinmotion 2022.1.2'
    ['epic:d3f3060fffa84a5dac91955bb65a8ae5']='Twinmotion 2022.2.3'
    ['epic:472b1a7ee8714d839bde7816a454db1d']='Twinmotion 2023.1.2'
    ['epic:36b0e40890f147fbb1e3965f87369156']='Tyranny - Gold Edition'
    ['epic:Nautilus']='Vampyr'
    ['epic:dd95e8c01b4b456f8ecbf18376a49c94']='Warhammer 40,000: Mechanicus - Standard Edition'
    ['epic:Angelonia']='Watch Dogs 2'
    ['epic:a95bf4df6627431ca5baff8173c59635']='Windbound'
    ['epic:8764f82381f5436f99e97172df06af35']='Witchfire'
    ['epic:a64dcf9b711a4a60a3c0b6f052dfc7da']='Wolfenstein: The New Order'
)

# install folder (Epic catalog FolderName) per eligible/excluded game
declare -A EPIC_GAME_DIR=(
    ['epic:e0fa47ae79514345823bff209ae29451']='APlagueTale'
    ['epic:11e598b192324994abce05bad4f81b50']='TotalWarSagaTROY'
    ['epic:8a0173bbe3ac48ac903f5bc7277e7b4e']='AlbaAWildlifeAdventusiuFk'
    ['epic:8935bb3e1420443a9789fe01758039a5']='AlienIsolation'
    ['epic:dc07b9ead8214591b8df6d2546d2a0e3']='AvenColony'
    ['epic:b22ce34b4ce0408c97a888554447479b']='BioShock2Remastered'
    ['epic:f9d6f0530ea140909f8e8a997a7532d7']='BioshockInfiniteCompleteEdition'
    ['epic:bc2c95c6ff564a16b26644f1d3ac3c55']='BioshockRemastered'
    ['epic:f4f0d39fbb4640e0be62aa91d9eca87d']='DaemonxMachina'
    ['epic:Boga']='DeathStranding'
    ['epic:fa5aa7e6c28c4c94aeac239eee700d5f']='DeliverAtAllCosts'
    ['epic:d2da64bd4c4e422da4b1a88041492a3a']='DishonoredDE'
    ['epic:verdi']='DragonAgeInquisitiontFgJu'
    ['epic:351fe5b32e22412d8fa41f4c7395fed1']='Dungeons3'
    ['epic:04a54ed532ce4fbfbf8fd5833f60def0']='DyingLight'
    ['epic:f653266870894ee1acbb5250e3b04bd1']='TheFollowing'
    ['epic:70f92598b33d42e290e411f07397aeee']='EximiusSeizeTheFrontline'
    ['epic:bf4808b3395b43fb80afbe6773e1661f']='FIST'
    ['epic:Larkspur']='FarCryPrimal'
    ['epic:b2e00fc16632475782a7730d1bd7cb60']='Frostpunk'
    ['epic:5f1c66366b2c4a6496d535d88c56e6cf']='GalacticCivilizations3'
    ['epic:a01150ee6deb406c92dd2b2445186163']='gamedec'
    ['epic:007ff8f4e30845a687e66aa77eb3e965']='GhostwireTokyo'
    ['epic:69911638c74449d2a2651241be1b3ad4']='GodsWillFall'
    ['epic:808f0dfbf3b84c2680793724d7f207bf']='HandOfFate2'
    ['epic:Barbet']='HITMAN'
    ['epic:c9b51edbca4d496cb39c6871f510620b']='HomeworldDesertsofKharak'
    ['epic:29ee5d32f328471590b3bd3ac03ed7d0']='InSoundMind'
    ['epic:373a4372c20540aca7fdd880d27fa49a']='JurassicWorldEvolution'
    ['epic:Kakopo']='JustCause4'
    ['epic:Finch']='KillingFloor2'
    ['epic:473e24df09f843a1acc4aa16b01dae83']='LayersofFear2'
    ['epic:806f3b7734764e2498962ce7b55c0dda']='LEGOBuildersJourney'
    ['epic:c53b738a47724c64acd227a6dbffb1fa']='LittleNightmares9a8b0'
    ['epic:63a665088eb1480298f1e57943b225d8']='MarvelGOTG'
    ['epic:a477f73fc8b54e09ba7a35f9579797cb']='Mechabellumd9qrx'
    ['epic:Hoopoe']='MW5Mercs'
    ['epic:Petunia']='Metro2033Redux'
    ['epic:Speedwell']='MetroLastLightRedux'
    ['epic:2e26af55c1a146e7a939dcc1014fc9fd']='Mordhau'
    ['epic:0055e45ce7654c55aade646467349e83']='MortalShell'
    ['epic:ee5c6a659d0f478fba0049fa44429a1f']='Mothergunship'
    ['epic:Bulbul']='MudRunner'
    ['epic:b5e42b0dc2f544a5bbb4080a433b8b71']='Nioh'
    ['epic:7c566548d24343e48151125ced4b494c']='OddworldNewNTasty'
    ['epic:b21f394024ef4b75afc2f09c04f0b9f1']='PathfinderKingmaker'
    ['epic:bcc75c246fe04e45b0c1f1c3fd52503a']='PillarsOfEternity'
    ['epic:52d88e9a6df248da913c8e99f1e4c526']='PREY'
    ['epic:8cf7c6b964514532ad8284a376a517bf']='RailwayEmpire'
    ['epic:Weaver']='RebelGalaxy'
    ['epic:1be5efb848844b1dabf9d67f8017a7ae']='RedoutEnhancedEdition'
    ['epic:b4a0d2d15acb4db894a599b810297543']='RemnantFromTheAshes'
    ['epic:f7cc1c999ac146f39b356f53e3489514']='RiseoftheTombRaider'
    ['epic:Loon']='SaintsRowTheThird'
    ['epic:Cobia']='Saturnalia'
    ['epic:18a85afedeac4ea885b27fee3e0c81db']='SecondExtinction'
    ['epic:7179f095efcc4f92a950a6d9dbd9c602']='SeveredSteel'
    ['epic:890d9cf396d04922a1559333df419fed']='ShadowoftheTombRaider'
    ['epic:a334978574a840d594c31521592925f3']='ShadowTacticsAikosChoice'
    ['epic:Fangtooth']='ShadowTactics'
    ['epic:Kinglet']='SidMeiersCivilizationVI'
    ['epic:d36336f190094951873ed6138ac208d8']='Sifu'
    ['epic:Morganite']='SludgeLife'
    ['epic:7b92cb9582b04a36b629321e848b12a1']='SpellForce3Versus'
    ['epic:MtMassive']='StarWarsBattlefront2'
    ['epic:Ovenbird']='SurvivingMars'
    ['epic:2feb2f328922458e9f698f620fbddc13']='SystemShock225thAnniT5DFq'
    ['epic:74977fee80de4e5e9f663e62560a0f2f']='TheEvilWithin2'
    ['epic:ed93b18355a84230938c705121c63661']='TheLongDark'
    ['epic:Rosemallow']='TheOuterWorlds'
    ['epic:cb3bf7ba89574a66ae3b795e039d4dbc']='TOWSpacersChoice'
    ['epic:7b8fb449c8d3404ba7eda9cd4da1401b']='TheSpectrumRetreat'
    ['epic:9447b19ffb6a47e1a654b75178779a28']='TheVanishingofEthanCarter'
    ['epic:58a6b5e81c644fba8bab2e05137429d9']='VanishingEthanCarterRedux'
    ['epic:eb6ddfb245f647e2bb6902f52f38a535']='TinyTinasWonderlands'
    ['epic:d6264d56f5ba434e91d4b0a0b056c83a']='TombRaiderGOTYE'
    ['epic:c90f02864e054feba10b315af7592fa3']='TotalWarPHARAOHDYNASTIES'
    ['epic:769f2fee68e9477180da900ccccbbcf0']='TotalWarTHREEKINGDOMS'
    ['epic:dd75b5c168d546cc869582c0389f0a1d']='TrainSimWorld2'
    ['epic:36b0e40890f147fbb1e3965f87369156']='Tyranny'
    ['epic:Nautilus']='Vampyr'
    ['epic:dd95e8c01b4b456f8ecbf18376a49c94']='Mechanicus'
    ['epic:Angelonia']='Watchdogs2'
    ['epic:a95bf4df6627431ca5baff8173c59635']='Windbound'
    ['epic:8764f82381f5436f99e97172df06af35']='WitchfireRjTMw'
    ['epic:aafc587fbf654758802c8e41e4fb3255']='ARKSurvivalEvolved'
    ['epic:Peppermint']='Chivalry2'
    ['epic:592c359fb0e0413fb46dee2d24448eb4']='Destiny2'
    ['epic:41869934302e4b8cafac2d3c0e7c293d']='GenshinImpact'
    ['epic:9d2d0eb64d5c44529cece33fe2a46482']='GTAV'
    ['epic:8769e24080ea413b8ebca3f1b8c50951']='GTAVEnhanced'
    ['epic:456f53b28c384f02865874299f956501']='MidnightGhostHunt'
    ['epic:Dodo']='Borderlands2'
    ['epic:Turkey']='BorderlandsThePreSequel'
    ['epic:1712357717804dce97a6598c0d91d1d2']='BURIEDSTARSd7620'
    ['epic:051eaac0842c46d7a5a62858ad534d5a']='CatQuest'
    ['epic:Pelican']='Everything'
    ['epic:74034e8449f2470d9f45115f3a49f9aa']='fallout2'
    ['epic:adeae8bbfc94427db57c7dfecce3f1d4']='fallout3'
    ['epic:908f75e7f1624819a70c27f543741dcd']='fallouttactics'
    ['epic:f8ef168f3522419caad27d82878e0329']='fallout'
    ['epic:5daeb974a22a435988892319b3a4f476']='FalloutNewVegas'
    ['epic:fab83c3bf3d449718e042d44369e7fb6']='Guacamelee2'
    ['epic:25b902f42cf04b17bc8a3db2f7292d58']='GuacameleeSTCE'
    ['epic:dcfccf8d965a4f2281dddf9fead042de']='HomeworldRemasterdCollection'
    ['epic:Grouse']='Jotun'
    ['epic:Hazelnut']='Limbo'
    ['epic:Sage']='Overcooked'
    ['epic:8fceb562623c430db9bb6abf0549c43e']='Pathway'
    ['epic:281a47e363284108b82bf05c1a612145']='RollerCoasterTycoon3'
    ['epic:499f085e442048aa854d6250b21c42fb']='SaltAndSanctuary'
    ['epic:41470cb5755440b8b55ec3f94351133a']='ShadowrunHongKong'
    ['epic:dc29cb42f32e4a17af1d68c715fa459c']='shadowrunReturns'
    ['epic:5b41454974be4d5883056ba298e53675']='ShadowrunDragonfall'
    ['epic:a2b2ed0324c44902b9058e23dedc76e3']='Spelldrifter'
    ['epic:Cardinal']='ThisWarOfMine'
    ['epic:8e425d507bd6473dbb927f0fea8ef4f6']='Torchlight2'
    ['epic:a617890cec1542d6ba760ba13f79225e']='TrainValley2vmDaQ'
    ['epic:Dill']='Transistor'
    ['epic:a64dcf9b711a4a60a3c0b6f052dfc7da']='WolfensteinTNO'
)

# non-game items: DLC that installs into a base game, tools, extras, betas
declare -A EPIC_GAME_SKIP=(
    ['epic:5d31a6c96b204613b17d690ca88cf9f9']='Train Sim World route add-on'
    ['epic:ca02598c9a5c4d5491d6431ce8e8d6e7']='test-branch build of Chivalry 2'
    ['epic:KingletAztec']='Civilization VI DLC'
    ['epic:5bf67f3153364181b54cb9e40ca7fa82']='digital extras pack'
    ['epic:84067e3ec8f149b2bbf2342d7a136065']='soundtrack'
    ['epic:71816b992ef04030b1c58af6b9845fe5']='The Bozak Horde challenge DLC'
    ['epic:ee9a44b4530942499ef1c8c390731fce']='Fallout: New Vegas DLC'
    ['epic:b290229eb58045cbab9501640f3278f3']='Fallout: New Vegas DLC'
    ['epic:7dcfb9cd9d134728b2646466c34c7b3b']='Fallout: New Vegas DLC'
    ['epic:562d4a2c1b3147b089a7c453e3ddbcbe']='Fallout: New Vegas DLC'
    ['epic:4fa3d8d9b2cb4714a19a38d1a598be8f']='Fallout: New Vegas DLC'
    ['epic:c8dae1ab0570475a8b38a9041e614840']='Fallout: New Vegas DLC'
    ['epic:8931f79300d04c5889799bffc8ef70bd']='test-branch build'
    ['epic:aabbfd8f324543be8b8a58c368326315']='a game-store client, not a game'
    ['epic:f8bf1e29bbef480a9b28115ad0d644a0']='wallpaper'
    ['epic:3223ccf6ac9b4189bd4e144c047d33fb']='beta-branch build of Killing Floor 2'
    ['epic:9596620d263b40c083ddf1f0c662c8ff']='cosmetic DLC'
    ['epic:HoopoeContent']='digital extras pack'
    ['epic:HoopoeEditor']='the Unreal editor for MechWarrior 5, not the game'
    ['epic:HoopoeManual']='manual'
    ['epic:f0ac8218ef7d4b5aabec153e3f193db6']='beta-branch build of Mortal Shell'
    ['epic:8e975c15166a4a1ca28d65fdfa411248']='DLC bundle for Pillars of Eternity'
    ['epic:098b530746fa4cfb8b11484bfdc18a2d']='Train Sim World route add-on'
    ['epic:4fec3df59df9406c9a243d40fbd7bdfb']='Train Sim World route add-on'
    ['epic:c311b22f878749449886949eeb588999']='art book'
    ['epic:87441b64c6d746b7a7c90017c227dd0c']='The Long Dark story DLC'
    ['epic:0d5096d5f109405d814ccab3dc6d94f3']='The Outer Worlds expansion DLC'
    ['epic:f5f1f25431bf43ec827656b41123c01b']='The Outer Worlds expansion DLC'
    ['epic:09c5bee2ad8940d7b923314b60ec8265']='Train Sim World route add-on'
    ['epic:909591bfde364a0da9e121df661c8484']='Train Sim World route add-on'
    ['epic:348930511a4b4694b1c6bfb5f9f76ae0']='Train Sim World route add-on'
    ['epic:ee596311b7e14e2d925c75e35ddd2721']='Train Sim World route add-on'
    ['epic:0e07b42c0ffe4cfdb2095568f461f38f']='Train Sim World route add-on'
    ['epic:19ef3873bd3e4a0db73bfc5422acf949']='Train Sim World route add-on'
    ['epic:90c4ae1c4d1c40469835d0c776cb53a7']='Train Sim World route add-on'
    ['epic:a7104176e36643c59707a2d2e3d77206']='Train Sim World route add-on'
    ['epic:57b7918bc8144858ade791e1dec267f0']='Train Sim World route add-on'
    ['epic:eb9d3124ce7f4442ad6742fec8df54ac']='Train Sim World route add-on'
    ['epic:0680ef8605d04d2ab1d53b073a3f2fda']='Train Sim World route add-on'
    ['epic:7e6e273823b8478e85f27d52abd80fe1']='Train Sim World route add-on'
    ['epic:TM_2020.1']='architecture-viz tool, not a game'
    ['epic:06b2bd7550d146c190c1f61e3f1e2fb6']='architecture-viz tool, not a game'
    ['epic:d919e78b3fc049678e63df7ff49cf65d']='architecture-viz tool, not a game'
    ['epic:cc7d703badf64f299f49779a4b7be03a']='architecture-viz tool, not a game'
    ['epic:d3f3060fffa84a5dac91955bb65a8ae5']='architecture-viz tool, not a game'
    ['epic:472b1a7ee8714d839bde7816a454db1d']='architecture-viz tool, not a game'
)

# executables known well enough for launch --verify process detection
# (blank = auto-detect; --verify still works by watching OptiScaler.log)
GAME_EXE_NAME['epic:8935bb3e1420443a9789fe01758039a5']='AI.exe'
GAME_EXE_NAME['epic:Boga']='DeathStranding.exe'
GAME_EXE_NAME['epic:Finch']='KFGame.exe'
GAME_EXE_NAME['epic:63a665088eb1480298f1e57943b225d8']='MarvelGOTG.exe'
GAME_EXE_NAME['epic:Hoopoe']='MW5Mercs.exe'
GAME_EXE_NAME['epic:52d88e9a6df248da913c8e99f1e4c526']='Prey.exe'
GAME_EXE_NAME['epic:f7cc1c999ac146f39b356f53e3489514']='ROTTR.exe'
GAME_EXE_NAME['epic:890d9cf396d04922a1559333df419fed']='SOTTR.exe'
GAME_EXE_NAME['epic:Kinglet']='CivilizationVI.exe'
GAME_EXE_NAME['epic:d6264d56f5ba434e91d4b0a0b056c83a']='TombRaider.exe'

# kernel anti-cheat / renderer exclusions (the Helldivers 2 policy)
GAME_EXCLUDE_REASON['epic:aafc587fbf654758802c8e41e4fb3255']='BattlEye kernel anti-cheat ships with the game (official servers; single-player does not need it): a proxy DLL can trigger a ban'
GAME_EXCLUDE_REASON['epic:Peppermint']='EasyAntiCheat kernel anti-cheat is present (added after launch): a proxy DLL can trigger a ban'
GAME_EXCLUDE_REASON['epic:592c359fb0e0413fb46dee2d24448eb4']='BattlEye kernel anti-cheat, and Bungie blocks Wine/Proton outright — the game does not run here in any case'
GAME_EXCLUDE_REASON['epic:41869934302e4b8cafac2d3c0e7c293d']='miHoYo kernel-mode protection (mhyprot) is present: a proxy DLL can trip it and ban the account'
GAME_EXCLUDE_REASON['epic:9d2d0eb64d5c44529cece33fe2a46482']='BattlEye kernel anti-cheat guards GTA Online: a proxy DLL can trigger a ban'
GAME_EXCLUDE_REASON['epic:8769e24080ea413b8ebca3f1b8c50951']='BattlEye kernel anti-cheat guards GTA Online: a proxy DLL can trigger a ban'
GAME_EXCLUDE_REASON['epic:456f53b28c384f02865874299f956501']='EasyAntiCheat kernel anti-cheat is present: a proxy DLL can trigger a ban'
GAME_EXCLUDE_REASON['epic:Dodo']='D3D9 with a 32-bit-only executable: the deploy engine refuses 32-bit folders, and the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:Turkey']='D3D9 with a 32-bit-only executable: the deploy engine refuses 32-bit folders, and the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:1712357717804dce97a6598c0d91d1d2']='visual novel (2D): the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:051eaac0842c46d7a5a62858ad534d5a']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:Pelican']='ambient title, renderer unverified and no upscaler route — left out until assessed'
GAME_EXCLUDE_REASON['epic:74034e8449f2470d9f45115f3a49f9aa']='pre-Direct3D-11 era renderer: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:adeae8bbfc94427db57c7dfecce3f1d4']='D3D9-only (Gamebryo): the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:908f75e7f1624819a70c27f543741dcd']='pre-Direct3D-11 era renderer: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:f8ef168f3522419caad27d82878e0329']='pre-Direct3D-11 era renderer: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:5daeb974a22a435988892319b3a4f476']='D3D9-only (Gamebryo): the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:fab83c3bf3d449718e042d44369e7fb6']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:25b902f42cf04b17bc8a3db2f7292d58']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:dcfccf8d965a4f2281dddf9fead042de']='OpenGL renderer on Windows: the dxgi.dll proxy never loads'
GAME_EXCLUDE_REASON['epic:Grouse']='2D hand-drawn rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:Hazelnut']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:Sage']='2D co-op rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:8fceb562623c430db9bb6abf0549c43e']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:281a47e363284108b82bf05c1a612145']='2004-era D3D9 engine: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:499f085e442048aa854d6250b21c42fb']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:41470cb5755440b8b55ec3f94351133a']='Unity 4.x D3D9-era renderer: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:dc29cb42f32e4a17af1d68c715fa459c']='Unity 4.x D3D9-era renderer: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:5b41454974be4d5883056ba298e53675']='Unity 4.x D3D9-era renderer: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:a2b2ed0324c44902b9058e23dedc76e3']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:Cardinal']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:8e425d507bd6473dbb927f0fea8ef4f6']='D3D9: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:a617890cec1542d6ba760ba13f79225e']='2D rendering: the NR pass has no meaningful target'
GAME_EXCLUDE_REASON['epic:Dill']='D3D9, 32-bit build: the NR pass needs D3D11/12'
GAME_EXCLUDE_REASON['epic:a64dcf9b711a4a60a3c0b6f052dfc7da']='OpenGL (id Tech 5) renderer on PC: the dxgi.dll proxy never loads'

# per-game notes for the eligible set
GAME_NOTE['epic:e0fa47ae79514345823bff209ae29451']='UE4 D3D11, no native upscaler — the NR pass runs at present time'
GAME_NOTE['epic:11e598b192324994abce05bad4f81b50']='DX11, no native upscaler — the NR pass runs at present time'
GAME_NOTE['epic:8a0173bbe3ac48ac903f5bc7277e7b4e']='Unity D3D11 — the NR pass runs at present time'
GAME_NOTE['epic:8935bb3e1420443a9789fe01758039a5']='CA engine, DX11, no upscaler — the NR pass runs at present time'
GAME_NOTE['epic:dc07b9ead8214591b8df6d2546d2a0e3']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:b22ce34b4ce0408c97a888554447479b']='2K remaster, DX11 — the NR pass runs at present time'
GAME_NOTE['epic:f9d6f0530ea140909f8e8a997a7532d7']='DX10/DX11 — the NR pass runs at present time'
GAME_NOTE['epic:bc2c95c6ff564a16b26644f1d3ac3c55']='2K remaster, DX11 — the NR pass runs at present time'
GAME_NOTE['epic:f4f0d39fbb4640e0be62aa91d9eca87d']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Boga']='Decima engine, D3D12, native DLSS 2 — the NR pass rides the DLSS route; enable DLSS in game'
GAME_NOTE['epic:fa5aa7e6c28c4c94aeac239eee700d5f']='UE5 D3D12 — the NR pass runs at present time'
GAME_NOTE['epic:d2da64bd4c4e422da4b1a88041492a3a']='UE3 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:verdi']='Frostbite DX11 — the NR pass runs at present time'
GAME_NOTE['epic:351fe5b32e22412d8fa41f4c7395fed1']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:04a54ed532ce4fbfbf8fd5833f60def0']='DX11; VAC (Steam) only, no kernel anti-cheat — the NR pass runs at present time'
GAME_NOTE['epic:f653266870894ee1acbb5250e3b04bd1']='The Following is the full Enhanced game, same DX11 engine — the NR pass runs at present time'
GAME_NOTE['epic:70f92598b33d42e290e411f07397aeee']='UE4 DX11; online — no kernel anti-cheat documented, check the engine evidence at setup'
GAME_NOTE['epic:bf4808b3395b43fb80afbe6773e1661f']='UE4 with native DLSS 2 (+ Frame Generation) — the NR pass rides the DLSS route'
GAME_NOTE['epic:Larkspur']='Dunia DX11, no native upscaler — the NR pass runs at present time'
GAME_NOTE['epic:b2e00fc16632475782a7730d1bd7cb60']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:5f1c66366b2c4a6496d535d88c56e6cf']='DX11 — the NR pass runs at present time'
GAME_NOTE['epic:a01150ee6deb406c92dd2b2445186163']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:007ff8f4e30845a687e66aa77eb3e965']='UE4, D3D12, native DLSS 2 + FSR 2 — the NR pass rides the upscaler route'
GAME_NOTE['epic:69911638c74449d2a2651241be1b3ad4']='Unity D3D11 — the NR pass runs at present time'
GAME_NOTE['epic:808f0dfbf3b84c2680793724d7f207bf']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Barbet']='Glacier, DX11 (+ a DX12 beta), no upscaler — the NR pass runs at present time'
GAME_NOTE['epic:c9b51edbca4d496cb39c6871f510620b']='DX11 (unlike the OpenGL Homeworld Remastered) — the NR pass runs at present time'
GAME_NOTE['epic:29ee5d32f328471590b3bd3ac03ed7d0']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:373a4372c20540aca7fdd880d27fa49a']='Frontier UE4 DX11/DX12, no native upscaler — the NR pass runs at present time'
GAME_NOTE['epic:Kakopo']='Apex engine DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Finch']='UE3 DX11; online co-op — VAC (Steam PvP) only, no kernel anti-cheat; the NR pass runs at present time'
GAME_NOTE['epic:473e24df09f843a1acc4aa16b01dae83']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:806f3b7734764e2498962ce7b55c0dda']='Unity with D3D12 — the NR pass runs at present time'
GAME_NOTE['epic:c53b738a47724c64acd227a6dbffb1fa']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:63a665088eb1480298f1e57943b225d8']='D3D12 with native DLSS 2 and FSR 1 — the NR pass rides the upscaler route'
GAME_NOTE['epic:a477f73fc8b54e09ba7a35f9579797cb']='Unity DX11; online — no kernel anti-cheat known; the NR pass runs at present time'
GAME_NOTE['epic:Hoopoe']='UE4 with native DLSS 2 (and FSR 2) — the NR pass rides the DLSS route'
GAME_NOTE['epic:Petunia']='4A engine DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Speedwell']='4A engine DX11 — the NR pass runs at present time'
GAME_NOTE['epic:2e26af55c1a146e7a939dcc1014fc9fd']='UE4 DX11/DX12; online — VAC only, no kernel anti-cheat; the NR pass runs at present time'
GAME_NOTE['epic:0055e45ce7654c55aade646467349e83']='UE4 with native DLSS 2 — the NR pass rides the DLSS route'
GAME_NOTE['epic:ee5c6a659d0f478fba0049fa44429a1f']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Bulbul']='Saber engine DX11 — the NR pass runs at present time'
GAME_NOTE['epic:b5e42b0dc2f544a5bbb4080a433b8b71']='Kiwami engine DX11 — the NR pass runs at present time'
GAME_NOTE['epic:7c566548d24343e48151125ced4b494c']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:b21f394024ef4b75afc2f09c04f0b9f1']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:bcc75c246fe04e45b0c1f1c3fd52503a']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:52d88e9a6df248da913c8e99f1e4c526']='CryEngine D3D11; DLSS was added in a late update — the NR pass rides the DLSS route'
GAME_NOTE['epic:8cf7c6b964514532ad8284a376a517bf']='DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Weaver']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:1be5efb848844b1dabf9d67f8017a7ae']='DX11 — the NR pass runs at present time'
GAME_NOTE['epic:b4a0d2d15acb4db894a599b810297543']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:f7cc1c999ac146f39b356f53e3489514']='D3D11/D3D12 with native DLSS 2 — pick DX12, the NR pass rides the DLSS route'
GAME_NOTE['epic:Loon']='remaster, DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Cobia']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:18a85afedeac4ea885b27fee3e0c81db']='UE4 with native FSR 1; online co-op with no kernel anti-cheat documented — check the engine evidence at setup'
GAME_NOTE['epic:7179f095efcc4f92a950a6d9dbd9c602']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:890d9cf396d04922a1559333df419fed']='D3D11/D3D12 with native DLSS 2 + XeSS — pick DX12, the NR pass rides the upscaler route'
GAME_NOTE['epic:a334978574a840d594c31521592925f3']='Epic lists it as "Shadow Tactics Blades of the Shogun" but the install folder is Aiko'\''s Choice; Unity DX11'
GAME_NOTE['epic:Fangtooth']='Unity DX11, 3D isometric — the NR pass runs at present time'
GAME_NOTE['epic:Kinglet']='DX11 and DX12 modes — pick DX12 in game; the NR pass runs at present time'
GAME_NOTE['epic:d36336f190094951873ed6138ac208d8']='UE4 with native DLSS 2 — the NR pass rides the DLSS route'
GAME_NOTE['epic:Morganite']='Unity D3D11 — the NR pass runs at present time'
GAME_NOTE['epic:7b92cb9582b04a36b629321e848b12a1']='Grimlore DX11 standalone multiplayer — the NR pass runs at present time'
GAME_NOTE['epic:MtMassive']='Frostbite DX11; FairFight is server-side only, but the Epic launch goes through the EA-account link'
GAME_NOTE['epic:Ovenbird']='Haemimont DX11 — the NR pass runs at present time'
GAME_NOTE['epic:2feb2f328922458e9f698f620fbddc13']='Nightdive remaster, D3D11/12-class — renderer unverified until installed'
GAME_NOTE['epic:74977fee80de4e5e9f663e62560a0f2f']='STEM engine DX11 — the NR pass runs at present time'
GAME_NOTE['epic:ed93b18355a84230938c705121c63661']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Rosemallow']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:cb3bf7ba89574a66ae3b795e039d4dbc']='UE4 upgraded re-release with native FSR 2 — the NR pass rides the FSR route'
GAME_NOTE['epic:7b8fb449c8d3404ba7eda9cd4da1401b']='engine unverified (likely UE4/DX11) — confirm at setup'
GAME_NOTE['epic:9447b19ffb6a47e1a654b75178779a28']='UE3 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:58a6b5e81c644fba8bab2e05137429d9']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:eb6ddfb245f647e2bb6902f52f38a535']='UE4 D3D11/D3D12 with native FSR 2 — the NR pass rides the FSR route'
GAME_NOTE['epic:d6264d56f5ba434e91d4b0a0b056c83a']='DX11 (2013) — the NR pass runs at present time'
GAME_NOTE['epic:c90f02864e054feba10b315af7592fa3']='D3D12; upscaler support per the store page — confirm with launch --verify'
GAME_NOTE['epic:769f2fee68e9477180da900ccccbbcf0']='DX11 — the NR pass runs at present time'
GAME_NOTE['epic:dd75b5c168d546cc869582c0389f0a1d']='UE4 DX11; the Dovetail launcher window opens first — pick a route, the game exe starts after'
GAME_NOTE['epic:36b0e40890f147fbb1e3965f87369156']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Nautilus']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:dd95e8c01b4b456f8ecbf18376a49c94']='Unity DX11 — the NR pass runs at present time'
GAME_NOTE['epic:Angelonia']='DX11; server-side anti-cheat only, no kernel driver — the NR pass runs at present time'
GAME_NOTE['epic:a95bf4df6627431ca5baff8173c59635']='UE4 DX11 — the NR pass runs at present time'
GAME_NOTE['epic:8764f82381f5436f99e97172df06af35']='UE5 early access, D3D12, native DLSS 3 + FSR 2.2 + XeSS — the NR pass rides the upscaler route'

# ----------------------------------------------------------------- utils ---
say()  { printf '%s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { local rc=$1; shift; printf '[-] %s\n' "$*" >&2; exit "$rc"; }

sha_of() { sha256sum -- "$1" 2>/dev/null | awk '{print $1}'; }

pin_ok() { [[ -f $1 ]] && [[ $(sha_of "$1") == "$2" ]]; }

hr() { printf -- '----\n'; }

usage() {
    cat <<EOF
$PROG $VERSION — DLSS 5 Neural Rendering override for Steam and Epic games (Linux/Proton)

Usage: $PROG <command> [options] [args]

Games are addressed by Steam appid (e.g. 292030) or, for games owned on the
Epic Games Launcher, as 'epic:<appName>' (epic:Boga is Death Stranding);
`list` prints every id. Epic games must be installed by the Epic Games
Launcher first (they show as 'owned' until the install folder exists).

Commands:
  list [--tsv]                 Games in the Steam and Epic libraries, override
                                state, exclusions. --tsv prints one line per
                                game: source<TAB>id<TAB>title<TAB>state<TAB>exedir
                                (for the tray app; states: eligible, installed,
                                excluded, owned, tool)
  doctor [appid]                Environment checks (GPU, driver, Wineland,
                                Epic Games Launcher v2, pins)
  setup <appid> [options]       Install / update the DLSS 5 NR override in a game
  refresh <appid> [options]     Alias for setup — re-run after a driver upgrade to
                                refresh the deployed _nvngx.dll from the new driver
  preset A|B <appid>            NR model weights: A = September (Preset 1),
                                B = October, smaller and faster (Preset 2, default)
  status [appid]                Installed state per game (files, pins, ini, log)
  restore <appid>               Undo everything: engine receipt + NR model + ini edits
  launch <appid> [--verify [N]] Launch via Steam (steam -applaunch) or, for epic:
                                ids, the Epic Games Launcher URL scheme. --verify
                                polls OptiScaler.log for up to N seconds (default
                                240) and reports whether the DLSS-NR model loaded

setup/refresh options:
  --exedir DIR         Game exe folder (skips auto-detection)
  --proxy NAME         Proxy DLL name (default dxgi.dll)
  --dry-run            Plan only, write nothing
  --no-nvngx           Do not copy the driver Wine _nvngx.dll
  --allow-online       Install into an excluded online game (at your own risk)
  --replace-foreign    Replace a foreign file at the proxy name (backed up first)
  --keep-reshade       Keep an existing ReShade as ReShade64.dll, load it via OptiScaler
  --allow-second-proxy Allow a second OptiScaler proxy name in the same folder

Environment:
  DLSS5_STEAM_ROOT        Force the Steam root (default: auto-detected)
  DLSS5_EPIC_ROOTS        Epic install roots, ':'-separated (default: the Epic
                          Games Launcher's defaultInstallDir, then ~/Games)
  DLSS5_EGLV2_DIR         Epic Games Launcher v2 data dir (default:
                          $DEFAULT_EGLV2_DATA)
  DLSS5_COMPONENTS_DIR    Components cache (default: $DEFAULT_COMPONENTS_DIR)
EOF
    exit "${1:-0}"
}

# ------------------------------------------------------------ components ---
components_dir() { printf '%s\n' "${DLSS5_COMPONENTS_DIR:-$DEFAULT_COMPONENTS_DIR}"; }
retoque_dir()     { printf '%s\n' "$(components_dir)/retoque"; }
model_file()      { printf '%s\n' "$(components_dir)/nvngx_dlssnr.dll"; }
engine_file()    { printf '%s\n' "$(retoque_dir)/deploy-to-game.sh"; }

# ----------------------------------------------------------- steam library --
steam_root() {
    local r
    [[ -n ${DLSS5_STEAM_ROOT:-} ]] && { printf '%s\n' "$DLSS5_STEAM_ROOT"; return 0; }
    for r in "${DEFAULT_STEAM_ROOTS[@]}"; do
        [[ -d $r/steamapps ]] && { printf '%s\n' "$r"; return 0; }
    done
    return 1
}

library_dirs() { # $1 = steam root -> library roots, one per line
    local root=$1 vdf=$root/steamapps/libraryfolders.vdf d
    local -a out=()
    if [[ -f $vdf ]]; then
        while IFS= read -r d; do
            [[ -n $d ]] && out+=("$d")
        done < <(sed -n 's/.*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf")
    fi
    (( ${#out[@]} )) || out+=("$root")
    printf '%s\n' "${out[@]}"
}

acf_value() { # $1 = acf file, $2 = key -> first value
    sed -n "s/.*\"$2\"[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -n1
}

find_manifest() { # $1 = appid -> path
    local appid=$1 root lib m
    root=$(steam_root) || return 1
    while IFS= read -r lib; do
        m="$lib/steamapps/appmanifest_$appid.acf"
        [[ -f $m ]] && { printf '%s\n' "$m"; return 0; }
    done < <(library_dirs "$root")
    return 1
}

require_game() { # $1 = appid (numeric Steam id or 'epic:<appName>');
                 #   sets GAME_NAME, GAME_DIR, GAME_MANIFEST ('' for epic)
    if is_epic "$1"; then
        [[ -n ${EPIC_GAME_TITLE[$1]:-} ]] ||
            die 1 "unknown Epic game: $1 is not in this launcher's Epic table"
        [[ -z ${EPIC_GAME_SKIP[$1]:-} ]] ||
            die 1 "${EPIC_GAME_TITLE[$1]} is not a game: ${EPIC_GAME_SKIP[$1]}"
        GAME_NAME=${EPIC_GAME_TITLE[$1]}
        GAME_MANIFEST=''
        if [[ -n ${GAME_EXCLUDE_REASON[$1]:-} ]]; then
            # an excluded game never needs an install dir: every command
            # reports the exclusion before it touches the exe dir
            GAME_DIR=''
            epic_gamedir_for "$1" >/dev/null 2>&1 && GAME_DIR=$(epic_gamedir_for "$1")
            return 0
        fi
        GAME_DIR=$(epic_gamedir_for "$1") || die 1 \
"$GAME_NAME is owned but not installed — install it with the Epic Games Launcher into: $(epic_roots | tr '\n' ' ')then re-run this command"
        return 0
    fi
    GAME_MANIFEST=$(find_manifest "$1") ||
        die 1 "appid $1 is not installed in any Steam library this launcher can see"
    GAME_NAME=$(acf_value "$GAME_MANIFEST" name)
    local installdir lib
    installdir=$(acf_value "$GAME_MANIFEST" installdir)
    lib=$(dirname "$(dirname "$GAME_MANIFEST")")
    GAME_DIR="$lib/steamapps/common/$installdir"
    [[ -d $GAME_DIR ]] || die 1 "install dir missing: $GAME_DIR"
    [[ -n $GAME_NAME ]] || GAME_NAME="appid $1"
}

compat_tool_for() { # $1 = appid -> compat tool id or empty (epic: EGL's own Proton)
    local root cfg
    is_epic "$1" && return 0
    root=$(steam_root) || return 0
    cfg="$root/config/config.vdf"
    [[ -f $cfg ]] || return 0
    grep -A3 "^[[:space:]]*\"$1\"$" "$cfg" 2>/dev/null |
        grep -m1 '"compat_tool"' |
        sed 's/.*"compat_tool"[[:space:]]*"\([^"]*\)".*/\1/' || true
}

launch_options_for() { # $1 = appid -> stored Steam launch options or empty
    local root cfg out
    is_epic "$1" && return 0
    root=$(steam_root) || return 0
    while IFS= read -r cfg; do
        [[ -f $cfg ]] || continue
        # values embed escaped quotes, so capture greedily to the last quote
        out=$(grep -A6 "^[[:space:]]*\"$1\"$" "$cfg" 2>/dev/null |
            grep -m1 'LaunchOptions' |
            sed 's/.*"LaunchOptions"[[:space:]]*"\(.*\)"/\1/')
        [[ -n $out ]] && { printf '%s\n' "$out"; return 0; }
    done < <(find "$root/userdata" -maxdepth 3 -name localconfig.vdf 2>/dev/null)
    return 0
}

# ------------------------------------------------------ epic library ----
# Epic games are 'epic:<appName>' keys in the same GAME_* maps the Steam
# table uses; the helpers below resolve data dir, install roots, and the
# owned-library cache of the native Epic Games Launcher v2.
is_epic()  { [[ $1 == epic:* ]]; }
epic_app() { printf '%s\n' "${1#epic:}"; }

eglv2_data() { # EGL v2 data dir (DLSS5_EGLV2_DIR overrides)
    printf '%s\n' "${DLSS5_EGLV2_DIR:-$DEFAULT_EGLV2_DATA}"
}

epic_roots() { # game install roots, one per line (DLSS5_EPIC_ROOTS overrides)
    local d r
    if [[ -n ${DLSS5_EPIC_ROOTS:-} ]]; then
        tr ':' '\n' <<<"$DLSS5_EPIC_ROOTS"
        return 0
    fi
    d=$(sed -n 's/.*"defaultInstallDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        "$(eglv2_data)/settings/app-settings.json" 2>/dev/null | head -n1)
    [[ -n $d ]] && printf '%s\n' "$d"
    for r in "${DEFAULT_EPIC_ROOTS[@]}"; do
        [[ -n $d && $r == "$d" ]] || printf '%s\n' "$r"
    done
}

epic_gamedir_for() { # $1 = 'epic:app' -> install dir (empty + rc 1 when absent)
    local key=$1 folder root
    folder=${EPIC_GAME_DIR[$key]:-}
    [[ -n $folder ]] || return 1
    while IFS= read -r root; do
        [[ -d $root/$folder ]] && { printf '%s\n' "$root/$folder"; return 0; }
    done < <(epic_roots)
    return 1
}

epic_cache_appnames() { # appNames from the EGL v2 library cache, one per line
    local lib
    lib=$(find "$(eglv2_data)/cache/prod/account" -maxdepth 2 -name library-cache.json 2>/dev/null | head -n1)
    [[ -n $lib ]] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$lib" 2>/dev/null <<'PYEOF' || return 0
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for item in data.get('items', []):
        app = (item.get('appId') or {}).get('appName')
        if app:
            print(app)
except Exception:
    pass
PYEOF
    return 0
}

epic_list_keys() { # every table key, sorted by title (one 'epic:app' per line)
    local k
    for k in "${!EPIC_GAME_TITLE[@]}"; do
        printf '%s\t%s\n' "${EPIC_GAME_TITLE[$k]}" "$k"
    done | sort -t$'\t' -k1,1 | cut -f2
}

epic_cross_check() { # warn when the EGL v2 cache holds items missing from the table
    local app
    while IFS= read -r app; do
        [[ -n $app ]] || continue
        [[ -n ${EPIC_GAME_TITLE[epic:$app]:-} ]] ||
            warn "Epic item not assessed in this launcher's table: epic:$app (new purchase? add it)"
    done < <(epic_cache_appnames)
}

# ------------------------------------------------------------- exe dir ----
resolve_exedir() { # $1 = appid, $2 = game dir -> exe folder
    local appid=$1 gamedir=$2 sub
    if [[ -n ${GAME_EXE_SUBDIR[$appid]:-} ]]; then
        sub=${GAME_EXE_SUBDIR[$appid]}
        [[ -d $gamedir/$sub ]] ||
            die 1 "expected exe folder '$sub' not found under $gamedir (game updated?)"
        printf '%s\n' "$gamedir/$sub"
        return 0
    fi
    local f d best='' bestscore=-1 score depth
    declare -A cnt=()
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        d=$(dirname "$f")
        cnt[$d]=$(( ${cnt[$d]:-0} + 1 ))
    done < <(find "$gamedir" -maxdepth 4 -type f -iname '*.exe' ! -iname '*crash*' ! -iname '*setup*' ! -iname '*anticheat*' ! -iname '*installer*' 2>/dev/null)
    for d in "${!cnt[@]}"; do
        depth=$(awk -F/ '{print NF}' <<< "${d#"$gamedir"}")
        score=$(( cnt[$d] * 10 - depth ))
        if (( score > bestscore )); then best=$d; bestscore=$score; fi
    done
    [[ -n $best ]] ||
        die 1 "no game executable found under $gamedir; pass --exedir explicitly"
    printf '%s\n' "$best"
}

# ------------------------------------------------------------------ ini ----
# Same semantics as the deploy engine: a key is replaced in place inside its
# section, later duplicates are dropped (the parser keeps the last one), and a
# missing key is inserted at the end of its section. CRLF-aware: a replaced
# line keeps its own line ending, injected lines use the file's style, so a
# Windows ini never becomes mixed-endings (a drifted hash would make the
# engine's uninstall treat the ini as user-edited and leave it behind).
ini_set() { # $1 file  $2 section  $3 key  $4 value
    local file=$1 section=$2 key=$3 value=$4 tmp
    [[ -f $file ]] || die 2 "ini_set: no such file: $file"
    tmp=$(mktemp) || die 2 'mktemp failed'
    awk -v sec="[$section]" -v key="$key" -v val="$value" '
        BEGIN { CR = sprintf("%c", 13); insec = 0; injected = 0; anysec = 0; style = "" }
        NR == 1 && index($0, CR) > 0 { style = CR }
        /^[[:space:]]*\[/ {
            if (insec && !injected) { print key "=" val style; injected = 1 }
            line = $0; gsub(/[[:space:]]/, "", line)
            insec = (tolower(line) == tolower(sec)) ? 1 : 0
            if (insec) anysec = 1
            print; next
        }
        insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
            if (!injected) { print key "=" val (index($0, CR) > 0 ? CR : ""); injected = 1 }
            next
        }
        { print }
        END {
            if (!injected) {
                if (!insec) print sec style
                print key "=" val style
            }
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; die 2 'ini_set: awk failed'; }
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f -T -- "$tmp" "$file"
}

ini_get() { # $1 file  $2 section  $3 key -> value, CR and trailing space stripped
    local v
    [[ -f $1 ]] || return 0
    v=$(awk -v sec="[$2]" -v key="$3" '
        BEGIN { insec = 0 }
        /^[[:space:]]*\[/ {
            line = $0; gsub(/[[:space:]]/, "", line)
            insec = (tolower(line) == tolower(sec)) ? 1 : 0
            next
        }
        insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") {
            sub(/^[^=]*[[:space:]]*=[[:space:]]*/, "")
            print; exit
        }
    ' "$1")
    v=${v%$'\r'}
    v="${v%"${v##*[![:space:]]}"}"   # trim trailing whitespace
    printf '%s\n' "$v"
}

ini_del() { # $1 file  $2 section  $3 key — remove the key line from the section
    local file=$1 section=$2 key=$3 tmp
    [[ -f $file ]] || return 0
    tmp=$(mktemp) || return 0
    awk -v sec="[$section]" -v key="$key" '
        BEGIN { insec = 0 }
        /^[[:space:]]*\[/ {
            line = $0; gsub(/[[:space:]]/, "", line)
            insec = (tolower(line) == tolower(sec)) ? 1 : 0
            print; next
        }
        insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=") { next }
        { print }
    ' "$file" > "$tmp" && mv -f -T -- "$tmp" "$file" || rm -f -- "$tmp"
}

# ---------------------------------------------------------------- guards ---
GPU_NAME='' GPU_DRIVER=''
gpu_info() {
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || true)
    GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)
}

require_rtx50() {
    gpu_info
    [[ -n $GPU_NAME ]] ||
        die 1 'no NVIDIA GPU visible (nvidia-smi failed); this override needs an RTX 50 GPU'
    [[ $GPU_NAME == *"RTX 50"* ]] || die 1 \
        "GPU is $GPU_NAME: the NVIDIA-signed DLSS 5 NR model starts on RTX 50 (Blackwell) only; RTX 20/30/40 need the community model via DLSS AiO Swapper"
}

driver_notes() {
    gpu_info
    case $GPU_DRIVER in
        621.01*) warn 'driver 621.01 is known-bad for the lecram/RenoDX ReShade add-on route in The Witcher 3 (crash at game start); 615.71.09 works' ;;
        620.73*) warn 'driver 620.73.04 GPU-faults in DOOM Eternal about a minute in, with or without Retoque loaded' ;;
    esac
}

verify_components() {
    local rd mf
    rd=$(retoque_dir)
    mf=$(model_file)
    [[ -f $rd/OptiScaler.dll ]]        || die 1 "missing component: $rd/OptiScaler.dll"
    [[ -f $rd/nvngx.dll_dlssnr.dll ]]  || die 1 "missing component: $rd/nvngx.dll_dlssnr.dll"
    [[ -f $rd/OptiScaler.ini ]]       || die 1 "missing component: $rd/OptiScaler.ini"
    [[ -f $rd/deploy-to-game.sh ]]     || die 1 "missing component: $rd/deploy-to-game.sh"
    [[ -f $mf ]]                       || die 1 "missing component: $mf (DLSS 5 NR model)"
    pin_ok "$rd/OptiScaler.dll" "$PIN_OPTISCALER" ||
        die 1 "SHA-256 mismatch: $rd/OptiScaler.dll is not the pinned Retoque 0.3.3 build"
    pin_ok "$rd/nvngx.dll_dlssnr.dll" "$PIN_FORWARDER" ||
        die 1 "SHA-256 mismatch: $rd/nvngx.dll_dlssnr.dll is not the pinned Retoque 0.3.3 forwarder"
    pin_ok "$mf" "$PIN_MODEL" ||
        die 1 "SHA-256 mismatch: $mf is not the pinned NVIDIA nvngx_dlssnr.dll 310.9.16"
    say '[+] components verified: Retoque 0.3.3 (engine, forwarder) + NVIDIA NR model 310.9.16 — all SHA pins match'
}

driver_wine_nvngx() { # -> first existing driver wine _nvngx.dll path
    local p
    for p in "${DRIVER_WINE_NVNGX_CANDIDATES[@]}"; do
        [[ -f $p ]] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

# ------------------------------------------------------------- journal ----
journal_add() { # $1 = exedir, $2 = line
    mkdir -p -- "$1/.dlss5-launcher"
    printf '%s\n' "$2" >> "$1/.dlss5-launcher/journal.txt"
}

# ------------------------------------------------------------ commands -----
cmd_list() {
    local tsv=0
    [[ ${1:-} == --tsv ]] && tsv=1
    local root lib m appid name installdir dir tool cls k title state exedir
    local epic_installed=0 epic_excluded=0
    if ! root=$(steam_root); then
        warn 'no Steam root found (set DLSS5_STEAM_ROOT?) — listing Epic games only'
        root=''
    fi
    if (( tsv )); then
        # machine-readable: source<TAB>id<TAB>title<TAB>state<TAB>exedir
        # (states: eligible, installed, excluded, owned, tool) — for the tray app
        if [[ -n $root ]]; then
            while IFS= read -r m; do
                appid=$(basename "$m" .acf); appid=${appid#appmanifest_}
                name=$(acf_value "$m" name)
                installdir=$(acf_value "$m" installdir)
                lib=$(dirname "$(dirname "$m")")
                dir="$lib/steamapps/common/$installdir"
                cls=tool
                [[ $TOOL_APPIDS == *" $appid "* ]] || cls=game
                exedir='-'
                if [[ $cls == game ]]; then
                    exedir=$(resolve_exedir_quiet "$appid" "$dir")
                    if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]]; then
                        cls=excluded
                    elif [[ $exedir != '-' && -f $exedir/.retoque/receipt.txt ]]; then
                        cls=installed
                    else
                        cls=eligible
                    fi
                fi
                printf 'steam\t%s\t%s\t%s\t%s\n' "$appid" "$name" "$cls" "$exedir"
            done < <(find_root_manifests "$root")
        fi
        while IFS= read -r k; do
            title=${EPIC_GAME_TITLE[$k]}
            exedir='-'
            if [[ -n ${EPIC_GAME_SKIP[$k]:-} ]]; then
                state=tool
            elif [[ -n ${GAME_EXCLUDE_REASON[$k]:-} ]]; then
                state=excluded
            elif dir=$(epic_gamedir_for "$k"); then
                exedir=$(resolve_exedir_quiet "$k" "$dir")
                if [[ $exedir != '-' && -f $exedir/.retoque/receipt.txt ]]; then
                    state=installed
                else
                    state=eligible
                fi
            else
                state=owned
            fi
            printf 'epic\t%s\t%s\t%s\t%s\n' "$k" "$title" "$state" "$exedir"
        done < <(epic_list_keys)
        epic_cross_check
        return 0
    fi
    # ---- human-readable ----
    if [[ -n $root ]]; then
        say "Steam root: $root"
        hr
        printf '%-10s %-28s %-8s %-22s %s\n' APPID GAME STATE 'COMPAT TOOL' 'EXE DIR'
        while IFS= read -r m; do
            appid=$(basename "$m" .acf); appid=${appid#appmanifest_}
            name=$(acf_value "$m" name)
            installdir=$(acf_value "$m" installdir)
            lib=$(dirname "$(dirname "$m")")
            dir="$lib/steamapps/common/$installdir"
            tool=$(compat_tool_for "$appid"); tool=${tool:-"-"}
            local cls=tool
            [[ $TOOL_APPIDS == *" $appid "* ]] || cls=game
            local exedir='-'
            if [[ $cls == game ]]; then
                exedir=$(resolve_exedir_quiet "$appid" "$dir")
                if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]]; then
                    cls=excluded
                elif [[ $exedir != '-' && -f $exedir/.retoque/receipt.txt ]]; then
                    cls=installed
                else
                    cls=eligible
                fi
            fi
            printf '%-10s %-28s %-9s %-22s %s\n' \
                "$appid" "${name:0:28}" "$cls" "${tool:0:22}" "$exedir"
        done < <(find_root_manifests "$root")
        hr
        local a
        for a in "${!GAME_EXCLUDE_REASON[@]}"; do
            [[ $a == epic:* ]] && continue
            say "excluded  $a: ${GAME_EXCLUDE_REASON[$a]}"
        done
    fi
    # ---- Epic Games Launcher (EGL v2) owned library ----
    say "Epic roots: $(epic_roots | tr '\n' ' ')"
    hr
    printf '%-43s %-44s %-9s %s\n' ID TITLE STATE 'EXE DIR'
    while IFS= read -r k; do
        title=${EPIC_GAME_TITLE[$k]}
        exedir='-'
        if [[ -n ${EPIC_GAME_SKIP[$k]:-} ]]; then
            state=tool
        elif [[ -n ${GAME_EXCLUDE_REASON[$k]:-} ]]; then
            state=excluded
            epic_excluded=$((epic_excluded + 1))
        elif dir=$(epic_gamedir_for "$k"); then
            epic_installed=$((epic_installed + 1))
            exedir=$(resolve_exedir_quiet "$k" "$dir")
            if [[ $exedir != '-' && -f $exedir/.retoque/receipt.txt ]]; then
                state=installed
            else
                state=eligible
            fi
        else
            state=owned
        fi
        printf '%-43s %-44s %-9s %s\n' "$k" "${title:0:44}" "$state" "$exedir"
    done < <(epic_list_keys)
    hr
    local epic_total=${#EPIC_GAME_TITLE[@]}
    local epic_skip=${#EPIC_GAME_SKIP[@]}
    say "Epic games: $epic_installed installed, $((epic_total - epic_skip - epic_excluded)) eligible, $epic_excluded excluded, $epic_skip not games ($epic_total owned items)"
    while IFS= read -r k; do
        [[ -n ${GAME_EXCLUDE_REASON[$k]:-} ]] &&
            say "excluded  $k: ${GAME_EXCLUDE_REASON[$k]}"
    done < <(epic_list_keys)
    epic_cross_check
}

find_root_manifests() { # $1 = root -> all appmanifest paths across libraries
    local root=$1 lib
    while IFS= read -r lib; do
        find "$lib/steamapps" -maxdepth 1 -name 'appmanifest_*.acf' 2>/dev/null
    done < <(library_dirs "$root") | sort -u
}

resolve_exedir_quiet() { # $1 appid $2 dir -> exe dir or '-' (never dies)
    local out
    out=$(resolve_exedir "$1" "$2" 2>/dev/null) || { echo '-'; return; }
    printf '%s\n' "$out"
}

cmd_doctor() {
    local appid=${1:-} drv_nvngx='' rd
    gpu_info
    say "== $PROG $VERSION doctor =="
    if [[ -n $GPU_NAME ]]; then
        say "GPU      : $GPU_NAME (driver $GPU_DRIVER)"
        if [[ $GPU_NAME == *"RTX 50"* ]]; then
            say 'RTX 50   : yes — the NVIDIA-signed NR model can run'
        else
            warn 'GPU is not RTX 50: the pinned NR model will not run'
        fi
    else
        warn 'no NVIDIA GPU visible (nvidia-smi failed)'
    fi
    driver_notes
    if drv_nvngx=$(driver_wine_nvngx); then
        say "driver Wine NGX : $drv_nvngx ($(stat -c %s "$drv_nvngx") bytes)"
        say "                  nvngx.dll beside it: $(dirname "$drv_nvngx")/nvngx.dll"
    else
        warn 'driver Wine NGX DLLs not found (install the nvidia driver wine NGX component)'
    fi
    local root
    root=$(steam_root) || { warn 'no Steam root found'; root=''; }
    if [[ -n $root ]]; then
        local ct="$root/compatibilitytools.d/$WINELAND_NAME"
        if [[ -d $ct ]]; then
            say "Wineland : $ct"
        else
            warn "Wineland Proton not found under $root/compatibilitytools.d (DLSS 5 NR needs it)"
        fi
    fi
    rd=$(retoque_dir)
    if [[ -d $rd ]]; then
        if pin_ok "$rd/OptiScaler.dll" "$PIN_OPTISCALER"; then
            say "Retoque  : $rd — OptiScaler.dll pin OK"
        else
            warn "Retoque  : $rd — OptiScaler.dll pin MISMATCH"
        fi
        if pin_ok "$(model_file)" "$PIN_MODEL"; then
            say "NR model: $(model_file) — 310.9.16 pin OK"
        else
            warn "NR model: $(model_file) — pin MISMATCH (expected NVIDIA 310.9.16)"
        fi
        local zip tarx
        zip="$(components_dir)/Retoque-v0.3.3.zip"
        tarx="$(components_dir)/wineland.tar.xz"
        if [[ -f $zip ]]; then
            if pin_ok "$zip" "$PIN_RETOQUE_ZIP"; then
                say "archive  : Retoque-v0.3.3.zip pin OK"
            else
                warn 'archive  : Retoque-v0.3.3.zip pin mismatch'
            fi
        fi
        if [[ -f $tarx ]]; then
            if pin_ok "$tarx" "$PIN_WINELAND_TAR"; then
                say "archive  : wineland.tar.xz pin OK"
            else
                warn 'archive  : wineland.tar.xz pin mismatch'
            fi
        fi
    else
        warn "components dir not found: $(components_dir)"
    fi
    if pgrep -f '[s]teamwebhelper|[s]steamrt64/steam' >/dev/null 2>&1; then
        say 'Steam    : running (launches go through the running client)'
    else
        say 'Steam    : not running'
    fi
    # ---- Epic Games Launcher v2 ----
    local egl eglbin handler eroot ekey ecount=0
    egl=$(eglv2_data)
    if [[ -d $egl ]]; then
        say "Epic EGLv2: $egl"
    else
        warn "Epic EGLv2: data dir not found: $egl (Epic support needs the Epic Games Launcher v2)"
    fi
    if eglbin=$(command -v "$EPIC_LAUNCH_CMD" 2>/dev/null); then
        say "Epic bin  : $eglbin"
    else
        warn "Epic bin  : $EPIC_LAUNCH_CMD not found in PATH"
    fi
    if command -v xdg-mime >/dev/null 2>&1; then
        handler=$(xdg-mime query default x-scheme-handler/com.epicgames.launcher 2>/dev/null)
        if [[ -n $handler ]]; then
            say "Epic URL  : com.epicgames.launcher:// handled by $handler"
        else
            warn 'Epic URL  : no handler registered for com.epicgames.launcher://'
        fi
    fi
    while IFS= read -r eroot; do
        [[ -n $eroot ]] || continue
        if [[ -d $eroot ]]; then
            say "Epic root : $eroot"
        else
            say "Epic root : $eroot (not created yet — the launcher makes it on first install)"
        fi
    done < <(epic_roots)
    while IFS= read -r ekey; do
        if epic_gamedir_for "$ekey" >/dev/null 2>&1; then
            ecount=$((ecount + 1))
        fi
    done < <(epic_list_keys)
    say "Epic games: $ecount installed of ${#EPIC_GAME_TITLE[@]} owned (table as of 2026-11-22)"
    if [[ -n $appid ]]; then
        hr
        status_one "$appid"
    fi
    return 0
}

# setup/refresh shared implementation ---------------------------------------
cmd_setup() {
    local appid=$1; shift
    local opt_exedir='' opt_proxy=dxgi.dll opt_dryrun=0 opt_nvngx=1
    local opt_allow_online=0 opt_replace_foreign=0 opt_keep_reshade=0 opt_allow_second=0
    while (( $# )); do
        case $1 in
            --exedir) opt_exedir=$2; shift 2 ;;
            --proxy) opt_proxy=$2; shift 2 ;;
            --dry-run|-n) opt_dryrun=1; shift ;;
            --no-nvngx) opt_nvngx=0; shift ;;
            --allow-online) opt_allow_online=1; shift ;;
            --replace-foreign) opt_replace_foreign=1; shift ;;
            --keep-reshade) opt_keep_reshade=1; shift ;;
            --allow-second-proxy) opt_allow_second=1; shift ;;
            *) die 1 "setup: unknown option: $1" ;;
        esac
    done
    require_game "$appid"
    if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]] && (( ! opt_allow_online )); then
        die 1 "refusing $appid ($GAME_NAME): ${GAME_EXCLUDE_REASON[$appid]} (override with --allow-online at your own risk)"
    fi
    require_rtx50
    driver_notes
    verify_components

    local exedir
    if [[ -n $opt_exedir ]]; then
        exedir=$opt_exedir
    else
        exedir=$(resolve_exedir "$appid" "$GAME_DIR")
    fi
    [[ -d $exedir ]] || die 1 "exe folder does not exist: $exedir"

    if is_epic "$appid"; then
        say "game     : $GAME_NAME ($appid)"
    else
        say "game     : $GAME_NAME (appid $appid)"
    fi
    say "exe dir  : $exedir"
    say "proxy    : $opt_proxy"
    [[ -n ${GAME_NOTE[$appid]:-} ]] && say "note     : ${GAME_NOTE[$appid]}"

    local -a eargs=(--source-dir "$(retoque_dir)" --enable-nr)
    (( opt_dryrun ))          && eargs+=(--dry-run)
    (( ! opt_nvngx ))         && eargs+=(--no-nvngx)
    (( opt_replace_foreign )) && eargs+=(--replace-foreign)
    (( opt_keep_reshade ))    && eargs+=(--keep-reshade)
    (( opt_allow_second ))    && eargs+=(--allow-second-proxy)
    eargs+=("$exedir" "$opt_proxy")

    local rc=0
    bash "$(engine_file)" "${eargs[@]}" || rc=$?
    (( rc == 0 )) || { warn "deploy engine exited $rc (see its output above)"; exit "$rc"; }

    if (( opt_dryrun )); then
        say '[=] dry run: nothing written (model and ini keys would follow)'
        return 0
    fi

    # NR model — the engine never ships or touches nvngx_dlssnr.dll
    local dst="$exedir/nvngx_dlssnr.dll" mf tmp
    mf=$(model_file)
    if [[ -f $dst ]] && [[ $(sha_of "$dst") == "$PIN_MODEL" ]]; then
        say '[=] nvngx_dlssnr.dll already present and matches the pinned 310.9.16 model'
    else
        [[ -f $dst ]] && warn 'replacing an nvngx_dlssnr.dll whose hash is not the pinned model'
        tmp=$(mktemp "$exedir/.dlss5-launcher.incoming.XXXXXX")
        cp -- "$mf" "$tmp"
        mv -f -T -- "$tmp" "$dst"
        [[ $(sha_of "$dst") == "$PIN_MODEL" ]] || die 1 'model copy failed its SHA check'
        say '[+] installed nvngx_dlssnr.dll — DLSS 5 NR model 310.9.16 (NVIDIA, SHA pinned)'
    fi
    journal_add "$exedir" "model	$PIN_MODEL	nvngx_dlssnr.dll"

    # ini keys (engine set Enabled=true via --enable-nr; verify, then preset)
    local ini="$exedir/OptiScaler.ini"
    [[ -f $ini ]] || die 1 "engine did not leave an OptiScaler.ini at $ini"
    local cur
    cur=$(ini_get "$ini" DlssNr Enabled)
    if [[ $cur != true ]]; then
        ini_set "$ini" DlssNr Enabled true
        journal_add "$exedir" "ini	DlssNr	Enabled	${cur:-unset}	true"
        say '[+] [DlssNr] Enabled=true'
    else
        say '[=] [DlssNr] Enabled already true'
    fi
    cur=$(ini_get "$ini" DlssNr Preset)
    if [[ -z $cur || $cur == auto ]]; then
        ini_set "$ini" DlssNr Preset 2
        journal_add "$exedir" "ini	DlssNr	Preset	${cur:-unset}	2"
        say '[+] [DlssNr] Preset=2 (model B, October — smaller and faster; default)'
    else
        say "[=] [DlssNr] Preset already $cur"
    fi

    hr
    say "receipt  : $exedir/.retoque/receipt.txt (engine journal; restore uses it)"
    say "journal  : $exedir/.dlss5-launcher/journal.txt (model + launcher ini keys)"

    local tool
    if is_epic "$appid"; then
        say 'compat   : the Epic Games Launcher runs this game under its own Proton runtime'
        say '           (no Steam compat-tool mapping applies here)'
        say "reminder : if the proxy does not load, set WINEDLLOVERRIDES=${opt_proxy%.*}=n,b"
        say '           in the game environment (the Epic Games Launcher starts the game)'
    else
        tool=$(compat_tool_for "$appid")
        if [[ $tool == "$WINELAND_NAME" ]]; then
            say "compat   : $tool (OK)"
        else
            warn "this game is not set to $WINELAND_NAME (currently: ${tool:-default}) — DLSS 5 NR needs the Wineland Proton"
            say '         Steam UI: right-click the game > Properties > Compatibility >'
            say "         Force the use of a specific tool > $WINELAND_NAME"
        fi
        say 'reminder : if the proxy does not load, set the game launch options to'
        say "           WINEDLLOVERRIDES=\"${opt_proxy%.*}=n,b\" %command%"
    fi
    say "undo     : $PROG restore $appid"
}

cmd_preset() {
    local which=$1 appid=$2 ini key val
    case $which in
        A|a) key=1; val='A (September model, the original)' ;;
        B|b) key=2; val='B (October model, smaller and faster)' ;;
        *) die 1 "preset: expected A or B, got '$which'" ;;
    esac
    require_game "$appid"
    local exedir
    exedir=$(resolve_exedir "$appid" "$GAME_DIR")
    ini="$exedir/OptiScaler.ini"
    [[ -f $ini ]] || die 1 "no OptiScaler.ini at $ini — run setup first"
    local cur
    cur=$(ini_get "$ini" DlssNr Preset)
    ini_set "$ini" DlssNr Preset "$key"
    journal_add "$exedir" "ini	DlssNr	Preset	${cur:-unset}	$key"
    say "[+] $GAME_NAME: [DlssNr] Preset=$key — model $val"
    say '    applies at the next game start'
}

status_one() {
    local appid=$1 exedir dir proxy receipt model_hash ini enabled preset tool
    require_game "$appid"
    dir=$GAME_DIR
    exedir=$(resolve_exedir_quiet "$appid" "$dir")
    if is_epic "$appid"; then
        tool="EGLv2 (the Epic Games Launcher's own Proton runtime)"
        say "$GAME_NAME ($appid)"
    else
        tool=$(compat_tool_for "$appid"); tool=${tool:-"(default)"}
        say "$GAME_NAME (appid $appid)"
    fi
    say "  exe dir   : $exedir"
    say "  compat    : $tool"
    if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]]; then
        say "  state     : EXCLUDED — ${GAME_EXCLUDE_REASON[$appid]}"
        return 0
    fi
    [[ $exedir == '-' ]] && { say '  state     : no exe dir resolved'; return 0; }
    proxy=missing
    [[ -f $exedir/dxgi.dll ]] && proxy=dxgi.dll
    local p
    for p in winmm.dll version.dll d3d12.dll dbghelp.dll winhttp.dll wininet.dll; do
        [[ -f $exedir/$p ]] && { proxy=$p; break; }
    done
    receipt='none'
    if [[ -f $exedir/.retoque/receipt.txt ]]; then
        receipt=$(awk -F'\t' '$1=="status"{print $2}' "$exedir/.retoque/receipt.txt" | tail -n1)
        receipt="${receipt:-present} ($(stat -c '%y' "$exedir/.retoque/receipt.txt" | cut -d. -f1))"
    fi
    model_hash=$(sha_of "$exedir/nvngx_dlssnr.dll" 2>/dev/null || true)
    if [[ -z $model_hash ]]; then
        model_hash='missing'
    elif [[ $model_hash == "$PIN_MODEL" ]]; then
        model_hash='310.9.16 (pinned) OK'
    else
        model_hash="present, hash $model_hash (NOT the pinned model)"
    fi
    ini="$exedir/OptiScaler.ini"
    enabled=$(ini_get "$ini" DlssNr Enabled 2>/dev/null || true); enabled=${enabled:-unset}
    preset=$(ini_get "$ini" DlssNr Preset 2>/dev/null || true)
    case $preset in
        1) preset='1 = model A (September)' ;;
        2) preset='2 = model B (October, default)' ;;
        ''|auto) preset='auto (falls back to model B)' ;;
    esac
    local nvngx_state='n/a'
    local drv
    if drv=$(driver_wine_nvngx); then
        if [[ -f $exedir/_nvngx.dll ]]; then
            if [[ $(sha_of "$exedir/_nvngx.dll") == $(sha_of "$drv") ]]; then
                nvngx_state='fresh (matches current driver)'
            else
                nvngx_state="STALE — run: $PROG refresh $appid after this driver upgrade"
            fi
        fi
    fi
    say "  proxy     : $proxy"
    say "  receipt   : $receipt"
    say "  NR model  : $model_hash"
    say "  _nvngx.dll: $nvngx_state"
    say "  ini       : [DlssNr] Enabled=$enabled, Preset=$preset"
    local log="$exedir/OptiScaler.log"
    if [[ -f $log ]]; then
        say "  last log  : $(stat -c '%y' "$log" | cut -d. -f1)"
        local run model_fail
        run=$(grep -a -m1 'DLSS-NR running' "$log" 2>/dev/null || true)
        model_fail=$(grep -a -c 'kernels cannot be loaded' "$log" 2>/dev/null || true)
        if [[ -n $run ]]; then
            say "             : $run"
        fi
        if (( ${model_fail:-0} > 0 )); then
            say "             : WARNING — 'kernels cannot be loaded' seen $model_fail time(s) in the last log (model did not load)"
        fi
    else
        say '  last log  : none yet (game has not run with the override)'
    fi
}

cmd_status() {
    local appid=${1:-}
    if [[ -n $appid ]]; then
        status_one "$appid"
        return 0
    fi
    local root m a k
    root=$(steam_root) || die 1 'no Steam root found'
    while IFS= read -r m; do
        a=$(basename "$m" .acf); a=${a#appmanifest_}
        [[ $TOOL_APPIDS == *" $a "* ]] && continue
        status_one "$a"
        hr
    done < <(find_root_manifests "$root")
    while IFS= read -r k; do
        [[ -z ${EPIC_GAME_SKIP[$k]:-} ]] || continue
        epic_gamedir_for "$k" >/dev/null 2>&1 || continue
        status_one "$k"
        hr
    done < <(epic_list_keys)
}

cmd_restore() {
    local appid=$1 exedir rc
    require_game "$appid"
    exedir=$(resolve_exedir "$appid" "$GAME_DIR")
    [[ -d $exedir ]] || die 1 "no exe dir: $exedir"

    # Revert this launcher's ini edits first (reverse journal order): the
    # engine's uninstall only removes/restores files whose hash still matches
    # what it recorded, so the ini must look exactly as the engine left it.
    local journal="$exedir/.dlss5-launcher/journal.txt" ini="$exedir/OptiScaler.ini"
    if [[ -f $journal && -f $ini ]]; then
        local kind section key old new cur
        while IFS=$'\t' read -r kind section key old new; do
            [[ $kind == ini ]] || continue
            cur=$(ini_get "$ini" "$section" "$key")
            [[ $cur == "$new" ]] || continue   # changed since; leave it alone
            if [[ -z $old || $old == unset ]]; then
                ini_del "$ini" "$section" "$key"
            else
                ini_set "$ini" "$section" "$key" "$old"
            fi
        done < <(tac "$journal")
    fi

    local -a eargs=(--uninstall "$exedir")
    rc=0
    bash "$(engine_file)" "${eargs[@]}" || rc=$?
    # the engine receipt never covers the NR model — remove it only if it is ours
    local dst="$exedir/nvngx_dlssnr.dll"
    if [[ -f $dst ]]; then
        if [[ $(sha_of "$dst") == "$PIN_MODEL" ]]; then
            rm -f -- "$dst"
            say '[+] removed nvngx_dlssnr.dll (pinned model installed by this launcher)'
        else
            warn "leaving $dst: its hash is not the pinned model (not ours to remove)"
        fi
    fi
    rm -rf -- "$exedir/.dlss5-launcher" 2>/dev/null || true
    (( rc == 0 )) || exit "$rc"
    say "[+] $GAME_NAME: override fully removed (engine receipt + model + launcher journal)"
}

cmd_launch() {
    local appid=$1; shift
    local opt_verify=0 opt_timeout=240
    while (( $# )); do
        case $1 in
            --verify) opt_verify=1; [[ ${2:-} =~ ^[0-9]+$ ]] && { opt_timeout=$2; shift; } ;;
            --timeout) opt_timeout=$2; shift 2 ;;
            *) die 1 "launch: unknown option: $1" ;;
        esac
        shift || true
    done
    require_game "$appid"
    local exedir log
    exedir=$(resolve_exedir_quiet "$appid" "$GAME_DIR")
    log="$exedir/OptiScaler.log"
    if [[ -n ${GAME_EXCLUDE_REASON[$appid]:-} ]]; then
        die 1 "refusing to launch-with-override for excluded game $appid: ${GAME_EXCLUDE_REASON[$appid]}"
    fi
    if [[ $exedir != '-' ]] && [[ ! -f $exedir/.retoque/receipt.txt ]]; then
        warn "no override installed for $GAME_NAME — launching the game as-is"
    fi
    local started=$(date +%s)
    if is_epic "$appid"; then
        # EGL v2 URL scheme: com.epicgames.launcher://apps/<appName>
        local app url bin
        app=$(epic_app "$appid")
        url="com.epicgames.launcher://apps/$app?action=launch&silent=true"
        if bin=$(command -v "$EPIC_LAUNCH_CMD" 2>/dev/null); then
            :
        elif command -v xdg-open >/dev/null 2>&1; then
            bin=xdg-open
        else
            die 1 "neither $EPIC_LAUNCH_CMD nor xdg-open found in PATH — cannot launch $appid"
        fi
        say "[+] launching $GAME_NAME via the Epic Games Launcher ($appid)"
        nohup "$bin" "$url" >/dev/null 2>&1 &
    else
        command -v steam >/dev/null 2>&1 || die 1 'steam command not found in PATH'
        local -a args=()
        local stored a
        stored=$(launch_options_for "$appid")
        for a in ${GAME_LAUNCH_ARGS[$appid]:-}; do
            [[ $stored == *"$a"* ]] || args+=("$a")
        done
        if (( ${#args[@]} )); then
            say "[+] launching $GAME_NAME via Steam (appid $appid) with ${args[*]}"
        elif [[ -n $stored ]]; then
            say "[+] launching $GAME_NAME via Steam (appid $appid) (stored launch options: $stored)"
        else
            say "[+] launching $GAME_NAME via Steam (appid $appid)"
        fi
        nohup steam -applaunch "$appid" ${args[@]+"${args[@]}"} >/dev/null 2>&1 &
    fi
    if (( ! opt_verify )); then
        if is_epic "$appid"; then
            say '[+] Epic launch requested; F7 toggles Neural Rendering in game (ToggleKey=0x76)'
        else
            say '[+] Steam launch requested; F7 toggles Neural Rendering in game (ToggleKey=0x76)'
        fi
        return 0
    fi
    # ---- verification: wait for the game process, then judge the fresh log ----
    local exe=${GAME_EXE_NAME[$appid]:-} i proc_up=0
    say "[.] verifying: waiting for the game process (timeout ${opt_timeout}s)"
    for ((i = 0; i < opt_timeout; i += 3)); do
        if [[ -n $exe ]] && pgrep -f "$exe" >/dev/null 2>&1; then proc_up=1; break; fi
        sleep 3
    done
    if (( proc_up )); then
        say "[+] game process is up ($exe)"
    elif [[ -n $exe ]]; then
        warn 'game process not detected — continuing to watch the log anyway'
    fi
    local deadline=$(( $(date +%s) + opt_timeout )) verdict=timeout
    local -a evidence=()
    while (( $(date +%s) < deadline )); do
        if [[ -f $log ]] && [[ $(stat -c %Y "$log" 2>/dev/null || echo 0) -ge $started ]]; then
            if grep -aq 'kernels cannot be loaded' "$log" 2>/dev/null; then
                verdict=model-not-loaded; break
            fi
            if grep -aq 'DLSS-NR running' "$log" 2>/dev/null; then
                verdict=running; break
            fi
            if grep -aq 'DLSS-NR model' "$log" 2>/dev/null; then
                verdict=model-loaded; break
            fi
        fi
        sleep 3
    done
    hr
    case $verdict in
        running)
            say '[PASS] DLSS-NR is running'
            mapfile -t evidence < <(grep -a 'DLSS-NR running' "$log" | tail -n2)
            ;;
        model-loaded)
            say '[PASS] DLSS-NR model messages present'
            mapfile -t evidence < <(grep -a 'DLSS-NR model' "$log" | tail -n3)
            ;;
        model-not-loaded)
            say '[FAIL] the model kernels still cannot be loaded — driver or _nvngx.dll mismatch'
            mapfile -t evidence < <(grep -a 'kernels cannot be loaded\|NOT AVAILABLE' "$log" | tail -n4)
            say '       hints: run doctor; run refresh '"$appid"' (updates the deployed _nvngx.dll);'
            say '       confirm the game is set to the Wineland Proton'
            ;;
        timeout)
            say '[TIMEOUT] no DLSS-NR verdict lines in OptiScaler.log yet'
            say '          the pass only dispatches during gameplay (enter the game world),'
            say '          then check: status '"$appid"' or grep "DLSS-NR" '"$log"
            ;;
    esac
    local line
    for line in "${evidence[@]:-}"; do
        if [[ -n $line ]]; then
            say "  $line"
        fi
    done
    [[ $verdict == running || $verdict == model-loaded ]]
}

# ------------------------------------------------------------------ main ---
[[ $# -ge 1 ]] || usage 1
cmd=$1; shift
case $cmd in
    list)    cmd_list "$@" ;;
    doctor)  cmd_doctor "$@" ;;
    setup)   [[ $# -ge 1 ]] || die 1 'setup: missing appid'; cmd_setup "$@" ;;
    refresh) [[ $# -ge 1 ]] || die 1 'refresh: missing appid'; cmd_setup "$@" ;;
    preset)  [[ $# -ge 2 ]] || die 1 'preset: expected A|B and an appid'; cmd_preset "$@" ;;
    status)  cmd_status "$@" ;;
    restore) [[ $# -ge 1 ]] || die 1 'restore: missing appid'; cmd_restore "$@" ;;
    launch)  [[ $# -ge 1 ]] || die 1 'launch: missing appid'; cmd_launch "$@" ;;
    -h|--help|help) usage 0 ;;
    --version) say "$PROG $VERSION"; exit 0 ;;
    *) usage 1 ;;
esac
