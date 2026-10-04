# Third-Party Notices

These components are not owned by Igor Andreevich Gubanov (Губанов Игорь Андреевич) and keep their own licenses.
They are not covered by LICENSE.md or ASSETS_LICENSE.md. In the game: Settings → «Лицензии».

| Component | Where | License | Copyright |
|---|---|---|---|
| Godot Engine 4.7.2 | the engine inside every build | MIT — `tools/release/GODOT_LICENSE.txt`; bundled third-party parts of the engine — `tools/release/GODOT_COPYRIGHT.txt` | Godot Engine contributors; Juan Linietsky, Ariel Manzur |
| Juicee 1.4.2 | `godot/addons/juicee/` | MIT — `godot/addons/juicee/LICENSE.md` | (c) 2026 kelpekk \| frogy |
| sfxr port inside Juicee | `godot/addons/juicee/audio/juicee_sfxr.gd` | public domain | — |
| godot-mcp interaction server (dev only; the script is packed into builds because it is an autoload, but it is disabled there by the "ship" feature and is off in every other run unless opted in via `NECRO_DEV_BRIDGE=1` or `godot/.dev_bridge`) | `godot/scripts/dev/mcp_interaction_server.gd` | MIT — `godot/scripts/dev/GODOT_MCP_LICENSE.txt` | (c) 2025 Tugcan Topaloglu; (c) 2025 Solomon Elias |
| Kenney Particle Pack 1.1, Kenney Light Masks | `godot/assets/vfx/` | CC0 1.0 (both packs; license text shipped with Particle Pack — `godot/assets/vfx/KENNEY_LICENSE.txt`) | Kenney Vleugels (kenney.nl) |
| Underdog font | `godot/assets/fonts/Underdog-Regular.ttf` | SIL OFL 1.1 — `godot/assets/fonts/OFL-Underdog.txt` | (c) 2012 Sergey Steblina, Jovanny Lemonad; Reserved Font Name "Underdog" |
| Neucha font | `godot/assets/fonts/Neucha-Regular.ttf` | SIL OFL 1.1 — `godot/assets/fonts/OFL-Neucha.txt` | (c) 2008–2010 Jovanny Lemonad |

## AI-generated content

Part of the art, music and voice was made with generative tools and services, then selected, edited,
cut and assembled by the author. Rights in the outputs are held under those services' terms.

| What | Tool / service |
|---|---|
| Character, building and map art, cutscenes | Google Nano Banana Pro (via MostAI), OpenAI gpt-image (ChatGPT; C2PA marks in some PNGs), local Z-Image Turbo and Qwen-Image (ComfyUI) |
| Directional character masters and attack contact poses (2026-10-04) | Alibaba Model Studio: Qwen Image 3.0 Pro, Qwen Image Edit Max |
| Directional attacks and deaths (2026-10-04) | Alibaba Model Studio: Wan 2.7 I2V; selected Wan 2.6 I2V Flash clips |
| Directional walks (2026-10-04) | Original scripted IK using the approved character masters; no external motion-capture or pose dataset |
| Some earlier animation in-betweens | RIFE v4.6 frame interpolation (MIT, local) |
| Voice | Google Gemini TTS and ElevenLabs (via MostAI) |
| Menu / battle / boss music | Suno (via MostAI) |
| Victory / defeat music | ACE-Step v1 (Apache 2.0 model, local) |
| UI icons, SVG, procedural effects and sounds | written as code by the author |

## Animation motion reference

The historical skeleton walk pipeline used **Character walking and running animation poses
(8 directions)** by **05p**, Civitai model **56307** (pose data, not a trained model):
https://civitai.com/models/56307

The model's public metadata was checked on 2026-10-04 at
https://civitai.com/api/v1/models/56307: `allowNoCredit=true`, `allowDerivatives=true`,
`allowDifferentLicense=true`, and `allowCommercialUse=[Image, RentCivit, Rent, Sell, SellMerge]`.
These are the uploader's published permission flags, not an independent verification of the
underlying 3D animation's ownership. The unused raw trajectory, its extraction tool and the replaced one-direction character
clips are excluded from the public source snapshot; the raw trajectory and replaced clips
are also excluded from game builds. The current directional walks use an independent
scripted IK pipeline, and the current directional attacks/deaths use the AI sources listed
above. Source hashes, selected video frames and timing are recorded in
`tools/directional_motion_manifests/`; canonical walk masters and rig data are in
`tools/walk_rig_masters/directional/`. Raw generated videos are not bundled.
