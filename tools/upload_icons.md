# Icon uploads

`Config.Icons` holds Roblox asset ids, not file paths — a local PNG cannot be
referenced at runtime, so every icon the game draws had to be uploaded to the
owner's account once. This file records which source file is behind each id so
they can be re-uploaded (to a different account, or at a different size)
without guessing.

Source: **Free Icon Pack 3.0.1 (Basic)** — Swarve Studios. All are the 256px
`1st Outline` variants, which carry the thick black outline that matches the
game's plaque and sign styling.

| `Config.Icons` key | Asset id | Source file in the pack |
|---|---|---|
| `Upgrade` | `86014261095925` | `Main/Upgrade/256px/Golden Upgrade 1st Outline 256px.png` |
| `House` | `118336776033036` | `Main/House/256px/Red House 1st Outline 256px.png` |
| `Cash` | `98948172539240` | `Currency/Cash/256px/Green Cash 1st Outline 256px.png` |
| `Gift` | `125895167437717` | `Item/Gift/256px/Green Gift 1st Outline 256px.png` |
| `Calendar` | `76476455943304` | `Item/Calendar/256px/Calendar 1st Outline 256px.png` |
| `Lock` | `84394998921158` | `Item/Lock/256px/Lock 1st Outline 256px.png` |
| `Shield` | `73099523361961` | `Item/Shield/256px/Shield 1st Outline 256px.png` |
| `Star` | `135507557051697` | `Main/Star/256px/Golden Star 1st Outline 256px.png` |
| `Coil` | `77650920811206` | `Item/Coil/256px/Blue Coil 1st Outline 256px.png` |
| `Wheel` | `91374848059044` | `Main/Wheel/256px/Wheel 1st Outline 256px.png` |

## Where each one is used

| Key | Drawn by |
|---|---|
| `Upgrade` | the arrow on the podium upgrade plaque (`PlotService`) |
| `House` | the marker floating over every base, and the vacant-plot sign (`BaseBuilder`) |
| `Lock` | slot unlock pads and the next-floor post (`PlotService`) |
| `Cash` / `Wheel` / `Gift` | the seven daily reward cards, one per reward kind (`DailyUi`) |
| `Calendar`, `Shield`, `Star`, `Coil` | uploaded and ready; not drawn yet (see below) |

`Shield` and `Lock` are the icons the Slap Protection and Lock Base game passes
will use once those pass ids exist. `Calendar`, `Star` and `Coil` are staged for
the daily-rewards HUD button, event board and speed-coil gear.

## Re-uploading

`upload_image` in the Studio MCP takes HTTP URLs, not local paths, so the files
have to be served first. `tools/iconserver.ps1` is the throwaway static server
used for this — run it, then point `upload_image` at
`http://localhost:8731/<name>.png`.
