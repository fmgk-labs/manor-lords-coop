# Prepare a parallel test lane: its own copy of the game (no mod loader inside; up.sh installs one) and its own save
# profile with the test saves, with the frame rate capped so several lanes can run beside the user's own work.
#   LANE=n sh tools/dev/lane_setup.sh
. "$(dirname "$0")/env.sh"
[ "$LANE" != "0" ] || { echo "lane 0 is the lead's copy (_ml_test); give LANE=1..9"; exit 1; }
SRC="$(cygpath -w "$(cygpath -u "$ML_TEST_ROOT")/_ml_test")"; DST="$(cygpath -w "$TROOT")"      # from the lead's test copy (local.env)
if [ ! -f "$TG/ManorLords-Win64-Shipping.exe" ]; then
  [ -f "$(cygpath -u "$SRC")/ManorLords/Binaries/Win64/ManorLords-Win64-Shipping.exe" ] || { echo "no lead test copy at $SRC (tools/dev/README.md, First-time setup)"; exit 1; }
  powershell -NoProfile -Command "robocopy '$SRC' '$DST' /E /MT:16 /XD ue4ss /NFL /NDL /NJH /NJS /NP | Out-Null; 'game copy for lane $LANE ready'"
fi
BASE="$(cygpath -u "$LOCALAPPDATA")/ManorLords/Saved_Coop"
mkdir -p "$SAVES/SaveGames" "$SAVES/Config"
cp -n "$BASE/SaveGames/"coop_test_1* "$BASE/SaveGames/"coop_test_2* "$BASE/SaveGames/"coop_test_rich* "$BASE/SaveGames/"saveGame_2* "$BASE/SaveGames/"menu.sav "$BASE/SaveGames/"rtsSettings.sav "$SAVES/SaveGames/" 2>/dev/null
cp -rn "$BASE/Config/"* "$SAVES/Config/" 2>/dev/null
echo "lane $LANE: game $TG ; saves $(ls "$SAVES/SaveGames" | grep -c "\.sav") files in $SAVES"
