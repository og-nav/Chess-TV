# Third-party assets in ChessUI

## Chess piece artwork

`Sources/ChessUI/Resources/Pieces.xcassets` contains 36 SVG piece images (3 sets × 12 pieces),
downloaded unmodified from the Lichess source repository:

<https://github.com/lichess-org/lila> — `public/piece/<set>/<piece>.svg`
(fetched via `https://cdn.jsdelivr.net/gh/lichess-org/lila@master/public/piece/<set>/<piece>.svg`).

| Set | Asset names | Author | License |
|---|---|---|---|
| `cburnett` | `cburnett_wK` … `cburnett_bP` | Colin M.L. Burnett | **GPLv2 or later** |
| `merida` | `merida_wK` … `merida_bP` | Armando Hernandez Marroquin | **GPLv2 or later** |
| `chessnut` | `chessnut_wK` … `chessnut_bP` | Alexis Luengas | **Apache License 2.0** |

The GPLv2-or-later sets are compatible with distributing this app under GPLv3, which is what the
bundled Stockfish already requires. Full license texts are in the lila repository under
`public/piece-css/` and `COPYING.md`.

Boards are drawn by `BoardView` from plain colors; no Lichess board images are used, because those
are AGPLv3.

## Attribution in the app

The app footer credits "Lichess TV · Stockfish 19 on this Apple TV". If the piece set is ever
shown by name in Settings, keep the set names (Classic/cburnett, Merida, Chessnut) so the origin of
the artwork stays visible.
